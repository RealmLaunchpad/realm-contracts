// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {RealmAnyPairsRouteLib} from "src/RealmAnyPairsRouteLib.sol";
import {RealmAnyPairsDividendTrackerAutoBasket as AB} from "src/RealmAnyPairsDividendTrackerAutoBasket.sol";
import {R106Token} from "./Round106.t.sol";
import {HookedFixture} from "./Round107.t.sol";

contract MockWethR108 is ERC20 {
    constructor() ERC20("WETH", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 a) external {
        _burn(msg.sender, a);
        (bool ok,) = msg.sender.call{value: a}("");
        require(ok, "eth");
    }
}

/// @dev Holds a PoolManager unlock open -- as a trader's router does -- and calls `convertStep` from inside it.
contract R108LockHarness is IUnlockCallback {
    IPoolManager internal immutable pm;
    address internal target;
    address internal syncToken;
    uint256 internal gasCap;
    bool public callOk;
    uint256 public gasUsed;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function run(address target_, address syncToken_, uint256 gasCap_) external {
        target = target_;
        syncToken = syncToken_;
        gasCap = gasCap_;
        pm.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        if (syncToken != address(0)) pm.sync(Currency.wrap(syncToken)); // a pending sync, as mid-settlement
        uint256 g0 = gasleft();
        (callOk,) = target.call{gas: gasCap}(abi.encodeWithSignature("convertStep()"));
        gasUsed = g0 - gasleft();
        if (syncToken != address(0)) pm.settle();
        return "";
    }
}

contract Round108AutoBasketTest is HookedFixture {
    R106Token quote;
    R106Token stock;
    MockWethR108 weth;
    address bob = makeAddr("bob");
    uint256 constant T0 = 1_000_000;

    // This test contract plays the token, the feeder (the hook) and the creator.
    function creatorOfCoin(address) external view returns (address) {
        return address(this);
    }

    function inSwapAllowed(address) external pure returns (uint256) {
        return 1;
    }

    function setUp() public {
        vm.warp(T0);
        _pm();
        _hooks();
        quote = new R106Token("USDG");
        stock = new R106Token("xSTOCK");
        quote.mint(address(this), 1e36);
        stock.mint(address(this), 1e36);
        weth = new MockWethR108();
    }

    function _legs1(address asset) internal pure returns (AB.Leg[] memory l) {
        l = new AB.Leg[](1);
        l[0] = AB.Leg(asset, 10_000);
    }

    function _config(AB.InputBasket[] memory ins) internal view returns (AB.Config memory c) {
        c.token = address(this);
        c.feeder = address(this);
        c.poolManager = address(pm);
        c.weth = address(weth);
        c.minEligible = 1;
        c.excluded = new address[](0);
        c.inputs = ins;
    }

    function _trackerOf(AB.InputBasket[] memory ins) internal returns (AB t) {
        t = new AB(_config(ins));
        t.setBalance(alice, 1e18);
    }

    function _tracker(address input, AB.Leg[] memory legs) internal returns (AB t) {
        AB.InputBasket[] memory ins = new AB.InputBasket[](1);
        ins[0] = AB.InputBasket(input, legs);
        t = _trackerOf(ins);
    }

    function _fund(AB t, uint256 amt) internal {
        quote.transfer(address(t), amt);
        t.feedToken(0);
    }

    function _stockTracker() internal returns (AB) {
        return _tracker(address(quote), _legs1(address(stock)));
    }

    // ───────────── feed, convert, pay ─────────────

    function test_directLegBooksAtFeed_convertingLegIsPendingForHolders() public {
        AB.Leg[] memory legs = new AB.Leg[](2);
        legs[0] = AB.Leg(address(quote), 4000);
        legs[1] = AB.Leg(address(stock), 6000);
        AB t = _tracker(address(quote), legs);
        _fund(t, 1e18);
        assertApproxEqAbs(t.claimableOf(alice, address(quote)), 0.4e18, 1, "the direct 40% is claimable at once");
        assertEq(t.buffered(address(quote)), 0.6e18);
        assertApproxEqAbs(t.pendingOf(alice, 0), 0.6e18, 1, "the converting 60% is already alice's, pending");
        (,,, uint256 pool,,,) = t.legInfo(0);
        assertEq(pool, 0.6e18);
    }

    function test_convertStepBooksTheAsset_andClaimPaysIt() public {
        _pool(address(quote), address(stock), 2500, 25, 1e24);
        AB t = _stockTracker();
        _fund(t, 1e18);
        assertTrue(t.convertStep());
        assertEq(t.buffered(address(quote)), 0);
        assertEq(t.pendingOf(alice, 0), 0);
        uint256 owed = t.claimableOf(alice, address(stock));
        assertGt(owed, 0.99e18, "converted at the pool price, less its 0.25% fee");
        vm.prank(alice);
        t.claim();
        assertEq(stock.balanceOf(alice), owed, "paid in the stock itself");
        assertEq(t.claimableOf(alice, address(stock)), 0);
    }

    function test_processAutoSendsTheConvertedAsset() public {
        _pool(address(quote), address(stock), 2500, 25, 1e24);
        AB t = _stockTracker();
        _fund(t, 1e18);
        t.convertStep();
        t.process(1_000_000);
        assertGt(stock.balanceOf(alice), 0.99e18, "pushed without a claim");
    }

    function test_convertStepPushesWhenThereIsNothingToConvert() public {
        _pool(address(quote), address(stock), 2500, 25, 1e24);
        AB t = _stockTracker();
        _fund(t, 1e18);
        t.convertStep(); // converts
        assertEq(stock.balanceOf(alice), 0);
        t.convertStep(); // nothing left to convert: pushes
        assertGt(stock.balanceOf(alice), 0.99e18);
    }

    function test_inSwap_convertsInsideSomeoneElsesUnlock() public {
        _pool(address(quote), address(stock), 2500, 25, 1e24);
        AB t = _stockTracker();
        _fund(t, 1e18);
        R108LockHarness h = new R108LockHarness(pm);
        h.run(address(t), address(0), 650_000); // reverts CurrencyNotSettled if the tracker left a delta open
        assertTrue(h.callOk());
        assertEq(t.buffered(address(quote)), 0, "swapped and settled without a nested unlock");
        assertGt(t.claimableOf(alice, address(stock)), 0.99e18);
    }

    function test_inSwap_waitsWhileASyncIsPending() public {
        _pool(address(quote), address(stock), 2500, 25, 1e24);
        AB t = _stockTracker();
        _fund(t, 1e18);
        R108LockHarness h = new R108LockHarness(pm);
        h.run(address(t), address(quote), 650_000);
        assertEq(t.buffered(address(quote)), 1e18, "never settles over another caller's pending sync");
        assertEq(t.failingSince(0), 0, "and it is not counted as a failure");
    }

    // ───────────── exact per-holder shares ─────────────

    function test_aLateBuyerGetsNothingFromEarlierFees() public {
        _pool(address(quote), address(stock), 2500, 25, 1e24);
        AB t = _stockTracker();
        _fund(t, 1e18); // alice alone holds when the fee arrives
        t.setBalance(bob, 9e18); // bob buys 90% of the supply before the conversion
        t.convertStep();
        assertGt(t.claimableOf(alice, address(stock)), 0.99e18, "alice keeps her whole share");
        assertEq(t.claimableOf(bob, address(stock)), 0, "bob bought after the fee: nothing");
    }

    function test_holderPullsPendingInTheQuoteInstantly() public {
        AB t = _stockTracker(); // no pool at all: the route is dead
        _fund(t, 1e18);
        vm.prank(alice);
        t.claimPending(alice);
        assertApproxEqAbs(quote.balanceOf(alice), 1e18, 1, "paid in the quote right away");
        (,,, uint256 pool,,,) = t.legInfo(0);
        assertLe(pool, 1, "and it left the conversion pool");
    }

    function test_onePullLeavesTheOthersShareToConvert() public {
        _pool(address(quote), address(stock), 2500, 25, 1e24);
        AB t = _stockTracker();
        t.setBalance(bob, 1e18); // 50/50 with alice
        _fund(t, 2e18);
        vm.prank(bob);
        t.claimPending(bob);
        assertApproxEqAbs(quote.balanceOf(bob), 1e18, 1);
        t.convertStep();
        assertGt(t.claimableOf(alice, address(stock)), 0.99e18, "alice's half converted");
        assertEq(t.claimableOf(bob, address(stock)), 0, "bob already took his");
    }

    function test_balanceChangesSettleAcrossManyConversions() public {
        _pool(address(quote), address(stock), 2500, 25, 1e25);
        AB t = _stockTracker();
        _fund(t, 1e18);
        t.convertStep(); // epoch 1: alice 100%
        _fund(t, 1e18);
        t.convertStep(); // epoch 2: alice 100%
        t.setBalance(alice, 0.5e18); // alice sends half to bob
        t.setBalance(bob, 0.5e18);
        _fund(t, 1e18);
        t.convertStep(); // epoch 3: 50/50
        assertApproxEqRel(t.claimableOf(alice, address(stock)), 2.5e18, 0.01e18, "1 + 1 + 0.5");
        assertApproxEqRel(t.claimableOf(bob, address(stock)), 0.5e18, 0.01e18, "only the last half");
        // and it all adds up to what the tracker really holds
        assertLe(
            t.claimableOf(alice, address(stock)) + t.claimableOf(bob, address(stock)), stock.balanceOf(address(t))
        );
    }

    function test_pendingFromBeforeATransferStillConverts() public {
        _pool(address(quote), address(stock), 2500, 25, 1e24);
        AB t = _stockTracker();
        _fund(t, 1e18);
        t.setBalance(alice, 0); // alice sells everything while her share is still pending
        t.convertStep();
        assertGt(t.claimableOf(alice, address(stock)), 0.99e18, "earned before she sold, paid after");
    }

    // ───────────── claim as one token ─────────────

    function test_claimAsTheQuote() public {
        _pool(address(quote), address(stock), 2500, 25, 1e24);
        AB t = _stockTracker();
        _fund(t, 1e18);
        t.convertStep();
        // denominations: [quote, stock]
        bytes[] memory routes = new bytes[](2);
        uint256[] memory mins = new uint256[](2);
        mins[1] = 0.98e18;
        vm.prank(alice);
        t.claimAs(alice, address(quote), routes, mins, false);
        assertEq(stock.balanceOf(alice), 0);
        assertGt(quote.balanceOf(alice), 0.98e18, "the stock came back as the quote");
    }

    function test_claimAsNativeEth() public {
        weth.deposit{value: 1_000_000 ether}();
        _pool(address(weth), address(stock), 2500, 25, 1e24);
        AB t = _tracker(address(weth), _legs1(address(stock)));
        t.feed{value: 1 ether}();
        t.convertStep();
        bytes[] memory routes = new bytes[](2); // [weth, stock]
        uint256[] memory mins = new uint256[](2);
        mins[1] = 0.98 ether;
        vm.prank(alice);
        t.claimAs(alice, address(0), routes, mins, false);
        assertGt(alice.balance, 0.98 ether, "paid in native ETH");
        assertEq(stock.balanceOf(alice), 0);
    }

    function test_claimAsWithPendingSkipsTheConversion() public {
        AB t = _stockTracker(); // dead route
        _fund(t, 1e18);
        bytes[] memory routes = new bytes[](2);
        uint256[] memory mins = new uint256[](2);
        vm.prank(alice);
        t.claimAs(alice, address(quote), routes, mins, true);
        assertApproxEqAbs(quote.balanceOf(alice), 1e18, 1);
    }

    function test_claimAsHonoursTheHoldersMinimum() public {
        _pool(address(quote), address(stock), 2500, 25, 1e24);
        AB t = _stockTracker();
        _fund(t, 1e18);
        t.convertStep();
        bytes[] memory routes = new bytes[](2);
        uint256[] memory mins = new uint256[](2);
        mins[1] = 2e18; // impossible
        vm.prank(alice);
        vm.expectRevert(AB.LegMinOutUnmet.selector);
        t.claimAs(alice, address(quote), routes, mins, false);
    }

    function test_claimAsWithASuppliedRouteReachesAHookedPool() public {
        PoolKey memory key = _hookedPool(address(quote), address(stock), HOOK_A, 1e24);
        AB t = _stockTracker();
        t.setRoute(address(quote), address(stock), abi.encode(key));
        _fund(t, 1e18);
        t.convertStep();
        bytes[] memory routes = new bytes[](2);
        routes[1] = abi.encode(key); // stock -> quote through the hooked pool
        uint256[] memory mins = new uint256[](2);
        mins[1] = 0.98e18;
        vm.prank(alice);
        t.claimAs(alice, address(quote), routes, mins, false);
        assertGt(quote.balanceOf(alice), 0.98e18);
    }

    // ───────────── failure, fallback, routes ─────────────

    function test_slippageRefusesAThinPool_thenFallsBackToTheInput() public {
        _pool(address(quote), address(stock), 2500, 25, 1e18);
        AB t = _stockTracker();
        _fund(t, 1e18);
        assertTrue(t.convertStep(), "attempted");
        assertEq(t.buffered(address(quote)), 1e18, "refused: the batch would move this pool far past 3%");
        assertEq(t.failingSince(0), T0);

        vm.warp(T0 + 1 days - 1);
        t.convert(1);
        assertEq(t.buffered(address(quote)), 1e18, "not yet");

        vm.warp(T0 + 1 days);
        t.convert(1);
        assertEq(t.buffered(address(quote)), 0);
        assertEq(t.failingSince(0), 0);
        assertApproxEqAbs(t.claimableOf(alice, address(quote)), 1e18, 1, "resolved in the quote instead");
        vm.prank(alice);
        t.claim();
        assertApproxEqAbs(quote.balanceOf(alice), 1e18, 1);
    }

    function test_creatorSetsTheFallbackDelay() public {
        AB t = _stockTracker();
        vm.expectRevert(AB.BadFallbackDelay.selector);
        t.setFallbackDelay(59 minutes);
        vm.expectRevert(AB.BadFallbackDelay.selector);
        t.setFallbackDelay(7 days + 1);
        vm.prank(alice);
        vm.expectRevert(AB.NotCreator.selector);
        t.setFallbackDelay(1 hours);
        t.setFallbackDelay(1 hours);
        _fund(t, 1e18);
        t.convert(1); // no route: clock starts
        vm.warp(T0 + 1 hours);
        t.convert(1);
        assertApproxEqAbs(t.claimableOf(alice, address(quote)), 1e18, 1, "fell back after one hour");
    }

    function test_tighterSlippageRefusesWhatTheDefaultAccepts() public {
        _pool(address(quote), address(stock), 2500, 25, 5e19); // ~2% price impact for a 1e18 batch
        AB loose = _stockTracker();
        AB tight = _stockTracker();
        tight.setSlippageBps(100);
        _fund(loose, 1e18);
        _fund(tight, 1e18);
        loose.convert(1);
        tight.convert(1);
        assertEq(loose.buffered(address(quote)), 0, "fits the default 3%");
        assertEq(tight.buffered(address(quote)), 1e18, "not 1%");
    }

    function test_storedRouteReachesAHookedPool_andClearsTheClock() public {
        PoolKey memory key = _hookedPool(address(quote), address(stock), HOOK_A, 1e24);
        AB t = _stockTracker();
        _fund(t, 1e18);
        t.convert(1);
        assertEq(t.buffered(address(quote)), 1e18, "a hooked pool cannot be discovered");
        assertEq(t.failingSince(0), T0);
        t.setRoute(address(quote), address(stock), abi.encode(key));
        t.convert(1);
        assertEq(t.buffered(address(quote)), 0, "the stored route reached it");
        assertEq(t.failingSince(0), 0, "and success clears the clock");
        (,,,,,, bytes memory r) = t.legInfo(0);
        assertEq(r, abi.encode(key));
    }

    function test_setRouteGuards() public {
        PoolKey memory key = _hookedPool(address(quote), address(stock), HOOK_A, 1e24);
        AB t = _stockTracker();
        vm.prank(alice);
        vm.expectRevert(AB.NotCreator.selector);
        t.setRoute(address(quote), address(stock), abi.encode(key));
        vm.expectRevert(AB.NotALeg.selector);
        t.setRoute(address(quote), address(quote), abi.encode(key));
        address other = address(new R106Token("OTHER"));
        vm.expectRevert(AB.NotALeg.selector);
        t.setRoute(address(quote), other, "");
        vm.expectRevert(RealmAnyPairsRouteLib.BadRoute.selector);
        t.setRoute(address(quote), address(stock), hex"1234");
        t.setRoute(address(quote), address(stock), abi.encode(key));
        t.setRoute(address(quote), address(stock), "");
        assertEq(t.routeOf(address(quote), address(stock)).length, 0);
    }

    function test_slippageIsCreatorSetWithinBounds() public {
        AB t = _stockTracker();
        assertEq(t.slippageBps(), 300);
        vm.expectRevert(AB.BadSlippage.selector);
        t.setSlippageBps(9);
        vm.expectRevert(AB.BadSlippage.selector);
        t.setSlippageBps(2001);
        vm.prank(alice);
        vm.expectRevert(AB.NotCreator.selector);
        t.setSlippageBps(500);
        t.setSlippageBps(500);
        assertEq(t.slippageBps(), 500);
    }

    // ───────────── inputs, limits, guards ─────────────

    function test_nativeFeedIsWrapped_andConverted() public {
        weth.deposit{value: 1_000_000 ether}();
        _pool(address(weth), address(stock), 2500, 25, 1e24);
        AB t = _tracker(address(weth), _legs1(address(stock)));
        t.feed{value: 1 ether}();
        assertEq(t.buffered(address(weth)), 1 ether, "wrapped and pending");
        t.convertStep();
        assertGt(t.claimableOf(alice, address(stock)), 0.99e18);
    }

    function test_nativeFeedRefusedWithoutANativeInput() public {
        AB t = _stockTracker();
        vm.expectRevert(AB.NoNativeInput.selector);
        t.feed{value: 1}();
    }

    function test_eachInputConvertsThroughItsOwnBasket() public {
        R106Token quote2 = new R106Token("Q2");
        R106Token stock2 = new R106Token("S2");
        quote2.mint(address(this), 1e36);
        stock2.mint(address(this), 1e36);
        _pool(address(quote), address(stock), 2500, 25, 1e24);
        _pool(address(quote2), address(stock2), 2500, 25, 1e24);
        AB.InputBasket[] memory ins = new AB.InputBasket[](2);
        ins[0] = AB.InputBasket(address(quote), _legs1(address(stock)));
        ins[1] = AB.InputBasket(address(quote2), _legs1(address(stock2)));
        AB t = _trackerOf(ins);
        assertEq(t.denominationCount(), 4);
        quote.transfer(address(t), 1e18);
        quote2.transfer(address(t), 1e18);
        t.feedToken(0);
        assertEq(t.convert(10), 2);
        assertGt(t.claimableOf(alice, address(stock)), 0.99e18);
        assertGt(t.claimableOf(alice, address(stock2)), 0.99e18);
    }

    function test_minConvertHoldsSmallPools() public {
        _pool(address(quote), address(stock), 2500, 25, 1e24);
        AB t = _stockTracker();
        _fund(t, 1e18);
        t.setMinConvert(address(quote), 2e18);
        assertEq(t.convert(1), 0);
        assertEq(t.buffered(address(quote)), 1e18);
    }

    function test_tooManyConvertingLegsForTheTransferStipendIsRefused() public {
        AB.Leg[] memory legs = new AB.Leg[](10);
        for (uint256 i; i < 10; ++i) {
            legs[i] = AB.Leg(address(new R106Token("S")), 1_000);
        }
        AB.InputBasket[] memory ins = new AB.InputBasket[](1);
        ins[0] = AB.InputBasket(address(quote), legs);
        AB.Config memory c = _config(ins);
        vm.expectRevert(AB.TooHeavy.selector);
        new AB(c);
    }

    function test_settlementFitsThePublishedStipend() public {
        _pool(address(quote), address(stock), 2500, 25, 1e25);
        AB.Leg[] memory legs = new AB.Leg[](3);
        R106Token s2 = new R106Token("S2");
        R106Token s3 = new R106Token("S3");
        s2.mint(address(this), 1e36);
        s3.mint(address(this), 1e36);
        _pool(address(quote), address(s2), 2500, 25, 1e25);
        _pool(address(quote), address(s3), 2500, 25, 1e25);
        legs[0] = AB.Leg(address(stock), 4_000);
        legs[1] = AB.Leg(address(s2), 3_000);
        legs[2] = AB.Leg(address(s3), 3_000);
        AB t = _tracker(address(quote), legs);
        for (uint256 r; r < 3; ++r) {
            _fund(t, 1e18);
            t.convert(3);
        }
        _fund(t, 1e18); // and something still pending
        uint256 stipend = t.balanceSyncGas();
        vm.cool(address(t));
        uint256 g0 = gasleft();
        t.setBalance{gas: stipend}(alice, 0);
        uint256 used = g0 - gasleft();
        emit log_named_uint("coldest settle across 3 legs x 3 conversions", used);
        emit log_named_uint("published stipend", stipend);
        assertEq(t.trackedBalance(alice), 0, "the debit landed inside the stipend");
    }

    function test_claimRefusesStrandingRecipients() public {
        AB t = _stockTracker();
        vm.prank(alice);
        vm.expectRevert(AB.ZeroRecipient.selector);
        t.claimTo(address(pm));
    }

    function test_badBasketsAreRefused() public {
        AB.Leg[] memory legs = new AB.Leg[](1);
        legs[0] = AB.Leg(address(stock), 9_999);
        AB.InputBasket[] memory ins = new AB.InputBasket[](1);
        ins[0] = AB.InputBasket(address(quote), legs);
        AB.Config memory c = _config(ins);
        vm.expectRevert(AB.BadBasket.selector);
        new AB(c);
    }

    function test_selfOnlyEntryPointsRefuseStrangers() public {
        AB t = _stockTracker();
        vm.expectRevert(AB.OnlySelf.selector);
        t.convertSelf(address(quote), address(stock), 1, false);
        vm.expectRevert(AB.OnlySelf.selector);
        t.claimSwapSelf(address(stock), address(quote), 1, 0, "", alice);
        vm.prank(address(pm));
        vm.expectRevert(AB.OnlySelf.selector);
        t.unlockCallback("");
    }
}
