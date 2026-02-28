// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice An interface for contracts that will receive livo-generated ETH fees, and from where receivers can claim
interface ILivoFeeHandler {
    /// ERRORS
    error EthTransferFailed();

    /// EVENTS
    event FeesDeposited(address indexed token, address indexed account, uint256 amount);
    event CreatorClaimed(address indexed token, address indexed account, uint256 amount);

    /// @notice Deposits msg.value into `feeReceiver` balance for `token`
    function depositFees(address token, address feeReceiver) external payable;

    /// @notice Claims accumulated ETH fees for msg.sender from the provided `tokens`
    function claim(address[] calldata tokens) external;

    /// @notice Returns the pending ETH fees for `account` and `token`
    function getClaimable(address token, address account) external view returns (uint256);
}
