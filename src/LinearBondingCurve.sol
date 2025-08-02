// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./interfaces/ILivoBondingCurve.sol";

contract LinearBondingCurve is ILivoBondingCurve {
    uint256 public constant BASE_PRICE = 0.000001 ether; // 0.000001 ETH per token
    uint256 public constant PRICE_SLOPE = 0.000000001 ether; // Price increase per token sold
    uint256 public constant PRECISION = 1e18;

    function getBuyPrice(uint256 ethAmount, uint256 currentSupply, uint256 ethSupply)
        external
        pure
        override
        returns (uint256)
    {
        // For linear curve: price = basePrice + (currentSupply * priceSlope)
        // We need to solve for how many tokens we can buy with ethAmount
        return _getTokensForEth(ethAmount, currentSupply, ethSupply);
    }

    function getSellPrice(uint256 tokenAmount, uint256 currentSupply, uint256 ethSupply)
        external
        pure
        override
        returns (uint256)
    {
        return _getEthForTokens(tokenAmount, currentSupply, ethSupply);
    }

    function getTokensForEth(uint256 ethAmount, uint256 currentSupply, uint256 ethSupply)
        external
        pure
        override
        returns (uint256)
    {
        return _getTokensForEth(ethAmount, currentSupply, ethSupply);
    }

    function getEthForTokens(uint256 tokenAmount, uint256 currentSupply, uint256 ethSupply)
        external
        pure
        override
        returns (uint256)
    {
        return _getEthForTokens(tokenAmount, currentSupply, ethSupply);
    }

    function _getTokensForEth(uint256 ethAmount, uint256 currentSupply, uint256 ethSupply)
        internal
        pure
        returns (uint256)
    {
        if (ethAmount == 0) return 0;

        // For linear bonding curve: price = BASE_PRICE + (tokens_sold * PRICE_SLOPE)
        // We solve the quadratic equation for how many tokens can be bought with ethAmount

        uint256 a = PRICE_SLOPE;
        uint256 b = BASE_PRICE + (currentSupply * PRICE_SLOPE);
        uint256 c = ethAmount;

        // Quadratic formula: tokens = (-b + sqrt(b^2 + 4*a*c)) / (2*a)
        // Simplified for our case where we want positive solution
        if (a == 0) {
            // If no slope, constant price
            return (ethAmount * PRECISION) / b;
        }

        uint256 discriminant = (b * b) + (4 * a * c);
        uint256 sqrtDiscriminant = sqrt(discriminant);

        if (sqrtDiscriminant <= b) return 0;

        return (sqrtDiscriminant - b) / (2 * a);
    }

    function _getEthForTokens(uint256 tokenAmount, uint256 currentSupply, uint256 ethSupply)
        internal
        pure
        returns (uint256)
    {
        if (tokenAmount == 0) return 0;

        // Calculate ETH received for selling tokens
        // This is the integral of the price function from (currentSupply - tokenAmount) to currentSupply

        uint256 startSupply = currentSupply > tokenAmount ? currentSupply - tokenAmount : 0;
        uint256 endSupply = currentSupply;

        // Integral of (BASE_PRICE + x * PRICE_SLOPE) from startSupply to endSupply
        // = BASE_PRICE * (endSupply - startSupply) + PRICE_SLOPE * (endSupply^2 - startSupply^2) / 2

        uint256 ethFromBasePrice = BASE_PRICE * (endSupply - startSupply);
        uint256 ethFromSlope = PRICE_SLOPE * ((endSupply * endSupply) - (startSupply * startSupply)) / 2;

        return ethFromBasePrice + ethFromSlope;
    }

    // Simple integer square root function
    function sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;

        uint256 z = (x + 1) / 2;
        uint256 y = x;

        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }

        return y;
    }
}
