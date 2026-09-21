// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {DirectLaunchQuotesTests, QuoteCoin} from "test/graduators/directLaunchQuotes.t.sol";
import {RealmFactoryUniV4Direct} from "src/factories/RealmFactoryUniV4Direct.sol";
import {RealmHookAnyPair} from "src/hooks/RealmHookAnyPair.sol";
import {SwapLpFeeRouter} from "src/feeRouters/SwapLpFeeRouter.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {IRealmMasterFeeHandler} from "src/interfaces/IRealmMasterFeeHandler.sol";
import {UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants.sol";
import {IUniversalRouter} from "src/interfaces/IUniswapV4UniversalRouter.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {PoolKey as CorePoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "lib/v4-core/src/types/PoolId.sol";
import {PoolId as HookPoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "lib/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "lib/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "lib/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "lib/v4-core/src/libraries/TickMath.sol";
import {Hooks} from "lib/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "lib/v4-core/src/libraries/CustomRevert.sol";
import {IPermit2} from "lib/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {IV4Router} from "lib/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";

/// @notice Swaps straight on the pool manager, with no settlement: only for pools whose swap is
///         expected to revert inside the hook before any delta exists.
contract PoolSwapProbe is IUnlockCallback {
    IPoolManager internal immutable MANAGER;

    constructor(IPoolManager manager) {
        MANAGER = manager;
    }

    function swap(CorePoolKey memory key, bool zeroForOne) external {
        MANAGER.unlock(abi.encode(key, zeroForOne));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (CorePoolKey memory key, bool zeroForOne) = abi.decode(data, (CorePoolKey, bool));
        MANAGER.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -1e6,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        return "";
    }
}

/// @notice `RealmHookAnyPair` on ERC20-quoted pools: the four fee legs (exact-output included), both pool
///         orientations, the router-only settlement fallback, pool identity resolution, and the events.
contract RealmHookAnyPairTests is DirectLaunchQuotesTests {
    using PoolIdLibrary for CorePoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant BPS = 10_000;
    /// @dev `_setup` launches every token at a 1% LP fee.
    uint256 internal constant LP_BPS = 100;
    uint256 internal constant TAX_BPS = 300;

    /// @dev Sorts below any mined token address, so the quote is `currency0`.
    address internal constant LOW_QUOTE = address(0x10000000);
    /// @dev Sorts above any mined token address, so the quote is `currency1`.
    address internal constant HIGH_QUOTE = address(type(uint160).max - 0xffff);

    struct ExpectedTrade {
        address token;
        address quote;
        address trader;
        bool isBuy;
        /// @dev `quoteIn` on a buy, `quoteOut` on a sell.
        uint256 quoteAmount;
        /// @dev `tokensOut` on a buy, `tokensIn` on a sell.
        uint256 tokenAmount;
        uint256 lpFee;
        uint256 tax;
    }

    /////////////////////////// HELPERS ///////////////////////////

    /// @dev A `QuoteCoin` etched at `where`, so its sort order against the token is fixed.
    function _placeQuote(address where) internal returns (address) {
        vm.etch(where, address(new QuoteCoin()).code);
        _whitelist(where, QC_PER_ETH);
        return where;
    }

    /// @dev A token taxed 3% both ways, launched against `quote` alone.
    function _launchTaxed(address quote, RealmFactoryUniV4Direct.DevBuy memory devBuy)
        internal
        returns (address token)
    {
        vm.prank(creator);
        token = directFactory.createToken(
            _setup(true),
            _pairs(quote, QC_LAUNCH_TICK),
            _noDirectAlloc(_taxCfg(uint16(TAX_BPS), uint16(TAX_BPS), uint32(14 days))),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            devBuy,
            address(0)
        );
    }

    /// @dev One swap on the `token`/`quote` pool through the universal router, with `trader` as both
    ///      sender and `tx.origin`. `amount` is the input on exact-input and the output on exact-output;
    ///      `limit` is the min out or the max in respectively.
    function _swapLeg(
        address trader,
        address token,
        address quote,
        bool isBuy,
        bool exactIn,
        uint256 amount,
        uint256 limit
    ) internal {
        address tokenIn = isBuy ? quote : token;
        vm.startPrank(trader, trader);
        IERC20(tokenIn).approve(permit2Address, type(uint256).max);
        IPermit2(permit2Address).approve(tokenIn, universalRouter, type(uint160).max, type(uint48).max);

        bytes memory actions = abi.encodePacked(
            uint8(exactIn ? Actions.SWAP_EXACT_IN_SINGLE : Actions.SWAP_EXACT_OUT_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, _legParams(token, quote, isBuy, exactIn, amount, limit));
        IUniversalRouter(universalRouter).execute(abi.encodePacked(uint8(0x10)), inputs, block.timestamp);
        vm.stopPrank();
    }

    function _legParams(address token, address quote, bool isBuy, bool exactIn, uint256 amount, uint256 limit)
        internal
        pure
        returns (bytes[] memory params)
    {
        PoolKey memory key = abi.decode(
            abi.encode(UniswapV4PoolConstants.realmPoolKey(token, quote, TEST_ANYPAIR_HOOK_ADDRESS)), (PoolKey)
        );
        // A buy moves quote -> token, so its direction is whichever way the quote sorted.
        bool zeroForOne = isBuy == (quote < token);
        params = new bytes[](3);
        params[0] = exactIn
            ? abi.encode(
                IV4Router.ExactInputSingleParams({
                    poolKey: key,
                    zeroForOne: zeroForOne,
                    amountIn: uint128(amount),
                    amountOutMinimum: uint128(limit),
                    hookData: ""
                })
            )
            : abi.encode(
                IV4Router.ExactOutputSingleParams({
                    poolKey: key,
                    zeroForOne: zeroForOne,
                    amountOut: uint128(amount),
                    amountInMaximum: uint128(limit),
                    hookData: ""
                })
            );
        params[1] = abi.encode(zeroForOne ? key.currency0 : key.currency1, exactIn ? amount : limit);
        params[2] = abi.encode(zeroForOne ? key.currency1 : key.currency0, exactIn ? limit : amount);
    }

    /// @dev The hook's ERC-6909 claim balance in `quote`.
    function _claims(address quote) internal view returns (uint256) {
        return IPoolManager(poolManagerAddress).balanceOf(address(anyPairHook), uint256(uint160(quote)));
    }

    function _creatorClaimable(address token, address quote) internal view returns (uint256) {
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        return IRealmMasterFeeHandler(address(feeHandler)).getClaimable(tokens, quote, creator)[0];
    }

    function _pendingFees(address token, address quote) internal view returns (uint256 lpFee, uint256 tax) {
        return (anyPairHook.pendingLpFees(token, quote), anyPairHook.pendingTaxes(token, quote));
    }

    function _pendingTotal(address token, address quote) internal view returns (uint256) {
        (uint256 lpFee, uint256 tax) = _pendingFees(token, quote);
        return lpFee + tax;
    }

    /// @dev How many ERC20 `Transfer`s of `quote` left the pool manager in `logs`: one per `take`, which
    ///      is the cost a batched settlement exists to pay only once.
    function _managerTakes(Vm.Log[] memory logs, address quote) internal view returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (
                logs[i].emitter == quote && logs[i].topics.length == 3
                    && logs[i].topics[0] == keccak256("Transfer(address,address,uint256)")
                    && address(uint160(uint256(logs[i].topics[1]))) == poolManagerAddress
            ) ++n;
        }
    }

    /// @dev Settles `token`'s ledger in `quote` and asserts where it went: the treasury gets the router's
    ///      30% of the LP fee, the creator the rest plus the whole tax, both in the quote, and the hook is
    ///      left with no quote and no claims.
    function _settleAndAssertDelivered(address token, address quote) internal {
        (uint256 lpFee, uint256 tax) = _pendingFees(token, quote);
        assertGt(lpFee, 0, "an LP fee to settle");
        assertEq(_claims(quote), lpFee + tax, "the hook's claims back its ledger");
        uint256 treasuryBefore = IERC20(quote).balanceOf(treasury);
        uint256 creatorBefore = _creatorClaimable(token, quote);

        anyPairHook.settleFees(token, quote);

        uint256 treasuryShare = lpFee * LP_TREASURY_BPS / BPS;
        assertEq(IERC20(quote).balanceOf(treasury) - treasuryBefore, treasuryShare, "treasury's LP share, in the quote");
        assertApproxEqAbs(
            _creatorClaimable(token, quote) - creatorBefore,
            lpFee - treasuryShare + tax,
            2,
            "creator's LP share plus the tax, in the quote"
        );
        (uint256 lpAfter, uint256 taxAfter) = _pendingFees(token, quote);
        assertEq(lpAfter + taxAfter, 0, "ledger cleared");
        assertEq(IERC20(quote).balanceOf(address(anyPairHook)), 0, "hook holds no quote");
        assertEq(_claims(quote), 0, "hook holds no claims");
    }

    /// @dev The logs `emitter` produced, in order.
    function _logsFrom(Vm.Log[] memory logs, address emitter) internal pure returns (Vm.Log[] memory out) {
        out = new Vm.Log[](logs.length);
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter) out[n++] = logs[i];
        }
        assembly ("memory-safe") {
            mstore(out, n)
        }
    }

    function _hasLog(Vm.Log[] memory logs, bytes32 sig) internal pure returns (bool) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) return true;
        }
        return false;
    }

    function _assertTokenQuoteLog(Vm.Log memory log, bytes32 sig, address token, address quote, bytes memory data)
        internal
        pure
    {
        assertEq(log.topics[0], sig, "event order");
        assertEq(address(uint160(uint256(log.topics[1]))), token, "token topic");
        assertEq(address(uint160(uint256(log.topics[2]))), quote, "quote topic");
        assertEq(log.data, data, "event payload");
    }

    /// @dev A swap leg's hook events, exactly and in order: the post-swap pool state, the LP fee and tax
    ///      booked at the trade, then the trade itself carrying `tx.origin`.
    function _assertTradeEvents(Vm.Log[] memory all, ExpectedTrade memory t) internal view {
        Vm.Log[] memory logs = _logsFrom(all, address(anyPairHook));
        assertEq(logs.length, 4, "pool state, LP fee, tax, trade");

        PoolId id = UniswapV4PoolConstants.realmPoolKey(t.token, t.quote, TEST_ANYPAIR_HOOK_ADDRESS).toId();
        (uint160 sqrtPriceX96,,,) = IPoolManager(poolManagerAddress).getSlot0(id);
        assertEq(logs[0].topics[0], RealmHookAnyPair.RealmPoolState.selector, "pool state precedes the trade");
        assertEq(address(uint160(uint256(logs[0].topics[1]))), t.token, "pool state token");
        assertEq(
            logs[0].data,
            abi.encode(PoolId.unwrap(id), sqrtPriceX96, IPoolManager(poolManagerAddress).getLiquidity(id)),
            "pool state is the post-swap state"
        );

        _assertTokenQuoteLog(logs[1], RealmHookAnyPair.LpFeesForwarded.selector, t.token, t.quote, abi.encode(t.lpFee));
        _assertTokenQuoteLog(
            logs[2], RealmHookAnyPair.CreatorTaxesAccrued.selector, t.token, t.quote, abi.encode(t.tax)
        );
        _assertTokenQuoteLog(
            logs[3],
            t.isBuy ? RealmHookAnyPair.RealmQuoteSwapBuy.selector : RealmHookAnyPair.RealmQuoteSwapSell.selector,
            t.token,
            t.quote,
            t.isBuy
                ? abi.encode(t.quoteAmount, t.tokenAmount, t.lpFee + t.tax)
                : abi.encode(t.tokenAmount, t.quoteAmount, t.lpFee + t.tax)
        );
        assertEq(address(uint160(uint256(logs[3].topics[3]))), t.trader, "txOrigin is the trader, not the router");
    }

    /// @dev What v4 reverts with when this hook's `beforeSwap` reverts with `inner`.
    function _wrappedBeforeSwapError(bytes4 inner) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            TEST_ANYPAIR_HOOK_ADDRESS,
            IHooks.beforeSwap.selector,
            abi.encodeWithSelector(inner),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /// @dev Opens a pool of `a` and `b` on this hook with the Realm fee and spacing, straight on the
    ///      manager as anyone could, and expects its first swap to revert with the hook's `inner` error.
    function _expectSwapReverts(address a, address b, bytes4 inner) internal {
        CorePoolKey memory key = UniswapV4PoolConstants.realmPoolKey(a, b, TEST_ANYPAIR_HOOK_ADDRESS);
        IPoolManager(poolManagerAddress).initialize(key, TickMath.getSqrtPriceAtTick(0));
        PoolSwapProbe probe = new PoolSwapProbe(IPoolManager(poolManagerAddress));

        vm.expectRevert(_wrappedBeforeSwapError(inner));
        probe.swap(key, true);
        vm.expectRevert(_wrappedBeforeSwapError(inner));
        probe.swap(key, false);
    }

    /////////////////////////// EXACT-OUTPUT LEGS ///////////////////////////

    /// @dev Exact-output buy: the fee is booked in `afterSwap` on the pool input grossed up, so it is the
    ///      combined bps of the trader's TOTAL quote rather than of what the pool consumed, and the trader
    ///      receives exactly the tokens requested.
    function test_exactOutputBuy_chargesTheFeeOnTheTradersTotalQuote() public {
        address quote = address(quoteCoin);
        address token = _launchTaxed(quote, _noDevBuy());
        quoteCoin.mintTo(alice, 1_000e6);

        uint256 want = 500_000e18;
        _swapLeg(alice, token, quote, true, false, want, 1_000e6);

        assertEq(IERC20(token).balanceOf(alice), want, "exactly the tokens requested");
        uint256 paid = 1_000e6 - quoteCoin.balanceOf(alice);
        (uint256 lpFee, uint256 tax) = _pendingFees(token, quote);
        uint256 poolIn = paid - lpFee - tax;
        uint256 gross = poolIn * BPS / (BPS - LP_BPS - TAX_BPS);
        assertEq(lpFee, gross * LP_BPS / BPS, "LP fee on the grossed-up pool input");
        assertEq(tax, gross * TAX_BPS / BPS, "tax on the grossed-up pool input");
        assertApproxEqAbs(lpFee + tax, paid * (LP_BPS + TAX_BPS) / BPS, 2, "fee is bps of the trader's total");
        assertGt(lpFee + tax, poolIn * (LP_BPS + TAX_BPS) / BPS, "and not bps of the pool-consumed amount");

        _settleAndAssertDelivered(token, quote);
    }

    /// @dev Exact-output sell: the fee is withheld in `beforeSwap` by grossing the pool output up, so the
    ///      trader receives exactly the quote requested and pays the fee in extra tokens sold.
    function test_exactOutputSell_grossesThePoolOutputUpAndDeliversExactQuote() public {
        address quote = address(quoteCoin);
        address token = _launchTaxed(quote, _noDevBuy());
        quoteCoin.mintTo(alice, 1_000e6);
        _swapLeg(alice, token, quote, true, true, 200e6, 0);
        anyPairHook.settleFees(token, quote);

        uint256 bag = IERC20(token).balanceOf(alice);
        uint256 quoteBefore = quoteCoin.balanceOf(alice);
        uint256 want = 50e6;
        _swapLeg(alice, token, quote, false, false, want, bag);

        assertEq(quoteCoin.balanceOf(alice) - quoteBefore, want, "exactly the quote requested");
        assertLt(IERC20(token).balanceOf(alice), bag, "paid for in tokens");
        (uint256 lpFee, uint256 tax) = _pendingFees(token, quote);
        uint256 gross = want * BPS / (BPS - LP_BPS - TAX_BPS);
        assertEq(lpFee, gross * LP_BPS / BPS, "LP fee on the grossed-up output");
        assertEq(tax, gross * TAX_BPS / BPS, "tax on the grossed-up output");
        assertApproxEqAbs(
            lpFee + tax, (want + lpFee + tax) * (LP_BPS + TAX_BPS) / BPS, 2, "fee is bps of the pool's total output"
        );

        _settleAndAssertDelivered(token, quote);
    }

    /////////////////////////// ORIENTATION ///////////////////////////

    /// @dev Launch, exact-input buy and sell, and settlement against a quote sorted on a chosen side.
    function _launchTradeAndSettle(address quote, bool quoteIsC0) internal {
        address token = _launchTaxed(quote, _noDevBuy());
        assertEq(quote < token, quoteIsC0, "quote sorts on the intended side");
        CorePoolKey memory key = UniswapV4PoolConstants.realmPoolKey(token, quote, TEST_ANYPAIR_HOOK_ADDRESS);
        (, int24 tick,,) = IPoolManager(poolManagerAddress).getSlot0(key.toId());
        assertEq(tick, quoteIsC0 ? -QC_LAUNCH_TICK : QC_LAUNCH_TICK, "pool opened at the launch price");

        QuoteCoin(quote).mintTo(alice, 1_000e6);
        _swapLeg(alice, token, quote, true, true, 100e6, 0);
        uint256 bag = IERC20(token).balanceOf(alice);
        assertGt(bag, 0, "buy delivered nothing");
        (address resolved, bool resolvedQuoteIsC0) = anyPairHook.poolInfo(HookPoolId.wrap(PoolId.unwrap(key.toId())));
        assertEq(resolved, token, "the token is the resolved side");
        assertEq(resolvedQuoteIsC0, quoteIsC0, "orientation resolved");
        (uint256 lpFee, uint256 tax) = _pendingFees(token, quote);
        assertEq(lpFee, 100e6 * LP_BPS / BPS, "buy LP fee on the input");
        assertEq(tax, 100e6 * TAX_BPS / BPS, "buy tax on the input");
        _settleAndAssertDelivered(token, quote);

        uint256 quoteBefore = IERC20(quote).balanceOf(alice);
        _swapLeg(alice, token, quote, false, true, bag / 2, 0);
        uint256 net = IERC20(quote).balanceOf(alice) - quoteBefore;
        assertGt(net, 0, "sell returned no quote");
        (lpFee, tax) = _pendingFees(token, quote);
        assertEq(lpFee, (net + lpFee + tax) * LP_BPS / BPS, "sell LP fee on the pool output");
        assertEq(tax, (net + lpFee + tax) * TAX_BPS / BPS, "sell tax on the pool output");
        _settleAndAssertDelivered(token, quote);
    }

    function test_orientation_quoteAsCurrency0_tradesAndSettles() public {
        _launchTradeAndSettle(_placeQuote(LOW_QUOTE), true);
    }

    function test_orientation_quoteAsCurrency1_tradesAndSettles() public {
        _launchTradeAndSettle(_placeQuote(HIGH_QUOTE), false);
    }

    /// @dev A dev buy on the ERC20 pair spends the creator's whole quote amount through the hook, which
    ///      books the buy fee like any other buy.
    function _devBuyOnPair(address quote) internal {
        QuoteCoin(quote).mintTo(creator, 100e6);
        vm.prank(creator);
        IERC20(quote).approve(address(directFactory), 100e6);
        RealmFactoryUniV4Direct.DevBuy memory devBuy = _devBuyTo(alice);
        devBuy.quoteAmount = 100e6;

        address token = _launchTaxed(quote, devBuy);

        assertGt(IERC20(token).balanceOf(alice), 0, "dev buy delivered nothing");
        assertEq(IERC20(quote).balanceOf(creator), 0, "the whole quote amount was spent");
        assertEq(IERC20(quote).balanceOf(address(directGraduator)), 0, "graduator keeps no quote");
        (uint256 lpFee, uint256 tax) = _pendingFees(token, quote);
        assertEq(lpFee, 100e6 * LP_BPS / BPS, "dev buy LP fee");
        assertEq(tax, 100e6 * TAX_BPS / BPS, "dev buy tax");
        _settleAndAssertDelivered(token, quote);
    }

    function test_orientation_quoteAsCurrency0_devBuy() public {
        _devBuyOnPair(_placeQuote(LOW_QUOTE));
    }

    function test_orientation_quoteAsCurrency1_devBuy() public {
        _devBuyOnPair(_placeQuote(HIGH_QUOTE));
    }

    /////////////////////////// SETTLEMENT FALLBACK ///////////////////////////

    /// @dev Only the router down: the LP fee falls back to the treasury while the tax still reaches the
    ///      token, and the events say exactly that.
    function test_settleFees_routerRevertSendsOnlyTheLpFeeToTheTreasury() public {
        address token = _taxedTokenWithPendingFees();
        address quote = address(quoteCoin);
        (uint256 lpFee, uint256 tax) = _pendingFees(token, quote);
        assertGt(tax, 0, "the buy booked a tax");
        vm.mockCallRevert(
            address(lpFeeRouter), abi.encodeWithSignature("depositLpFees(address,address,uint256,uint256,uint256)"), ""
        );
        uint256 treasuryBefore = quoteCoin.balanceOf(treasury);
        uint256 creatorBefore = _creatorClaimable(token, quote);

        vm.recordLogs();
        vm.expectEmit(address(feeHandler));
        emit IRealmMasterFeeHandler.CreatorAssetFeesDeposited(token, quote, tax);
        vm.expectEmit(address(anyPairHook));
        emit RealmHookAnyPair.TreasuryFallback(token, quote, lpFee, 0);
        vm.expectEmit(address(anyPairHook));
        emit RealmHookAnyPair.FeesSettled(token, quote, lpFee, tax);
        anyPairHook.settleFees(token, quote);

        assertFalse(
            _hasLog(vm.getRecordedLogs(), SwapLpFeeRouter.LpAssetFeesRouted.selector), "the router routed nothing"
        );
        assertEq(quoteCoin.balanceOf(treasury) - treasuryBefore, lpFee, "only the LP fee fell back");
        assertApproxEqAbs(_creatorClaimable(token, quote) - creatorBefore, tax, 1, "the tax still reached the token");
        assertEq(quoteCoin.allowance(address(anyPairHook), address(lpFeeRouter)), 0, "router approval revoked");
        assertEq(quoteCoin.balanceOf(address(anyPairHook)), 0, "hook holds no quote");
        assertEq(_claims(quote), 0, "hook holds no claims");
    }

    /////////////////////////// POOL IDENTITY ///////////////////////////

    /// @dev A native pool on this hook is refused even for a real Realm token: native belongs to `RealmHook`.
    function test_resolve_nativeQuotedPoolRevertsNativeQuoteNotSupported() public {
        address token = _launch(0, _noDevBuy());
        _expectSwapReverts(token, address(0), RealmHookAnyPair.NativeQuoteNotSupported.selector);
    }

    /// @dev A Realm token cannot be charged on a pool against an ERC20 it never registered as a quote.
    function test_resolve_unregisteredQuoteRevertsNotARealmPool() public {
        address token = _launchAgainstQuoteCoin(_noDevBuy());
        _expectSwapReverts(token, address(new QuoteCoin()), RealmHookAnyPair.NotARealmPool.selector);
    }

    function test_resolve_twoNonRealmErc20sRevertNotARealmPool() public {
        _expectSwapReverts(address(new QuoteCoin()), address(new QuoteCoin()), RealmHookAnyPair.NotARealmPool.selector);
    }

    /////////////////////////// EVENTS ///////////////////////////

    /// @dev Exact-input legs: `quoteIn` is the whole input on a buy, `quoteOut` the pool's output before
    ///      the fee on a sell.
    function test_events_exactInputTrades() public {
        address quote = address(quoteCoin);
        address token = _launchTaxed(quote, _noDevBuy());
        quoteCoin.mintTo(alice, 1_000e6);

        vm.recordLogs();
        _swapLeg(alice, token, quote, true, true, 100e6, 0);
        uint256 bag = IERC20(token).balanceOf(alice);
        _assertTradeEvents(
            vm.getRecordedLogs(),
            ExpectedTrade(token, quote, alice, true, 100e6, bag, 100e6 * LP_BPS / BPS, 100e6 * TAX_BPS / BPS)
        );
        anyPairHook.settleFees(token, quote);

        uint256 quoteBefore = quoteCoin.balanceOf(alice);
        vm.recordLogs();
        _swapLeg(alice, token, quote, false, true, bag / 2, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 lpFee, uint256 tax) = _pendingFees(token, quote);
        uint256 poolOut = quoteCoin.balanceOf(alice) - quoteBefore + lpFee + tax;
        _assertTradeEvents(logs, ExpectedTrade(token, quote, alice, false, poolOut, bag / 2, lpFee, tax));
    }

    /// @dev Exact-output legs: `quoteIn` is everything the buyer paid, fee included; `quoteOut` is the
    ///      pool's grossed-up output, i.e. the exact amount requested plus the fee.
    function test_events_exactOutputTrades() public {
        address quote = address(quoteCoin);
        address token = _launchTaxed(quote, _noDevBuy());
        quoteCoin.mintTo(alice, 1_000e6);

        vm.recordLogs();
        _swapLeg(alice, token, quote, true, false, 500_000e18, 1_000e6);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 lpFee, uint256 tax) = _pendingFees(token, quote);
        _assertTradeEvents(
            logs, ExpectedTrade(token, quote, alice, true, 1_000e6 - quoteCoin.balanceOf(alice), 500_000e18, lpFee, tax)
        );
        anyPairHook.settleFees(token, quote);

        vm.recordLogs();
        _swapLeg(alice, token, quote, false, false, 20e6, 500_000e18);
        logs = vm.getRecordedLogs();
        (lpFee, tax) = _pendingFees(token, quote);
        _assertTradeEvents(
            logs,
            ExpectedTrade(
                token, quote, alice, false, 20e6 + lpFee + tax, 500_000e18 - IERC20(token).balanceOf(alice), lpFee, tax
            )
        );
    }

    /// @dev The happy-path settlement: the router reports its split, the fee handler both deposits (LP
    ///      creator share, then tax), and the hook `FeesSettled` last, with no fallback and no fee event
    ///      re-emitted.
    function test_events_settleFees() public {
        address token = _taxedTokenWithPendingFees();
        address quote = address(quoteCoin);
        (uint256 lpFee, uint256 tax) = _pendingFees(token, quote);
        uint256 treasuryShare = lpFee * LP_TREASURY_BPS / BPS;

        vm.recordLogs();
        vm.expectEmit(address(lpFeeRouter));
        emit SwapLpFeeRouter.LpAssetFeesRouted(token, quote, lpFee - treasuryShare, treasuryShare, 0);
        vm.expectEmit(address(feeHandler));
        emit IRealmMasterFeeHandler.CreatorAssetFeesDeposited(token, quote, lpFee - treasuryShare);
        vm.expectEmit(address(feeHandler));
        emit IRealmMasterFeeHandler.CreatorAssetFeesDeposited(token, quote, tax);
        vm.expectEmit(address(anyPairHook));
        emit RealmHookAnyPair.FeesSettled(token, quote, lpFee, tax);
        anyPairHook.settleFees(token, quote);

        Vm.Log[] memory hookLogs = _logsFrom(vm.getRecordedLogs(), address(anyPairHook));
        assertEq(hookLogs.length, 1, "the hook emits only FeesSettled");
        assertEq(hookLogs[0].topics[0], RealmHookAnyPair.FeesSettled.selector);
    }

    /////////////////////////// OVERALL FEE CAP ///////////////////////////

    /// @dev The ERC20 twin of `RealmSwapHookLpFees.test_swapReverts_whenCombinedFeeExceedsCap`: the hook
    ///      caps LP fee + tax at `MAX_OVERALL_FEE_BPS` (20%). The factory cannot configure a token above
    ///      5%, so the over-cap config is injected with `vm.mockCall` to reach the runtime backstop.
    function test_resolve_feeAboveCapRevertsFeeTooHigh() public {
        address quote = address(quoteCoin);
        address token = _launchTaxed(quote, _noDevBuy());
        quoteCoin.mintTo(alice, 1_000e6);

        // Exactly at the cap (0 + 2000): allowed.
        _mockFees(token, 0, 2000);
        _swapLeg(alice, token, quote, true, true, 10e6, 0);

        // One bps over (1 + 2000): refused. The approvals above still stand, so only the router call
        // itself is under `expectRevert`.
        _mockFees(token, 1, 2000);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)),
            _legParams(token, quote, true, true, 10e6, 0)
        );
        vm.prank(alice, alice);
        vm.expectRevert(_wrappedBeforeSwapError(RealmHookAnyPair.FeeTooHigh.selector));
        IUniversalRouter(universalRouter).execute(abi.encodePacked(uint8(0x10)), inputs, block.timestamp);
    }

    /// @dev Forces `token.getSwapFees(isBuy)` to report an arbitrary split, bypassing the factory's
    ///      `MAX_TOTAL_FEE_BPS` validation.
    function _mockFees(address token, uint16 lpFeeBps, uint16 taxBps) internal {
        vm.mockCall(
            token,
            abi.encodeWithSelector(IRealmToken.getSwapFees.selector),
            abi.encode(IRealmToken.RealmTradeFees({taxBps: taxBps, lpFeeBps: lpFeeBps}))
        );
    }

    /////////////////////////// UNLOCK CALLBACK ///////////////////////////

    /// @dev The hook's only unlock is the one `settleFees` opens; anything else reaching this entry
    ///      point could `burn`+`take` out of band and desync the ledger from the hook's claim balance.
    function test_unlockCallback_revertsForNonPoolManagerCaller() public {
        vm.expectRevert(RealmHookAnyPair.OnlyPoolManager.selector);
        anyPairHook.unlockCallback("");

        vm.prank(alice);
        vm.expectRevert(RealmHookAnyPair.OnlyPoolManager.selector);
        anyPairHook.unlockCallback(abi.encode(address(quoteCoin), uint256(1)));
    }

    /////////////////////////// LEDGER ACCUMULATION ///////////////////////////

    /// @dev The ledger ADDS up: three trades before one redemption must settle the sum, not the last
    ///      one's fee. An accidental `=` for `+=` would pass every settle-after-each-swap test.
    function test_settleFees_sumsFeesAcrossMultipleSwapsBeforeRedemption() public {
        address quote = address(quoteCoin);
        address token = _launchTaxed(quote, _noDevBuy());
        quoteCoin.mintTo(alice, 1_000e6);

        _swapLeg(alice, token, quote, true, true, 100e6, 0);
        (uint256 lpFirst, uint256 taxFirst) = _pendingFees(token, quote);
        _swapLeg(alice, token, quote, true, true, 100e6, 0);
        uint256 bag = IERC20(token).balanceOf(alice);
        _swapLeg(alice, token, quote, false, true, bag / 2, 0);

        (uint256 lpFee, uint256 tax) = _pendingFees(token, quote);
        assertGt(lpFee, 2 * lpFirst, "three legs' LP fees, not the last one's");
        assertGt(tax, 2 * taxFirst, "three legs' taxes, not the last one's");
        assertApproxEqRel(lpFee * TAX_BPS, tax * LP_BPS, 1e12, "both ledgers grew, each at its own rate");

        _settleAndAssertDelivered(token, quote);
    }

    /////////////////////////// BATCHED REDEMPTION ///////////////////////////

    /// @dev The batched overload's whole point: N tokens sharing one quote leave the pool manager on ONE
    ///      `take`, not N. Delivery must be unchanged — each token's own creator and the treasury are
    ///      credited exactly what a per-token settle would have given them.
    function test_settleFees_batchTakesOnceForEveryTokenSharingTheQuote() public {
        address quote = address(quoteCoin);
        address first = _launchTaxed(quote, _noDevBuy());
        address second = _launchTaxed(quote, _noDevBuy());
        quoteCoin.mintTo(alice, 1_000e6);
        _swapLeg(alice, first, quote, true, true, 100e6, 0);
        _swapLeg(alice, second, quote, true, true, 60e6, 0);

        (uint256 lpFirst, uint256 taxFirst) = _pendingFees(first, quote);
        (uint256 lpSecond, uint256 taxSecond) = _pendingFees(second, quote);
        assertGt(lpSecond, 0, "both pools traded");
        assertEq(_claims(quote), lpFirst + taxFirst + lpSecond + taxSecond, "both ledgers are claim-backed");
        uint256 treasuryBefore = IERC20(quote).balanceOf(treasury);
        uint256 firstBefore = _creatorClaimable(first, quote);
        uint256 secondBefore = _creatorClaimable(second, quote);

        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (first, second);
        vm.recordLogs();
        anyPairHook.settleFees(tokens, quote);

        assertEq(_managerTakes(vm.getRecordedLogs(), quote), 1, "one take out of the manager, not two");
        assertEq(
            IERC20(quote).balanceOf(treasury) - treasuryBefore,
            lpFirst * LP_TREASURY_BPS / BPS + lpSecond * LP_TREASURY_BPS / BPS,
            "both LP treasury shares, in the quote"
        );
        assertApproxEqAbs(
            _creatorClaimable(first, quote) - firstBefore,
            lpFirst - lpFirst * LP_TREASURY_BPS / BPS + taxFirst,
            2,
            "the first token's creator, credited against its own token"
        );
        assertApproxEqAbs(
            _creatorClaimable(second, quote) - secondBefore,
            lpSecond - lpSecond * LP_TREASURY_BPS / BPS + taxSecond,
            2,
            "and the second's, against its own"
        );
        assertEq(_pendingTotal(first, quote) + _pendingTotal(second, quote), 0, "both ledgers cleared");
        assertEq(IERC20(quote).balanceOf(address(anyPairHook)), 0, "hook holds no quote");
        assertEq(_claims(quote), 0, "hook holds no claims");
    }

    /// @dev A batch may carry entries that settle nothing: an untraded token and a repeated one must
    ///      neither revert nor pay twice. The repeat is also the reentrancy shape — every ledger is
    ///      already zero by the time any destination is called, so a second pass finds nothing.
    function test_settleFees_batchSkipsEmptyAndDuplicatedEntries() public {
        address quote = address(quoteCoin);
        address traded = _launchTaxed(quote, _noDevBuy());
        address untraded = _launchTaxed(quote, _noDevBuy());
        quoteCoin.mintTo(alice, 1_000e6);
        _swapLeg(alice, traded, quote, true, true, 100e6, 0);

        (uint256 lpFee, uint256 tax) = _pendingFees(traded, quote);
        uint256 treasuryBefore = IERC20(quote).balanceOf(treasury);
        uint256 creatorBefore = _creatorClaimable(traded, quote);

        address[] memory tokens = new address[](3);
        (tokens[0], tokens[1], tokens[2]) = (traded, untraded, traded);
        vm.recordLogs();
        anyPairHook.settleFees(tokens, quote);

        assertEq(_managerTakes(vm.getRecordedLogs(), quote), 1, "still a single take");
        assertEq(
            IERC20(quote).balanceOf(treasury) - treasuryBefore,
            lpFee * LP_TREASURY_BPS / BPS,
            "the treasury was paid once, not twice"
        );
        assertApproxEqAbs(
            _creatorClaimable(traded, quote) - creatorBefore,
            lpFee - lpFee * LP_TREASURY_BPS / BPS + tax,
            2,
            "and so was the creator"
        );
        assertEq(_pendingTotal(traded, quote) + _pendingTotal(untraded, quote), 0, "nothing left pending");
        assertEq(IERC20(quote).balanceOf(address(anyPairHook)), 0, "nothing stranded in the hook");

        // Re-running the same batch is now an all-empty one: no unlock, no take, no revert.
        vm.recordLogs();
        anyPairHook.settleFees(tokens, quote);
        assertEq(_managerTakes(vm.getRecordedLogs(), quote), 0, "an all-empty batch touches nothing");
    }

    /// @dev Two ERC20 pools of the SAME token keep separate ledgers and separate identity caches:
    ///      trading one must leave the other's pending fees at zero and settle only its own.
    function test_resolve_secondErc20PoolOfSameTokenIsIndependent() public {
        address low = _placeQuote(LOW_QUOTE);
        address high = _placeQuote(HIGH_QUOTE);
        RealmFactoryUniV4Direct.DirectPair[] memory pairs = new RealmFactoryUniV4Direct.DirectPair[](2);
        pairs[0] = RealmFactoryUniV4Direct.DirectPair({quote: low, weightBps: 5_000, launchTick: QC_LAUNCH_TICK});
        pairs[1] = RealmFactoryUniV4Direct.DirectPair({quote: high, weightBps: 5_000, launchTick: QC_LAUNCH_TICK});

        vm.prank(creator);
        address token = directFactory.createToken(
            _setup(true),
            pairs,
            _noDirectAlloc(_taxCfg(uint16(TAX_BPS), uint16(TAX_BPS), uint32(14 days))),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            _noDevBuy(),
            address(0)
        );

        QuoteCoin(low).mintTo(alice, 1_000e6);
        _swapLeg(alice, token, low, true, true, 100e6, 0);

        (uint256 lpLow, uint256 taxLow) = _pendingFees(token, low);
        assertEq(lpLow, 100e6 * LP_BPS / BPS, "the traded pool booked its fee");
        (uint256 lpHigh, uint256 taxHigh) = _pendingFees(token, high);
        assertEq(lpHigh + taxHigh, 0, "the untraded pool booked nothing");

        // The second pool trades on its own terms, and settling the first leaves it untouched.
        QuoteCoin(high).mintTo(alice, 1_000e6);
        _swapLeg(alice, token, high, true, true, 50e6, 0);
        assertEq(anyPairHook.pendingLpFees(token, high), 50e6 * LP_BPS / BPS, "and its own fee when it does");
        assertEq(anyPairHook.pendingLpFees(token, low), lpLow, "the first pool's ledger is unchanged by it");

        anyPairHook.settleFees(token, low);
        assertEq(anyPairHook.pendingLpFees(token, low) + anyPairHook.pendingTaxes(token, low), 0, "the first cleared");
        assertEq(
            anyPairHook.pendingLpFees(token, high) + anyPairHook.pendingTaxes(token, high),
            50e6 * (LP_BPS + TAX_BPS) / BPS,
            "and only the first"
        );
        assertEq(taxLow, 100e6 * TAX_BPS / BPS, "the traded pool's tax was its own too");
    }

    /// @dev The token announces its ERC20 quotes once, at creation, native excluded; a native-only launch
    ///      announces none.
    function test_events_quotesRegisteredAtCreation() public {
        vm.recordLogs();
        vm.prank(creator);
        address token = directFactory.createToken(
            _setup(false),
            _twoPairs(),
            _noDirectAlloc(_emptyTaxCfg()),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            _noDevBuy(),
            address(0)
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 0 || logs[i].topics[0] != IRealmToken.QuotesRegistered.selector) continue;
            ++found;
            assertEq(logs[i].emitter, token, "emitted by the token");
            address[] memory quotes = abi.decode(logs[i].data, (address[]));
            assertEq(quotes.length, 1, "native is not announced");
            assertEq(quotes[0], address(quoteCoin));
        }
        assertEq(found, 1, "announced once");

        vm.recordLogs();
        _launch(0, _noDevBuy());
        assertFalse(_hasLog(vm.getRecordedLogs(), IRealmToken.QuotesRegistered.selector), "native-only: nothing");
    }
}
