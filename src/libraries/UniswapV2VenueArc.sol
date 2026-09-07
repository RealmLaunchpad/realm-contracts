// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IUniswapV2Router} from "src/interfaces/IUniswapV2Router.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title UniswapV2VenueArc
/// @notice ARC (Circle L1, native = USDC) variant of `UniswapV2Venue`, import-swapped in by the
///         `chain-arc-*` recipe. There is no WETH: native USDC is 18-dec at `msg.value`/balance level,
///         but the pair quote token is the SAME USDC exposed as a 6-dec ERC-20 at 0x3600…0000. So V2
///         pairs are `<token, USDC-ERC20>` added via the plain two-ERC20 `addLiquidity` — NOT
///         `addLiquidityETH`, whose `router.WETH()` is a dead revert stub on ARC. See [[arc-chain-facts]].
/// @dev All functions are `internal` so they inline into the caller's bytecode (no deployed library).
library UniswapV2VenueArc {
    using SafeERC20 for IERC20;

    /// @notice 6-dec USDC ERC-20 alias — the same predeploy on ARC testnet (5042002) and mainnet (5042).
    address internal constant USDC = 0x3600000000000000000000000000000000000000;

    /// @notice Multiplier from the pool's quote-reserve units (6-dec USDC) to native 18-dec.
    uint256 internal constant QUOTE_TO_NATIVE_SCALE = 1e12;

    /// @notice Token every graduated pair is quoted in: the 6-dec USDC ERC-20 (router arg unused).
    function pairToken(IUniswapV2Router) internal pure returns (address) {
        return USDC;
    }

    /// @notice Adds `tokenAmount` tokens + `nativeValue` (18-dec native USDC) of liquidity via the
    ///         two-ERC20 path. Native USDC and its 6-dec ERC-20 share one balance, so no wrap is
    ///         needed: the router pulls `usdc6` via `transferFrom`, debiting native by `usdc6 · 1e12`.
    /// @dev `usdc6` floors; sub-1e-6-USDC dust stays in native balance and is swept by the graduator.
    /// @return amountToken tokens added, amountNative native added (18-dec), liquidity LP minted.
    function supplyLiquidity(
        IUniswapV2Router router,
        address token,
        address quote,
        uint256 tokenAmount,
        uint256 nativeValue,
        address to
    ) internal returns (uint256 amountToken, uint256 amountNative, uint256 liquidity) {
        uint256 usdc6 = nativeValue / QUOTE_TO_NATIVE_SCALE;
        IERC20(quote).forceApprove(address(router), usdc6);
        uint256 amountQuote6;
        (amountToken, amountQuote6, liquidity) =
            router.addLiquidity(token, quote, tokenAmount, usdc6, 0, 0, to, block.timestamp);
        amountNative = amountQuote6 * QUOTE_TO_NATIVE_SCALE;
    }

    /// @notice Swaps `amountIn` tax tokens (held by `address(this)`) to USDC, delivering it to
    ///         `address(this)`. The received 6-dec USDC IS native balance on ARC, so the caller's
    ///         `address(this).balance` reflects it with no unwrap. FoT-aware.
    /// @param minOut minimum output, in 6-dec USDC (quote decimals) — NOT 18-dec.
    function swapTaxToNative(IUniswapV2Router router, address quote, uint256 amountIn, uint256 minOut) internal {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = quote;
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn, minOut, path, address(this), block.timestamp
        );
    }

    /// @notice Spends `nativeValue` (18-dec native USDC) buying the asset at the end of `path`,
    ///         delivering it to `address(this)`. Native USDC and its 6-dec ERC-20 alias share one
    ///         balance, so the swap is a plain two-ERC20 hop out of the 6-dec side — no wrap, and the
    ///         debit shows up as a drop in `address(this).balance`.
    /// @dev Low-level so a failed swap REPORTS rather than reverts — see the ETH-family twin. The
    ///      allowance is cleared on failure, since only a successful swap consumes it exactly.
    /// @param minOut minimum output in the ASSET's own decimals.
    /// @return ok false if the swap reverted (dead pair, slippage floor missed).
    function trySwapNativeToAsset(
        IUniswapV2Router router,
        address quote,
        address[] memory path,
        uint256 nativeValue,
        uint256 minOut
    ) internal returns (bool ok) {
        uint256 usdc6 = nativeValue / QUOTE_TO_NATIVE_SCALE;
        IERC20(quote).forceApprove(address(router), usdc6);
        (ok,) = address(router)
            .call(
                abi.encodeCall(
                    IUniswapV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens,
                    (usdc6, minOut, path, address(this), block.timestamp)
                )
            );
        if (!ok) IERC20(quote).forceApprove(address(router), 0);
    }
}
