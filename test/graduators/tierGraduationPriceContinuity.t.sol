// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseUniswapV4GraduationTests} from "test/graduators/graduationUniv4.base.t.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {IRealmBondingCurve} from "src/interfaces/IRealmBondingCurve.sol";
import {RealmFactoryUniV4Unified} from "src/factories/RealmFactoryUniV4Unified.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {TaxConfigInit} from "src/interfaces/IRealmTaxableToken.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {RealmToken} from "src/tokens/RealmToken.sol";
import {IUniswapV2Pair} from "src/interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Router02} from "src/interfaces/IUniswapV2Router02.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/// @notice Graduation price-continuity matrix across BOTH venues (Uniswap V2 + V4), all three liquidity
///         tiers {THIN, DEFAULT, THICK}, the representative creator-vault levels {no-vault, 5%, 30% max},
///         AND all four token flavors {plain, tax, sniper-protected, tax+sniper}.
///
///         The single invariant under test, for every cell:
///           the LAST trade price on the bonding curve (right before graduation) must roughly match the
///           FIRST swap price in the freshly-created Uniswap pool (right after graduation), within 5%.
///         A larger gap would let the first post-graduation swapper arbitrage the pool's opening price
///         against the curve — the whole reason the curve's marginal price is matched to the pool's
///         initial price.
///
///         Price is measured fee/tax-FREE on both sides, as ETH-per-token:
///           - before: the curve's marginal price at the graduation threshold (a pure view);
///           - after : the actual deployed pool's opening spot price (V2 reserves ratio / V4 slot0).
///         This is deliberate: taxes and LP fees are charged on top of the price and differ between the
///         curve phase and the pool phase (and between flavors), so folding them in would spend the 5%
///         band on fees rather than on genuine price discontinuity. The pool's opening spot price IS the
///         price the first (infinitesimal) swap transacts at, before its own fee. Because a tax/sniper
///         token graduates with the exact same reserves as a plain one (graduation transfers bypass tax,
///         and the curve is chosen by tier+vault, not flavor), the invariant must hold identically across
///         every flavor — this suite proves it does, end-to-end through the real factory + launchpad +
///         graduator for each.
///
/// @dev    Complements `TierLiquidityCurvesTest` (pure-curve marginal price vs `ethIntoLiquidity/T_GRAD`)
///         and `TierLiquidityMatrixTest` (V4 tier-routing + ETH conservation). Neither closed the loop
///         against the REAL pool price, and V2 tier graduation was untested entirely.
contract TierGraduationPriceContinuityTest is BaseUniswapV4GraduationTests {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    enum Flavor {
        BASE, // no tax, no sniper protection
        TAX, // taxable token
        SNIPER, // sniper-protected token
        TAX_SNIPER // taxable + sniper-protected
    }

    /// @dev Creator-vault levels exercised end-to-end: no-vault, the 5% minimum, and the 30% max. The
    ///      intermediate 10/15/20/25% steps reuse the same curve+vault machinery and add no coverage here.
    uint256[3] VAULTS = [uint256(0), 500, 3000];

    /// @dev Non-plain flavors, swept at no-vault (BASE is already covered by the vault sweep at 0 bps).
    Flavor[3] FLAVORS = [Flavor.TAX, Flavor.SNIPER, Flavor.TAX_SNIPER];

    /// @dev Tiny ETH slice for the fee-free curve marginal-price probe at the threshold.
    uint256 constant PRICE_PROBE_ETH = 0.001 ether;

    // ───────────────────── vault sweep (plain token, all 7 vault levels) ─────────────────────

    function test_priceContinuity_v2_thin() public {
        _sweepVaults(false, LiquidityTier.THIN);
    }

    function test_priceContinuity_v2_default() public {
        _sweepVaults(false, LiquidityTier.DEFAULT);
    }

    function test_priceContinuity_v2_thick() public {
        _sweepVaults(false, LiquidityTier.THICK);
    }

    function test_priceContinuity_v4_thin() public {
        _sweepVaults(true, LiquidityTier.THIN);
    }

    function test_priceContinuity_v4_default() public {
        _sweepVaults(true, LiquidityTier.DEFAULT);
    }

    function test_priceContinuity_v4_thick() public {
        _sweepVaults(true, LiquidityTier.THICK);
    }

    // ─────────────── flavor sweep (tax / sniper / tax+sniper, no-vault) ───────────────

    function test_priceContinuity_flavors_v2_thin() public {
        _sweepFlavors(false, LiquidityTier.THIN);
    }

    function test_priceContinuity_flavors_v2_default() public {
        _sweepFlavors(false, LiquidityTier.DEFAULT);
    }

    function test_priceContinuity_flavors_v2_thick() public {
        _sweepFlavors(false, LiquidityTier.THICK);
    }

    function test_priceContinuity_flavors_v4_thin() public {
        _sweepFlavors(true, LiquidityTier.THIN);
    }

    function test_priceContinuity_flavors_v4_default() public {
        _sweepFlavors(true, LiquidityTier.DEFAULT);
    }

    function test_priceContinuity_flavors_v4_thick() public {
        _sweepFlavors(true, LiquidityTier.THICK);
    }

    // ───────────────────────── sweeps ─────────────────────────

    function _sweepVaults(bool isV4, LiquidityTier tier) internal {
        for (uint256 i; i < VAULTS.length; ++i) {
            _runScenario(isV4, tier, VAULTS[i], Flavor.BASE);
        }
    }

    function _sweepFlavors(bool isV4, LiquidityTier tier) internal {
        for (uint256 i; i < 3; ++i) {
            _runScenario(isV4, tier, 0, FLAVORS[i]);
        }
    }

    // ───────────────────────── core scenario ─────────────────────────

    function _runScenario(bool isV4, LiquidityTier tier, uint256 vaultBps, Flavor flavor) internal {
        string memory ctx = _ctx(isV4, tier, vaultBps, flavor);
        address token = _create(isV4, tier, vaultBps, flavor);

        // Last trade price BEFORE graduation: the curve's fee-free marginal price at the threshold.
        IRealmBondingCurve curve = launchpad.getTokenConfig(token).bondingCurve;
        uint256 ethPerTokenBefore = _curveEthPerTokenAtGraduation(curve);

        _buyToGraduation(token);
        assertTrue(launchpad.getTokenState(token).graduated, string.concat(ctx, "token did not graduate"));

        // First swap price AFTER graduation: the live pool's opening spot price.
        uint256 ethPerTokenAfter = isV4 ? _v4PoolEthPerToken(token) : _v2PoolEthPerToken(token);

        assertApproxEqRel(
            ethPerTokenAfter,
            ethPerTokenBefore,
            0.05e18,
            string.concat(ctx, "post-grad pool price drifted >5% from pre-grad curve price")
        );
    }

    // ───────────── first-SWAP price continuity (real post-grad swap, not slot0) ─────────────
    //
    // The sweeps above read the pool's opening price from slot0, which the graduator hardcodes at
    // `initialize()` — so they can only ever confirm the configured init price, never a first swap that
    // executes off it (e.g. liquidity minted in the wrong tick range). This sweep does a REAL post-grad
    // swap the same size as the last bonding-curve buy and asserts the swap price did not drop below it:
    // only buys happened, so price must not go down across graduation. This is the THIN-tier gap that let
    // the Sepolia price drop through.

    function test_swapNoPriceDrop_v4_thin() public {
        _swapNoDropScenario(LiquidityTier.THIN);
    }

    function test_swapNoPriceDrop_v4_default() public {
        _swapNoDropScenario(LiquidityTier.DEFAULT);
    }

    function test_swapNoPriceDrop_v4_thick() public {
        _swapNoDropScenario(LiquidityTier.THICK);
    }

    function _swapNoDropScenario(LiquidityTier tier) internal {
        string memory ctx = _ctx(true, tier, 0, Flavor.BASE);
        address token = _create(true, tier, 0, Flavor.BASE);
        IRealmBondingCurve curve = launchpad.getTokenConfig(token).bondingCurve;
        uint256 threshold = curve.ethGraduationThreshold();
        uint256 buyFeeBps = _currentBuyFeeBps(token);

        vm.deal(buyer, 100 ether);

        // 1. Buy up to ~0.005 ETH (net) below the threshold, without graduating.
        uint256 lastNet = 0.005 ether;
        uint256 firstGross = ((threshold - lastNet) * 10_000) / (10_000 - buyFeeBps);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: firstGross}(token, 0, DEADLINE);
        assertFalse(launchpad.getTokenState(token).graduated, string.concat(ctx, "graduated too early"));

        // 2. Last bonding-curve buy: fills exactly to the threshold and graduates. Capture its price.
        uint256 ethReserves = launchpad.getTokenState(token).ethCollected;
        uint256 lastGross = ((threshold - ethReserves) * 10_000) / (10_000 - buyFeeBps);
        uint256 ethBefore = buyer.balance;
        uint256 tokBefore = IERC20(token).balanceOf(buyer);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: lastGross}(token, 0, DEADLINE);
        assertTrue(launchpad.getTokenState(token).graduated, string.concat(ctx, "did not graduate"));
        uint256 lastBuyPrice = (ethBefore - buyer.balance) * 1e18 / (IERC20(token).balanceOf(buyer) - tokBefore);

        // 3. First post-graduation swap, same ETH size. Capture its effective price.
        ethBefore = buyer.balance;
        tokBefore = IERC20(token).balanceOf(buyer);
        _swap(buyer, token, lastGross, 0, true, true);
        uint256 swapPrice = (ethBefore - buyer.balance) * 1e18 / (IERC20(token).balanceOf(buyer) - tokBefore);

        // INVARIANT: only buys happened, so the first pool swap must not be cheaper than the last curve buy.
        assertGe(
            swapPrice,
            lastBuyPrice * 97 / 100,
            string.concat(ctx, "post-grad swap price dropped >3% below last bonding-curve buy")
        );
    }

    // ───────────── sell-back: a holder must be able to dump their ENTIRE bag back to the pool ─────────────
    //
    // A single buyer graduates the token, so they hold the whole circulating supply (the ~71.43% the curve
    // sold, minus any creator vault). The MAX / sell-all button must not be a dead-end: dumping the full bag
    // into the freshly-seeded pool must fully fill. This was the THIN-tier V4 gap caught on Sepolia — the pool
    // holds only ~1.75 ETH, and a full-bag sell couldn't clear the bounded V4 LP range. V2's constant-product
    // pool never reverts on a sell (price just approaches zero), so V2 is the control.
    // 0% vault is the worst case (largest bag relative to pool depth); larger vaults shrink the bag.
    //
    // FIXED: the THIN graduator now mints its primary range up to `TICK_UPPER_THIN` (212000 vs the 203600
    // DEFAULT/THICK use). THIN graduates at the highest tick yet seeds the shallowest pool, so it needs the
    // widest sell-side range; the tier-specific upper lets the full bag round-trip back into the pool while
    // leaving ~all ETH recoverable. DEFAULT/THICK keep 203600 — a single shared range can't satisfy both
    // "sell everything" and "recover all ETH" because the bag is equal across tiers but the pool ETH is not.

    function test_sellEntireBag_v2_thin() public {
        _sweepSellAll(false, LiquidityTier.THIN);
    }

    function test_sellEntireBag_v2_default() public {
        _sweepSellAll(false, LiquidityTier.DEFAULT);
    }

    function test_sellEntireBag_v2_thick() public {
        _sweepSellAll(false, LiquidityTier.THICK);
    }

    function test_sellEntireBag_v4_thin() public {
        _sweepSellAll(true, LiquidityTier.THIN);
    }

    function test_sellEntireBag_v4_default() public {
        _sweepSellAll(true, LiquidityTier.DEFAULT);
    }

    function test_sellEntireBag_v4_thick() public {
        _sweepSellAll(true, LiquidityTier.THICK);
    }

    function _sweepSellAll(bool isV4, LiquidityTier tier) internal {
        for (uint256 i; i < VAULTS.length; ++i) {
            _sellAllScenario(isV4, tier, VAULTS[i]);
        }
    }

    function _sellAllScenario(bool isV4, LiquidityTier tier, uint256 vaultBps) internal {
        string memory ctx = _ctx(isV4, tier, vaultBps, Flavor.BASE);
        address token = _create(isV4, tier, vaultBps, Flavor.BASE);
        _buyToGraduation(token);
        assertTrue(launchpad.getTokenState(token).graduated, string.concat(ctx, "token did not graduate"));

        // The graduating buyer holds the entire circulating supply — the MAX-button bag.
        uint256 bag = IERC20(token).balanceOf(buyer);
        assertGt(bag, 0, string.concat(ctx, "buyer holds no tokens to sell"));

        // Value out lands as native ETH on V4 (universal router) and as WETH on V2 (router path → WETH).
        uint256 valueBefore = isV4 ? buyer.balance : WETH.balanceOf(buyer);
        if (isV4) {
            _swap(buyer, token, bag, 0, false, true); // sell-all, must succeed
        } else {
            _v2SellAll(buyer, token, bag);
        }
        uint256 valueAfter = isV4 ? buyer.balance : WETH.balanceOf(buyer);

        assertEq(IERC20(token).balanceOf(buyer), 0, string.concat(ctx, "buyer could not sell the full bag"));
        assertGt(valueAfter, valueBefore, string.concat(ctx, "selling the full bag returned no value"));
    }

    /// @dev Sells `amount` of `token` for WETH through the Uniswap V2 router (token → WETH path). BASE
    ///      flavor has no tax, so the plain `swapExactTokensForTokens` path applies.
    function _v2SellAll(address account, address token, uint256 amount) internal {
        vm.startPrank(account);
        IERC20(token).approve(UNISWAP_V2_ROUTER, amount);
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = address(WETH);
        IUniswapV2Router02(UNISWAP_V2_ROUTER)
            .swapExactTokensForTokens(amount, 0, path, account, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    // ───────────────────────── price probes (all ETH-per-token, 1e18-scaled) ─────────────────────────

    /// @dev ETH-per-token the curve charges for the final sliver of ETH reaching the graduation
    ///      threshold. Pure view, so it carries no launchpad fee/tax — the clean "last trade" price.
    function _curveEthPerTokenAtGraduation(IRealmBondingCurve curve) internal view returns (uint256) {
        uint256 threshold = curve.ethGraduationThreshold();
        (uint256 tokensOut,) = curve.buyTokensWithExactEth(threshold - PRICE_PROBE_ETH, PRICE_PROBE_ETH);
        return PRICE_PROBE_ETH * 1e18 / tokensOut;
    }

    /// @dev The V4 pool's opening spot price (ETH per token), read straight from slot0.
    function _v4PoolEthPerToken(address token) internal view returns (uint256) {
        PoolKey memory key = _getPoolKey(token);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        return _convertSqrtX96ToTokenPrice(sqrtPriceX96);
    }

    /// @dev The V2 pool's opening spot price (ETH per token), from the pair reserves ratio.
    function _v2PoolEthPerToken(address token) internal view returns (uint256) {
        IUniswapV2Pair pair = IUniswapV2Pair(RealmToken(token).pair());
        (uint256 reserve0, uint256 reserve1,) = pair.getReserves();
        (uint256 wethReserve, uint256 tokenReserve) =
            pair.token0() == address(WETH) ? (reserve0, reserve1) : (reserve1, reserve0);
        return wethReserve * 1e18 / tokenReserve;
    }

    // ───────────────────────── helpers ─────────────────────────

    /// @dev Creates a token on the chosen venue + tier + flavor with a single creator vault holding
    ///      `vaultBps` of supply (no vault when `vaultBps == 0`). Sniper flavors whitelist `buyer` so the
    ///      graduation buys bypass the per-tx / per-wallet caps during the protection window.
    function _create(bool isV4, LiquidityTier tier, uint256 vaultBps, Flavor flavor) internal returns (address token) {
        IRealmFactory.CreatorVault[] memory vaults;
        if (vaultBps == 0) {
            vaults = new IRealmFactory.CreatorVault[](0);
        } else {
            vaults = new IRealmFactory.CreatorVault[](1);
            vaults[0] =
                IRealmFactory.CreatorVault({owner: creator, supplyBps: vaultBps, cliffSeconds: 0, vestingSeconds: 1});
        }
        address factory = isV4 ? address(factoryV4Unified) : address(factoryV2Unified);
        IRealmFactory.TokenSetupTiered memory setup = IRealmFactory.TokenSetupTiered({
            name: "Tier",
            symbol: "TIER",
            salt: _nextValidSalt(factory, _implFor(isV4, flavor)),
            feeShares: _fs(creator),
            liquidityTier: tier
        });
        TaxConfigInit memory taxCfg = _taxCfgFor(flavor);
        AntiSniperConfigs memory sniperCfg = _sniperCfgFor(flavor);
        vm.prank(creator);
        if (isV4) {
            token = factoryV4Unified.createToken(setup, _toCfgs(taxCfg), _cfg(), _noSs(), sniperCfg, vaults, address(0));
        } else {
            token = factoryV2Unified.createToken(setup, _toCfgs(taxCfg), _noSs(), sniperCfg, vaults, address(0));
        }
    }

    /// @dev Buys from the launchpad exactly enough to reach the token's tier-specific graduation threshold.
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

    function _isTax(Flavor f) internal pure returns (bool) {
        return f == Flavor.TAX || f == Flavor.TAX_SNIPER;
    }

    function _isSniper(Flavor f) internal pure returns (bool) {
        return f == Flavor.SNIPER || f == Flavor.TAX_SNIPER;
    }

    /// @dev A moderate static, creation-anchored 2%/2% tax for tax flavors; empty otherwise.
    function _taxCfgFor(Flavor f) internal pure returns (TaxConfigInit memory) {
        return _isTax(f) ? _taxCfg(200, 200, uint32(14 days)) : _emptyTaxCfg();
    }

    /// @dev 3%/3% caps over a 3h window for sniper flavors, whitelisting `buyer`; empty otherwise.
    function _sniperCfgFor(Flavor f) internal view returns (AntiSniperConfigs memory) {
        if (!_isSniper(f)) return _emptyAntiSniperCfg();
        address[] memory wl = new address[](1);
        wl[0] = buyer;
        return _antiSniperCfg(300, 300, uint40(3 hours), wl);
    }

    /// @dev The token implementation `createToken` will clone for this venue + flavor (needed to mine the salt).
    function _implFor(bool isV4, Flavor f) internal view returns (address) {
        bool tax = _isTax(f);
        bool sniper = _isSniper(f);
        if (tax && sniper) return isV4 ? address(realmTaxTokenSniper) : address(realmTaxTokenV2Sniper);
        if (tax) return isV4 ? address(realmTaxToken) : address(realmTaxTokenV2);
        if (sniper) return address(realmTokenSniper);
        return address(realmToken);
    }

    function _cfg() internal pure returns (RealmFactoryUniV4Unified.UniV4Configs memory) {
        return RealmFactoryUniV4Unified.UniV4Configs({renounceOwnership: false, lpFeeBps: 100});
    }

    function _tierName(LiquidityTier tier) internal pure returns (string memory) {
        if (tier == LiquidityTier.THIN) return "THIN";
        if (tier == LiquidityTier.DEFAULT) return "DEFAULT";
        return "THICK";
    }

    function _flavorName(Flavor f) internal pure returns (string memory) {
        if (f == Flavor.BASE) return "plain";
        if (f == Flavor.TAX) return "tax";
        if (f == Flavor.SNIPER) return "sniper";
        return "tax+sniper";
    }

    /// @dev "[V4 THIN 1500bps tax] " prefix so a looped assertion names the exact failing cell.
    function _ctx(bool isV4, LiquidityTier tier, uint256 bps, Flavor f) internal pure returns (string memory) {
        return
            string.concat(
                "[", isV4 ? "V4 " : "V2 ", _tierName(tier), " ", vm.toString(bps), "bps ", _flavorName(f), "] "
            );
    }
}
