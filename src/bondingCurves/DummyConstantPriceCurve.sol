// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILivoBondingCurve} from "src/interfaces/ILivoBondingCurve.sol";

/// @notice Constant price dummy bonding curve
/// @dev This contract is only for testing purposes. Never meant to be used in production!
contract DummyConstantPriceCurve is ILivoBondingCurve {
    uint256 constant PRECISION = 1e18;

    /// @notice 1e18 means 1 token == 1 eth
    /// @dev units: [ETH/token]
    uint256 tokenPrice = 1e10;

    function buyTokensForExactEth(uint256 tokenReserves, uint256 ethReserves, uint256 ethAmount)
        external
        view
        returns (uint256 tokensReceived)
    {
        return (PRECISION * ethAmount) / tokenPrice;
    }

    function buyExactTokens(uint256 tokenReserves, uint256 ethReserves, uint256 tokenAmount)
        external
        view
        returns (uint256 ethRequired)
    {
        return tokenAmount * tokenPrice / PRECISION;
    }

    function sellExactTokens(uint256 tokenReserves, uint256 ethReserves, uint256 tokenAmount)
        external
        view
        returns (uint256 ethReceived)
    {
        return tokenAmount * tokenPrice / PRECISION;
    }

    function sellTokensForExactEth(uint256 tokenReserves, uint256 ethReserves, uint256 ethAmount)
        external
        view
        returns (uint256 tokensRequired)
    {
        return (PRECISION * ethAmount) / tokenPrice;
    }

    /// @dev Allows changing the token price.
    function setPrice(uint256 newPrice) external {
        // Only for testing purposes
        require(newPrice > 0, "Invalid price");
        tokenPrice = newPrice;
    }
}
