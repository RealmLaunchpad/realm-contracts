// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IUniswapV2Router} from "src/interfaces/IUniswapV2Router.sol";

/// @title UniswapV2Venue
/// @notice Chain-specific Uniswap V2 venue helpers shared by the V2 graduator and the V2 taxable
///         token. This is the ETH-family variant (native = ETH, pairs quoted in 18-dec WETH). The
///         `chain-arc-*` recipe import-swaps this file for `UniswapV2VenueArc` (native = USDC, 6-dec
///         ERC-20 quote), exactly like the fee/pool-geometry libs. See [[arc-chain-facts]].
/// @dev All functions are `internal` so they inline into the caller's bytecode (no deployed library).
library UniswapV2Venue {
    /// @notice Multiplier from the pool's quote-reserve units to native 18-dec. WETH is 18-dec ⇒ 1.
    uint256 internal constant QUOTE_TO_NATIVE_SCALE = 1;

    /// @notice Token every graduated pair is quoted in: the router's canonical WETH.
    function pairToken(IUniswapV2Router router) internal pure returns (address) {
        return router.WETH();
    }

    /// @notice Adds `tokenAmount` tokens + `nativeValue` (18-dec) of native liquidity via the WETH path.
    /// @return amountToken tokens added, amountNative native added (18-dec), liquidity LP minted.
    function supplyLiquidity(
        IUniswapV2Router router,
        address token,
        address, /*quote*/
        uint256 tokenAmount,
        uint256 nativeValue,
        address to
    ) internal returns (uint256 amountToken, uint256 amountNative, uint256 liquidity) {
        (amountToken, amountNative, liquidity) =
            router.addLiquidityETH{value: nativeValue}(token, tokenAmount, 0, 0, to, block.timestamp);
    }

    /// @notice Swaps `amountIn` tax tokens (held by `address(this)`) to native ETH, delivering the
    ///         proceeds to `address(this)`. FoT-aware (the tax token diverts on the router's pull).
    /// @param minOut minimum output, in native 18-dec.
    function swapTaxToNative(IUniswapV2Router router, address quote, uint256 amountIn, uint256 minOut) internal {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = quote;
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            amountIn, minOut, path, address(this), block.timestamp
        );
    }

    /// @notice Spends `nativeValue` (18-dec native) buying the asset at the end of `path`, delivering it
    ///         to `address(this)`. On ETH-family chains `path` must start at WETH, which
    ///         `swapExactETHForTokens…` wraps implicitly.
    /// @dev Low-level so a failed swap REPORTS rather than reverts: the only caller is a dividend
    ///      freeze, and a dead pool must leave the buffer intact rather than reverting the round (see
    ///      `DividendDistributionLogic._freezeDividends`). A reverted call keeps the native, so nothing
    ///      is spent.
    /// @param minOut minimum output in the ASSET's own decimals.
    /// @return ok false if the swap reverted (dead pair, slippage floor missed).
    function trySwapNativeToAsset(
        IUniswapV2Router router,
        address, /*quote*/
        address[] memory path,
        uint256 nativeValue,
        uint256 minOut
    ) internal returns (bool ok) {
        (ok,) = address(router).call{value: nativeValue}(
            abi.encodeCall(
                IUniswapV2Router.swapExactETHForTokensSupportingFeeOnTransferTokens,
                (minOut, path, address(this), block.timestamp)
            )
        );
    }
}
