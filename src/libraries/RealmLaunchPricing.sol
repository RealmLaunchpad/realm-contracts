// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TickMath} from "lib/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "lib/v4-core/src/libraries/FullMath.sol";

/// @title RealmLaunchPricing
/// @notice Turns a direct launch's `launchTick` into the numbers a human reads: the opening price of
///         one whole coin, and the market capitalisation that implies across the fixed supply.
///
/// @dev WHY THIS EXISTS. A creator picks their launch price as a TICK, because that is the only thing
///      Uniswap V4 can be given exactly and the only thing this protocol will accept un-rounded. A tick
///      is `1.0001^n` on RAW units, which is not a number anyone can sanity-check by eye — and the
///      failure it hides is not subtle: a creator who is out by one decimal launches at ten times or a
///      tenth of the price they meant, and the first buyer keeps the difference. This is the reader
///      that closes that gap, and it is the same arithmetic a frontend would otherwise reimplement in
///      floating point.
///
/// @dev PURE, and deliberately not on any contract's storage: nothing here depends on a token existing,
///      so a creator can price a launch before deciding to make one.
library RealmLaunchPricing {
    /// @notice Whole coins in a Realm token's fixed supply: 1e27 raw at 18 decimals.
    uint256 internal constant WHOLE_SUPPLY = 1_000_000_000;

    /// @notice Every Realm token's decimals. The coin side of the ratio is always this.
    uint256 internal constant COIN_DECIMALS = 18;

    /// @notice Thrown when a quote's decimals are outside anything an ERC20 sensibly uses, which would
    ///         make the scaling below overflow rather than merely produce a strange number.
    error UnsupportedDecimals();

    /// @notice The opening price `launchTick` encodes, and the market cap it implies.
    /// @param launchTick Opening price as QUOTE PER COIN, in ticks — the value passed to `createToken`.
    /// @param quoteDecimals Decimals of the currency the pair is quoted in (18 for native).
    /// @return priceX18 Whole quote units per whole coin, scaled by 1e18. A `priceX18` of 5e14 on a
    ///         6-decimal stablecoin means one coin opens at 0.0005 of that stablecoin.
    /// @return marketCapX18 `priceX18 * WHOLE_SUPPLY`: what the whole supply is worth at that opening
    ///         price, in whole quote units scaled by 1e18.
    /// @dev The tick is a ratio of RAW units, so converting it to whole units is where the decimals
    ///      come in: a 6-decimal quote against an 18-decimal coin puts twelve orders of magnitude
    ///      between the two readings, which is exactly the mistake this function exists to surface.
    /// @dev Reverts with an arithmetic panic when the market cap does not fit in 256 bits — only at
    ///      prices far outside what the direct factory accepts, which bounds `pricePerCoin` instead.
    function priceAtTick(int24 launchTick, uint8 quoteDecimals)
        internal
        pure
        returns (uint256 priceX18, uint256 marketCapX18)
    {
        priceX18 = pricePerCoin(launchTick, quoteDecimals);
        marketCapX18 = priceX18 * WHOLE_SUPPLY;
    }

    /// @notice The market cap `launchTick` implies in the quote's RAW units (wei for native): the whole
    ///         supply at that price, no decimals applied. The same units an indexer derives from a pool's
    ///         `sqrtPriceX96`, so the two compare without knowing the quote's decimals.
    /// @dev Fits in 256 bits at every tick: `1.0001^tick` is below 2^128 and the raw supply is 1e27.
    function rawMarketCapAtTick(int24 launchTick) internal pure returns (uint256) {
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(launchTick);
        uint256 priceX128 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
        return FullMath.mulDiv(priceX128, WHOLE_SUPPLY * 10 ** COIN_DECIMALS, 1 << 128);
    }

    /// @notice `priceAtTick`'s `priceX18` alone, which fits in 256 bits at every tick and decimals value.
    function pricePerCoin(int24 launchTick, uint8 quoteDecimals) internal pure returns (uint256 priceX18) {
        require(quoteDecimals <= 36, UnsupportedDecimals());

        // `1.0001^tick` (raw quote per raw coin) in Q128. `sqrtPriceX96` is below 2^160, so its square
        // over 2^64 always fits in 256 bits, and Q128 keeps precision down to the cheapest tick.
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(launchTick);
        uint256 priceX128 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);

        // Raw -> whole units, scaled by 1e18, in ONE step: times the coin's units-per-whole and 1e18,
        // over the quote's units-per-whole. Scaling to 1e18 before dividing out the quote's decimals
        // would round a cheap coin on a low-decimals quote down to zero.
        priceX18 = FullMath.mulDiv(priceX128, 10 ** (COIN_DECIMALS + 18 - quoteDecimals), 1 << 128);
    }
}
