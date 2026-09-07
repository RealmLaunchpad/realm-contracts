// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTestsWithUniv4Graduator} from "test/launchpad/base.t.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {IRealmBondingCurve} from "src/interfaces/IRealmBondingCurve.sol";
import {RealmFactoryUniV4Unified} from "src/factories/RealmFactoryUniV4Unified.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {TokenState} from "src/types/tokenData.sol";

/// @notice Integrated lifecycle matrix (Uniswap V4 fork) across the (liquidity tier x creator-vault
///         supply) space: the 3 tiers {THIN, DEFAULT, THICK} x the representative vault levels {5%, 30%
///         max}. The intermediate 10/15/20/25% levels reuse the same per-allocation curve machinery
///         (each proven wired in `creatorVaults.e2e`), so the e2e matrix only exercises the extremes.
///         For every cell it exercises the six deployer-facing scenarios end-to-end through the real
///         factory + launchpad + V4 graduator:
///           1. create                          -> token wired to the tier+vault curve and tier graduator
///           2. create + creator buy (small)    -> deployer receives ~the quoted token amount
///           3. create + creator buy (max/cap)  -> same, at the buy-on-deploy cap (10% of supply)
///           4. buy from launchpad              -> curve returns tokens
///           5. sell from launchpad             -> curve returns eth, matches the launchpad quote
///           6. graduate                        -> tier routing + full ETH conservation at graduation
///
///         The pure-curve math of all 21 curves (buy/sell round-trip, graduation price/mcap) is proven
///         fork-free in `TierLiquidityCurvesTest`; this suite proves the integrated path on top of it.
///
/// @dev    Tests sweep per-tier (one public test per tier per scenario) and loop the representative vault
///         levels inside, so a failure isolates to a tier+scenario and the assert message names the cell.
///         Tiers are referenced by name only (never by enum index): the enum is ordered by pool depth
///         (THIN=0), so positional assumptions would silently target the wrong tier.
contract TierLiquidityMatrixTest is LaunchpadBaseTestsWithUniv4Graduator {
    /// @dev The six supported creator-vault supply levels (5%..30% in 5% steps). Used both as a value
    ///      lookup (`BPS[idx]`) and to index the matching deployed curve (`vaults[idx]`).
    uint256[6] BPS = [uint256(500), 1000, 1500, 2000, 2500, 3000];

    /// @dev Indices into `BPS` the e2e sweeps actually exercise: the 5% minimum and the 30% maximum. The
    ///      intermediate levels add no integrated-path coverage, so they're skipped to keep the fork
    ///      matrix cheap (the per-allocation curve wiring for all six is covered in `creatorVaults.e2e`).
    uint256[2] BPS_IDX = [uint256(0), 5];

    // ───────────────────────── expected wiring per tier ─────────────────────────

    function _expectedThreshold(LiquidityTier tier) internal pure returns (uint256) {
        if (tier == LiquidityTier.THIN) return 2.0 ether;
        if (tier == LiquidityTier.DEFAULT) return 3.75 ether;
        return 7.25 ether; // THICK
    }

    function _expectedGraduator(LiquidityTier tier) internal view returns (address) {
        if (tier == LiquidityTier.THIN) return address(graduatorV4Thin);
        if (tier == LiquidityTier.DEFAULT) return address(graduatorV4);
        return address(graduatorV4Thick); // THICK
    }

    /// @dev The configurable curve a (tier, vault-level) token must be wired to. `bpsIdx` indexes `BPS`.
    function _expectedCurve(LiquidityTier tier, uint256 bpsIdx) internal view returns (address) {
        if (tier == LiquidityTier.THIN) return thinCurves.vaults[bpsIdx];
        if (tier == LiquidityTier.THICK) return thickCurves.vaults[bpsIdx];
        return vaultCurves[bpsIdx]; // DEFAULT
    }

    function _tierName(LiquidityTier tier) internal pure returns (string memory) {
        if (tier == LiquidityTier.THIN) return "THIN";
        if (tier == LiquidityTier.DEFAULT) return "DEFAULT";
        return "THICK";
    }

    /// @dev "[TIER NbpsBps] " prefix so a looped assertion names the exact failing cell.
    function _ctx(LiquidityTier tier, uint256 bps) internal pure returns (string memory) {
        return string.concat("[", _tierName(tier), " ", vm.toString(bps), "bps] ");
    }

    // ───────────────────────── shared helpers ─────────────────────────

    function _cfg() internal pure returns (RealmFactoryUniV4Unified.UniV4Configs memory) {
        return RealmFactoryUniV4Unified.UniV4Configs({renounceOwnership: false, lpFeeBps: 100});
    }

    /// @dev Creates a plain V4 token in `tier` with a single creator vault holding `vaultBps`. When
    ///      `value > 0`, `ss` recipients receive the buy-on-deploy supply funded by that ETH.
    function _create(LiquidityTier tier, uint256 vaultBps, uint256 value, IRealmFactory.SupplyShare[] memory ss)
        internal
        returns (address token)
    {
        IRealmFactory.CreatorVault[] memory vaults = new IRealmFactory.CreatorVault[](1);
        vaults[0] =
            IRealmFactory.CreatorVault({owner: creator, supplyBps: vaultBps, cliffSeconds: 0, vestingSeconds: 1});
        IRealmFactory.TokenSetupTiered memory setup = IRealmFactory.TokenSetupTiered({
            name: "Tier",
            symbol: "TIER",
            salt: _nextValidSalt(address(factoryV4Unified), address(realmToken)),
            feeShares: _fs(creator),
            liquidityTier: tier
        });
        if (value > 0) vm.deal(creator, value);
        vm.prank(creator);
        token = factoryV4Unified.createToken{value: value}(
            setup, _toCfgs(_emptyTaxCfg()), _cfg(), ss, _emptyAntiSniperCfg(), vaults, address(0)
        );
    }

    /// @dev Scenario 1 assertion: the token is wired to the tier+vault curve and the tier graduator.
    function _assertWiring(address token, LiquidityTier tier, uint256 bpsIdx) internal view {
        string memory ctx = _ctx(tier, BPS[bpsIdx]);
        IRealmBondingCurve curve = launchpad.getTokenConfig(token).bondingCurve;
        assertEq(address(curve), _expectedCurve(tier, bpsIdx), string.concat(ctx, "wrong tier+vault curve"));
        assertEq(curve.ethGraduationThreshold(), _expectedThreshold(tier), string.concat(ctx, "wrong tier threshold"));
        assertEq(IRealmToken(token).graduator(), _expectedGraduator(tier), string.concat(ctx, "wrong tier graduator"));
    }

    /// @dev Buys (from `buyer`) exactly enough to reach the token's tier-specific graduation threshold.
    function _buyToGraduation(address token) internal {
        IRealmBondingCurve curve = launchpad.getTokenConfig(token).bondingCurve;
        uint256 threshold = curve.ethGraduationThreshold();
        uint256 ethReserves = launchpad.getTokenState(token).ethCollected;
        uint256 buyFeeBps = _currentBuyFeeBps(token);
        uint256 missing = ((threshold - ethReserves) * 10_000) / (10_000 - buyFeeBps);
        vm.deal(buyer, missing);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: missing}(token, 0, DEADLINE);
    }

    // ───────────────────────── per-scenario sweeps (loop the 6 vault levels) ─────────────────────────

    /// @dev Scenarios 1: create wires the correct tier+vault curve and graduator for every vault level.
    function _sweepCreateWiring(LiquidityTier tier) internal {
        for (uint256 j; j < BPS_IDX.length; ++j) {
            uint256 i = BPS_IDX[j];
            address token = _create(tier, BPS[i], 0, _noSs());
            _assertWiring(token, tier, i);
        }
    }

    /// @dev Scenarios 2/3: create with a creator buy-on-deploy of `tokenAmount`. The vault-aware tier
    ///      quote must fund ~exactly `tokenAmount` for the deployer (never less) for every vault level.
    function _sweepCreatorBuy(LiquidityTier tier, uint256 tokenAmount) internal {
        for (uint256 j; j < BPS_IDX.length; ++j) {
            uint256 i = BPS_IDX[j];
            string memory ctx = _ctx(tier, BPS[i]);
            uint256 ethNeeded =
                factoryV4Unified.quoteBuyOnDeploy(tier, tokenAmount, BPS[i], _toCfgs(_emptyTaxCfg()), _cfg());
            address token = _create(tier, BPS[i], ethNeeded, _ss(creator));
            _assertWiring(token, tier, i);
            uint256 received = IRealmToken(token).balanceOf(creator);
            assertGe(received, tokenAmount, string.concat(ctx, "deployer got less than quoted"));
            assertApproxEqRel(received, tokenAmount, 0.00000001e18, string.concat(ctx, "deployer not ~= quoted"));
        }
    }

    /// @dev Scenario 3: a creator buy sized at `maxBuyOnDeploy` (the entire pre-graduation float) is
    ///      accepted for every vault level and graduates the token inside the same `createToken` tx — the
    ///      max buy reaches the graduation threshold without tripping `MaxEthReservesExceeded`. Proves the
    ///      no-cap deploy buy is bounded only by graduation, across tiers and up to the 30% max vault.
    function _sweepCreatorBuyMax(LiquidityTier tier) internal {
        for (uint256 j; j < BPS_IDX.length; ++j) {
            uint256 i = BPS_IDX[j];
            string memory ctx = _ctx(tier, BPS[i]);
            uint256 maxTokens = factoryV4Unified.maxBuyOnDeploy(tier, BPS[i]);
            uint256 ethNeeded =
                factoryV4Unified.quoteBuyOnDeploy(tier, maxTokens, BPS[i], _toCfgs(_emptyTaxCfg()), _cfg());
            address token = _create(tier, BPS[i], ethNeeded, _ss(creator));
            assertTrue(
                launchpad.getTokenState(token).graduated, string.concat(ctx, "max creator buy must graduate the token")
            );
            assertGe(IRealmToken(token).balanceOf(creator), maxTokens, string.concat(ctx, "deployer got less than max"));
        }
    }

    /// @dev Scenarios 4/5: a normal launchpad buy returns tokens; selling them all back returns eth that
    ///      matches the launchpad quote and never exceeds the eth deposited. Stays well below the lowest
    ///      tier threshold (THIN = 2.0 ETH) so the token does not graduate mid-test.
    function _sweepBuyThenSell(LiquidityTier tier) internal {
        uint256 buyValue = 0.5 ether;
        for (uint256 j; j < BPS_IDX.length; ++j) {
            uint256 i = BPS_IDX[j];
            string memory ctx = _ctx(tier, BPS[i]);
            address token = _create(tier, BPS[i], 0, _noSs());
            _assertWiring(token, tier, i);

            vm.deal(buyer, buyValue);
            vm.prank(buyer);
            uint256 tokensOut = launchpad.buyTokensWithExactEth{value: buyValue}(token, 0, DEADLINE);
            assertGt(tokensOut, 0, string.concat(ctx, "buy returned no tokens"));

            (,, uint256 expectedEthForSeller) = launchpad.quoteSellExactTokens(token, tokensOut);
            uint256 buyerBefore = buyer.balance;
            vm.prank(buyer);
            uint256 ethOut = launchpad.sellExactTokens(token, tokensOut, 0, DEADLINE);

            assertEq(ethOut, expectedEthForSeller, string.concat(ctx, "sell != launchpad quote"));
            assertGt(ethOut, 0, string.concat(ctx, "sell returned no eth"));
            assertLe(ethOut, buyValue, string.concat(ctx, "extracted more eth than deposited"));
            assertEq(buyer.balance, buyerBefore + ethOut, string.concat(ctx, "eth not credited to seller"));
        }
    }

    /// @dev Scenario 6: graduation tier-routing + full ETH conservation for every vault level.
    function _sweepGraduation(LiquidityTier tier) internal {
        for (uint256 j; j < BPS_IDX.length; ++j) {
            uint256 i = BPS_IDX[j];
            string memory ctx = _ctx(tier, BPS[i]);
            address token = _create(tier, BPS[i], 0, _noSs());
            _assertWiring(token, tier, i);

            uint256 treasuryBefore = treasury.balance;
            _buyToGraduation(token);
            TokenState memory st = launchpad.getTokenState(token);

            // Invariant B: all of this token's reserves leave the launchpad; the graduator keeps nothing.
            assertTrue(st.graduated, string.concat(ctx, "token must be graduated"));
            assertEq(st.ethCollected, 0, string.concat(ctx, "launchpad still holds reserves for token"));
            assertEq(_expectedGraduator(tier).balance, 0, string.concat(ctx, "graduator retained eth"));
            // Treasury received at least its graduation share (V4: 0.125 ETH); excess reserves swept here too.
            assertGe(
                treasury.balance - treasuryBefore,
                CREATOR_GRADUATION_COMPENSATION,
                string.concat(ctx, "treasury missing graduation share")
            );
        }
    }

    // ───────────────────────── scenario 1: create / wiring ─────────────────────────

    function test_createWiring_thin() public {
        _sweepCreateWiring(LiquidityTier.THIN);
    }

    function test_createWiring_default() public {
        _sweepCreateWiring(LiquidityTier.DEFAULT);
    }

    function test_createWiring_thick() public {
        _sweepCreateWiring(LiquidityTier.THICK);
    }

    // ───────────────────────── scenario 2: create + creator buy (small) ─────────────────────────
    // 1% of supply — a modest deploy buy, well under the 10% cap.

    function test_creatorBuySmall_thin() public {
        _sweepCreatorBuy(LiquidityTier.THIN, TOTAL_SUPPLY / 100);
    }

    function test_creatorBuySmall_default() public {
        _sweepCreatorBuy(LiquidityTier.DEFAULT, TOTAL_SUPPLY / 100);
    }

    function test_creatorBuySmall_thick() public {
        _sweepCreatorBuy(LiquidityTier.THICK, TOTAL_SUPPLY / 100);
    }

    // ───────────────────────── scenario 3: create + creator buy (max = up to graduation) ─────────────────────────
    // No buy-on-deploy cap: the max is `maxBuyOnDeploy` (the whole pre-graduation float), and buying it
    // graduates the token in the same createToken tx.

    function test_creatorBuyMax_thin() public {
        _sweepCreatorBuyMax(LiquidityTier.THIN);
    }

    function test_creatorBuyMax_default() public {
        _sweepCreatorBuyMax(LiquidityTier.DEFAULT);
    }

    function test_creatorBuyMax_thick() public {
        _sweepCreatorBuyMax(LiquidityTier.THICK);
    }

    // ───────────────────────── scenarios 4/5: buy + sell from launchpad ─────────────────────────

    function test_buyThenSell_thin() public {
        _sweepBuyThenSell(LiquidityTier.THIN);
    }

    function test_buyThenSell_default() public {
        _sweepBuyThenSell(LiquidityTier.DEFAULT);
    }

    function test_buyThenSell_thick() public {
        _sweepBuyThenSell(LiquidityTier.THICK);
    }

    // ───────────────────────── scenario 6: graduate ─────────────────────────

    function test_graduation_thin() public {
        _sweepGraduation(LiquidityTier.THIN);
    }

    function test_graduation_default() public {
        _sweepGraduation(LiquidityTier.DEFAULT);
    }

    function test_graduation_thick() public {
        _sweepGraduation(LiquidityTier.THICK);
    }
}
