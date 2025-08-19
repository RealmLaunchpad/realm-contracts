// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ILivoBondingCurve {
    /// @notice How many tokens can be purchased with a given amount of ETH
    function ethToTokens_onBuy(uint256 circulatingSupply, uint256 ethReserves, uint256 ethAmount)
        external
        view
        returns (uint256 tokensReceived);

    /// @notice how many tokens have to be sold to receive amount of ETH
    function ethToTokens_onSell(uint256 circulatingSupply, uint256 ethReserves, uint256 ethAmount)
        external
        view
        returns (uint256 tokensRequired);

    /// @notice how much ETH is required to buy a given amount of tokens
    function tokensToEth_onBuy(uint256 circulatingSupply, uint256 ethReserves, uint256 tokenAmount)
        external
        view
        returns (uint256 ethRequired);

    /// @notice how much ETH will be received when selling a given amount of tokens
    function tokensToEth_onSell(uint256 circulatingSupply, uint256 ethReserves, uint256 tokenAmount)
        external
        view
        returns (uint256 ethReceived);
}
