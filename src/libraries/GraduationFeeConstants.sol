// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title GraduationFeeConstants
/// @notice Per-chain graduation fee amounts, in the native unit (18-dec wei-scale).
library GraduationFeeConstants {
    /// @notice Total graduation fee (creator compensation + treasury fee [+ triggerer, V2 only]).
    uint256 internal constant GRADUATION_FEE = 0.25 ether;

    /// @notice Native compensation paid to `tx.origin` for triggering V2 graduation (offsets the gas
    ///         of the lazy pair deploy inside `graduateToken()`).
    uint256 internal constant TRIGGERER_GRADUATION_COMPENSATION = 0.005 ether;
}
