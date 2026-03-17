// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title UniswapV4PoolConstants
/// @notice Shared Uniswap V4 pool configuration constants used by the graduator and fee handler.
library UniswapV4PoolConstants {
    /// @notice LP fees in pips, i.e. 1e6 = 100%, so 10000 = 1%
    /// @dev Set to 0 because LP fees are now charged by the hook (LivoSwapHook)
    uint24 internal constant LP_FEE = 0;

    /// @notice Tick spacing used to be 200 for volatile pairs in univ3. (60 for 0.3% fee tier)
    /// @dev The larger the spacing the cheaper to swap gas-wise
    int24 internal constant TICK_SPACING = 200;

    // In the uniswapV4 pool, the pair is (currency0,currency1) = (nativeEth, token)
    // The `sqrtPriceX96` is denominated as sqrt(amountToken1/amountToken0) * 2^96,
    // so tokens/ETH (eth price of one token).
    // Thus, the max token price is found at the low tick, and the min token price at the high tick

    /// @notice The upper boundary of the liquidity range when the position is created (minimum token price in ETH)
    /// @dev High tick: 203600 -> 2088220564709554551739049874292736 -> 694694034.078335 tokens per ETH
    /// @dev Ticks need to be multiples of TICK_SPACING
    int24 internal constant TICK_UPPER = 203600;

    /// @notice The lower boundary of the liquidity range when the position is created (maximum token price in ETH)
    /// @dev Low tick: -7000 -> sqrtX96price: 55832119482513121612260179968 -> 0.49660268342258984 tokens per ETH
    /// @dev At this tick, the token price would imply a market cap of 2,000,000,000 ETH (8,000,000,000,000 USD with ETH at 4000 USD)
    int24 internal constant TICK_LOWER = -7000;

    /// @notice Tick at graduation price
    int24 internal constant TICK_GRADUATION = 182200;

    /// @notice Second position lower tick (single-sided ETH, concentrated right below the graduation price)
    int24 internal constant TICK_LOWER_2 = TICK_GRADUATION + TICK_SPACING;

    /// @notice Second position upper tick (single-sided ETH)
    /// @dev This secondary position covers roughly a -67% drop from graduation price. After that, only the main position would be active
    /// @dev However, the second position has much less liquidity, so the impact would be barely noticeable.
    int24 internal constant TICK_UPPER_2 = TICK_UPPER - (51 * TICK_SPACING);
}
