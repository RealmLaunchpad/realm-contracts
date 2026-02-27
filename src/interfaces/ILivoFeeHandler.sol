// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice An interface for contracts that will receive livo-generated ETH fees, and from where receivers can claim
interface ILivoFeeHandler {
    /// ERRORS
    error EthTransferFailed();

    /// EVENTS
    event FeesDeposited(address indexed account, uint256 amount);
    event FeesClaimed(address indexed account, uint256 amount);

    /// @notice Deposits msg.value into `account` balance
    function depositFees(address account) external payable;

    /// @notice Claims accumulated ETH fees for msg.sender
    function claim() external;

    /// @notice Returns the pending ETH fees for `account`
    function getClaimable(address account) external view returns (uint256);
}
