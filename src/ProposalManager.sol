// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.24;

import {Plugin, IDAO} from "@aragon/osx/core/plugin/Plugin.sol";
import {IProposal} from "@aragon/osx/core/plugin/proposal/IProposal.sol";
import {SafeCast} from "@oz/utils/math/SafeCast.sol";

interface IProposalCreateValidator {
    function canCreate(address _sender, bytes calldata _data) external view returns (bool);

    error NotAuthorizedToCreate(address sender, bytes data);
}

interface IProposalVetoValidator {
    function canVeto(address _sender, bytes calldata _data) external view returns (bool);

    error NotAuthorizedToVeto(address sender, bytes data);
}

contract OSXAuth {
    modifier auth(bytes32 _role) {
        require(msg.sender == address(this), "OSXAuth: not authorized");
        _;
    }
}

interface IProposalManager {
    struct Proposal {
        bool executed;
        ProposalParameters parameters;
        IDAO.Action[] actions;
        uint256 allowFailureMap;
        bool cancelled;
    }

    /// @notice A container for the proposal parameters at the time of proposal creation.
    /// @param votingMode A parameter to select the vote mode.
    /// @param supportThreshold The support threshold value.
    /// The value has to be in the interval [0, 10^6] defined by `RATIO_BASE = 10**6`.
    /// @param startDate The start date of the proposal vote.
    /// @param endDate The end date of the proposal vote.
    /// @param snapshotBlock The number of the block prior to the proposal creation.
    /// @param minVotingPower The minimum voting power needed.
    struct ProposalParameters {
        uint64 startDate;
        uint64 endDate;
        uint64 snapshotBlock;
    }

    function getProposal(uint256 _proposalId) external view returns (Proposal memory proposal);
}

contract ProposalManager is IProposal, IProposalManager, OSXAuth {
    using SafeCast for uint256;
    bytes32 public constant SET_CREATE_VALIDATOR_ROLE = keccak256("SET_CREATE_VALIDATOR_ROLE");
    bytes32 public constant SET_VETO_VALIDATOR_ROLE = keccak256("SET_VETO_VALIDATOR_ROLE");

    uint _proposalCount;
    Proposal[] public proposals;

    /// @notice Thrown if a date is out of bounds.
    /// @param limit The limit value.
    /// @param actual The actual value.
    error DateOutOfBounds(uint64 limit, uint64 actual);

    IProposalCreateValidator createValidator;
    IProposalVetoValidator vetoValidator;

    function proposalCount() external view returns (uint256) {
        return _proposalCount;
    }

    function setCreateValidator(
        IProposalCreateValidator _createValidator
    ) external auth("SET_CREATE_VALIDATOR_ROLE") {
        createValidator = _createValidator;
    }

    function setVetoValidator(
        IProposalVetoValidator _vetoValidator
    ) external auth("SET_VETO_VALIDATOR_ROLE") {
        vetoValidator = _vetoValidator;
    }

    function createProposal(
        bytes calldata _metadata,
        IDAO.Action[] calldata _actions,
        uint256 _allowFailureMap,
        uint64 _startDate,
        uint64 _endDate,
        bytes memory _supportData /* used for canCreate */
    ) external returns (uint256 proposalId) {
        if (!createValidator.canCreate(msg.sender, _supportData)) {
            revert IProposalCreateValidator.NotAuthorizedToCreate(msg.sender, _supportData);
        }

        (_startDate, _endDate) = _validateProposalDates(_startDate, _endDate);

        proposalId = _createProposal({
            _creator: msg.sender,
            _metadata: _metadata,
            _startDate: _startDate,
            _endDate: _endDate,
            _actions: _actions,
            _allowFailureMap: _allowFailureMap
        });

        // Store proposal related information
        Proposal storage proposal_ = proposals[proposalId];

        uint256 snapshotBlock;
        unchecked {
            // The snapshot block must be mined already to
            // protect the transaction against backrunning transactions causing census changes.
            snapshotBlock = block.number - 1;
        }

        proposal_.parameters.startDate = _startDate;
        proposal_.parameters.endDate = _endDate;

        proposal_.parameters.snapshotBlock = snapshotBlock.toUint64();

        // Reduce costs
        if (_allowFailureMap != 0) {
            proposal_.allowFailureMap = _allowFailureMap;
        }

        for (uint256 i; i < _actions.length; ) {
            proposal_.actions.push(_actions[i]);
            unchecked {
                ++i;
            }
        }
    }

    function vetoProposal(uint256 _proposalId, bytes calldata _vetoData) external {
        if (!vetoValidator.canVeto(msg.sender, _vetoData)) {
            revert IProposalVetoValidator.NotAuthorizedToVeto(msg.sender, _vetoData);
        }

        Proposal storage proposal_ = proposals[_proposalId];
        // bit of a  hack because currently no concept of cancelled
        proposal_.executed = true;
    }

    /// @notice Creates a proposal ID.
    /// @return proposalId The proposal ID.
    function _createProposalId() internal returns (uint256 proposalId) {
        proposalId = _proposalCount;
        _proposalCount++;
    }

    /// @notice Internal function to create a proposal.
    /// @param _metadata The proposal metadata.
    /// @param _startDate The start date of the proposal in seconds.
    /// @param _endDate The end date of the proposal in seconds.
    /// @param _allowFailureMap A bitmap allowing the proposal to succeed, even if individual actions might revert. If the bit at index `i` is 1, the proposal succeeds even if the `i`th action reverts. A failure map value of 0 requires every action to not revert.
    /// @param _actions The actions that will be executed after the proposal passes.
    /// @return proposalId The ID of the proposal.
    function _createProposal(
        address _creator,
        bytes calldata _metadata,
        uint64 _startDate,
        uint64 _endDate,
        IDAO.Action[] calldata _actions,
        uint256 _allowFailureMap
    ) internal virtual returns (uint256 proposalId) {
        proposalId = _createProposalId();

        emit ProposalCreated({
            proposalId: proposalId,
            creator: _creator,
            metadata: _metadata,
            startDate: _startDate,
            endDate: _endDate,
            actions: _actions,
            allowFailureMap: _allowFailureMap
        });
    }

    /// @notice Validates and returns the proposal vote dates.
    /// @param _start The start date of the proposal vote.
    /// If 0, the current timestamp is used and the vote starts immediately.
    /// @param _end The end date of the proposal vote. If 0, `_start + minDuration` is used.
    /// @return startDate The validated start date of the proposal vote.
    /// @return endDate The validated end date of the proposal vote.
    function _validateProposalDates(
        uint64 _start,
        uint64 _end
    ) internal view virtual returns (uint64 startDate, uint64 endDate) {
        uint64 currentTimestamp = block.timestamp.toUint64();

        if (_start == 0) {
            startDate = currentTimestamp;
        } else {
            startDate = _start;

            if (startDate < currentTimestamp) {
                revert DateOutOfBounds({limit: currentTimestamp, actual: startDate});
            }
        }

        if (_end == 0) {
            endDate = startDate + 1 weeks;
        } else if (_end < startDate) {
            endDate = _end;
            revert DateOutOfBounds({limit: startDate, actual: _end});
        }
    }

    /// @notice Internal function to check if a proposal vote is still open.
    /// @param proposal_ The proposal struct.
    /// @return True if the proposal vote is open, false otherwise.
    function _isProposalOpen(Proposal storage proposal_) internal view virtual returns (bool) {
        uint64 currentTime = block.timestamp.toUint64();

        return
            proposal_.parameters.startDate <= currentTime &&
            currentTime < proposal_.parameters.endDate &&
            !proposal_.executed;
    }

    /// @notice Returns all information for a proposal vote by its ID.
    /// @param _proposalId The ID of the proposal.
    /// @dev TODO: call voting status from votingmanager?
    function getProposal(uint256 _proposalId) public view virtual returns (Proposal memory) {
        return proposals[_proposalId];
    }
}

/// @title IMajorityVoting
/// @author Aragon Association - 2022-2023
/// @notice The interface of majority voting plugin.
/// @custom:security-contact sirt@aragon.org
interface IMajorityVoting {
    /// @notice Vote options that a voter can chose from.
    /// @param None The default option state of a voter indicating the absence from the vote.
    /// This option neither influences support nor participation.
    /// @param Abstain This option does not influence the support but counts towards participation.
    /// @param Yes This option increases the support and counts towards participation.
    /// @param No This option decreases the support and counts towards participation.
    enum VoteOption {
        None,
        Abstain,
        Yes,
        No
    }

    /// @notice Emitted when a vote is cast by a voter.
    /// @param proposalId The ID of the proposal.
    /// @param voter The voter casting the vote.
    /// @param voteOption The casted vote option.
    /// @param votingPower The voting power behind this vote.
    event VoteCast(
        uint256 indexed proposalId,
        address indexed voter,
        VoteOption voteOption,
        uint256 votingPower
    );

    /// @notice Returns the support threshold parameter stored in the voting settings.
    /// @return The support threshold parameter.
    function supportThreshold() external view returns (uint32);

    /// @notice Returns the minimum participation parameter stored in the voting settings.
    /// @return The minimum participation parameter.
    function minParticipation() external view returns (uint32);

    /// @notice Checks if the support value defined as:
    /// $$\texttt{support} = \frac{N_\text{yes}}{N_\text{yes}+N_\text{no}}$$
    /// for a proposal vote is greater than the support threshold.
    /// @param _proposalId The ID of the proposal.
    /// @return Returns `true` if the  support is greater than the support threshold and `false` otherwise.
    function isSupportThresholdReached(uint256 _proposalId) external view returns (bool);

    /// @notice Checks if the worst-case support value defined as:
    /// $$\texttt{worstCaseSupport} = \frac{N_\text{yes}}{ N_\text{total}-N_\text{abstain}}$$
    /// for a proposal vote is greater than the support threshold.
    /// @param _proposalId The ID of the proposal.
    /// @return Returns `true` if the worst-case support is greater than the support threshold and `false` otherwise.
    function isSupportThresholdReachedEarly(uint256 _proposalId) external view returns (bool);

    /// @notice Checks if the participation value defined as:
    /// $$\texttt{participation} = \frac{N_\text{yes}+N_\text{no}+N_\text{abstain}}{N_\text{total}}$$
    /// for a proposal vote is greater or equal than the minimum participation value.
    /// @param _proposalId The ID of the proposal.
    /// @return Returns `true` if the participation is greater than the minimum participation and `false` otherwise.
    function isMinParticipationReached(uint256 _proposalId) external view returns (bool);

    /// @notice Checks if an account can participate on a proposal vote. This can be because the vote
    /// - has not started,
    /// - has ended,
    /// - was executed, or
    /// - the voter doesn't have voting powers.
    /// @param _proposalId The proposal Id.
    /// @param _account The account address to be checked.
    /// @param  _voteOption Whether the voter abstains, supports or opposes the proposal.
    /// @return Returns true if the account is allowed to vote.
    /// @dev The function assumes the queried proposal exists.
    function canVote(
        uint256 _proposalId,
        address _account,
        VoteOption _voteOption
    ) external view returns (bool);

    /// @notice Checks if a proposal can be executed.
    /// @param _proposalId The ID of the proposal to be checked.
    /// @return True if the proposal can be executed, false otherwise.
    function canExecute(uint256 _proposalId) external view returns (bool);

    /// @notice Executes a proposal.
    /// @param _proposalId The ID of the proposal to be executed.
    function execute(uint256 _proposalId) external;
}
