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

    // And we can define the constraints to calculate K, T0, E0 as follows (top one is the most important)
    //  - when no eth has been collected, the token supply should equal the total supply (1B tokens, so 1,000,000,000e18) // review this
    //  - The graduation should happen when 8 ETH are collected, and 200,000,000 tokens are still in the reserves
    //  - If all tokens were purchased, the total ETH collected would be 37.5 ETH

    // Solving numerically for the above constraints. Only the first constraint above is strictly enforced.
    uint256 public constant K = 2.925619836e45;
    uint256 public constant T0 = 72727273200000000286060606; // 7.27e27
    uint256 public constant E0 = 2727272727272727272; // 2.72e18

    // IMPORTANT: These constants define a curve that doesn't behave well for ethReserves > 37 eth.
    // This is not a problem in practice as long as the graduation threshold + limit excess is well below that.

    error NotImplemented();

    /// @notice how many tokens can be purchased with a given amount of ETH
    function buyTokensWithExactEth(uint256, /*tokenReserves*/ uint256 ethReserves, uint256 ethAmount)
        external
        pure
        returns (uint256 tokensReceived)
    {
        // tokenReserves are passed to the bonding curve to comply with the ILivoBondingCurve interface
        // but if they are derived from the formula, it is more difficult to trick the curve

        // The final expression is derived from these two:
        //      tokenReserves = K / (ethReserves + E0) - T0;
        //      tokensReceived = T0 + tokenReserves - K / (ethReserves + ethAmount + E0);
        // The denominator can never be 0, as E0 is a non-zero constant
        tokensReceived = K * ethAmount / ((ethReserves + E0) * (ethReserves + ethAmount + E0));
    }

    /// @notice how much ETH is required to buy an exact amount of tokens
    function buyExactTokens(uint256, /*tokenReserves*/ uint256 ethReserves, uint256 tokenAmount)
        external
        pure
        returns (uint256 ethRequired)
    {
        // This would be the formula to implement, but not needed for this version.
        // uint256 tokenReserves = K / (ethReserves + E0) - T0;
        // ethRequired = K / (tokenReserves + T0 - tokenAmount) - ethReserves - E0;

        revert NotImplemented();
    }

    /// @notice how much ETH will be received when selling an exact amount of tokens
    function sellExactTokens(uint256, /*tokenReserves*/ uint256 ethReserves, uint256 tokenAmount)
        external
        pure
        returns (uint256 ethReceived)
    {
        // The final expression is derived from these two:
        //      uint256 tokenReserves = K / (ethReserves + E0) - T0;
        //      ethReceived = E0 + ethReserves - K / (tokenReserves + tokenAmount + T0);
        // The denominator can never be 0
        ethReceived = tokenAmount * (ethReserves + E0) ** 2 / (K + tokenAmount * (ethReserves + E0));
    }

    /// @notice how many tokens need to be sold to receive an exact amount of ETH
    function sellTokensForExactEth(uint256, /*tokenReserves*/ uint256 ethReserves, uint256 ethAmount)
        external
        pure
        returns (uint256 tokensRequired)
    {
        // This would be the formula to implement, but not needed for this version.
        // uint256 tokenReserves = K / (ethReserves + E0) - T0;
        // tokensRequired = K / (ethReserves + E0 - ethAmount) - tokenReserves - T0;

        revert NotImplemented();
    }

    function getTokenReserves(uint256 ethReserves) external pure returns (uint256) {
        return _getTokenReserves(ethReserves);
    }

    ///////////////////////////// INTERNALS //////////////////////////////////

    function _getTokenReserves(uint256 ethReserves) internal pure returns (uint256) {
        // todo review left side is smaller than T0
        return K / (ethReserves + E0) - T0;
    }
}
