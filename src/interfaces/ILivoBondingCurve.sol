// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ILivoBondingCurve {
    /// @notice how many tokens can be purchased with a given amount of ETH
    function buyTokensForExactEth(uint256 tokenReserves, uint256 ethReserves, uint256 ethAmount)
        external
        view
        returns (uint256 tokensReceived);

    /// @notice how much ETH is required to buy an exact amount of tokens
    function buyExactTokens(uint256 tokenReserves, uint256 ethReserves, uint256 tokenAmount)
        external
        view
        returns (uint256 ethRequired);

    /// @notice how much ETH will be received when selling an exact amount of tokens
    function sellExactTokens(uint256 tokenReserves, uint256 ethReserves, uint256 tokenAmount)
        external
        view
        returns (uint256 ethReceived);

    /// @notice how many tokens need to be sold to receive an exact amount of ETH
    function sellTokensForExactEth(uint256 tokenReserves, uint256 ethReserves, uint256 ethAmount)
        external
        view
        returns (uint256 tokensRequired);
}
