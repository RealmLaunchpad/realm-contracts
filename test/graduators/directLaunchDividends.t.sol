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
import {RealmTaxableToken} from "src/tokens/RealmTaxableToken.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {TaxConfigsWithMultiAllocation} from "src/interfaces/IRealmTaxableToken.sol";
import {IAllowanceTransfer} from "lib/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";

/// @notice Stand-in for the universal router on a PARTIAL fill of an ERC20-quoted buy-back: the pool
///         pulls half the quote through Permit2, the other half never leaves the token, and a fixed
///         amount of the token is delivered either way.
contract HalfFillQuoteBuyBackRouterStub {
    address internal immutable TOKEN;
    address internal immutable QUOTE;
    address internal immutable PERMIT2;

    constructor(address token, address quote, address permit2) {
        TOKEN = token;
        QUOTE = quote;
        PERMIT2 = permit2;
    }

    function execute(bytes calldata, bytes[] calldata inputs, uint256) external payable {
        // `params[1]` is the `SETTLE_ALL` pair: (quote, amountIn).
        (, bytes[] memory params) = abi.decode(inputs[0], (bytes, bytes[]));
        (, uint256 amountIn) = abi.decode(params[1], (address, uint256));
        IAllowanceTransfer(PERMIT2).transferFrom(msg.sender, address(0xdEaD), uint160(amountIn / 2), QUOTE);
        IERC20(TOKEN).transfer(msg.sender, 1e18);
    }
}

/// @notice Dividends on the direct venue, on every quote: the allocation-aware `createToken`, and a
///         dividends slice that arrives in an ERC20 quote and is paid out in that quote, in the token
///         itself, in native, or in a third asset. Quoted against real Robinhood AAPL so the registry
///         legs cross real pools: AAPL -> ETH on V4, ETH -> MSFT on the V2 pair. AAPL is the quote
///         because its native V4 pool is the one hookless, static-fee pool with live liquidity at the
///         pinned block; USDG would mirror USDC's 6 decimals but its pool is empty there.
contract DirectLaunchDividendsTests is DirectLaunchQuotesTests {
    address internal constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address internal constant MSFT = 0xe93237C50D904957Cf27E7B1133b510C669c2e74;
    /// @dev AAPL's real native V4 pool on Robinhood: hookless, static fee.
    uint24 internal constant V4_FEE_AAPL = 8_000;
    int24 internal constant V4_SPACING_AAPL = 80;
    address internal stranger = makeAddr("stranger");

    function setUp() public virtual override {
        super.setUp();
        _whitelist(AAPL, QC_PER_ETH);
        // Priced 1:1 with ETH: the launch opens at 2.25 MSFT of market cap.
        _whitelist(MSFT, 1e18);
        // Robinhood's V2 pairs are thin — the xStock/WETH pairs hold ~0.005 ETH a side, far under the
        // default depth floor of 10x MAX_EARNINGS_PER_PROCESS. The floor is per-chain configurable for
        // exactly this reason; drop it so the V2 leg is exercised rather than rejected as too shallow.
        vm.prank(admin);
        dividendSwapRegistry.setDefaultThreshold(0.001 ether);
    }

    /////////////////////////// HELPERS ///////////////////////////

    function _v4Route(address currency) internal pure returns (bytes memory) {
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({currency: currency, fee: V4_FEE_AAPL, tickSpacing: V4_SPACING_AAPL, hooks: address(0)});
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

    function _aaplPair() internal pure returns (RealmFactoryUniV4Direct.DirectPair[] memory p) {
        p = new RealmFactoryUniV4Direct.DirectPair[](1);
        p[0] = RealmFactoryUniV4Direct.DirectPair({quote: AAPL, weightBps: 10_000});
    }

    /// @dev A AAPL-paired token paying in `asset`, with alice holding a bag and the dividends slice of
    ///      her buy's LP fee buffered in AAPL.
    function _earningToken(address asset, bytes memory assetRoute, bytes[] memory quoteRoutes)
        internal
        returns (RealmTaxableTokenUniV4 token)
    {
        token = _launch(_aaplPair(), _cfg(asset, assetRoute, quoteRoutes));
        _buyAndSettle(address(token), 10_000e18);
    }

    /// @dev Alice buys on the AAPL pool and the hook's claimed fees are redeemed, which is what pushes
    ///      the LP-fee creator share through the allocation split.
    function _buyAndSettle(address token, uint256 aaplIn) internal {
        deal(AAPL, alice, aaplIn);
        _swapQuotePool(alice, token, AAPL, true, aaplIn);
        anyPairHook.settleFees(token, AAPL);
    }

    function _pending(RealmTaxableTokenUniV4 token) internal view returns (uint256) {
        return token.quoteDividendPending(AAPL)[0];
    }

    function _active(RealmTaxableTokenUniV4 token) internal view returns (bool) {
        (, uint40 lastDistribution,,,,,,) = token.dividendAssets(0);
        return lastDistribution != 0;
    }

    /////////////////////////// THE ALLOCATION OVERLOAD ///////////////////////////

    function test_directAlloc_configuresAndActivatesAtGraduation() public {
        RealmTaxableTokenUniV4 token = _launch(_aaplPair(), _cfg(AAPL, _v4Route(AAPL), new bytes[](0)));
        assertEq(uint256(token.dividendsBps()), 5_000, "allocation stored");
        assertEq(token.dividendToken(), AAPL, "payout asset stored");
        assertTrue(_active(token), "activated by the graduation the seed triggered");
        assertTrue(IRealmToken(address(token)).graduated());
    }

    /// @dev No tax at all: the LP-fee share is the whole earnings stream, and the allocation alone
    ///      routes the clone to the taxable implementation — as the preview must also say.
    function test_directAlloc_zeroTaxRevenueShareTokenClonesTheTaxableImpl() public {
        TaxConfigsWithDirectAllocation memory cfg = _cfg(AAPL, _v4Route(AAPL), new bytes[](0));
        cfg.sellTaxBps = 0;
        cfg.taxDurationSeconds = 0;
        assertEq(
            directFactory.previewTokenImplementation(
                _previewSetup(), _pairs(address(0)), cfg, _emptyAntiSniperCfg(), _noVaults(), _noDevBuy(), address(0)
            ),
            address(realmTaxToken),
            "an allocation alone selects the taxable implementation"
        );
        RealmTaxableTokenUniV4 token = _launch(_aaplPair(), cfg);
        assertEq(uint256(token.sellTaxBps()), 0, "no tax");
        _buyAndSettle(address(token), 10_000e18);
        assertGt(_pending(token), 0, "the LP-fee share alone feeds the dividends buffer");
    }

    function test_directAlloc_rejectsARouteOnANativePair() public {
        RealmFactoryUniV4Direct.DirectPair[] memory pairs = _pairs(address(0));
        TaxConfigsWithDirectAllocation memory cfg = _cfg(address(0), "", _one(_v4Route(AAPL)));
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
        TaxConfigsWithDirectAllocation memory cfg = _cfg(AAPL, _v4Route(AAPL), new bytes[](0));
        cfg.earningsAllocation.dividendsBps = 0;
        cfg.earningsAllocation.burnBps = 1_000;
        vm.prank(creator);
        vm.expectRevert(IRealmFactory.DividendAssetWithoutShare.selector);
        directFactory.createToken(
            _setup(true),
            _aaplPair(),
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
        TaxConfigsWithDirectAllocation memory cfg = _cfg(MSFT, "", new bytes[](0));
        vm.prank(creator);
        vm.expectRevert(RealmTaxableTokenUniV4Base.QuoteRouteUnsupported.selector);
        directFactory.createToken(
            _setup(true),
            _aaplPair(),
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
        RealmTaxableTokenUniV4 token = _launch(_pairs(address(0)), _cfg(address(0), "", new bytes[](0)));
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
        RealmTaxableTokenUniV4 token = _earningToken(AAPL, _v4Route(AAPL), new bytes[](0));
        uint256 buffered = _pending(token);
        assertGt(buffered, 0, "the dividends slice arrived in AAPL");

        vm.expectEmit(true, true, false, true, address(token));
        emit DividendDistribution.DividendsFunded(AAPL, AAPL, buffered, buffered);
        uint256 before = IERC20(AAPL).balanceOf(alice);
        token.processDividends(0, AAPL, 0, _one(alice));

        assertEq(_pending(token), 0, "the whole buffer was credited at once");
        assertApproxEqRel(IERC20(AAPL).balanceOf(alice) - before, buffered, 0.01e18, "alice was paid in AAPL");
        assertEq(token.committedDividends(AAPL), token.dividendsOwed(), "what is still owed is committed");
    }

    function test_quoteDividends_passthroughOpensToAnyoneOnceStale() public {
        RealmTaxableTokenUniV4 token = _earningToken(AAPL, _v4Route(AAPL), new bytes[](0));
        vm.prank(stranger);
        vm.expectRevert(KeeperGated.NotAKeeper.selector);
        token.processDividends(0, AAPL, 0, _one(alice));

        vm.warp(block.timestamp + token.STALE_DIVIDEND_WINDOW());
        vm.prank(stranger);
        token.processDividends(0, AAPL, 0, _one(alice));
        assertEq(_pending(token), 0, "a stale passthrough is anyone's to trigger");
    }

    /// @dev The buffer is money holders are owed: `rescueTokens` sees none of it as stray.
    function test_quoteDividends_bufferIsOutOfTheOwnersReach() public {
        RealmTaxableTokenUniV4 token = _earningToken(AAPL, _v4Route(AAPL), new bytes[](0));
        uint256 held = IERC20(AAPL).balanceOf(address(token));
        vm.prank(creator);
        token.rescueTokens(AAPL);
        assertEq(IERC20(AAPL).balanceOf(address(token)), held, "nothing left the token");
    }

    /// @dev Payout in the token itself: a buy-back on the QUOTE's pool, capped at a quarter of the
    ///      buffer per call, keeper-only however stale.
    function test_quoteDividends_selfTokenBuysBackOnTheQuotePool() public {
        RealmTaxableTokenUniV4 token = _earningToken(realmTaxToken.DIVIDEND_SELF_TOKEN(), "", new bytes[](0));
        uint256 buffered = _pending(token);
        uint256 bag = IERC20(address(token)).balanceOf(alice);

        vm.expectEmit(true, false, false, true, address(token));
        emit RealmTaxableTokenUniV4Base.DividendBuyBackInitiated(AAPL, buffered / 4);
        token.processDividends(0, AAPL, 0, _one(alice));

        assertGt(IERC20(address(token)).balanceOf(alice), bag, "alice was paid in the token");
        uint256 left = _pending(token);
        assertGe(left, buffered * 3 / 4, "at most a quarter was spent");
        assertLt(left, buffered, "and something was");

        vm.warp(block.timestamp + token.STALE_DIVIDEND_WINDOW());
        vm.roll(block.number + 1);
        vm.prank(stranger);
        vm.expectRevert(KeeperGated.NotAKeeper.selector);
        token.processDividends(0, AAPL, 0, _one(alice));
    }

    /// @dev Payout in native from a AAPL pool: the registry walks AAPL's route backwards. The keeper's
    ///      cut comes out of that native, as it does on every registry conversion.
    function test_quoteDividends_nativePayoutFromAnErc20Quote() public {
        address keeperWallet = makeAddr("keeperWallet");
        vm.prank(admin);
        dividendSwapRegistry.setKeeperFunding(keeperWallet);
        RealmTaxableTokenUniV4 token = _earningToken(address(0), "", _one(_v4Route(AAPL)));

        uint256 before = alice.balance;
        token.processDividends(0, AAPL, 0, _one(alice));

        assertGt(alice.balance - before, 0, "alice was paid in native");
        assertGt(keeperWallet.balance, 0, "the keeper was funded in native");
        assertGt(_pending(token), 0, "only a slice of the buffer was spent");
    }

    /// @dev Payout in a third asset from a AAPL pool: AAPL -> ETH on V4, ETH -> MSFT on the V2 pair.
    function test_quoteDividends_thirdAssetFromAnErc20Quote() public {
        RealmTaxableTokenUniV4 token = _earningToken(MSFT, "", _one(_v4Route(AAPL)));
        uint256 before = IERC20(MSFT).balanceOf(alice);
        token.processDividends(0, AAPL, 0, _one(alice));
        assertGt(IERC20(MSFT).balanceOf(alice) - before, 0, "alice was paid in MSFT");
        assertEq(token.committedDividends(MSFT), token.dividendsOwed(), "the MSFT still owed is committed");
    }

    /// @dev A quote that is itself the payout asset needs no second route; its own is walked backwards
    ///      when a SIBLING asset has to leave it. Here AAPL pays half in AAPL and half in MSFT.
    function test_quoteDividends_quoteRouteReusedWhenTheQuoteIsAPayoutAsset() public {
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5_000;
        weights[1] = 5_000;
        address[] memory assets = new address[](2);
        assets[0] = AAPL;
        assets[1] = MSFT;
        bytes[] memory routes = new bytes[](1);
        routes[0] = _v4Route(AAPL);
        TaxConfigsWithDirectAllocation memory cfg = _cfg(AAPL, _v4Route(AAPL), new bytes[](0));
        cfg.earningsAllocation.dividendTokens = assets;
        cfg.earningsAllocation.dividendWeightsBps = weights;
        cfg.earningsAllocation.dividendRoutes = routes;
        RealmTaxableTokenUniV4 token = _launch(_aaplPair(), cfg);
        _buyAndSettle(address(token), 10_000e18);

        uint128[3] memory pending = token.quoteDividendPending(AAPL);
        assertGt(pending[0], 0, "AAPL leg buffered");
        assertApproxEqAbs(uint256(pending[0]), uint256(pending[1]), 1, "split evenly");

        uint256 dai = IERC20(MSFT).balanceOf(alice);
        token.processDividends(1, AAPL, 0, _one(alice));
        assertGt(IERC20(MSFT).balanceOf(alice) - dai, 0, "the MSFT leg left AAPL through AAPL's own route");
    }

    /// @dev Two pools, one payout: the native pool's slice takes the shared machine, the AAPL pool's the
    ///      quote path, and both pay AAPL.
    function test_quoteDividends_mixedPairsBothPayTheSameAsset() public {
        RealmFactoryUniV4Direct.DirectPair[] memory pairs = new RealmFactoryUniV4Direct.DirectPair[](2);
        pairs[0] = RealmFactoryUniV4Direct.DirectPair({quote: address(0), weightBps: 5_000});
        pairs[1] = RealmFactoryUniV4Direct.DirectPair({quote: AAPL, weightBps: 5_000});
        RealmTaxableTokenUniV4 token = _launch(pairs, _cfg(AAPL, _v4Route(AAPL), new bytes[](0)));
        _buyAndSettle(address(token), 10_000e18);
        vm.deal(address(this), 2 ether);
        token.accrueFees{value: 2 ether}();

        uint256 before = IERC20(AAPL).balanceOf(alice);
        token.processDividends(0, AAPL, 0, _one(alice));
        uint256 fromUsdcPool = IERC20(AAPL).balanceOf(alice) - before;
        assertGt(fromUsdcPool, 0, "the AAPL pool's slice paid as-is");

        vm.roll(block.number + 1);
        token.processDividends(0, address(0), 0, _one(alice));
        assertGt(IERC20(AAPL).balanceOf(alice) - before, fromUsdcPool, "the native pool's slice was converted to AAPL");
    }

    function test_quoteDividends_unknownQuoteReverts() public {
        RealmTaxableTokenUniV4 token = _earningToken(AAPL, _v4Route(AAPL), new bytes[](0));
        vm.expectRevert(RealmToken.UnknownQuote.selector);
        token.processDividends(0, MSFT, 0, _one(alice));
    }

    /////////////////////////// CONVERSION FAILURES ///////////////////////////

    /// @dev An unreachable floor: with no holders the call reverts and the buffer is untouched, with
    ///      holders it returns and the buffer is whole, and neither claims the block's cooldown — a sane
    ///      floor converts in the same block.
    function _assertUnreachableFloorKeepsTheBuffer(RealmTaxableTokenUniV4 token) internal {
        uint256 buffered = _pending(token);
        assertGt(buffered, 0, "a buffer to convert");

        vm.expectRevert(DividendDistribution.DividendConversionFailed.selector);
        token.processDividends(0, AAPL, type(uint128).max, new address[](0));
        assertEq(_pending(token), buffered, "a refused conversion leaves the buffer untouched");

        token.processDividends(0, AAPL, type(uint128).max, _one(alice));
        assertEq(_pending(token), buffered, "a push call swallows the failure and keeps the buffer whole");

        token.processDividends(0, AAPL, 0, new address[](0));
        assertLt(_pending(token), buffered, "the failure claimed no cooldown: a sane floor converts this block");
    }

    /// @dev The registry's reverse leg misses the floor on the way to native.
    function test_quoteDividends_unreachableFloorOnANativePayoutKeepsTheBuffer() public {
        _assertUnreachableFloorKeepsTheBuffer(_earningToken(address(0), "", _one(_v4Route(AAPL))));
    }

    /// @dev The registry's forward leg misses the floor after the reverse one already swapped.
    function test_quoteDividends_unreachableFloorOnAThirdAssetPayoutKeepsTheBuffer() public {
        _assertUnreachableFloorKeepsTheBuffer(_earningToken(MSFT, "", _one(_v4Route(AAPL))));
    }

    /// @dev The buy-back on the quote's own pool misses the floor.
    function test_quoteDividends_unreachableFloorOnTheSelfTokenBuyBackKeepsTheBuffer() public {
        _assertUnreachableFloorKeepsTheBuffer(_earningToken(realmTaxToken.DIVIDEND_SELF_TOKEN(), "", new bytes[](0)));
    }

    /// @dev A self-token token with a AAPL buffer whose next buy-back the pool only half-fills. Returns
    ///      the buffer before that call and the quarter of it the call attempts to spend.
    function _halfFilledSelfTokenBuyBack()
        internal
        returns (RealmTaxableTokenUniV4 token, uint256 buffered, uint256 spend)
    {
        token = _earningToken(realmTaxToken.DIVIDEND_SELF_TOKEN(), "", new bytes[](0));
        buffered = _pending(token);
        spend = buffered * 2_500 / 10_000;
        address router = token.UNIV4_UNIVERSAL_ROUTER();
        deal(address(token), router, 1e18);
        vm.etch(router, address(new HalfFillQuoteBuyBackRouterStub(address(token), AAPL, token.PERMIT2())).code);
    }

    /// @dev Whatever the pool did not take goes back on the dividend buffer, not into the stray pool.
    function test_quoteDividends_partialFillReturnsTheUnspentQuoteToTheBuffer() public {
        (RealmTaxableTokenUniV4 token, uint256 buffered, uint256 spend) = _halfFilledSelfTokenBuyBack();
        token.processDividends(0, AAPL, 0, new address[](0));

        assertEq(_pending(token), buffered - spend / 2, "only the half the pool took left the buffer");
        assertEq(token.dividendsOwed(), 1e18, "what the pool delivered was credited");
        assertEq(IERC20(AAPL).balanceOf(address(token)), _pending(token), "the unspent half is backed and earmarked");
    }

    /// @dev `DividendsFunded.amountIn` is what the conversion CONSUMED: on a partial fill, the half that went
    ///      back on the buffer is not reported as spent.
    function test_quoteDividends_partialFillEventReportsWhatWasConsumed() public {
        (RealmTaxableTokenUniV4 token,, uint256 spend) = _halfFilledSelfTokenBuyBack();
        vm.expectEmit(true, true, false, true, address(token));
        emit DividendDistribution.DividendsFunded(AAPL, address(token), spend / 2, 1e18);
        token.processDividends(0, AAPL, 0, new address[](0));
    }

    /////////////////////////// RESCUE VS COMMITTED QUOTE DIVIDENDS ///////////////////////////

    /// @dev AAPL is both the quote and the payout. After a push that paid only alice, bob's share is
    ///      still owed in AAPL and a fresh buffer sits on top: `rescueTokens` takes the stray above both
    ///      and nothing else.
    function test_quoteDividends_rescueTakesOnlyTheStrayAboveBuffersAndCommittedDividends() public {
        RealmTaxableTokenUniV4 token = _launch(_aaplPair(), _cfg(AAPL, _v4Route(AAPL), new bytes[](0)));
        _buyAndSettle(address(token), 10_000e18);
        deal(AAPL, bob, 10_000e18);
        _swapQuotePool(bob, address(token), AAPL, true, 10_000e18);
        token.processDividends(0, AAPL, 0, _one(alice));
        uint256 committed = token.committedDividends(AAPL);
        assertGt(committed, 0, "bob's share is still owed after a push that skipped him");

        _buyAndSettle(address(token), 1_000e18);
        uint256 buffered = _pending(token);
        assertGt(buffered, 0, "and a fresh buffer sits on top");

        uint256 stray = 777e18;
        deal(AAPL, address(token), IERC20(AAPL).balanceOf(address(token)) + stray);
        uint256 before = IERC20(AAPL).balanceOf(creator);
        vm.prank(creator);
        token.rescueTokens(AAPL);

        assertEq(IERC20(AAPL).balanceOf(creator) - before, stray, "only the stray left");
        assertEq(IERC20(AAPL).balanceOf(address(token)), committed + buffered, "owed dividends and the buffer stayed");

        address[] memory holders = new address[](2);
        holders[0] = alice;
        holders[1] = bob;
        uint256 bobBefore = IERC20(AAPL).balanceOf(bob);
        token.processDividends(0, AAPL, 0, holders);
        assertGt(IERC20(AAPL).balanceOf(bob) - bobBefore, 0, "bob is still paid after the rescue");
    }

    /////////////////////////// POSITIONAL QUOTE ROUTES ///////////////////////////

    /// @dev The native/MSFT V4 pool live at the fork block: 0.3%, spacing 60, hookless.
    function _daiRoute() internal pure returns (bytes memory) {
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({currency: MSFT, fee: 3_000, tickSpacing: 60, hooks: address(0)});
        return DividendRouteLib.encodeV4(hops);
    }

    /// @dev `quoteRoutes` is per PAIR; the token takes it per ERC20 QUOTE. A native pair ahead of AAPL
    ///      moves AAPL's route from pair slot 1 to quote slot 0, and the MSFT leg converts through it.
    function test_quoteRoutes_nativePairFirstShiftsTheErc20RouteIntoPlace() public {
        RealmFactoryUniV4Direct.DirectPair[] memory pairs = new RealmFactoryUniV4Direct.DirectPair[](2);
        pairs[0] = RealmFactoryUniV4Direct.DirectPair({quote: address(0), weightBps: 5_000});
        pairs[1] = RealmFactoryUniV4Direct.DirectPair({quote: AAPL, weightBps: 5_000});
        bytes[] memory quoteRoutes = new bytes[](2);
        quoteRoutes[1] = _v4Route(AAPL);

        RealmTaxableTokenUniV4 token = _launch(pairs, _cfg(MSFT, "", quoteRoutes));
        assertEq(dividendSwapRegistry.routeOf(address(token), AAPL), _v4Route(AAPL), "AAPL registered its own route");

        _buyAndSettle(address(token), 10_000e18);
        uint256 before = IERC20(MSFT).balanceOf(alice);
        token.processDividends(0, AAPL, 0, _one(alice));
        assertGt(IERC20(MSFT).balanceOf(alice) - before, 0, "the MSFT leg left AAPL through that route");
    }

    /// @dev Three pairs, two of them ERC20: each quote registers the route in its own slot and converts
    ///      its own buffer into native through it.
    function test_quoteRoutes_twoErc20QuotesEachConvertThroughTheirOwnRoute() public {
        RealmFactoryUniV4Direct.DirectPair[] memory pairs = new RealmFactoryUniV4Direct.DirectPair[](3);
        pairs[0] = RealmFactoryUniV4Direct.DirectPair({quote: address(0), weightBps: 4_000});
        pairs[1] = RealmFactoryUniV4Direct.DirectPair({quote: AAPL, weightBps: 3_000});
        // 1e-8 MSFT per coin: a 10 MSFT opening market cap, inside the launch bounds.
        pairs[2] = RealmFactoryUniV4Direct.DirectPair({quote: MSFT, weightBps: 3_000});
        bytes[] memory quoteRoutes = new bytes[](3);
        quoteRoutes[1] = _v4Route(AAPL);
        quoteRoutes[2] = _daiRoute();

        RealmTaxableTokenUniV4 token = _launch(pairs, _cfg(address(0), "", quoteRoutes));
        assertEq(dividendSwapRegistry.routeOf(address(token), AAPL), _v4Route(AAPL), "AAPL's route");
        assertEq(dividendSwapRegistry.routeOf(address(token), MSFT), _daiRoute(), "MSFT's route");

        _buyAndSettle(address(token), 10_000e18);
        deal(MSFT, alice, 1_000e18);
        _swapQuotePool(alice, address(token), MSFT, true, 1_000e18);
        anyPairHook.settleFees(address(token), MSFT);
        uint256 usdcBuffered = token.quoteDividendPending(AAPL)[0];
        uint256 daiBuffered = token.quoteDividendPending(MSFT)[0];
        assertGt(daiBuffered, 0, "the MSFT pool's slice arrived in MSFT");

        uint256 before = alice.balance;
        token.processDividends(0, AAPL, 0, _one(alice));
        uint256 fromUsdc = alice.balance - before;
        assertGt(fromUsdc, 0, "the AAPL buffer paid native");
        assertLt(token.quoteDividendPending(AAPL)[0], usdcBuffered, "out of the AAPL buffer");

        vm.roll(block.number + 1);
        token.processDividends(0, MSFT, 0, _one(alice));
        assertGt(alice.balance - before, fromUsdc, "the MSFT buffer paid native too");
        assertLt(token.quoteDividendPending(MSFT)[0], daiBuffered, "out of the MSFT buffer");
    }

    /// @dev A quote that is itself a payout is checked against the route it registered AS A PAYOUT, not
    ///      the one passed for it as a quote: AAPL paid through its V2 pair cannot be walked backwards for
    ///      the MSFT leg, whatever V4 route the creator also supplies.
    function test_quoteRoutes_refusesAPayoutQuoteWhoseOwnRouteIsNotV4() public {
        address[] memory assets = new address[](2);
        assets[0] = AAPL;
        assets[1] = MSFT;
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5_000;
        weights[1] = 5_000;
        // No quote route passed for AAPL: one given for a payout quote is refused on its own (see below).
        TaxConfigsWithDirectAllocation memory cfg = _cfg(AAPL, "", new bytes[](0));
        cfg.earningsAllocation.dividendTokens = assets;
        cfg.earningsAllocation.dividendWeightsBps = weights;
        cfg.earningsAllocation.dividendRoutes = new bytes[](2);

        vm.prank(creator);
        vm.expectRevert(RealmTaxableTokenUniV4Base.QuoteRouteUnsupported.selector);
        directFactory.createToken(
            _setup(true),
            _aaplPair(),
            cfg,
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            _noDevBuy(),
            address(0)
        );
    }

    /// @dev A route the token would never register is refused, not silently dropped: AAPL is a payout
    ///      here, so the MSFT leg converts out of AAPL through AAPL's PAYOUT route, and a quote route for it
    ///      would be ignored.
    function test_quoteRoutes_refusesARouteForAPayoutQuote() public {
        address[] memory assets = new address[](2);
        assets[0] = AAPL;
        assets[1] = MSFT;
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5_000;
        weights[1] = 5_000;
        TaxConfigsWithDirectAllocation memory cfg = _cfg(AAPL, "", _one(_v4Route(AAPL)));
        cfg.earningsAllocation.dividendTokens = assets;
        cfg.earningsAllocation.dividendWeightsBps = weights;
        cfg.earningsAllocation.dividendRoutes = new bytes[](2);
        cfg.earningsAllocation.dividendRoutes[0] = _v4Route(AAPL);

        vm.prank(creator);
        vm.expectRevert(RealmTaxableTokenUniV4Base.QuoteRouteUnsupported.selector);
        directFactory.createToken(
            _setup(true),
            _aaplPair(),
            cfg,
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            _noDevBuy(),
            address(0)
        );
    }

    /////////////////////////// QUOTE-LEG GUARDS ///////////////////////////

    /// @dev The funding cooldown is the ASSET's: a conversion out of either buffer locks the block for
    ///      the other.
    function test_quoteDividends_cooldownIsSharedAcrossQuotes() public {
        RealmFactoryUniV4Direct.DirectPair[] memory pairs = new RealmFactoryUniV4Direct.DirectPair[](2);
        pairs[0] = RealmFactoryUniV4Direct.DirectPair({quote: address(0), weightBps: 5_000});
        pairs[1] = RealmFactoryUniV4Direct.DirectPair({quote: AAPL, weightBps: 5_000});
        RealmTaxableTokenUniV4 token = _launch(pairs, _cfg(AAPL, _v4Route(AAPL), new bytes[](0)));
        _buyAndSettle(address(token), 10_000e18);
        vm.deal(address(this), 2 ether);
        token.accrueFees{value: 2 ether}();
        uint256 buffered = _pending(token);

        token.processDividends(0, address(0), 0, new address[](0));
        vm.expectRevert(DividendDistribution.DividendProcessCooldown.selector);
        token.processDividends(0, AAPL, 0, new address[](0));
        assertEq(_pending(token), buffered, "the native conversion locked the AAPL buffer for the block");

        vm.roll(block.number + 1);
        token.processDividends(0, AAPL, 0, new address[](0));
        assertEq(_pending(token), 0, "the next block converts it");
        vm.expectRevert(DividendDistribution.DividendProcessCooldown.selector);
        token.processDividends(0, address(0), 0, new address[](0));
    }

    /// @dev An empty quote buffer means "wait for earnings", not "the swap is broken".
    function test_quoteDividends_emptyBufferRevertsBelowThreshold() public {
        RealmTaxableTokenUniV4 token = _launch(_aaplPair(), _cfg(AAPL, _v4Route(AAPL), new bytes[](0)));
        assertEq(_pending(token), 0, "nothing traded yet");
        vm.expectRevert(DividendDistribution.BelowDividendThreshold.selector);
        token.processDividends(0, AAPL, 0, new address[](0));
    }

    function test_quoteDividends_assetIndexPastTheSetReverts() public {
        RealmTaxableTokenUniV4 token = _earningToken(AAPL, _v4Route(AAPL), new bytes[](0));
        vm.expectRevert(DividendDistribution.DividendAssetOutOfRange.selector);
        token.processDividends(1, AAPL, 0, _one(alice));
    }

    /// @dev The registry is a proxy at a constant address the token was compiled against; if it ever had
    ///      no code, a raw `call` to it would "succeed" with empty returndata. The quote path must read
    ///      that as "not converted" and leave the debited buffer whole, exactly as the native path does —
    ///      otherwise holders' pending balance is written off with no revert, no payout and no re-earmark.
    function test_quoteDividends_codelessRegistryFailsClosed() public {
        RealmTaxableTokenUniV4 token = _earningToken(MSFT, "", _one(_v4Route(AAPL)));
        uint256 buffered = _pending(token);
        assertGt(buffered, 0, "a buffer to convert");

        vm.etch(token.DIVIDEND_SWAP_REGISTRY(), "");

        vm.expectRevert(DividendDistribution.DividendConversionFailed.selector);
        token.processDividends(0, AAPL, 0, new address[](0));
        assertEq(_pending(token), buffered, "the debited slice was re-earmarked, not written off");
        assertEq(token.dividendsOwed(), 0, "and nothing was credited to holders");
    }

    /// @dev One route per payout asset; a longer array is a caller mistake, not silently trailing data —
    ///      it almost certainly means the routes and the assets are misaligned.
    function test_multiAsset_routesLongerThanAssetsIsRejected() public {
        TaxConfigsWithDirectAllocation memory cfg = _cfg(AAPL, _v4Route(AAPL), new bytes[](0));
        bytes[] memory routes = new bytes[](2);
        routes[0] = _v4Route(AAPL);
        routes[1] = _v4Route(AAPL);
        cfg.earningsAllocation.dividendRoutes = routes;

        vm.prank(creator);
        vm.expectRevert(DividendDistribution.InvalidDividendAssetSet.selector);
        directFactory.createToken(
            _setup(true),
            _aaplPair(),
            cfg,
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            _noDevBuy(),
            address(0)
        );
    }

    /////////////////////////// OWNER-ONLY ADMIN ///////////////////////////

    /// @dev A direct token has no launchpad, so its owner is its only admin: a stranger and the protocol
    ///      admin who owns the curve venue's launchpad both get `NotTokenOwner`, not an empty revert.
    function test_directToken_onlyItsOwnerMayRescueOrLowerTheTax() public {
        RealmTaxableTokenUniV4 token = _launch(_aaplPair(), _cfg(AAPL, _v4Route(AAPL), new bytes[](0)));
        address[2] memory callers = [stranger, admin];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(RealmTaxableToken.NotTokenOwner.selector);
            token.rescueTokens(AAPL);

            vm.prank(callers[i]);
            vm.expectRevert(RealmTaxableToken.NotTokenOwner.selector);
            token.setTaxBps(0, 0);
        }

        vm.prank(creator);
        token.setTaxBps(0, 0);
        assertEq(uint256(token.sellTaxBps()), 0, "the owner still can");
    }

    /////////////////////////// REVIEW FIXES ///////////////////////////

    /// @dev A burn-only allocation (no dividends share) with `quoteRoutes` positional to the pairs.
    function _burnOnlyCfg(bytes[] memory quoteRoutes) internal pure returns (TaxConfigsWithDirectAllocation memory c) {
        c = _cfg(AAPL, "", quoteRoutes);
        c.earningsAllocation.burnBps = 5_000;
        c.earningsAllocation.dividendsBps = 0;
        c.earningsAllocation.dividendTokens = new address[](0);
        c.earningsAllocation.dividendWeightsBps = new uint16[](0);
        c.earningsAllocation.dividendRoutes = new bytes[](0);
    }

    /// @dev The token only registers quote routes for a dividends leg, so a route with no dividends
    ///      share would be dropped silently; refused instead, like every other unsupported input.
    function test_directAlloc_rejectsQuoteRoutesWithoutADividendsShare() public {
        RealmFactoryUniV4Direct.DirectTokenSetup memory setup = _setup(true);
        TaxConfigsWithDirectAllocation memory cfg = _burnOnlyCfg(_one(_v4Route(AAPL)));
        vm.prank(creator);
        vm.expectRevert(RealmFactoryUniV4Direct.InvalidQuoteRoutes.selector);
        directFactory.createToken(
            setup, _aaplPair(), cfg, _emptyAntiSniperCfg(), new IRealmFactory.CreatorVault[](0), _noDevBuy(), address(0)
        );
    }

    /// @dev A burn slice past `uint128` reverts rather than being truncated into stray balance.
    function test_quoteBurnBuffer_overflowRevertsInsteadOfTruncating() public {
        RealmTaxableTokenUniV4 token = _launch(_aaplPair(), _burnOnlyCfg(new bytes[](0)));
        uint256 amount = 2 * uint256(type(uint128).max) + 4; // half of it is 2^128 + 1
        deal(AAPL, stranger, amount);
        vm.startPrank(stranger);
        IERC20(AAPL).approve(address(token), amount);
        vm.expectRevert(DividendDistribution.DividendBufferOverflow.selector);
        token.accrueFees(AAPL, amount);
        vm.stopPrank();
    }

    /// @dev A registry conversion that fails leaves no standing allowance to the (upgradeable) registry.
    function test_quoteDividends_failedConversionClearsTheRegistryAllowance() public {
        RealmTaxableTokenUniV4 token = _earningToken(MSFT, "", _one(_v4Route(AAPL)));
        assertGt(_pending(token), 0, "a buffer to convert");
        token.processDividends(0, AAPL, type(uint128).max, _one(alice));
        assertGt(_pending(token), 0, "the conversion failed and kept the buffer");
        assertEq(IERC20(AAPL).allowance(address(token), address(dividendSwapRegistry)), 0, "no allowance left");
    }
}
