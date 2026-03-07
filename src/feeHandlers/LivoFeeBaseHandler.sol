// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILivoFeeHandler} from "src/interfaces/ILivoFeeHandler.sol";

contract LivoFeeBaseHandler is ILivoFeeHandler {
    /// @notice claimable eth per account associated to a token
    /// @dev claims are per token to not force an account to claim all-or-none
    mapping(address token => mapping(address account => uint256 amount)) pendingClaims;

    /// @notice Returns the address that should own LP position NFTs
    function lpFeesPositionOwner() external view virtual returns (address) {
        return address(this);
    }

    /// @notice Deposits ETH fees for a token's fee receiver
    function depositFees(address token, address feeReceiver) external payable {
        pendingClaims[token][feeReceiver] += msg.value;
        emit CreatorFeesDeposited(token, feeReceiver, msg.value);
    }

    /// @notice Claims accumulated ETH fees for msg.sender from the provided `tokens`
    /// @dev claiming per token is less gas efficient than bulk claiming all tokens together in one balance.
    ///         However, if we'd do that, we would be forcing users to claim from all tokens at once, even from the ones they don't endorse
    function claim(address[] calldata tokens) external virtual {
        uint256 totalClaimable;
        uint256 nTokens = tokens.length;

        for (uint256 i = 0; i < nTokens; i++) {
            address token = tokens[i];
            uint256 tokenClaimable = pendingClaims[token][msg.sender];
            if (tokenClaimable == 0) continue;

            totalClaimable += tokenClaimable;
            delete pendingClaims[token][msg.sender];

            emit CreatorClaimed(token, msg.sender, tokenClaimable);
        }

        if (totalClaimable == 0) return;

        _transferEth(msg.sender, totalClaimable);
    }

    /// @notice Returns the pending claimable ETH fees for an account across the given tokens
    /// @dev This doesn't include non-accrued LP fees that are sitting in the LP position
    function getClaimable(address[] calldata tokens, address account)
        external
        view
        virtual
        returns (uint256[] memory claimable)
    {
        uint256 nTokens = tokens.length;
        claimable = new uint256[](nTokens);
        for (uint256 i = 0; i < nTokens; i++) {
            claimable[i] = pendingClaims[tokens[i]][account];
        }
    }

    /// @notice Transfers ETH to a recipient, reverting on failure
    function _transferEth(address recipient, uint256 amount) internal {
        if (amount == 0) return;
        (bool success,) = recipient.call{value: amount}("");
        require(success, EthTransferFailed());
    }
}
