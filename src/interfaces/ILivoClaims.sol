// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Minimal interface for contracts that allow claiming accrued ETH fees
interface ILivoClaims {
    /// ERRORS
    error EthTransferFailed();

    /// EVENTS
    event CreatorClaimed(address indexed token, address indexed account, uint256 amount);

    /// @notice Claims accumulated ETH fees for msg.sender from the provided `tokens`
    function claim(address[] calldata tokens) external;

    /// @notice Returns the pending ETH fees for `account` across the given `tokens`
    function getClaimable(address[] calldata tokens, address account) external view returns (uint256[] memory);
}
