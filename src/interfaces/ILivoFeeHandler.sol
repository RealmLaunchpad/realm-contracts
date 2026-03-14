// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILivoClaims} from "src/interfaces/ILivoClaims.sol";

/// @notice An interface for contracts that will receive livo-generated ETH fees, and from where receivers can claim
interface ILivoFeeHandler is ILivoClaims {
    /// EVENTS
    event CreatorFeesDeposited(address indexed token, address indexed account, uint256 amount);

    event TreasuryFeesDeposited(address token, uint256 amount);

    ///////////// EXTERNAL FUNCTIONS //////////////

    /// @notice Deposits msg.value into `feeReceiver` balance for `token`
    function depositFees(address token, address feeReceiver) external payable;

    /// @notice Accrues pending LP fees for the given tokens
    function accrueTokenFees(address[] calldata tokens) external;

    ////////////// VIEW FUNCTIONS /////////////

    /// @notice Returns the address that should own LP position NFTs (for Uniswap V4 fee collection)
    function liquidityPositionOwner() external view returns (address);
}
