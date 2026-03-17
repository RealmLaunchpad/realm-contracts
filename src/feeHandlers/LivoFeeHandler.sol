// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILivoFeeHandler} from "src/interfaces/ILivoFeeHandler.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";

/// @title LivoFeeHandler
/// @notice Fee handler with pending-claims tracking, reentrancy protection, and excess ETH sweep.
contract LivoFeeHandler is ILivoFeeHandler, Ownable, ReentrancyGuardTransient {
    /// @notice claimable eth per account associated to a token
    /// @dev claims are per token to not force an account to claim all-or-none
    mapping(address token => mapping(address account => uint256 amount)) internal _pendingClaims;

    /// @notice Sum of all pending creator claims (used to identify excess/stuck ETH)
    uint256 internal totalPendingCreatorClaims;

    constructor() Ownable(msg.sender) {}

    ////////////////////////////// EXTERNAL FUNCTIONS ///////////////////////////////////

    /// @notice Deposits ETH fees for a token's fee receiver, tracking total pending claims
    function depositFees(address token, address feeReceiver) external payable {
        _pendingClaims[token][feeReceiver] += msg.value;
        totalPendingCreatorClaims += msg.value;
        emit CreatorFeesDeposited(token, feeReceiver, msg.value);
    }

    /// @notice Claims accumulated ETH fees for msg.sender from the provided `tokens`
    function claim(address[] calldata tokens) external nonReentrant {
        uint256 claimable;
        uint256 nTokens = tokens.length;

        for (uint256 i = 0; i < nTokens; i++) {
            address token = tokens[i];

            uint256 tokenClaimable = _pendingClaims[token][msg.sender];
            if (tokenClaimable == 0) continue;

            claimable += tokenClaimable;
            delete _pendingClaims[token][msg.sender];

            emit CreatorClaimed(token, msg.sender, tokenClaimable);
        }

        if (claimable == 0) return;

        totalPendingCreatorClaims -= claimable;
        _transferEth(msg.sender, claimable);
    }

    /// @notice Sweeps excess ETH (donations, dust) to a recipient. Only callable by owner.
    function sweepExcessEth(address recipient) external onlyOwner {
        uint256 excess = address(this).balance - totalPendingCreatorClaims;
        if (excess > 0) {
            _transferEth(recipient, excess);
        }
    }

    ////////////////////////////// VIEW FUNCTIONS ///////////////////////////////////

    /// @notice Returns the pending claimable ETH fees for an account across the given tokens
    /// @param tokens Array of token addresses
    /// @param receiver Address for which pending claimable amounts are computed
    /// @return creatorClaimable Array of claimable ETH amounts per token for `receiver`
    function getClaimable(address[] calldata tokens, address receiver)
        external
        view
        returns (uint256[] memory creatorClaimable)
    {
        uint256 nTokens = tokens.length;
        creatorClaimable = new uint256[](nTokens);

        for (uint256 i = 0; i < nTokens; i++) {
            creatorClaimable[i] = _pendingClaims[tokens[i]][receiver];
        }
    }

    ///////////////////////// INTERNAL //////////////////////////

    /// @notice Transfers ETH to a recipient, reverting on failure
    function _transferEth(address recipient, uint256 amount) internal {
        if (amount == 0) return;
        (bool success,) = recipient.call{value: amount}("");
        require(success, EthTransferFailed());
    }
}
