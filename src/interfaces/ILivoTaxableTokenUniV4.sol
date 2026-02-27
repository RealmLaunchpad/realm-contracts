// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILivoToken} from "src/interfaces/ILivoToken.sol";

/// @title ILivoTaxableTokenUniV4
/// @notice Interface for tokens that support time-limited buy/sell taxes via Uniswap V4 hooks
/// @dev Extends ILivoToken to add tax configuration functionality
interface ILivoTaxableTokenUniV4 is ILivoToken {
    /// @notice Returns the graduation timestamp for this token
    function graduationTimestamp() external view returns (uint40);
}
