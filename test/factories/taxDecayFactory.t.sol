// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTestsWithUniv2Graduator} from "test/launchpad/base.t.sol";
import {LivoTaxableTokenUniV2} from "src/tokens/LivoTaxableTokenUniV2.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {TaxConfigs, TaxConfigsWithAllocation, EarningsAllocationConfig} from "src/interfaces/ILivoTaxableToken.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";

/// @notice Factory-layer tests for the linear tax-decay add-on: validation (caps + sentinel
///         consistency) and dispatch (a decay-only token — no long-term static tax — still routes to
///         the taxable impl, since post-graduation collection lives there).
contract TaxDecayFactoryTests is LaunchpadBaseTestsWithUniv2Graduator {
    uint16 internal constant MAX_DECAY_TOTAL_BPS = 2_000; // 20% combined (buy + sell)
    uint32 internal constant MAX_DECAY_DURATION = 20 minutes; // 1200s

    function _tax(address token, bool isBuy) internal view returns (uint16) {
        return ILivoToken(token)
        .getLaunchpadFees(ILivoToken.LaunchpadTrade({isBuy: isBuy, ethReserves: 0, releasedSupply: 0}))
        .taxBps;
    }

    // ───────────── Dispatch: decay-only routes to the taxable impl ─────────────

    function test_dispatch_decayOnly_returnsTaxImpl() public view {
        // static tax all zero, only decay configured
        address impl = factoryV2Unified.previewTokenImplementation(
            _fs(creator), _noSs(), _decayCfg(1000, 1000, MAX_DECAY_DURATION, true), _emptyAntiSniperCfg()
        );
        assertEq(impl, address(livoTaxTokenV2), "decay-only must route to the taxable impl");
    }

    function test_createToken_decayOnly_isTaxableCloneWithDecay() public {
        TaxConfigs memory cfg = _decayCfg(1000, 800, MAX_DECAY_DURATION, true);
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), address(livoTaxTokenV2));
        ILivoFactory.TokenSetupTiered memory setup = ILivoFactory.TokenSetupTiered({
            name: "D", symbol: "D", salt: salt, feeShares: _fs(creator), liquidityTier: LiquidityTier.DEFAULT
        });

        vm.prank(creator);
        address token = factoryV2Unified.createToken(
            setup, cfg, _noSs(), _emptyAntiSniperCfg(), new ILivoFactory.CreatorVault[](0), address(0)
        );

        LivoTaxableTokenUniV2 t = LivoTaxableTokenUniV2(payable(token));
        // no long-term static tax
        assertEq(uint256(t.buyTaxBps()), 0, "static buy 0");
        assertEq(uint256(t.sellTaxBps()), 0, "static sell 0");
        assertEq(uint256(t.taxDurationSeconds()), 0, "static duration 0");
        // decay stored
        assertEq(uint256(t.buyTaxDecayStartBps()), 1000, "buy decay start");
        assertEq(uint256(t.sellTaxDecayStartBps()), 800, "sell decay start");
        assertEq(uint256(t.taxDecayDuration()), MAX_DECAY_DURATION, "decay duration");
        // effective rate at launch is the decay start
        assertEq(_tax(token, true), 1000, "buy decay live at launch");
        assertEq(_tax(token, false), 800, "sell decay live at launch");
    }

    // ───────────── Decay sentinel validation ─────────────

    function test_preview_revertsOnDecayDurationWithZeroBps() public {
        TaxConfigs memory cfg = _decayCfg(0, 0, MAX_DECAY_DURATION, true);
        vm.expectRevert(ILivoFactory.InvalidTaxConfig.selector);
        factoryV2Unified.previewTokenImplementation(_fs(creator), _noSs(), cfg, _emptyAntiSniperCfg());
    }

    function test_preview_revertsOnDecayBpsWithZeroDuration() public {
        // decay bps set but duration 0 — inconsistent
        TaxConfigs memory cfg = _taxCfg(0, 0, 0, true, 1000, 0, 0);
        vm.expectRevert(ILivoFactory.InvalidTaxConfig.selector);
        factoryV2Unified.previewTokenImplementation(_fs(creator), _noSs(), cfg, _emptyAntiSniperCfg());
    }

    // ───────────── Decay caps (combined buy + sell) ─────────────

    function test_preview_acceptsBalancedDecayBpsAtMax() public view {
        // 10% / 10% — sums to exactly the combined cap
        TaxConfigs memory cfg = _decayCfg(MAX_DECAY_TOTAL_BPS / 2, MAX_DECAY_TOTAL_BPS / 2, MAX_DECAY_DURATION, true);
        factoryV2Unified.previewTokenImplementation(_fs(creator), _noSs(), cfg, _emptyAntiSniperCfg());
    }

    function test_preview_acceptsAsymmetricSplitAtMax() public view {
        // 5% / 15% — rejected under the old per-direction 10% cap, allowed now (sum == 20%)
        TaxConfigs memory cfg = _decayCfg(500, 1500, MAX_DECAY_DURATION, true);
        factoryV2Unified.previewTokenImplementation(_fs(creator), _noSs(), cfg, _emptyAntiSniperCfg());
    }

    function test_preview_acceptsSingleDirectionAtMax() public view {
        // 20% / 0% — whole combined budget on one direction
        TaxConfigs memory cfg = _decayCfg(MAX_DECAY_TOTAL_BPS, 0, MAX_DECAY_DURATION, true);
        factoryV2Unified.previewTokenImplementation(_fs(creator), _noSs(), cfg, _emptyAntiSniperCfg());
    }

    function test_preview_revertsOnCombinedDecayBpsOverMax() public {
        // 10% + 10.01% = 20.01% combined, one bp over the cap
        TaxConfigs memory cfg = _decayCfg(1000, MAX_DECAY_TOTAL_BPS / 2 + 1, MAX_DECAY_DURATION, true);
        vm.expectRevert(ILivoFactory.InvalidTaxBps.selector);
        factoryV2Unified.previewTokenImplementation(_fs(creator), _noSs(), cfg, _emptyAntiSniperCfg());
    }

    function test_preview_acceptsDecayDurationAtMax() public view {
        TaxConfigs memory cfg = _decayCfg(1000, 1000, MAX_DECAY_DURATION, true);
        factoryV2Unified.previewTokenImplementation(_fs(creator), _noSs(), cfg, _emptyAntiSniperCfg());
    }

    function test_preview_revertsOnDecayDurationOverMax() public {
        TaxConfigs memory cfg = _decayCfg(1000, 1000, MAX_DECAY_DURATION + 1, true);
        vm.expectRevert(ILivoFactory.InvalidTaxDuration.selector);
        factoryV2Unified.previewTokenImplementation(_fs(creator), _noSs(), cfg, _emptyAntiSniperCfg());
    }

    // ───────────── Decay composes with a long-term static tax ─────────────

    function test_createToken_decayPlusStatic() public {
        // static 500 over 7 days + decay 1000 over 20min
        TaxConfigs memory cfg = _taxCfg(500, 500, uint32(7 days), true, 1000, 1000, MAX_DECAY_DURATION);
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), address(livoTaxTokenV2));
        ILivoFactory.TokenSetupTiered memory setup = ILivoFactory.TokenSetupTiered({
            name: "DS", symbol: "DS", salt: salt, feeShares: _fs(creator), liquidityTier: LiquidityTier.DEFAULT
        });

        vm.prank(creator);
        address token = factoryV2Unified.createToken(
            setup, cfg, _noSs(), _emptyAntiSniperCfg(), new ILivoFactory.CreatorVault[](0), address(0)
        );

        assertEq(_tax(token, true), 1000, "at launch, decay 10% dominates static 5%");
    }

    // ───────────── Static duration must cover the decay window (when both are configured) ─────────────

    function test_preview_revertsWhenStaticDurationShorterThanDecay() public {
        // both configured, but the static window (600s) is shorter than the decay window (1200s) — the
        // static tax would never effectively apply. Must revert.
        TaxConfigs memory cfg = _taxCfg(500, 500, 600, true, 1000, 1000, MAX_DECAY_DURATION);
        vm.expectRevert(ILivoFactory.InvalidTaxDuration.selector);
        factoryV2Unified.previewTokenImplementation(_fs(creator), _noSs(), cfg, _emptyAntiSniperCfg());
    }

    function test_preview_acceptsStaticDurationEqualToDecay() public view {
        // boundary: static window exactly equals the decay window
        TaxConfigs memory cfg = _taxCfg(500, 500, MAX_DECAY_DURATION, true, 1000, 1000, MAX_DECAY_DURATION);
        factoryV2Unified.previewTokenImplementation(_fs(creator), _noSs(), cfg, _emptyAntiSniperCfg());
    }

    // ───────────── Decay start must exceed the static rate (per direction) ─────────────
    // The decay interpolates DOWN to the long-term static rate, so a start at or below it would never
    // decay (the effective `max(decay, static)` would just hold the static rate). Enforced per direction
    // and only when that direction's decay start is set, so a single-direction decay (the other start 0)
    // stays valid.

    function test_preview_revertsWhenBuyDecayStartEqualsStatic() public {
        // buy decay start (500) == buy static (500): inert decay, must revert
        TaxConfigs memory cfg = _taxCfg(500, 0, MAX_DECAY_DURATION, true, 500, 0, MAX_DECAY_DURATION);
        vm.expectRevert(ILivoFactory.InvalidTaxBps.selector);
        factoryV2Unified.previewTokenImplementation(_fs(creator), _noSs(), cfg, _emptyAntiSniperCfg());
    }

    function test_preview_revertsWhenBuyDecayStartBelowStatic() public {
        // buy decay start (400) < buy static (500): decay below the rate it decays toward, must revert
        TaxConfigs memory cfg = _taxCfg(500, 0, MAX_DECAY_DURATION, true, 400, 0, MAX_DECAY_DURATION);
        vm.expectRevert(ILivoFactory.InvalidTaxBps.selector);
        factoryV2Unified.previewTokenImplementation(_fs(creator), _noSs(), cfg, _emptyAntiSniperCfg());
    }

    function test_preview_revertsWhenSellDecayStartNotAboveStatic() public {
        // sell decay start (500) == sell static (500): inert decay, must revert
        TaxConfigs memory cfg = _taxCfg(0, 500, MAX_DECAY_DURATION, true, 0, 500, MAX_DECAY_DURATION);
        vm.expectRevert(ILivoFactory.InvalidTaxBps.selector);
        factoryV2Unified.previewTokenImplementation(_fs(creator), _noSs(), cfg, _emptyAntiSniperCfg());
    }

    function test_preview_acceptsDecayStartJustAboveStatic() public view {
        // boundary: one bp above the static rate, both directions
        TaxConfigs memory cfg = _taxCfg(500, 500, MAX_DECAY_DURATION, true, 501, 501, MAX_DECAY_DURATION);
        factoryV2Unified.previewTokenImplementation(_fs(creator), _noSs(), cfg, _emptyAntiSniperCfg());
    }

    function test_preview_acceptsSingleDirectionDecayWithStaticOnOther() public view {
        // buy decays (1000 > static 0); sell has no decay (start 0) but a flat static 400 — the guard
        // skips the zero-start sell direction, so this is still valid.
        TaxConfigs memory cfg = _taxCfg(0, 400, uint32(7 days), true, 1000, 0, MAX_DECAY_DURATION);
        factoryV2Unified.previewTokenImplementation(_fs(creator), _noSs(), cfg, _emptyAntiSniperCfg());
    }

    function test_createToken_revertsWhenDecayStartNotAboveStatic() public {
        // same constraint enforced on the real deploy path, not just preview: sell decay (500) == sell
        // static (500) reverts even though buy decay (1000 > 500) is fine.
        TaxConfigs memory cfg = _taxCfg(500, 500, uint32(7 days), true, 1000, 500, MAX_DECAY_DURATION);
        ILivoFactory.TokenSetupTiered memory setup = ILivoFactory.TokenSetupTiered({
            name: "X", symbol: "X", salt: bytes32(0), feeShares: _fs(creator), liquidityTier: LiquidityTier.DEFAULT
        });

        vm.prank(creator);
        vm.expectRevert(ILivoFactory.InvalidTaxBps.selector);
        factoryV2Unified.createToken(
            setup, cfg, _noSs(), _emptyAntiSniperCfg(), new ILivoFactory.CreatorVault[](0), address(0)
        );
    }

    // ───────────── Earnings allocation is gated on a long-term static tax ─────────────

    /// @dev Builds a `TaxConfigsWithAllocation` from a plain `TaxConfigs` plus a burn share.
    function _allocCfg(TaxConfigs memory t, uint16 burnBps) internal pure returns (TaxConfigsWithAllocation memory) {
        return TaxConfigsWithAllocation({
            buyTaxBps: t.buyTaxBps,
            sellTaxBps: t.sellTaxBps,
            taxDurationSeconds: t.taxDurationSeconds,
            startTaxFromLaunch: t.startTaxFromLaunch,
            buyTaxDecayStartBps: t.buyTaxDecayStartBps,
            sellTaxDecayStartBps: t.sellTaxDecayStartBps,
            taxDecayDuration: t.taxDecayDuration,
            earningsAllocation: EarningsAllocationConfig({
                burnBps: burnBps, dividendsBps: 0, liquidityBps: 0, dividendToken: address(0)
            })
        });
    }

    function _allocSetup() internal returns (ILivoFactory.TokenSetupTiered memory) {
        return ILivoFactory.TokenSetupTiered({
            name: "A",
            symbol: "A",
            salt: _nextValidSalt(address(factoryV2Unified), address(livoTaxTokenV2)),
            feeShares: _fs(creator),
            liquidityTier: LiquidityTier.DEFAULT
        });
    }

    function test_createToken_revertsOnAllocationForDecayOnlyToken() public {
        // decay-only: no long-term static tax, so no earnings stream worth splitting
        TaxConfigsWithAllocation memory cfg = _allocCfg(_decayCfg(1000, 1000, MAX_DECAY_DURATION, true), 5000);
        vm.prank(creator);
        vm.expectRevert(ILivoFactory.EarningsAllocationRequiresTax.selector);
        factoryV2Unified.createToken(
            _allocSetup(), cfg, _noSs(), _emptyAntiSniperCfg(), new ILivoFactory.CreatorVault[](0), address(0)
        );
    }

    function test_createToken_allowsAllocationWhenStaticTaxAccompaniesDecay() public {
        TaxConfigsWithAllocation memory cfg =
            _allocCfg(_taxCfg(0, 400, uint32(14 days), true, 0, 1000, MAX_DECAY_DURATION), 5000);
        vm.prank(creator);
        address token = factoryV2Unified.createToken(
            _allocSetup(), cfg, _noSs(), _emptyAntiSniperCfg(), new ILivoFactory.CreatorVault[](0), address(0)
        );
        assertEq(uint256(LivoTaxableTokenUniV2(payable(token)).burnBps()), 5000, "allocation stored");
    }
}
