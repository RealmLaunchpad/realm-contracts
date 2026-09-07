// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {Currency} from "lib/v4-core/src/types/Currency.sol";
import {IHooks} from "lib/v4-core/src/interfaces/IHooks.sol";

/// @title UniswapV4PoolConstantsArc
/// @notice ARC (Circle L1, native currency = USDC) variant of `UniswapV4PoolConstants`.
/// @dev ARC has no ETH: the native currency is USDC ($1), 18-dec at `msg.value` (identical wei math to
///      ETH). The V4 pool is still (currency0, currency1) = (native, token), both 18-dec, so the pool
///      decimals are unchanged vs the ETH deployment — the ONLY difference is the price level.
///
///      Repricing rule (see [[arc-integration-plan]]): assume ETH = $2000, native USDC = $1. A token
///      keeps the same USD value at graduation, so its price denominated in the native unit rises ×2000
///      (one native unit is worth 1/2000 of one ETH). The pool price P = tokens/native therefore FALLS
///      ×1/2000, i.e. sqrtPrice ×1/√2000 and every set-point tick shifts by log_1.0001(1/2000) ≈ −76013.
///
///      That exact shift rounds to −76000 (a multiple of TICK_SPACING) uniformly for all three tiers, so
///      here the ARC ticks ARE the ETH ticks −76000. Each set-point is re-derived from its ARC target
///      price via `simulations/script/uniswapV4Settings.py <eth_wei_per_token × 2000>` (see below), and
///      the range bounds preserve the exact ETH tick DISTANCES (same distance ⇒ same price ratio ⇒ same
///      pool geometry). Validated in `test/graduators/uniswapV4ConstantsArc.t.sol`.
library UniswapV4PoolConstantsArc {
    /// @notice LP fees in pips. 0 because LP fees are charged by the hook (LivoSwapHook). Chain-invariant.
    uint24 internal constant LP_FEE = 0;

    /// @notice Tick spacing. Chain-invariant (pool granularity, not a price).
    int24 internal constant TICK_SPACING = 200;

    // Pair is (currency0, currency1) = (native USDC, token). sqrtPriceX96 = sqrt(amountToken/amountNative)
    // * 2^96, i.e. tokens per native unit. Max token price = low tick; min token price = high tick.

    /// @notice DEFAULT/THICK upper boundary of the primary range (minimum token price in native USDC).
    /// @dev ETH 203600 − 76000 (preserves 21400 above the DEFAULT graduation tick). Multiple of 200.
    int24 internal constant TICK_UPPER = 127600;

    /// @notice THIN-tier upper boundary of the primary range.
    /// @dev ETH 212000 − 76000 (preserves 22800 above the THIN graduation tick, keeping the "full bag
    ///      sellable" tuning). Multiple of 200.
    int24 internal constant TICK_UPPER_THIN = 136000;

    /// @notice Lower boundary of the range at position creation (maximum token price in native USDC).
    /// @dev ETH −7000 − 76000 (preserves 189200 below the DEFAULT graduation tick). Multiple of 200.
    int24 internal constant TICK_LOWER = -83000;

    /// @notice Tick at the DEFAULT-tier graduation price (reference; the graduator derives it per-tier
    ///         on-chain from the passed sqrtPrice). ETH 182200 − 76000 = 106200.
    int24 internal constant TICK_GRADUATION = 106200;

    /// @notice Second position lower tick (single-sided native, concentrated right below graduation).
    int24 internal constant TICK_LOWER_2 = TICK_GRADUATION + TICK_SPACING;

    /// @notice Tick distance from the primary upper tick down to the secondary native-only position's
    ///         upper tick. Chain-invariant (a relative offset, translation-invariant under repricing).
    int24 internal constant TICK_UPPER_2_OFFSET = 51 * TICK_SPACING;

    ////////////////////// per-tier graduation prices (deploy-time constructor args) //////////////////////
    // Re-derived from `uniswapV4Settings.py <eth_wei_per_token × 2000> --tick-upper <tier upper>`.
    // ARC native-wei-per-token = ETH-wei-per-token × 2000 (token USD value unchanged; native mcap ×2000).

    /// @notice DEFAULT graduation sqrtPriceX96. ETH wei/token 12250000000 → ARC 24500000000000
    ///         (12.25 ETH → 24500 USDC mcap, same $24,500). Tick 106200.
    uint160 internal constant SQRT_PRICEX96_GRADUATION_DEFAULT = 16006505992796041211692164579328;

    /// @notice THIN graduation sqrtPriceX96. ETH wei/token 6125000000 → ARC 12250000000000
    ///         (6.125 ETH → 12250 USDC mcap, same $12,250). Tick 113200. Uses TICK_UPPER_THIN.
    uint160 internal constant SQRT_PRICEX96_GRADUATION_THIN = 22636617861218382812955361148928;

    /// @notice THICK graduation sqrtPriceX96. ETH wei/token 24500000000 → ARC 49000000000000
    ///         (24.5 ETH → 49000 USDC mcap, same $49,000). Tick 99200.
    uint160 internal constant SQRT_PRICEX96_GRADUATION_THICK = 11318308930609191406477680574464;

    /// @notice The canonical PoolKey of a graduated Livo token's V4 pool: `(native USDC, token)` with
    ///         this library's fee/spacing and the graduator's hook. THE single source of truth — the
    ///         graduator, the buy-back mixin and the token's liquidity leg must all target the same
    ///         pool, so none of them may hand-roll the key.
    function livoPoolKey(address token, address hook) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)), // native USDC
            currency1: Currency.wrap(token),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook)
        });
    }
}
