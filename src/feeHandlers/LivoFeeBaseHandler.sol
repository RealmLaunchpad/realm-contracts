// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILivoFeeHandler} from "src/interfaces/ILivoFeeHandler.sol";

contract LivoFeeBaseHandler is ILivoFeeHandler {
    mapping(address token => mapping(address account => uint256 amount)) pendingClaims;

    function depositFees(address token, address feeReceiver) external payable {
        pendingClaims[token][feeReceiver] += msg.value;
        emit FeesDeposited(token, feeReceiver, msg.value);
    }

    /// @notice Claims accumulated ETH fees for msg.sender from the provided `tokens`
    /// @dev claiming per token is less gas efficient than bulk claiming all tokens together in one balance. 
    ///         However, if we'd do that, we would be forcing users to claim from all tokens at once, even from the ones they don't endorse
    function claim(address[] calldata tokens) external {
        uint256 claimable;
        uint256 nTokens = tokens.length;

        for (uint256 i = 0; i < nTokens; i++) {
            address token = tokens[i];
            uint256 tokenClaimable = pendingClaims[token][msg.sender];
            if (tokenClaimable == 0) continue;

            claimable += tokenClaimable;
            delete pendingClaims[token][msg.sender];

            emit CreatorClaimed(token, msg.sender, tokenClaimable);
        }

        if (claimable == 0) return;

        (bool success,) = msg.sender.call{value: claimable}("");
        require(success, EthTransferFailed());
    }

    /// @dev This doesn't include non-accrued LP fees that are sitting in the LP position
    function getClaimable(address token, address account) external view returns (uint256) {
        return pendingClaims[token][account];
    }
}
