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
    function priceAtTick(int24 launchTick, uint8 quoteDecimals)
        internal
        pure
        returns (uint256 priceX18, uint256 marketCapX18)
    {
        require(quoteDecimals <= 36, UnsupportedDecimals());

        // `1.0001^tick` in Q64.96, squared back out of its square root in two steps so neither
        // intermediate leaves 256 bits: `sqrtPriceX96` reaches ~1.46e48, and its square alone is 2.1e96.
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(launchTick);
        uint256 priceQ96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 96);
        uint256 rawPriceX18 = FullMath.mulDiv(priceQ96, 1e18, 1 << 96);

        // Raw quote per raw coin -> whole quote per whole coin: multiply by the coin's units-per-whole
        // and divide by the quote's.
        priceX18 = FullMath.mulDiv(rawPriceX18, 10 ** COIN_DECIMALS, 10 ** uint256(quoteDecimals));
        marketCapX18 = priceX18 * WHOLE_SUPPLY;
    }
}
