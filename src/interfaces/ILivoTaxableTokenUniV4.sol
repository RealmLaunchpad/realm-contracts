// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILivoToken} from "src/interfaces/ILivoToken.sol";

/// @title ILivoTaxableTokenUniV4
/// @notice Interface for tokens that support time-limited buy/sell taxes via Uniswap V4 hooks
/// @dev Extends ILivoToken to add tax configuration functionality
interface ILivoTaxableTokenUniV4 is ILivoToken {
    /// @notice Tax configuration for a token
    /// @dev All values are immutable once set during initialization
    struct TaxConfig {
        uint16 buyTaxBps; // Buy tax in basis points (max 500 = 5%)
        uint16 sellTaxBps; // Sell tax in basis points (max 500 = 5%)
        uint40 taxDurationSeconds; // Duration after graduation during which taxes apply
        uint40 graduationTimestamp; // Timestamp when token graduated (0 if not graduated)
        address taxRecipient; // Address receiving tax payments (token owner)
    }

    /// @notice Returns the tax configuration for this token
    /// @dev Called by the tax hook to determine tax rates and validity
    /// @return config The complete tax configuration
    function getTaxConfig() external view returns (TaxConfig memory config);

    /// @notice Returns the graduation timestamp for this token
    function graduationTimestamp() external view returns (uint40);

    /// @notice Returns the encoded token calldata for this token
    function encodeTokenCalldata(uint16 _buyTaxBps, uint16 _sellTaxBps, uint40 _taxDurationSeconds)
        external
        pure
        returns (bytes memory);
}
