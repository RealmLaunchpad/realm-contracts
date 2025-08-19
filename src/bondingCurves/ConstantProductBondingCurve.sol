// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../interfaces/ILivoBondingCurve.sol";

contract ConstantProductBondingCurve is ILivoBondingCurve {
    // The contract follows a constant product formula
    // K = (B - circulatingSupply) * (A + ethReserves)

    uint256 private constant A = 2.67e18;
    uint256 private constant B = 1.067e27;

    uint256 private constant K = 2.844e45;

    /// @notice How many tokens can be purchased with a given amount of ETH
    function ethToTokens_onBuy(uint256 circulatingSupply, uint256 ethReserves, uint256 ethAmount)
        external
        view
        returns (uint256 tokensReceived)
    {
        // review
        // a purchase increases both the eth reserves and the circulating supply
        // K = (B - circulatingSupply + tokens) * (A + ethReserves + value)
        // tokensReceived = B - circulatingSupply - K/(A + ethReserves + value)
        tokensReceived = B - circulatingSupply - (K / (A + ethReserves + ethAmount));
    }

    /// @notice how many tokens have to be sold to receive amount of ETH
    function ethToTokens_onSell(uint256 circulatingSupply, uint256 ethReserves, uint256 ethAmount)
        external
        view
        returns (uint256 tokensRequired)
    {
        // review
        // a purchase increases both the eth reserves and the circulating supply
        // K = (B - circulatingSupply + tokens) * (A + ethReserves + value)
        // tokens = K / (A + ethReserves - value) - B + circulatingSupply
        tokensRequired = (K / (A + ethReserves - ethAmount)) - B + circulatingSupply;
    }

    /// @notice how much ETH is required to buy a given amount of tokens
    function tokensToEth_onBuy(uint256 circulatingSupply, uint256 ethReserves, uint256 tokenAmount)
        external
        view
        returns (uint256 ethRequired)
    {
        // review
        // a sell decreases both the eth reserves and the circulating supply
        // K = (B - circulatingSupply - tokens) * (A + ethReserves - value)
        // value = K / (B - circulatingSupply - tokenAmount) - A - ethReserves
        ethRequired = (K / (B - circulatingSupply - tokenAmount)) - A - ethReserves;
    }

    /// @notice how much ETH will be received when selling a given amount of tokens
    function tokensToEth_onSell(uint256 circulatingSupply, uint256 ethReserves, uint256 tokenAmount)
        external
        view
        returns (uint256 ethReceived)
    {
        // review
        // a sell decreases both the eth reserves and the circulating supply
        // K = (B - circulatingSupply - tokens) * (A + ethReserves - value)
        // value = A + ethReserves - K / (B - circulatingSupply + tokens)
        ethReceived = (A + ethReserves) - (K / (B - circulatingSupply + tokenAmount));
    }
}
