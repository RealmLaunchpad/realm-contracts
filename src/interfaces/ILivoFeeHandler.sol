// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice An interface for contracts that will receive livo-generated ETH fees, and from where receivers can claim
interface ILivoFeeHandler {
    /// ERRORS
    error EthTransferFailed();

    /// EVENTS
    event CreatorFeesDeposited(address indexed token, address indexed account, uint256 amount);
    event CreatorClaimed(address indexed token, address indexed account, uint256 amount);

    event TreasuryFeesDeposited(address token, uint256 amount);

    ///////////// EXTERNAL FUNCTIONS //////////////

    /// @notice Deposits msg.value into `feeReceiver` balance for `token`
    function depositFees(address token, address feeReceiver) external payable;

    /// @notice Claims accumulated ETH fees for msg.sender from the provided `tokens`
    function claim(address[] calldata tokens) external;

    ////////////// VIEW FUNCTIONS /////////////

    /// @notice Returns the address that should own LP position NFTs (for Uniswap V4 fee collection)
    function lpFeesPositionOwner() external view returns (address);

    /// @notice Returns the pending ETH fees for `account` across the given `tokens`
    function getClaimable(address[] calldata tokens, address account) external view returns (uint256[] memory);
}
