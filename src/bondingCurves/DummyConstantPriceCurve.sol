// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILivoBondingCurve} from "src/interfaces/ILivoBondingCurve.sol";

/// @notice Constant price dummy bonding curve
/// @dev This contract is only for testing purposes. Never meant to be used in production!
contract DummyConstantPriceCurve is ILivoBondingCurve {
    uint256 constant PRECISION = 1e18;

    /// @notice 1e18 means 1 token == 1 eth
    /// @dev units: [ETH/token]
    uint256 TOKEN_PRICE = 1e10;

    function ethToTokens_onBuy(uint256 circulatingSupply, uint256 ethReserves, uint256 ethAmount)
        external
        view
        returns (uint256 tokensReceived)
    {
        return (PRECISION * ethAmount) / TOKEN_PRICE;
    }

    function ethToTokens_onSell(uint256 circulatingSupply, uint256 ethReserves, uint256 ethAmount)
        external
        view
        returns (uint256 tokensRequired)
    {
        return (PRECISION * ethAmount) / TOKEN_PRICE;
    }

    function tokensToEth_onBuy(uint256 circulatingSupply, uint256 ethReserves, uint256 tokenAmount)
        external
        view
        returns (uint256 ethRequired)
    {
        return tokenAmount * TOKEN_PRICE / PRECISION;
    }

    function tokensToEth_onSell(uint256 circulatingSupply, uint256 ethReserves, uint256 tokenAmount)
        external
        view
        returns (uint256 ethReceived)
    {
        return tokenAmount * TOKEN_PRICE / PRECISION;
    }

    /// @dev Allows changing the token price.
    function setPrice(uint256 newPrice) external {
        // Only for testing purposes
        require(newPrice > 0, "Invalid price");
        TOKEN_PRICE = newPrice;
    }
}
