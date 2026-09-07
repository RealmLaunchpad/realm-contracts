// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RealmGraduatorUniswapV2Base} from "src/graduators/RealmGraduatorUniswapV2Base.sol";
import {IUniswapV2Router} from "src/interfaces/IUniswapV2Router.sol";
import {UniswapV2Venue} from "src/libraries/UniswapV2Venue.sol";
import {GraduationFeeConstants} from "src/libraries/GraduationFeeConstants.sol";

/// @title RealmGraduatorUniswapV2
/// @notice ETH-family (native = ETH, WETH-quoted) Uniswap V2 graduator. Shared logic in the base;
///         this fills the venue hooks with the WETH `addLiquidityETH` path and the ETH fee amounts.
/// @dev The ARC (native = USDC) counterpart is the separate `RealmGraduatorUniswapV2Arc` — the venues
///      differ behaviorally, so they are distinct deployable contracts, not one import-swapped file.
contract RealmGraduatorUniswapV2 is RealmGraduatorUniswapV2Base {
    constructor(address _uniswapRouter, address _launchpad, bytes32 _pairInitCodeHash)
        RealmGraduatorUniswapV2Base(_uniswapRouter, _launchpad, _pairInitCodeHash)
    {}

    function _assertDeployableOn(uint256 chainId) internal pure override {
        GraduationFeeConstants.assertDeployableOn(chainId);
    }

    function _graduationFee() internal pure override returns (uint256) {
        return GraduationFeeConstants.GRADUATION_FEE;
    }

    function _triggererCompensation() internal pure override returns (uint256) {
        return GraduationFeeConstants.TRIGGERER_GRADUATION_COMPENSATION;
    }

    function _pairToken(IUniswapV2Router router) internal pure override returns (address) {
        return UniswapV2Venue.pairToken(router);
    }

    function _quoteToNativeScale() internal pure override returns (uint256) {
        return UniswapV2Venue.QUOTE_TO_NATIVE_SCALE;
    }

    function _supplyLiquidity(address token, address quote, uint256 tokenAmount, uint256 nativeValue, address to)
        internal
        override
        returns (uint256, uint256, uint256)
    {
        return UniswapV2Venue.supplyLiquidity(UNISWAP_ROUTER, token, quote, tokenAmount, nativeValue, to);
    }
}
