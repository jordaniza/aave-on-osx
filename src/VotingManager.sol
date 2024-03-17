import {SafeCast} from "@oz/utils/math/SafeCast.sol";
import {IVotes} from "@oz/governance/utils/IVotes.sol";
import {IERC20} from "@oz/token/ERC20/IERC20.sol";
import {IMajorityVoting} from "@aragon/osx/plugins/governance/majority-voting/IMajorityVoting.sol";
import {IDAO} from "@aragon/osx/core/dao/IDAO.sol";
import {RATIO_BASE, RatioOutOfBounds} from "@aragon/osx/plugins/utils/Ratio.sol";
import {IProposalManager} from "./ProposalManager.sol";

interface ITokenVotingManager {
    function setProposalManager(address _proposalManager) external;
}

interface IVotingManager {
    /// @notice The different voting modes available.
    /// @param Standard In standard mode, early execution and vote replacement are disabled.
    /// @param EarlyExecution In early execution mode, a proposal can be executed early before the end date if the vote outcome cannot mathematically change by more voters voting.
    /// @param VoteReplacement In vote replacement mode, voters can change their vote multiple times and only the latest vote option is tallied.
    enum VotingMode {
        Standard,
        EarlyExecution,
        VoteReplacement
    }

    /// @notice A container for the majority voting settings that will be applied as parameters on proposal creation.
    /// @param votingMode A parameter to select the vote mode. In standard mode (0), early execution and vote replacement are disabled. In early execution mode (1), a proposal can be executed early before the end date if the vote outcome cannot mathematically change by more voters voting. In vote replacement mode (2), voters can change their vote multiple times and only the latest vote option is tallied.
    /// @param supportThreshold The support threshold value. Its value has to be in the interval [0, 10^6] defined by `RATIO_BASE = 10**6`.
    /// @param minParticipation The minimum participation value. Its value has to be in the interval [0, 10^6] defined by `RATIO_BASE = 10**6`.
    /// @param minDuration The minimum duration of the proposal vote in seconds.
    /// @param minProposerVotingPower The minimum voting power required to create a proposal.
    struct VotingSettings {
        VotingMode votingMode;
        uint32 supportThreshold;
        uint32 minParticipation;
        uint64 minDuration;
        uint256 minProposerVotingPower;
    }

    /// @notice A container for proposal-related information.
    /// @param proposalId The ID of the proposal, numerical and incrementing from 0
    /// @param tally The vote tally of the proposal.
    /// @param voters The votes casted by the voters.
    struct ProposalVotes {
        uint proposalId;
        Tally tally;
        ProposalVotingParameters parameters;
        mapping(address voter => IMajorityVoting.VoteOption option) voters;
    }

    /// @notice A container for the proposal parameters at the time of proposal creation.
    /// @param votingMode A parameter to select the vote mode.
    /// @param supportThreshold The support threshold value. The value has to be in the interval [0, 10^6] defined by `RATIO_BASE = 10**6`.
    /// @param startDate The start date of the proposal vote.
    /// @param endDate The end date of the proposal vote.
    /// @param snapshotBlock The number of the block prior to the proposal creation.
    /// @param minVotingPower The minimum voting power needed.
    struct ProposalVotingParameters {
        VotingMode votingMode;
        uint32 supportThreshold;
        uint256 minVotingPower;
    }

    /// @notice A container for the proposal vote tally.
    /// @param abstain The number of abstain votes casted.
    /// @param yes The number of yes votes casted.
    /// @param no The number of no votes casted.
    struct Tally {
        uint256 abstain;
        uint256 yes;
        uint256 no;
    }

    /// @notice Thrown if a date is out of bounds.
    /// @param limit The limit value.
    /// @param actual The actual value.
    error DateOutOfBounds(uint64 limit, uint64 actual);

    /// @notice Thrown if the minimal duration value is out of bounds (less than one hour or greater than 1 year).
    /// @param limit The limit value.
    /// @param actual The actual value.
    error MinDurationOutOfBounds(uint64 limit, uint64 actual);

    /// @notice Thrown when a sender is not allowed to create a proposal.
    /// @param sender The sender address.
    error ProposalCreationForbidden(address sender);

    /// @notice Thrown if an account is not allowed to cast a vote. This can be because the vote
    /// - has not started,
    /// - has ended,
    /// - was executed, or
    /// - the account doesn't have voting powers.
    /// @param proposalId The ID of the proposal.
    /// @param account The address of the _account.
    /// @param voteOption The chosen vote option.
    error VoteCastForbidden(
        uint256 proposalId,
        address account,
        IMajorityVoting.VoteOption voteOption
    );

    /// @notice Thrown if the proposal execution is forbidden.
    /// @param proposalId The ID of the proposal.
    error ProposalExecutionForbidden(uint256 proposalId);

    error NotProposalManager(address sender, address proposalManager);

    /// @notice Emitted when the voting settings are updated.
    /// @param votingMode A parameter to select the vote mode.
    /// @param supportThreshold The support threshold value.
    /// @param minParticipation The minimum participation value.
    /// @param minDuration The minimum duration of the proposal vote in seconds.
    /// @param minProposerVotingPower The minimum voting power required to create a proposal.
    event VotingSettingsUpdated(
        VotingMode votingMode,
        uint32 supportThreshold,
        uint32 minParticipation,
        uint64 minDuration,
        uint256 minProposerVotingPower
    );

    /// Gated to proposal manager and can be subsequently gated to the DAO

    function setVotingToken(IVotes _votingToken) external;
}

contract TokenVotingManager is IVotingManager {
    using SafeCast for uint256;

    /// @notice The [ERC-165](https://eips.ethereum.org/EIPS/eip-165) interface ID of the contract.
    bytes4 internal constant MAJORITY_VOTING_BASE_INTERFACE_ID =
        this.minDuration.selector ^
            this.minProposerVotingPower.selector ^
            this.votingMode.selector ^
            this.totalVotingPower.selector ^
            // this.getProposal.selector ^
            this.updateVotingSettings.selector;
    // this.createProposal.selector;

    /// @notice The ID of the permission required to call the `updateVotingSettings` function.
    bytes32 public constant UPDATE_VOTING_SETTINGS_PERMISSION_ID =
        keccak256("UPDATE_VOTING_SETTINGS_PERMISSION");

    /// @notice A mapping between proposal IDs and proposal information.
    mapping(uint256 => ProposalVotes) internal proposalVotes;

    address public proposalManager;
    IVotes public votingToken;

    /// @notice The struct storing the voting settings.
    VotingSettings private votingSettings;

    // could change this to DAO
    modifier onlyProposalManager() {
        if (msg.sender != proposalManager) {
            revert NotProposalManager({sender: msg.sender, proposalManager: proposalManager});
        }
        _;
    }

    /// @param _proposalManager The address of the proposal manager.
    /// @param _dao The IDAO interface of the associated DAO.
    /// @param _votingSettings The voting settings.
    constructor(
        address _proposalManager,
        IDAO _dao,
        VotingSettings memory _votingSettings,
        IVotes _votingToken
    ) {
        proposalManager = _proposalManager;
        votingToken = _votingToken;
        // __PluginUUPSUpgradeable_init(_dao);
        // init the plugin one the DAO
        _updateVotingSettings(_votingSettings);
    }

    function setProposalManager(address _proposalManager) external onlyProposalManager {
        proposalManager = _proposalManager;
    }

    function setVotingToken(IVotes _votingToken) external onlyProposalManager {
        votingToken = _votingToken;
    }

    function vote(
        uint256 _proposalId,
        IMajorityVoting.VoteOption _voteOption
    ) public virtual onlyProposalManager {
        // address account = _msgSender();
        address account = msg.sender;
        _vote(_proposalId, _voteOption, account);
    }

    function getVoteOption(
        uint256 _proposalId,
        address _voter
    ) public view virtual returns (IMajorityVoting.VoteOption) {
        return proposalVotes[_proposalId].voters[_voter];
    }

    function isSupportThresholdReached(uint256 _proposalId) public view virtual returns (bool) {
        ProposalVotes storage proposal_ = proposalVotes[_proposalId];

        // The code below implements the formula of the support criterion explained in the top of this file.
        // `(1 - supportThreshold) * N_yes > supportThreshold *  N_no`
        return
            (RATIO_BASE - proposal_.parameters.supportThreshold) * proposal_.tally.yes >
            proposal_.parameters.supportThreshold * proposal_.tally.no;
    }

    function isSupportThresholdReachedEarly(
        uint256 _proposalId
    ) public view virtual returns (bool) {
        ProposalVotes storage proposalVotes_ = proposalVotes[_proposalId];
        IProposalManager.Proposal memory proposal_ = IProposalManager(proposalManager).getProposal(
            _proposalId
        );

        uint256 noVotesWorstCase = totalVotingPower(proposal_.parameters.snapshotBlock) -
            proposalVotes_.tally.yes -
            proposalVotes_.tally.abstain;

        // The code below implements the formula of the early execution support criterion explained in the top of this file.
        // `(1 - supportThreshold) * N_yes > supportThreshold *  N_no,worst-case`
        return
            (RATIO_BASE - proposalVotes_.parameters.supportThreshold) * proposalVotes_.tally.yes >
            proposalVotes_.parameters.supportThreshold * noVotesWorstCase;
    }

    function isMinParticipationReached(uint256 _proposalId) public view virtual returns (bool) {
        ProposalVotes storage proposal_ = proposalVotes[_proposalId];

        // The code below implements the formula of the participation criterion explained in the top of this file.
        // `N_yes + N_no + N_abstain >= minVotingPower = minParticipation * N_total`
        return
            proposal_.tally.yes + proposal_.tally.no + proposal_.tally.abstain >=
            proposal_.parameters.minVotingPower;
    }

    function supportThreshold() public view virtual returns (uint32) {
        return votingSettings.supportThreshold;
    }

    function minParticipation() public view virtual returns (uint32) {
        return votingSettings.minParticipation;
    }

    /// @notice Returns the minimum duration parameter stored in the voting settings.
    /// @return The minimum duration parameter.
    function minDuration() public view virtual returns (uint64) {
        return votingSettings.minDuration;
    }

    /// @notice Returns the minimum voting power required to create a proposal stored in the voting settings.
    /// @return The minimum voting power required to create a proposal.
    function minProposerVotingPower() public view virtual returns (uint256) {
        return votingSettings.minProposerVotingPower;
    }

    /// @notice Returns the vote mode stored in the voting settings.
    /// @return The vote mode parameter.
    function votingMode() public view virtual returns (VotingMode) {
        return votingSettings.votingMode;
    }

    function isMember(address _account) external view returns (bool) {
        // A member must own at least one token or have at least one token delegated to her/him.
        return
            votingToken.getVotes(_account) > 0 ||
            IERC20(address(votingToken)).balanceOf(_account) > 0;
    }

    /// @notice getter function for the voting token.
    /// @dev public function also useful for registering interfaceId and for distinguishing from majority voting interface.
    /// @return The token used for voting.
    function getVotingToken() public view returns (IVotes) {
        return votingToken;
    }

    function totalVotingPower(uint256 _blockNumber) public view returns (uint256) {
        return votingToken.getPastTotalSupply(_blockNumber);
    }

    /// @notice Updates the voting settings.
    /// @param _votingSettings The new voting settings.
    function updateVotingSettings(
        VotingSettings calldata _votingSettings
    ) external virtual onlyProposalManager {
        _updateVotingSettings(_votingSettings);
    }

    /// @notice Internal function to cast a vote. It assumes the queried vote exists.
    /// @param _proposalId The ID of the proposal.
    /// @param _voteOption The chosen vote option to be casted on the proposal vote.
    function _vote(
        uint256 _proposalId,
        IMajorityVoting.VoteOption _voteOption,
        address _voter
    ) internal virtual {
        ProposalVotes storage proposalVotes_ = proposalVotes[_proposalId];
        IProposalManager.Proposal memory proposal_ = IProposalManager(proposalManager).getProposal(
            _proposalId
        );

        // This could re-enter, though we can assume the governance token is not malicious
        // @dev so why not add reentrancy guard?
        uint256 votingPower = votingToken.getPastVotes(_voter, proposal_.parameters.snapshotBlock);
        IMajorityVoting.VoteOption state = proposalVotes_.voters[_voter];

        // If voter had previously voted, decrease count
        if (state == IMajorityVoting.VoteOption.Yes) {
            proposalVotes_.tally.yes = proposalVotes_.tally.yes - votingPower;
        } else if (state == IMajorityVoting.VoteOption.No) {
            proposalVotes_.tally.no = proposalVotes_.tally.no - votingPower;
        } else if (state == IMajorityVoting.VoteOption.Abstain) {
            proposalVotes_.tally.abstain = proposalVotes_.tally.abstain - votingPower;
        }

        // write the updated/new vote for the voter.
        if (_voteOption == IMajorityVoting.VoteOption.Yes) {
            proposalVotes_.tally.yes = proposalVotes_.tally.yes + votingPower;
        } else if (_voteOption == IMajorityVoting.VoteOption.No) {
            proposalVotes_.tally.no = proposalVotes_.tally.no + votingPower;
        } else if (_voteOption == IMajorityVoting.VoteOption.Abstain) {
            proposalVotes_.tally.abstain = proposalVotes_.tally.abstain + votingPower;
        }

        proposalVotes_.voters[_voter] = _voteOption;

        emit IMajorityVoting.VoteCast({
            proposalId: _proposalId,
            voter: _voter,
            voteOption: _voteOption,
            votingPower: votingPower
        });
    }

    /// @notice Internal function to update the plugin-wide proposal vote settings.
    /// @param _votingSettings The voting settings to be validated and updated.
    function _updateVotingSettings(VotingSettings memory _votingSettings) internal virtual {
        // Require the support threshold value to be in the interval [0, 10^6-1], because `>` comparision is used in the support criterion and >100% could never be reached.
        if (_votingSettings.supportThreshold > RATIO_BASE - 1) {
            revert RatioOutOfBounds({
                limit: RATIO_BASE - 1,
                actual: _votingSettings.supportThreshold
            });
        }

        // Require the minimum participation value to be in the interval [0, 10^6], because `>=` comparision is used in the participation criterion.
        if (_votingSettings.minParticipation > RATIO_BASE) {
            revert RatioOutOfBounds({limit: RATIO_BASE, actual: _votingSettings.minParticipation});
        }

        if (_votingSettings.minDuration < 60 minutes) {
            revert MinDurationOutOfBounds({limit: 60 minutes, actual: _votingSettings.minDuration});
        }

        if (_votingSettings.minDuration > 365 days) {
            revert MinDurationOutOfBounds({limit: 365 days, actual: _votingSettings.minDuration});
        }

        votingSettings = _votingSettings;

        emit VotingSettingsUpdated({
            votingMode: _votingSettings.votingMode,
            supportThreshold: _votingSettings.supportThreshold,
            minParticipation: _votingSettings.minParticipation,
            minDuration: _votingSettings.minDuration,
            minProposerVotingPower: _votingSettings.minProposerVotingPower
        });
    }
}
