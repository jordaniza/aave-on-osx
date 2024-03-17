pragma solidity 0.8.24;

import {IProposalCreateValidator} from "../ProposalManager.sol";
import {TokenVotingManager} from "../VotingManager.sol";
import {IERC20} from "@oz/token/ERC20/IERC20.sol";
import {IVotes} from "@oz/governance/utils/IVotes.sol";

contract TokenGatingProposalValidator is IProposalCreateValidator {
    TokenVotingManager public immutable votingManager;

    constructor(address _votingManager) {
        votingManager = TokenVotingManager(_votingManager);
    }

    function canCreate(address _sender, bytes calldata) external view returns (bool success) {
        // Check that either `_msgSender` owns enough tokens or has enough voting power from being a delegatee.
        {
            uint256 minProposerVotingPower_ = votingManager.minProposerVotingPower();

            if (minProposerVotingPower_ != 0) {
                IVotes votingToken = votingManager.votingToken();
                // Because of the checks in `TokenVotingSetup`, we can assume that `votingToken` is an [ERC-20](https://eips.ethereum.org/EIPS/eip-20) token.
                if (
                    votingToken.getVotes(_sender) < minProposerVotingPower_ &&
                    IERC20(address(votingToken)).balanceOf(_sender) < minProposerVotingPower_
                ) {
                    return false;
                }
            }
        }

        uint256 snapshotBlock;
        unchecked {
            snapshotBlock = block.number - 1; // The snapshot block must be mined already to protect the transaction against backrunning transactions causing census changes.
        }

        uint256 totalVotingPower_ = votingManager.totalVotingPower(snapshotBlock);

        if (totalVotingPower_ == 0) {
            return false;
        }

        return true;
    }
}
