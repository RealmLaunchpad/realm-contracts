// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILivoClaims} from "src/interfaces/ILivoClaims.sol";

/// @notice An interface for contracts that will receive livo-generated ETH fees, and from where receivers can claim
interface ILivoFeeHandler is ILivoClaims {
    /// EVENTS
    event CreatorFeesDeposited(address indexed token, address indexed account, uint256 amount);

    ///////////// EXTERNAL FUNCTIONS //////////////

    /// @notice Deposits msg.value into `feeReceiver` balance for `token`
    function depositFees(address token, address feeReceiver) external payable;
}
