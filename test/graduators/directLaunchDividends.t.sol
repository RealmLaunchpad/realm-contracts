// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DirectLaunchQuotesTests} from "test/graduators/directLaunchQuotes.t.sol";
import {RealmFactoryUniV4Direct} from "src/factories/RealmFactoryUniV4Direct.sol";
import {RealmTaxableTokenUniV4} from "src/tokens/RealmTaxableTokenUniV4.sol";
import {RealmTaxableTokenUniV4Base} from "src/tokens/RealmTaxableTokenUniV4Base.sol";
import {DividendDistribution} from "src/tokens/DividendDistribution.sol";
import {KeeperGated} from "src/tokens/KeeperGated.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {RealmToken} from "src/tokens/RealmToken.sol";
import {TaxConfigsWithDirectAllocation, EarningsAllocationMultiConfig} from "src/interfaces/IRealmTaxableToken.sol";
import {Hop} from "src/interfaces/IRealmDividendSwapRegistry.sol";
import {DividendRouteLib} from "src/libraries/DividendRouteLib.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @notice Dividends on the direct venue, on every quote: the allocation-aware `createToken`, and a
///         dividends slice that arrives in an ERC20 quote and is paid out in that quote, in the token
///         itself, in native, or in a third asset. Quoted against real mainnet USDC so the registry legs
///         cross real pools: USDC -> ETH on V4, ETH -> DAI on the V2 pair.
contract DirectLaunchDividendsTests is DirectLaunchQuotesTests {
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    uint24 internal constant V4_FEE_005 = 500;
    int24 internal constant V4_SPACING_10 = 10;
    address internal stranger = makeAddr("stranger");

    /////////////////////////// HELPERS ///////////////////////////

    function _v4Route(address currency) internal pure returns (bytes memory) {
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({currency: currency, fee: V4_FEE_005, tickSpacing: V4_SPACING_10, hooks: address(0)});
        return DividendRouteLib.encodeV4(hops);
    }

    function _one(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    function _one(bytes memory r) internal pure returns (bytes[] memory list) {
        list = new bytes[](1);
        list[0] = r;
    }

    /// @dev A 4% sell tax for two weeks plus a 50% dividends slice paid in `asset`, bought through
    ///      `assetRoute`, with `quoteRoutes` positional to the pairs.
    function _cfg(address asset, bytes memory assetRoute, bytes[] memory quoteRoutes)
        internal
        pure
        returns (TaxConfigsWithDirectAllocation memory)
    {
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        return TaxConfigsWithDirectAllocation({
            buyTaxBps: 0,
            sellTaxBps: 400,
            taxDurationSeconds: uint32(14 days),
            startTaxFromLaunch: true,
            buyTaxDecayStartBps: 0,
            sellTaxDecayStartBps: 0,
            taxDecayDuration: 0,
            earningsAllocation: EarningsAllocationMultiConfig({
                burnBps: 0,
                dividendsBps: 5_000,
                liquidityBps: 0,
                dividendTokens: _one(asset),
                dividendWeightsBps: weights,
                dividendRoutes: _one(assetRoute)
            }),
            quoteRoutes: quoteRoutes
        });
    }

    function _launch(RealmFactoryUniV4Direct.DirectPair[] memory pairs, TaxConfigsWithDirectAllocation memory cfg)
        internal
        returns (RealmTaxableTokenUniV4 token)
    {
        vm.prank(creator);
        token = RealmTaxableTokenUniV4(
            payable(directFactory.createToken(
                    _setup(true),
                    pairs,
                    cfg,
                    _emptyAntiSniperCfg(),
                    new IRealmFactory.CreatorVault[](0),
                    _noDevBuy(),
                    address(0)
                ))
        );
    }

    function _usdcPair() internal pure returns (RealmFactoryUniV4Direct.DirectPair[] memory p) {
        p = new RealmFactoryUniV4Direct.DirectPair[](1);
        p[0] = RealmFactoryUniV4Direct.DirectPair({quote: USDC, weightBps: 10_000, launchTick: QC_LAUNCH_TICK});
    }

    /// @dev A USDC-paired token paying in `asset`, with alice holding a bag and the dividends slice of
    ///      her buy's LP fee buffered in USDC.
    function _earningToken(address asset, bytes memory assetRoute, bytes[] memory quoteRoutes)
        internal
        returns (RealmTaxableTokenUniV4 token)
    {
        token = _launch(_usdcPair(), _cfg(asset, assetRoute, quoteRoutes));
        _buyAndSettle(address(token), 10_000e6);
    }

    /// @dev Alice buys on the USDC pool and the hook's claimed fees are redeemed, which is what pushes
    ///      the LP-fee creator share through the allocation split.
    function _buyAndSettle(address token, uint256 usdcIn) internal {
        deal(USDC, alice, usdcIn);
        _swapQuotePool(alice, token, USDC, true, usdcIn);
        anyPairHook.settleFees(token, USDC);
    }

    function _pending(RealmTaxableTokenUniV4 token) internal view returns (uint256) {
        return token.quoteDividendPending(USDC)[0];
    }

    function _active(RealmTaxableTokenUniV4 token) internal view returns (bool) {
        (, uint40 lastDistribution,,,,,,) = token.dividendAssets(0);
        return lastDistribution != 0;
    }

    /////////////////////////// THE ALLOCATION OVERLOAD ///////////////////////////

    function test_directAlloc_configuresAndActivatesAtGraduation() public {
        RealmTaxableTokenUniV4 token = _launch(_usdcPair(), _cfg(USDC, _v4Route(USDC), new bytes[](0)));
        assertEq(uint256(token.dividendsBps()), 5_000, "allocation stored");
        assertEq(token.dividendToken(), USDC, "payout asset stored");
        assertTrue(_active(token), "activated by the graduation the seed triggered");
        assertTrue(IRealmToken(address(token)).graduated());
    }

    /// @dev No tax at all: the LP-fee share is the whole earnings stream, and the allocation alone
    ///      routes the clone to the taxable implementation — as the preview must also say.
    function test_directAlloc_zeroTaxRevenueShareTokenClonesTheTaxableImpl() public {
        TaxConfigsWithDirectAllocation memory cfg = _cfg(USDC, _v4Route(USDC), new bytes[](0));
        cfg.sellTaxBps = 0;
        cfg.taxDurationSeconds = 0;
        assertEq(
            directFactory.previewTokenImplementation(cfg, _emptyAntiSniperCfg()),
            address(realmTaxToken),
            "an allocation alone selects the taxable implementation"
        );
        RealmTaxableTokenUniV4 token = _launch(_usdcPair(), cfg);
        assertEq(uint256(token.sellTaxBps()), 0, "no tax");
        _buyAndSettle(address(token), 10_000e6);
        assertGt(_pending(token), 0, "the LP-fee share alone feeds the dividends buffer");
    }

    function test_directAlloc_rejectsARouteOnANativePair() public {
        RealmFactoryUniV4Direct.DirectPair[] memory pairs = _pairs(address(0), LAUNCH_TICK);
        TaxConfigsWithDirectAllocation memory cfg = _cfg(address(0), "", _one(_v4Route(USDC)));
        vm.prank(creator);
        vm.expectRevert(RealmFactoryUniV4Direct.InvalidQuoteRoutes.selector);
        directFactory.createToken(
            _setup(true),
            pairs,
            cfg,
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            _noDevBuy(),
            address(0)
        );
    }

    function test_directAlloc_rejectsAPayoutAssetWithoutAShare() public {
        TaxConfigsWithDirectAllocation memory cfg = _cfg(USDC, _v4Route(USDC), new bytes[](0));
        cfg.earningsAllocation.dividendsBps = 0;
        cfg.earningsAllocation.burnBps = 1_000;
        vm.prank(creator);
        vm.expectRevert(IRealmFactory.DividendAssetWithoutShare.selector);
        directFactory.createToken(
            _setup(true),
            _usdcPair(),
            cfg,
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            _noDevBuy(),
            address(0)
        );
    }

    /// @dev A leg that has to leave the quote needs the quote's route, and the venue check happens at
    ///      creation: an empty entry means the V2 pair, which cannot be walked backwards.
    function test_directAlloc_refusesAMissingQuoteRouteAtCreation() public {
        TaxConfigsWithDirectAllocation memory cfg = _cfg(DAI, "", new bytes[](0));
        vm.prank(creator);
        vm.expectRevert(RealmTaxableTokenUniV4Base.QuoteRouteUnsupported.selector);
        directFactory.createToken(
            _setup(true),
            _usdcPair(),
            cfg,
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            _noDevBuy(),
            address(0)
        );
    }

    /// @dev The native pair on this venue is the shared machine, untouched: earnings buffer as native
    ///      and `processDividends(0, …)` pays native.
    function test_directAlloc_nativePairPaysNativeDividends() public {
        RealmTaxableTokenUniV4 token = _launch(_pairs(address(0), LAUNCH_TICK), _cfg(address(0), "", new bytes[](0)));
        _swapBuyV4(alice, address(token), 1 ether, 0, true);
        vm.deal(address(this), 1 ether);
        token.accrueFees{value: 1 ether}();
        (,,,,,, uint88 pendingNative,) = token.dividendAssets(0);
        // Half of the accrual, plus half of the creator's LP-fee share of alice's buy.
        assertGe(uint256(pendingNative), 0.5 ether, "half of the earnings buffered as native");

        uint256 before = alice.balance;
        token.processDividends(0, 0, _one(alice));
        assertGt(alice.balance - before, 0.49 ether, "alice, the only holder, got nearly all of it in native");
    }

    /////////////////////////// QUOTE-DENOMINATED LEGS ///////////////////////////

    /// @dev Payout IS the quote: no swap, no cap, no keeper needed once stale; the whole buffer credits.
    function test_quoteDividends_passthroughPaysTheQuoteItself() public {
        RealmTaxableTokenUniV4 token = _earningToken(USDC, _v4Route(USDC), new bytes[](0));
        uint256 buffered = _pending(token);
        assertGt(buffered, 0, "the dividends slice arrived in USDC");

        vm.expectEmit(true, true, false, true, address(token));
        emit DividendDistribution.DividendsFunded(USDC, USDC, buffered, buffered);
        uint256 before = IERC20(USDC).balanceOf(alice);
        token.processDividends(0, USDC, 0, _one(alice));

        assertEq(_pending(token), 0, "the whole buffer was credited at once");
        assertApproxEqRel(IERC20(USDC).balanceOf(alice) - before, buffered, 0.01e18, "alice was paid in USDC");
        assertEq(token.committedDividends(USDC), token.dividendsOwed(), "what is still owed is committed");
    }

    function test_quoteDividends_passthroughOpensToAnyoneOnceStale() public {
        RealmTaxableTokenUniV4 token = _earningToken(USDC, _v4Route(USDC), new bytes[](0));
        vm.prank(stranger);
        vm.expectRevert(KeeperGated.NotAKeeper.selector);
        token.processDividends(0, USDC, 0, _one(alice));

        vm.warp(block.timestamp + token.STALE_DIVIDEND_WINDOW());
        vm.prank(stranger);
        token.processDividends(0, USDC, 0, _one(alice));
        assertEq(_pending(token), 0, "a stale passthrough is anyone's to trigger");
    }

    /// @dev The buffer is money holders are owed: `rescueTokens` sees none of it as stray.
    function test_quoteDividends_bufferIsOutOfTheOwnersReach() public {
        RealmTaxableTokenUniV4 token = _earningToken(USDC, _v4Route(USDC), new bytes[](0));
        uint256 held = IERC20(USDC).balanceOf(address(token));
        vm.prank(creator);
        token.rescueTokens(USDC);
        assertEq(IERC20(USDC).balanceOf(address(token)), held, "nothing left the token");
    }

    /// @dev Payout in the token itself: a buy-back on the QUOTE's pool, capped at a quarter of the
    ///      buffer per call, keeper-only however stale.
    function test_quoteDividends_selfTokenBuysBackOnTheQuotePool() public {
        RealmTaxableTokenUniV4 token = _earningToken(realmTaxToken.DIVIDEND_SELF_TOKEN(), "", new bytes[](0));
        uint256 buffered = _pending(token);
        uint256 bag = IERC20(address(token)).balanceOf(alice);

        vm.expectEmit(false, false, false, true, address(token));
        emit RealmTaxableTokenUniV4Base.DividendBuyBackInitiated(buffered / 4);
        token.processDividends(0, USDC, 0, _one(alice));

        assertGt(IERC20(address(token)).balanceOf(alice), bag, "alice was paid in the token");
        uint256 left = _pending(token);
        assertGe(left, buffered * 3 / 4, "at most a quarter was spent");
        assertLt(left, buffered, "and something was");

        vm.warp(block.timestamp + token.STALE_DIVIDEND_WINDOW());
        vm.roll(block.number + 1);
        vm.prank(stranger);
        vm.expectRevert(KeeperGated.NotAKeeper.selector);
        token.processDividends(0, USDC, 0, _one(alice));
    }

    /// @dev Payout in native from a USDC pool: the registry walks USDC's route backwards. The keeper's
    ///      cut comes out of that native, as it does on every registry conversion.
    function test_quoteDividends_nativePayoutFromAnErc20Quote() public {
        address keeperWallet = makeAddr("keeperWallet");
        vm.prank(admin);
        dividendSwapRegistry.setKeeperFunding(keeperWallet);
        RealmTaxableTokenUniV4 token = _earningToken(address(0), "", _one(_v4Route(USDC)));

        uint256 before = alice.balance;
        token.processDividends(0, USDC, 0, _one(alice));

        assertGt(alice.balance - before, 0, "alice was paid in native");
        assertGt(keeperWallet.balance, 0, "the keeper was funded in native");
        assertGt(_pending(token), 0, "only a slice of the buffer was spent");
    }

    /// @dev Payout in a third asset from a USDC pool: USDC -> ETH on V4, ETH -> DAI on the V2 pair.
    function test_quoteDividends_thirdAssetFromAnErc20Quote() public {
        RealmTaxableTokenUniV4 token = _earningToken(DAI, "", _one(_v4Route(USDC)));
        uint256 before = IERC20(DAI).balanceOf(alice);
        token.processDividends(0, USDC, 0, _one(alice));
        assertGt(IERC20(DAI).balanceOf(alice) - before, 0, "alice was paid in DAI");
        assertEq(token.committedDividends(DAI), token.dividendsOwed(), "the DAI still owed is committed");
    }

    /// @dev A quote that is itself the payout asset needs no second route; its own is walked backwards
    ///      when a SIBLING asset has to leave it. Here USDC pays half in USDC and half in DAI.
    function test_quoteDividends_quoteRouteReusedWhenTheQuoteIsAPayoutAsset() public {
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5_000;
        weights[1] = 5_000;
        address[] memory assets = new address[](2);
        assets[0] = USDC;
        assets[1] = DAI;
        bytes[] memory routes = new bytes[](1);
        routes[0] = _v4Route(USDC);
        TaxConfigsWithDirectAllocation memory cfg = _cfg(USDC, _v4Route(USDC), new bytes[](0));
        cfg.earningsAllocation.dividendTokens = assets;
        cfg.earningsAllocation.dividendWeightsBps = weights;
        cfg.earningsAllocation.dividendRoutes = routes;
        RealmTaxableTokenUniV4 token = _launch(_usdcPair(), cfg);
        _buyAndSettle(address(token), 10_000e6);

        uint128[3] memory pending = token.quoteDividendPending(USDC);
        assertGt(pending[0], 0, "USDC leg buffered");
        assertApproxEqAbs(uint256(pending[0]), uint256(pending[1]), 1, "split evenly");

        uint256 dai = IERC20(DAI).balanceOf(alice);
        token.processDividends(1, USDC, 0, _one(alice));
        assertGt(IERC20(DAI).balanceOf(alice) - dai, 0, "the DAI leg left USDC through USDC's own route");
    }

    /// @dev Two pools, one payout: the native pool's slice takes the shared machine, the USDC pool's the
    ///      quote path, and both pay USDC.
    function test_quoteDividends_mixedPairsBothPayTheSameAsset() public {
        RealmFactoryUniV4Direct.DirectPair[] memory pairs = new RealmFactoryUniV4Direct.DirectPair[](2);
        pairs[0] = RealmFactoryUniV4Direct.DirectPair({quote: address(0), weightBps: 5_000, launchTick: LAUNCH_TICK});
        pairs[1] = RealmFactoryUniV4Direct.DirectPair({quote: USDC, weightBps: 5_000, launchTick: QC_LAUNCH_TICK});
        RealmTaxableTokenUniV4 token = _launch(pairs, _cfg(USDC, _v4Route(USDC), new bytes[](0)));
        _buyAndSettle(address(token), 10_000e6);
        vm.deal(address(this), 2 ether);
        token.accrueFees{value: 2 ether}();

        uint256 before = IERC20(USDC).balanceOf(alice);
        token.processDividends(0, USDC, 0, _one(alice));
        uint256 fromUsdcPool = IERC20(USDC).balanceOf(alice) - before;
        assertGt(fromUsdcPool, 0, "the USDC pool's slice paid as-is");

        vm.roll(block.number + 1);
        token.processDividends(0, address(0), 0, _one(alice));
        assertGt(IERC20(USDC).balanceOf(alice) - before, fromUsdcPool, "the native pool's slice was converted to USDC");
    }

    function test_quoteDividends_unknownQuoteReverts() public {
        RealmTaxableTokenUniV4 token = _earningToken(USDC, _v4Route(USDC), new bytes[](0));
        vm.expectRevert(RealmToken.UnknownQuote.selector);
        token.processDividends(0, DAI, 0, _one(alice));
    }
}
