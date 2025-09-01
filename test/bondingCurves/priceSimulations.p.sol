// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {ConstantProductBondingCurve} from "src/bondingCurves/ConstantProductBondingCurve.sol";

contract ConstantProductPriceSimulations is Test {
    ConstantProductBondingCurve bondingCurve = new ConstantProductBondingCurve();

    uint256 E0 = bondingCurve.E0();
    uint256 T0 = bondingCurve.T0();
    uint256 K = bondingCurve.K();

    function _getTokenReserves(uint256 ethReserves) internal view returns (uint256 tokenReserves) {
        tokenReserves = K / (ethReserves + E0) - T0;
    }

    function _estimateBuyPrice(uint256 ethReserves) internal view returns (uint256 buyPrice) {
        // simple estimation, assuming a very small buy-size
        buyPrice = 1e18 * (ethReserves + E0) / (_getTokenReserves(ethReserves) + T0);

        // rewriting the above into a more efficient computation:
        // 1e18 * ( ethReserves + E0) / (_getTokenReserves(ethReserves) + T0)
        // 1e18 * (ethReserves + E0) / (K / (ethReserves + E0) - T0 + T0)
        // 1e18 * (ethReserves + E0) / (K / (ethReserves + E0))
        // 1e18 * (ethReserves + E0)^2 / K
        buyPrice = 1e18 * (ethReserves + E0) ** 2 / K;
    }

    function test_graduationPriceTransition_nonExactPriceEstimations() public view {
        uint256 startEthReserves = 7.9e18;
        uint256 endEthReserves = 8.2e18;

        for (uint256 ethReserves = startEthReserves; ethReserves <= endEthReserves; ethReserves += 0.01e18) {
            uint256 tokenReserves = _getTokenReserves(ethReserves);
            uint256 buyPrice = _estimateBuyPrice(ethReserves);
            // console.log(ethReserves, tokenReserves, buyPrice);
        }
    }

    function test_graduationPriceTransition_bondingCurveQuotingFunctions() public view {
        uint256 startEthReserves = 7.9e18;
        uint256 endEthReserves = 8.2e18;
        uint256 ethFee = 0.4 ether;
        uint256 creatorSupply = 10_000_000e18;

        for (uint256 ethReserves = startEthReserves; ethReserves <= endEthReserves; ethReserves += 0.01e18) {
            uint256 tokenReserves = bondingCurve.getTokenReserves(ethReserves);
            uint256 ethValue = 0.001e18;
            uint256 tokensReceived = bondingCurve.buyTokensWithExactEth(tokenReserves, ethReserves, ethValue);
            uint256 buyPrice = 10e18 * ethValue / tokensReceived; // ETH/tokens
            uint256 univ2price = 10e18 * (ethReserves - ethFee) / (tokenReserves - creatorSupply); // ETH/tokens
            uint256 priceStep = (univ2price - buyPrice) * 1e18 / buyPrice;
            // console.log(ethReserves, tokenReserves, buyPrice, univ2price);
            // console.log(priceStep);
        }
    }
}
