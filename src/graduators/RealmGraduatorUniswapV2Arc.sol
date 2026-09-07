// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RealmGraduatorUniswapV2Base} from "src/graduators/RealmGraduatorUniswapV2Base.sol";
import {IUniswapV2Router} from "src/interfaces/IUniswapV2Router.sol";
import {UniswapV2VenueArc} from "src/libraries/UniswapV2VenueArc.sol";
import {GraduationFeeConstantsArc} from "src/libraries/GraduationFeeConstantsArc.sol";

/// @title RealmGraduatorUniswapV2Arc
/// @notice ARC (Circle L1, native = USDC) Uniswap V2 graduator. Shared logic in the base; this fills
///         the venue hooks with the two-ERC20 `addLiquidity` path against the 6-dec USDC ERC-20 (ARC
///         has no wrappable WETH) plus the 18↔6-decimal conversion, and the ARC (×2000) fee amounts.
/// @dev Selected at deploy time by chain id (see DeployLaunchpadCore) — NOT via source retargeting.
///      Its ctor guard (`GraduationFeeConstantsArc.assertDeployableOn`) restricts it to ARC chains,
///      so it compiles on every target but only constructs on 5042002 / 5042.
contract RealmGraduatorUniswapV2Arc is RealmGraduatorUniswapV2Base {
    constructor(address _uniswapRouter, address _launchpad, bytes32 _pairInitCodeHash)
        RealmGraduatorUniswapV2Base(_uniswapRouter, _launchpad, _pairInitCodeHash)
    {}

    function _assertDeployableOn(uint256 chainId) internal pure override {
        GraduationFeeConstantsArc.assertDeployableOn(chainId);
    }

    function _graduationFee() internal pure override returns (uint256) {
        return GraduationFeeConstantsArc.GRADUATION_FEE;
    }

    function _triggererCompensation() internal pure override returns (uint256) {
        return GraduationFeeConstantsArc.TRIGGERER_GRADUATION_COMPENSATION;
    }

    function _pairToken(IUniswapV2Router router) internal pure override returns (address) {
        return UniswapV2VenueArc.pairToken(router);
    }

    function _quoteToNativeScale() internal pure override returns (uint256) {
        return UniswapV2VenueArc.QUOTE_TO_NATIVE_SCALE;
    }

    function _supplyLiquidity(address token, address quote, uint256 tokenAmount, uint256 nativeValue, address to)
        internal
        override
        returns (uint256, uint256, uint256)
    {
        return UniswapV2VenueArc.supplyLiquidity(UNISWAP_ROUTER, token, quote, tokenAmount, nativeValue, to);
    }
}
