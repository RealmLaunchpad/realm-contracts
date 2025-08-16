// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILivoBondingCurve} from "src/interfaces/ILivoBondingCurve.sol";

contract DummyLinearBondingCurve is ILivoBondingCurve {
    uint256 private constant INITIAL_PRICE = 0.000001 ether; // 0.000001 ETH in wei
    uint256 private constant FINAL_PRICE = 0.01 ether; // 0.01 ETH in wei
    uint256 private constant MAX_SUPPLY = 1_000_000_000 ether; // 1B tokens with 18 decimals
    uint256 private constant PRICE_SLOPE = (FINAL_PRICE - INITIAL_PRICE) * 1e18 / MAX_SUPPLY; // Price increase per token

    function getTokensForEth(uint256 circulatingSupply, uint256 ethAmount) external pure returns (uint256) {
        if (circulatingSupply >= MAX_SUPPLY) return 0;

        // todo this is clearly a simplification. The right would be the average price between the start and end prices
        uint256 currentPrice = INITIAL_PRICE + (PRICE_SLOPE * circulatingSupply) / 1e18;
        uint256 tokens = (ethAmount * 1e18) / currentPrice;

        // Ensure we don't exceed max supply
        uint256 remainingSupply = MAX_SUPPLY - circulatingSupply;
        if (tokens > remainingSupply) {
            tokens = remainingSupply;
        }

        return tokens;
    }

    function getEthForTokens(uint256 circulatingSupply, uint256 tokenAmount) external pure returns (uint256) {
        if (circulatingSupply >= MAX_SUPPLY || tokenAmount == 0) return 0;

        // Ensure we don't go beyond max supply
        if (circulatingSupply + tokenAmount > MAX_SUPPLY) {
            tokenAmount = MAX_SUPPLY - circulatingSupply;
        }

        uint256 currentPrice = INITIAL_PRICE + (PRICE_SLOPE * circulatingSupply) / 1e18;
        return (tokenAmount * currentPrice) / 1e18;
    }
}
