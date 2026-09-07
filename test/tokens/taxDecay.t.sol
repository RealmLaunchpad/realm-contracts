// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTests, LaunchpadBaseTestsWithUniv2Graduator} from "test/launchpad/base.t.sol";
import {RealmTaxableTokenUniV2} from "src/tokens/RealmTaxableTokenUniV2.sol";
import {RealmTaxableToken} from "src/tokens/RealmTaxableToken.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {TaxConfigs} from "src/interfaces/IRealmTaxableToken.sol";
import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";

/// @title Linear tax-decay computation — token-level unit tests
/// @notice Exercises the effective-rate logic (`max(decay, static)` decaying linearly from the anchor)
///         directly on a cloned `RealmTaxableTokenUniV2`, via `getLaunchpadFees`/`getTaxConfig`. Forks
///         mainnet (via `LaunchpadBaseTests`) for the real V2 router used by the impl's init approval.
contract TaxDecayUnitTest is LaunchpadBaseTestsWithUniv2Graduator {
    /// @dev Clone the V2 taxable impl and init it directly with `cfg` (bypasses the factory so the
    ///      computation can be tested in isolation). `graduatorV2.initialize` sets the pair.
    function _cloneAndInit(TaxConfigs memory cfg) internal returns (RealmTaxableTokenUniV2 t) {
        t = RealmTaxableTokenUniV2(payable(Clones.clone(address(realmTaxTokenV2))));
        t.initialize(
            IRealmToken.InitializeParams({
                name: "Decay",
                symbol: "DCY",
                tokenOwner: creator,
                graduator: address(graduatorV2),
                launchpad: address(launchpad),
                feeHandler: address(feeHandler),
                vaultAllocation: 0,
                lpFeeBps: 100,
                treasuryShareBps: 5_000,
                swapLpFeeBps: 0
            }),
            cfg,
            _emptyAntiSniperCfg()
        );
    }

    function _tax(RealmTaxableTokenUniV2 t, bool isBuy) internal view returns (uint16) {
        return t.getLaunchpadFees(IRealmToken.LaunchpadTrade({isBuy: isBuy, ethReserves: 0, releasedSupply: 0})).taxBps;
    }

    function _graduate(RealmTaxableTokenUniV2 t) internal {
        vm.prank(address(graduatorV2));
        t.markGraduated();
    }

    event RealmTaxableTokenInitialized(
        uint16 buyTaxBps,
        uint16 sellTaxBps,
        uint40 taxDurationSeconds,
        bool startTaxFromLaunch,
        uint16 buyTaxDecayStartBps,
        uint16 sellTaxDecayStartBps,
        uint40 taxDecayDuration
    );

    /// @dev Init emits the decay fields (previously always 0) on `RealmTaxableTokenInitialized`.
    function test_init_emitsDecayFields() public {
        RealmTaxableTokenUniV2 t = RealmTaxableTokenUniV2(payable(Clones.clone(address(realmTaxTokenV2))));
        vm.expectEmit(true, true, true, true, address(t));
        emit RealmTaxableTokenInitialized(0, 0, 0, true, 1000, 800, 1200);
        t.initialize(
            IRealmToken.InitializeParams({
                name: "Decay",
                symbol: "DCY",
                tokenOwner: creator,
                graduator: address(graduatorV2),
                launchpad: address(launchpad),
                feeHandler: address(feeHandler),
                vaultAllocation: 0,
                lpFeeBps: 100,
                treasuryShareBps: 5_000,
                swapLpFeeBps: 0
            }),
            _decayCfg(1000, 800, 1200, true),
            _emptyAntiSniperCfg()
        );
    }

    /// @dev A decay-only token has zero static tax, and `setTaxBps` is decrease-only, so the owner can
    ///      never grant the token a long-term tax — it cannot be turned into a taxable token.
    function test_setTaxBps_cannotRaiseDecayOnlyToTaxable() public {
        RealmTaxableTokenUniV2 token = _cloneAndInit(_decayCfg(1000, 1000, 1200, true));

        vm.prank(creator);
        vm.expectRevert(RealmTaxableToken.TaxBpsCanOnlyDecrease.selector);
        token.setTaxBps(1, 0);

        vm.prank(creator);
        vm.expectRevert(RealmTaxableToken.TaxBpsCanOnlyDecrease.selector);
        token.setTaxBps(0, 1);

        // setting to 0/0 (the only allowed value) is a no-op and does not touch the decay config
        vm.prank(creator);
        token.setTaxBps(0, 0);
        assertEq(uint256(token.buyTaxDecayStartBps()), 1000, "decay untouched by setTaxBps");
    }

    /// @dev A decay-only token (no static tax): buy decay 1000 bps over 1200s, anchored at launch.
    ///      The rate falls linearly from 1000 at the anchor to 0 at the end, staying 0 afterwards.
    function test_decayOnly_linearCurve_buy() public {
        uint40 t0 = uint40(block.timestamp);
        RealmTaxableTokenUniV2 token = _cloneAndInit(_decayCfg(1000, 0, 1200, true));

        assertEq(_tax(token, true), 1000, "elapsed 0");
        vm.warp(t0 + 300);
        assertEq(_tax(token, true), 750, "elapsed 300 (3/4)");
        vm.warp(t0 + 600);
        assertEq(_tax(token, true), 500, "elapsed 600 (1/2)");
        vm.warp(t0 + 900);
        assertEq(_tax(token, true), 250, "elapsed 900 (1/4)");
        vm.warp(t0 + 1200);
        assertEq(_tax(token, true), 0, "elapsed 1200 (end)");
        vm.warp(t0 + 5000);
        assertEq(_tax(token, true), 0, "past window");
    }

    /// @dev Sell decay is independent of buy decay (each direction has its own start rate).
    function test_decayOnly_linearCurve_sell() public {
        uint40 t0 = uint40(block.timestamp);
        RealmTaxableTokenUniV2 token = _cloneAndInit(_decayCfg(0, 800, 1200, true));

        assertEq(_tax(token, false), 800, "sell elapsed 0");
        assertEq(_tax(token, true), 0, "buy has no decay configured");
        vm.warp(t0 + 600);
        assertEq(_tax(token, false), 400, "sell elapsed 600 (1/2)");
        vm.warp(t0 + 1200);
        assertEq(_tax(token, false), 0, "sell elapsed end");
    }

    /// @dev The spec example: buy decay starts at 10% and decays linearly to the 5% long-term static
    ///      rate over the FULL 20min decay window (no early crossover — the decay duration the deployer
    ///      configures is honored end to end). The static 5% then holds until the 1h static window ends.
    function test_decayInterpolatesToStaticRate() public {
        uint40 t0 = uint40(block.timestamp);
        // static buy 500 for 1h; buy decay 1000 -> 500 over 20min; same launch anchor.
        RealmTaxableTokenUniV2 token = _cloneAndInit(_taxCfg(500, 0, uint32(1 hours), true, 1000, 0, 1200));

        assertEq(_tax(token, true), 1000, "t0: decay starts at 10%");
        vm.warp(t0 + 300);
        assertEq(_tax(token, true), 875, "t+5min: 3/4 of the way 10%->5% = 8.75%");
        vm.warp(t0 + 600);
        assertEq(_tax(token, true), 750, "t+10min: halfway 10%->5% = 7.5%");
        vm.warp(t0 + 900);
        assertEq(_tax(token, true), 625, "t+15min: 1/4 of the way = 6.25%");
        vm.warp(t0 + 1200);
        assertEq(_tax(token, true), 500, "t+20min: decay reaches static 5%");
        vm.warp(t0 + 3600);
        assertEq(_tax(token, true), 500, "t+1h: static inclusive boundary");
        vm.warp(t0 + 3601);
        assertEq(_tax(token, true), 0, "t+1h+1s: both windows closed");
    }

    /// @dev Graduation-anchored decay charges nothing before graduation, then decays from the graduation
    ///      timestamp.
    function test_decay_graduationAnchored() public {
        RealmTaxableTokenUniV2 token = _cloneAndInit(_decayCfg(1000, 1000, 1200, false));

        // before graduation: anchor is 0, so no tax
        vm.warp(block.timestamp + 100);
        assertEq(_tax(token, true), 0, "no decay before graduation");

        _graduate(token);
        uint40 g = uint40(block.timestamp);
        assertEq(_tax(token, true), 1000, "decay starts at graduation");
        vm.warp(g + 600);
        assertEq(_tax(token, true), 500, "decays from graduation anchor");
        vm.warp(g + 1200);
        assertEq(_tax(token, true), 0, "decay ends `duration` after graduation");
    }

    /// @dev The V2 intrinsic `_update` diverts the EFFECTIVE (decayed) rate post-graduation, not just
    ///      the static `sellTaxBps`. A decay-only token (static 0) must still divert its decay tax.
    function test_v2Intrinsic_divertsDecayRate_onSell() public {
        uint40 t0 = uint40(block.timestamp);
        RealmTaxableTokenUniV2 token = _cloneAndInit(_decayCfg(0, 1000, 1200, true));
        address pair = token.pair();

        // fund a seller from the launchpad's minted supply (pre-graduation, not to the pair → allowed)
        address seller = makeAddr("seller");
        vm.prank(address(launchpad));
        token.transfer(seller, 1_000_000e18);

        _graduate(token);

        // elapsed 600 of 1200 ⇒ sell decay rate = 500 bps
        vm.warp(t0 + 600);
        uint256 sellAmount = 10_000e18; // well below SWAP_THRESHOLD, so no auto swap-back fires
        uint256 contractBefore = token.balanceOf(address(token));

        vm.prank(seller);
        token.transfer(pair, sellAmount); // sell → _update(seller, pair, ...) diverts the tax

        assertEq(token.balanceOf(address(token)) - contractBefore, sellAmount * 500 / 10_000, "decayed sell tax");
    }

    /// @dev `getTaxConfig` (the V4 hook's read) reflects the current decayed rate and keeps the hook's
    ///      `graduationTimestamp + taxDurationSeconds` expiry open for the whole window, then zeroes out.
    function test_getTaxConfig_postGrad_decaysAndExpires() public {
        uint40 t0 = uint40(block.timestamp);
        RealmTaxableTokenUniV2 token = _cloneAndInit(_decayCfg(1000, 1000, 1200, true));

        // graduate 300s after launch (creation-anchored: anchor stays launchTimestamp)
        vm.warp(t0 + 300);
        _graduate(token);

        IRealmToken.TaxConfig memory c = token.getTaxConfig();
        assertEq(c.buyTaxBps, 750, "decayed buy rate at elapsed 300");
        assertEq(c.sellTaxBps, 750, "decayed sell rate at elapsed 300");
        assertEq(c.graduationTimestamp, t0 + 300, "graduationTimestamp");
        // hook expiry must reach the true window end (launch + 1200)
        assertEq(
            uint256(c.graduationTimestamp) + c.taxDurationSeconds, t0 + 1200, "synthetic duration -> true window end"
        );
        assertGe(uint256(c.graduationTimestamp) + c.taxDurationSeconds, block.timestamp, "hook stays open");

        // after the window: fully zeroed so the hook stops taxing
        vm.warp(t0 + 1200 + 1);
        c = token.getTaxConfig();
        assertEq(c.buyTaxBps, 0, "buy zeroed after window");
        assertEq(c.sellTaxBps, 0, "sell zeroed after window");
        assertEq(c.taxDurationSeconds, 0, "duration zeroed after window");
        assertEq(c.graduationTimestamp, t0 + 300, "graduationTimestamp still surfaced");
    }
}
