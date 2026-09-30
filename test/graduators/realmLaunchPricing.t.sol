// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {RealmLaunchPricing} from "src/libraries/RealmLaunchPricing.sol";

/// @notice The reader that turns a launch tick into a price a creator can check. The property under
///         test throughout is the one a creator gets wrong by hand: the answer depends on the QUOTE's
///         decimals, because a tick is a ratio of raw units.
contract PricingHarness {
    function priceAtTick(int24 tick, uint8 dec) external pure returns (uint256, uint256) {
        return RealmLaunchPricing.priceAtTick(tick, dec);
    }
}

contract RealmLaunchPricingTests is Test {
    /// @dev Tick 0 is a raw ratio of exactly 1. Against an 18-decimal quote that is one whole quote per
    ///      whole coin; the 1e27 supply is then worth 1e9 whole units.
    function test_tickZero_againstAnEighteenDecimalQuote() public pure {
        (uint256 price, uint256 mcap) = RealmLaunchPricing.priceAtTick(0, 18);
        assertEq(price, 1e18, "one whole quote per whole coin");
        assertEq(mcap, 1e18 * RealmLaunchPricing.WHOLE_SUPPLY);
    }

    /// @dev The same tick against a 6-decimal quote is a TRILLION times more expensive per whole coin —
    ///      twelve orders of magnitude, one per decimal of difference. This is the mistake the reader
    ///      exists to surface.
    function test_tickZero_againstASixDecimalQuote() public pure {
        (uint256 price,) = RealmLaunchPricing.priceAtTick(0, 6);
        assertEq(price, 1e18 * 1e12);
    }

    /// @dev Tick -184,200 against native: ~1e-8 native per coin, i.e. a
    ///      ~10-unit market cap across the whole supply.
    function test_nativeLaunchTick_impliesATenUnitMarketCap() public pure {
        (uint256 price, uint256 mcap) = RealmLaunchPricing.priceAtTick(-184_200, 18);
        assertApproxEqRel(price, 1e10, 0.01e18, "~1e-8 whole native per whole coin");
        assertApproxEqRel(mcap, 10e18, 0.01e18, "~10 whole native of market cap");
    }

    /// @dev A cheap coin on a low-decimals quote keeps its precision: tick -552,600 on a 6-decimal quote is
    ///      a raw price of ~1e-24 and a ~0.001-unit market cap. Rounding the raw price to 1e18 fixed point
    ///      before dividing out the quote's decimals would read it as zero.
    function test_cheapCoinOnASixDecimalQuoteKeepsItsPrecision() public pure {
        (uint256 price, uint256 mcap) = RealmLaunchPricing.priceAtTick(-552_600, 6);
        assertApproxEqRel(price, 1.0048e6, 0.001e18, "~1e-12 whole quote per whole coin");
        assertApproxEqRel(mcap, 1.0048e15, 0.001e18, "~0.001 whole quote of market cap");
    }

    /// @dev Monotonic, which is the whole reason the tick is defined as quote-per-coin rather than in
    ///      the pool's own orientation: a higher tick is ALWAYS a more expensive coin, whichever way the
    ///      pair happens to sort.
    function testFuzz_priceIsMonotonicInTheTick(int24 a, uint8 dec) public pure {
        a = int24(bound(a, -700_000, 700_000));
        dec = uint8(bound(dec, 0, 24));
        (uint256 lower,) = RealmLaunchPricing.priceAtTick(a, dec);
        (uint256 higher,) = RealmLaunchPricing.priceAtTick(a + 200, dec);
        assertGe(higher, lower, "a higher tick is never a cheaper coin");
    }

    /// @dev Through a harness, because `expectRevert` needs a call frame and a library is inlined.
    function test_rejectsAbsurdDecimals() public {
        PricingHarness h = new PricingHarness();
        vm.expectRevert(RealmLaunchPricing.UnsupportedDecimals.selector);
        h.priceAtTick(0, 37);
    }

    /// @dev `tickForMarketCap` is the inverse the direct factory prices every launch with: the tick it
    ///      returns must read back, through `priceAtTick`, as the target native market cap to within the
    ///      half spacing step (~1%) the rounding allows.
    function _assertRoundTrip(uint256 rateX18, uint8 dec) internal pure {
        uint256 target = 2.25 ether;
        int24 tick = RealmLaunchPricing.tickForMarketCap(target, rateX18, dec);
        assertEq(tick % 200, 0, "spacing-aligned");
        (, uint256 capInQuoteX18) = RealmLaunchPricing.priceAtTick(tick, dec);
        assertApproxEqRel(capInQuoteX18 * 1e18 / rateX18, target, 0.0101e18, "reads back as the target cap");
    }

    function test_tickForMarketCap_native() public pure {
        _assertRoundTrip(1e18, 18);
    }

    function test_tickForMarketCap_roundTripsAcrossDecimalsAndRates() public pure {
        uint8[3] memory decs = [uint8(6), 8, 18];
        uint256[6] memory rates = [uint256(1e15), 1e17, 1e18, 10e18, 3_500e18, 1e24];
        for (uint256 d; d < decs.length; ++d) {
            for (uint256 r; r < rates.length; ++r) {
                _assertRoundTrip(rates[r], decs[d]);
            }
        }
    }

    function testFuzz_tickForMarketCap_roundTrips(uint256 rateX18, uint8 dec) public pure {
        _assertRoundTrip(bound(rateX18, 1e15, 1e24), uint8(bound(dec, 6, 18)));
    }

    /// @dev Nearest, not floor: the target sits within half a spacing step (100 ticks, plus the one tick
    ///      `getTickAtSqrtPrice` floors away) of the returned tick, in tick (log-price) space.
    function testFuzz_tickForMarketCap_isTheNearestSpacingMultiple(uint256 rateX18) public pure {
        rateX18 = bound(rateX18, 1e15, 1e24);
        int24 tick = RealmLaunchPricing.tickForMarketCap(2.25 ether, rateX18, 18);
        uint256 target = 2.25 ether * rateX18 / 1e18;
        (, uint256 lo) = RealmLaunchPricing.priceAtTick(tick - 101, 18);
        (, uint256 hi) = RealmLaunchPricing.priceAtTick(tick + 101, 18);
        assertLe(lo, target, "not more than half a step above the target");
        assertGe(hi, target, "not more than half a step below the target");
    }
}
