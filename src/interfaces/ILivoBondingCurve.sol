// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ILivoBondingCurve {
    /// @notice How many tokens can be purchased with a given amount of ETH
    /// @param circulatingSupply Tokens already sold and in circulation
    /// @param ethAmount Amount of ETH to spend
    /// @return Number of tokens that can be purchased
    function getTokensForEth(uint256 circulatingSupply, uint256 ethAmount) external pure returns (uint256);

    /// @notice How much ETH is required to purchase a given amount of tokens
    /// @param circulatingSupply Tokens already sold and in circulation
    /// @param tokenAmount Amount of tokens to purchase
    /// @return Amount of ETH required to purchase the tokens
    function getEthForTokens(uint256 circulatingSupply, uint256 tokenAmount) external pure returns (uint256);
}
