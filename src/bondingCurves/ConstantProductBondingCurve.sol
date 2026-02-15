// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILivoBondingCurve} from "../interfaces/ILivoBondingCurve.sol";

contract ConstantProductBondingCurve is ILivoBondingCurve {
    // the bonding curve follows the constant product formula:
    // K = (t + T0) * (e + E0)
    // `t` is the reserves of the token in the bonding curve (not sold yet )
    // `e` is the reserves of ETH in the bonding curve (collected from purchases)
    // where K, T0 and E0 are a constant calculated numerically to define the curve's shape

    // The token reserves can be expressed as a function of the eth reserves:
    // t = K / (e + E0) - T0

    // Here are the constraints to calculate K, T0, E0 as follows (top one is the most important)
    //  - when no eth has been collected, the token supply should equal 1B tokens (so 1,000,000,000e18)
    //  - The graduation should happen when ~8.5 ETH are collected, and 200,000,000 tokens are still in the reserves
    //  - 0.5 ETH will be used as graduation fees (for treasury and creator)
    //  - The remaining 8 ETH + 200M tokens are deployed in uniswap, so the price in uniswap must not deviate too much from the price in the bonding curve

    /// @notice Constant K for the bonding curve formula
    /// @dev Solving numerically for the above constraints. Only the first constraint above is strictly enforced
    uint256 public constant K = 3385715840941176470588235277153900000000000000;
    /// @notice Constant T0 for the bonding curve formula
    uint256 public constant T0 = 91849411764705882352941171;
    /// @notice Constant E0 for the bonding curve formula
    uint256 public constant E0 = 3100900000000000000;

    /// - t(8.5 ETH) = 199999999999999999999999985 (off from 200M target by 15 token-wei)
    /// - fee needed for exact price match: 0.499999837370237712 ETH (off from 0.5 ETH target by 0.000000162629762288 ETH)
    /// - price deviation if you take exactly 0.5 ETH fee: 0.00000203%

    // IMPORTANT: These constants define a curve that doesn't behave well for ethReserves > 30 eth.
    // This is not a problem in practice as long as the graduation threshold + limit excess is well below that.

    /// @notice Calculates how many tokens can be purchased with a given amount of ETH
    /// @param ethReserves Current ETH reserves in the bonding curve
    /// @param ethAmount Amount of ETH to spend
    /// @return tokensReceived Amount of tokens that would be received
    function buyTokensWithExactEth(uint256 ethReserves, uint256 ethAmount)
        external
        pure
        returns (uint256 tokensReceived)
    {
        // The final expression is derived from these two:
        //      tokenReserves = K / (ethReserves + E0) - T0;
        //      tokensReceived = T0 + tokenReserves - K / (ethReserves + ethAmount + E0);
        // The denominator can never be 0, as E0 is a non-zero constant
        tokensReceived = K * ethAmount / ((ethReserves + E0) * (ethReserves + ethAmount + E0));
    }

    /// @notice Calculates how much ETH will be received when selling an exact amount of tokens
    /// @param ethReserves Current ETH reserves in the bonding curve
    /// @param tokenAmount Amount of tokens to sell
    /// @return ethReceived Amount of ETH that would be received
    function sellExactTokens(uint256 ethReserves, uint256 tokenAmount) external pure returns (uint256 ethReceived) {
        // The final expression is derived from these two:
        //      uint256 tokenReserves = K / (ethReserves + E0) - T0;
        //      ethReceived = E0 + ethReserves - K / (tokenReserves + tokenAmount + T0);
        // The denominator can never be 0
        ethReceived = tokenAmount * (ethReserves + E0) ** 2 / (K + tokenAmount * (ethReserves + E0));
    }

    /// @notice Returns the token reserves for a given amount of ETH reserves
    /// @dev this calculation starts reverting with an overflow at some point above ethReserves > 37 ether
    /// @param ethReserves Current ETH reserves in the bonding curve
    /// @return Token reserves
    function getTokenReserves(uint256 ethReserves) external pure returns (uint256) {
        return _getTokenReserves(ethReserves);
    }

    ///////////////////////////// INTERNALS //////////////////////////////////

    function _getTokenReserves(uint256 ethReserves) internal pure returns (uint256) {
        // note: this calculation starts reverting with an overflow at some point above ethReserves > 37 ether
        // So this curve should not be used in that range
        // For the current graduation setup it should be safe, as the graduation happens at around 8.5 ether
        return K / (ethReserves + E0) - T0;
    }
}
