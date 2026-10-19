// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

import {RealmBasket} from "src/basket/RealmBasket.sol";
import {RealmBasketAssets, IBasketRates} from "src/basket/RealmBasketAssets.sol";
import {RealmBasketFactory} from "src/basket/RealmBasketFactory.sol";
import {RealmBasketHook} from "src/basket/RealmBasketHook.sol";
import {DeploymentAddressesRobinhoodMainnet as Mainnet} from "src/config/DeploymentAddresses.sol";

/// @notice ETF baskets on a Robinhood mainnet fork: real rStocks on their real USDG pools (SPY and META on
///         V4, NVDA and QQQ on V3), priced by the live `RealmAssetsWhitelist`.
contract RealmBasketTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 constant BLOCKNUMBER = 92_800_000;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant WHITELIST = 0x1Fe8baA5254fD125386Da072cddd1c804BEe0e94;
    address constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant META = 0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant QQQ = 0xD5f3879160bc7c32ebb4dC785F8a4F505888de68;
    address constant NVDA_V3 = 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3;
    address constant QQQ_V3 = 0xD60A5d14dB690B7Afad71F76B108071D7175597d;
    /// @dev The USDG/WETH V3 pool: a real Uniswap pool, but not against SPY.
    address constant USDG_WETH_V3 = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca;
    uint256 constant SEED = 1_000e6;

    IPoolManager manager = IPoolManager(Mainnet.UNIV4_POOL_MANAGER);
    RealmBasketAssets registry;
    RealmBasketFactory factory;
    RealmBasketHook hook;
    RealmBasket basket;
    PoolKey basketKey;
    PoolSwapTest router;

    address owner = makeAddr("owner");
    address approver = makeAddr("approver");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"), BLOCKNUMBER);
        registry = new RealmBasketAssets(owner, address(manager), Mainnet.UNIV3_FACTORY, USDG, WHITELIST);
        vm.prank(owner);
        registry.setApprover(approver, true);
        vm.startPrank(approver);
        registry.setRoute(SPY, _v4Route(SPY));
        registry.setRoute(META, _v4Route(META));
        registry.setRoute(NVDA, _v3Route(NVDA_V3));
        registry.setRoute(QQQ, _v3Route(QQQ_V3));
        vm.stopPrank();

        address hookAddress = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            ) | (uint160(0x4444) << 144)
        );
        deployCodeTo("RealmBasketHook.sol:RealmBasketHook", abi.encode(manager, registry), hookAddress);
        hook = RealmBasketHook(hookAddress);
        factory = hook.FACTORY();

        address[] memory assets = new address[](3);
        (assets[0], assets[1], assets[2]) = (SPY, META, NVDA);
        uint16[] memory weights = new uint16[](3);
        (weights[0], weights[1], weights[2]) = (5_000, 3_000, 2_000);
        deal(USDG, creator, SEED);
        vm.startPrank(creator);
        IERC20(USDG).approve(address(factory), SEED);
        basket = RealmBasket(factory.createBasket("Tech Basket", "TECH", assets, weights, SEED, 0));
        vm.stopPrank();

        basketKey = _key(address(basket), USDG, 0, 1, address(hook));
        manager.initialize(basketKey, uint160(1 << 96));
        router = new PoolSwapTest(manager);
    }

    //////////////////////// creation //////////////////////

    function test_createBasket_seedsByWeightsAndMintsDeadShares() public view {
        assertEq(basket.owner(), creator);
        assertEq(basket.balanceOf(basket.DEAD()), basket.DEAD_SHARES());
        assertEq(basket.balanceOf(creator), 1_000e18 - basket.DEAD_SHARES());
        assertTrue(factory.isBasket(address(basket)));
        // Bought at market: worth the seed, less fees and impact.
        assertApproxEqRel(basket.totalAssets(), SEED, 0.03e18);
    }

    function test_createBasket_rejectsUnlistedAsset() public {
        address[] memory assets = new address[](1);
        assets[0] = USDG;
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        vm.expectRevert(RealmBasket.AssetNotListed.selector);
        factory.createBasket("X", "X", assets, weights, SEED, 0);
    }

    //////////////////////// deposit / redeem //////////////////////

    function test_deposit_mintsTheSmallestFractionAdded() public {
        address[] memory assets = basket.getAssets();
        uint256[] memory before = _balances(assets);
        uint256 supply = basket.totalSupply();

        uint256 shares = _deposit(alice, 1_000e6);

        assertEq(basket.balanceOf(alice), shares);
        assertApproxEqRel(shares, 1_000e18, 0.03e18);
        // Every holding grew by at least the fraction of supply minted.
        uint256[] memory afterBalances = _balances(assets);
        for (uint256 i; i < assets.length; ++i) {
            assertGe(afterBalances[i] * supply, before[i] * (supply + shares));
        }
    }

    function test_deposit_revertsBelowMinShares() public {
        deal(USDG, alice, 1_000e6);
        vm.startPrank(alice);
        IERC20(USDG).approve(address(basket), 1_000e6);
        vm.expectRevert(RealmBasket.Slippage.selector);
        basket.deposit(1_000e6, alice, 1_100e18);
        vm.stopPrank();
    }

    function test_redeem_paysUsdgForAProRataSlice() public {
        uint256 shares = _deposit(alice, 1_000e6);
        vm.prank(alice);
        uint256 out = basket.redeem(shares, alice, alice, 0);
        assertEq(IERC20(USDG).balanceOf(alice), out);
        assertApproxEqRel(out, 1_000e6, 0.03e18);
        assertEq(basket.balanceOf(alice), 0);
    }

    function test_redeem_revertsBelowMinAssets() public {
        uint256 shares = _deposit(alice, 1_000e6);
        vm.prank(alice);
        vm.expectRevert(RealmBasket.Slippage.selector);
        basket.redeem(shares, alice, alice, 1_000e6);
    }

    function test_redeemInKind_sendsEveryAssetProRata() public {
        address[] memory assets = basket.getAssets();
        uint256[] memory held = _balances(assets);
        uint256 supply = basket.totalSupply();
        uint256 shares = basket.balanceOf(creator) / 2;

        vm.prank(creator);
        uint256[] memory amounts = basket.redeemInKind(shares, alice, creator);

        for (uint256 i; i < assets.length; ++i) {
            assertEq(amounts[i], held[i] * shares / supply);
            assertEq(IERC20(assets[i]).balanceOf(alice), amounts[i]);
        }
    }

    function test_mintAndWithdraw_areUnsupported() public {
        assertEq(basket.maxMint(alice), 0);
        assertEq(basket.maxWithdraw(alice), 0);
        vm.expectRevert(RealmBasket.NotSupported.selector);
        basket.mint(1, alice);
        vm.expectRevert(RealmBasket.NotSupported.selector);
        basket.withdraw(1, alice, alice);
    }

    //////////////////////// rebalance //////////////////////

    function test_rebalance_onlyCreator() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        basket.rebalance(NVDA, type(uint256).max, QQQ);
    }

    function test_rebalance_sellingAllRemovesAndBuyingNewAdds() public {
        uint256 valueBefore = basket.totalAssets();
        vm.prank(creator);
        uint256 bought = basket.rebalance(NVDA, type(uint256).max, QQQ);

        address[] memory assets = basket.getAssets();
        assertEq(assets.length, 3);
        assertEq(IERC20(NVDA).balanceOf(address(basket)), 0);
        assertEq(IERC20(QQQ).balanceOf(address(basket)), bought);
        for (uint256 i; i < assets.length; ++i) {
            assertTrue(assets[i] != NVDA);
        }
        assertApproxEqRel(basket.totalAssets(), valueBefore, 0.03e18);
    }

    function test_rebalance_revertsWhenValueLostExceedsBound() public {
        // The snapshot now says QQQ is worth half: whatever is bought looks like a 50% loss.
        uint256 rate = IBasketRates(WHITELIST).unitsPerNativeX18(QQQ);
        vm.mockCall(WHITELIST, abi.encodeCall(IBasketRates.unitsPerNativeX18, (QQQ)), abi.encode(rate * 2));
        vm.prank(creator);
        vm.expectRevert(RealmBasket.RebalanceTooLossy.selector);
        basket.rebalance(NVDA, type(uint256).max, QQQ);
    }

    //////////////////////// hook //////////////////////

    function test_hook_buyThroughThePoolMintsShares() public {
        uint256 shares = _swap(alice, USDG, 1_000e6);
        assertEq(basket.balanceOf(alice), shares);
        assertApproxEqRel(shares, 1_000e18, 0.03e18);
        _assertPoolUntouched();
    }

    function test_hook_sellThroughThePoolRedeemsForUsdg() public {
        uint256 shares = basket.balanceOf(creator) / 2;
        uint256 supply = basket.totalSupply();
        uint256 out = _swap(creator, address(basket), shares);
        // The sold shares sit in the pool manager behind the hook's claims, out of circulation.
        assertEq(basket.totalSupply(), supply - shares);
        assertEq(basket.balanceOf(address(manager)), shares);
        assertEq(IERC20(USDG).balanceOf(creator), out);
        assertApproxEqRel(out, 500e6, 0.03e18);
        _assertPoolUntouched();
    }

    function test_redeemOnCredit_onlyTheHook() public {
        vm.prank(creator);
        vm.expectRevert(RealmBasket.Unauthorized.selector);
        basket.redeemOnCredit(1e18, creator);
    }

    function test_hook_rejectsExactOutput() public {
        deal(USDG, alice, 1_000e6);
        vm.startPrank(alice);
        IERC20(USDG).approve(address(router), 1_000e6);
        vm.expectRevert();
        router.swap(basketKey, _params(USDG, 1e18, false), PoolSwapTest.TestSettings(false, false), "");
        vm.stopPrank();
    }

    function test_hook_rejectsLiquidity() public {
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        vm.expectRevert();
        lp.modifyLiquidity(basketKey, ModifyLiquidityParams(-60, 60, 1e18, 0), "");
    }

    function test_hook_rejectsPoolsOfNonBaskets() public {
        vm.expectRevert();
        manager.initialize(_key(SPY, USDG, 0, 1, address(hook)), uint160(1 << 96));
    }

    //////////////////////// registry //////////////////////

    function test_registry_onlyApproverSetsRoutes() public {
        RealmBasketAssets.Route memory route = _v4Route(SPY);
        vm.prank(alice);
        vm.expectRevert(RealmBasketAssets.NotApprover.selector);
        registry.setRoute(SPY, route);
    }

    function test_registry_rejectsPoolNotAgainstUsdg() public {
        RealmBasketAssets.Route memory route = _v3Route(USDG_WETH_V3);
        vm.prank(approver);
        vm.expectRevert(RealmBasketAssets.InvalidRoute.selector);
        registry.setRoute(SPY, route);
    }

    function test_registry_requiresAWhitelistRate() public {
        RealmBasketAssets.Route memory route = _v4Route(SPY);
        vm.mockCall(WHITELIST, abi.encodeCall(IBasketRates.unitsPerNativeX18, (SPY)), abi.encode(0));
        vm.prank(approver);
        vm.expectRevert(RealmBasketAssets.NotPriced.selector);
        registry.setRoute(SPY, route);
    }

    function test_registry_delistingBlocksBuyingInButNotExiting() public {
        vm.prank(approver);
        registry.setListed(QQQ, false);
        vm.prank(creator);
        vm.expectRevert(RealmBasket.AssetNotListed.selector);
        basket.rebalance(NVDA, type(uint256).max, QQQ);

        vm.prank(approver);
        registry.setListed(NVDA, false);
        uint256 shares = basket.balanceOf(creator);
        vm.prank(creator);
        assertGt(basket.redeem(shares, creator, creator), 0);
    }

    //////////////////////// helpers //////////////////////

    function _key(address a, address b, uint24 fee, int24 spacing, address hooks)
        internal
        pure
        returns (PoolKey memory)
    {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), fee, spacing, IHooks(hooks));
    }

    function _v4Route(address asset) internal pure returns (RealmBasketAssets.Route memory r) {
        r.venue = RealmBasketAssets.Venue.V4;
        r.key = _key(asset, USDG, 3000, 60, address(0));
    }

    function _v3Route(address pool) internal pure returns (RealmBasketAssets.Route memory r) {
        r.venue = RealmBasketAssets.Venue.V3;
        r.pool = pool;
    }

    function _balances(address[] memory assets) internal view returns (uint256[] memory b) {
        b = new uint256[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            b[i] = IERC20(assets[i]).balanceOf(address(basket));
        }
    }

    function _deposit(address who, uint256 amount) internal returns (uint256 shares) {
        deal(USDG, who, amount);
        vm.startPrank(who);
        IERC20(USDG).approve(address(basket), amount);
        shares = basket.deposit(amount, who);
        vm.stopPrank();
    }

    function _params(address tokenIn, uint256 amount, bool exactIn) internal view returns (SwapParams memory) {
        bool zeroForOne = Currency.unwrap(basketKey.currency0) == tokenIn;
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: exactIn ? -int256(amount) : int256(amount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    /// @dev Exact-input swap of `amount` `tokenIn` on the basket pool through a standard router.
    function _swap(address who, address tokenIn, uint256 amount) internal returns (uint256 out) {
        if (tokenIn == USDG) deal(USDG, who, amount);
        address tokenOut = tokenIn == USDG ? address(basket) : USDG;
        uint256 before = IERC20(tokenOut).balanceOf(who);
        vm.startPrank(who);
        IERC20(tokenIn).approve(address(router), amount);
        router.swap(basketKey, _params(tokenIn, amount, true), PoolSwapTest.TestSettings(false, false), "");
        vm.stopPrank();
        out = IERC20(tokenOut).balanceOf(who) - before;
    }

    function _assertPoolUntouched() internal view {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(basketKey.toId());
        assertEq(sqrtPriceX96, uint160(1 << 96));
        assertEq(manager.getLiquidity(basketKey.toId()), 0);
    }
}
