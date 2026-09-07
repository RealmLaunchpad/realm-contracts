// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseHook} from "lib/v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {IRealmLpFeeRouter} from "src/interfaces/IRealmLpFeeRouter.sol";

/// @title LivoSwapHook V2
/// @notice Uniswap V4 hook that collects LP fees and time-limited buy/sell taxes on swaps of
///         tokens graduated via RealmGraduatorUniswapV4.
/// @dev Singleton, ownerless hook shared by every taxable token. Per-token LP-fee + tax rates come
///      from `IRealmToken.getSwapFees(isBuy)`, which already windows the tax (zero outside the
///      post-graduation period) and returns only the swap's direction, so the hook stays agnostic to
///      the tax schedule. It places no cap
///      on either component individually; instead it reverts a swap whose combined
///      `lpFeeBps + taxBps` for the leg exceeds `MAX_OVERALL_FEE_BPS`, leaving each token free to
///      split that budget as it likes. Collected LP fees are forwarded to `RealmLpFeeRouter` (which
///      splits them between the treasury and the token's fee receivers); taxes are forwarded to the
///      token's master fee handler via `IRealmToken.accrueFees()`, which distributes them to the
///      token's configured fee receivers. The hook is unaware of either split and only forwards.
///
/// @dev Fees are always charged on the ETH side (currency0); which callback withholds them depends
///      on whether the ETH amount is already known in `beforeSwap`:
///      - exact-input buy:   ETH is the input, its size is `amountSpecified` → withheld in
///                           `beforeSwap` (the pool sees a smaller effective `ethIn`).
///      - exact-output sell: ETH is the output, its size is `amountSpecified` → withheld in
///                           `beforeSwap`, grossing the pool output up by the fee so the swapper
///                           still receives the exact ETH they requested.
///      - exact-output buy:  ETH is the input, size unknown until the swap → settled in `afterSwap`.
///      - exact-input sell:  ETH is the output, size unknown until the swap → settled in `afterSwap`.
contract LivoSwapHook is BaseHook {
    uint256 public constant VERSION = 2;

    /// @notice LP fee router that splits forwarded fees between treasury and creator.
    /// @dev Resolved at swap time; upgrade the router via its own UUPS proxy without redeploying
    ///      this hook.
    IRealmLpFeeRouter public immutable FEE_ROUTER;

    /// @notice Protocol treasury. Receives the LP fee on the router-failure fallback path so the
    ///         fee stays under protocol control.
    /// @dev Passed in directly at construction (not read from the router), so the hook's fallback
    ///      never depends on the router being live or correctly configured at deploy time.
    address public immutable TREASURY;

    /// @notice Basis points denominator (10000 = 100%).
    uint256 private constant BASIS_POINTS = 10000;

    /// @notice Hard ceiling on the COMBINED fee (LP fee + active tax) charged on a single swap leg,
    ///         so a misconfigured token can never overcharge users. The swap reverts if the token's
    ///         `lpFeeBps + taxBps` exceeds this; the hook stays agnostic to how the token splits the
    ///         budget between LP fee and taxes.
    /// @dev    The high fee (20%) is to allow teams to have temporary high taxes which decay over some hours
    uint16 private constant MAX_OVERALL_FEE_BPS = 2000; // 20%

    /// @notice Gas budget forwarded to the router on `depositLpFees`. Sized with generous headroom
    ///         over the router's worst-case path: the marketcap split, the treasury transfer, the
    ///         creator forward through `RealmMasterFeeHandler` (up to `MAX_DIRECT_RECEIVERS` *
    ///         `DIRECT_FORWARD_GAS` ≈ 400k of direct-receiver forwards), and a future
    ///         liquidity-reinvestment leg (`modifyLiquidity`). Still capped so a misbehaving router
    ///         cannot drain the remaining gas and starve the fallback path — which is now a single
    ///         cheap `.call` to the treasury.
    uint256 private constant ROUTER_GAS_LIMIT = 1_000_000;

    /// @notice LP fee withheld on the ETH leg in `beforeSwap`, carried to `afterSwap`.
    /// @dev Set by the two legs that withhold in `beforeSwap` (exact-input buy, exact-output sell)
    ///      and routed there once the token amount is known. The other two legs never read it.
    uint256 private transient _cachedLpFee;

    /// @notice Tax withheld on the ETH leg in `beforeSwap`, carried to `afterSwap`. See `_cachedLpFee`.
    uint256 private transient _cachedTax;

    /////////////////////////// ERRORS & EVENTS ///////////////////////////

    error NoSwapsBeforeGraduation();
    /// @notice Thrown when a token's combined fee (`lpFeeBps + taxBps`) for this swap leg exceeds
    ///         `MAX_OVERALL_FEE_BPS`.
    error FeeTooHigh();
    /// @notice Thrown when the pool's `currency0` is not native ETH (`address(0)`). The hook charges
    ///         all fees on `currency0` assuming it is ETH; a non-ETH pool would misroute fees.
    error UnexpectedPoolCurrency();
    /// @notice Thrown when the router-failure fallback cannot push the LP fee to the treasury.
    error TreasuryTransferFailed();

    /// @notice Emitted when swap taxes are forwarded to the token's master fee handler, which
    ///         distributes them to the token's configured fee receivers.
    event CreatorTaxesAccrued(address indexed token, uint256 amount);
    /// @notice Emitted when LP fees are forwarded out of the hook on a swap leg.
    /// @dev The split is reported by the router in `RealmLpFeeRouter.LpFeesRouted`; on the fallback
    ///      path (router reverts) that event is absent and the full amount goes to the treasury,
    ///      which is how indexers detect the fallback.
    event LpFeesForwarded(address indexed token, uint256 amount);
    /// @notice Emitted on every buy for off-chain indexing.
    event LivoSwapBuy(
        address indexed token, address indexed txOrigin, uint256 ethIn, uint256 tokensOut, uint256 ethFees
    );
    /// @notice Emitted on every sell for off-chain indexing.
    event LivoSwapSell(
        address indexed token, address indexed txOrigin, uint256 tokensIn, uint256 ethOut, uint256 ethFees
    );

    //////////////////////////////////////////////////////////////////////

    /// @notice Initializes the hook with the pool manager, LP fee router, and treasury addresses.
    /// @dev `_treasury` is the protocol address that receives the LP fee on the router-failure
    ///      fallback path.
    constructor(IPoolManager _poolManager, address _router, address _treasury) BaseHook(_poolManager) {
        FEE_ROUTER = IRealmLpFeeRouter(_router);
        TREASURY = _treasury;
    }

    /// @notice Allows contract to receive ETH from `poolManager.take()`.
    /// @dev ETH should never remain in this contract between transactions. If it does, it is
    ///      accepted as stuck. Adding a rescue mechanism would require `Ownable`, which is
    ///      avoided to keep this singleton hook minimal and ownerless.
    receive() external payable {}

    /// @notice Returns the hook permissions indicating which callbacks are implemented.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    //////////////////////////// SWAP CALLBACKS ///////////////////////////

    /// @notice Enforces graduation and withholds the fee on the legs whose ETH size is known here:
    ///         exact-input buys (charged on the ETH input) and exact-output sells (charged on the
    ///         grossed-up ETH output). Exact-output buys and exact-input sells defer to `_afterSwap`.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        address token = Currency.unwrap(key.currency1);
        // The hook charges all fees on `currency0` assuming it is native ETH. Every Realm pool pairs
        // the token against ETH (`address(0)`), which always sorts as `currency0`. Enforce it here so
        // the hook can never be attached to a non-ETH pool and misroute fees. Cheap calldata compare,
        // kept before the external `graduated()` call.
        if (Currency.unwrap(key.currency0) != address(0)) revert UnexpectedPoolCurrency();
        if (!IRealmToken(token).graduated()) revert NoSwapsBeforeGraduation();

        uint256 lpFee;
        uint256 tax;
        if (params.zeroForOne) {
            // BUY. Only exact-input is charged here
            if (params.amountSpecified >= 0) {
                // exact-output (amountSpecified > 0) doesn't know the ETH input yet, so it defers to afterSwap.
                return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
            }
            (lpFee, tax) = _computeFees(_exactInputAmount(params.amountSpecified), token, true);
        } else {
            // SELL. Only exact-output is charged here;
            if (params.amountSpecified <= 0) {
                // exact-input (amountSpecified < 0) doesn't know the ETH output yet, so it defers to afterSwap.
                return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
            }
            (lpFee, tax) = _grossedUpSellFee(token, _exactOutputAmount(params.amountSpecified));
        }

        uint256 totalFee = lpFee + tax;
        _cachedLpFee = lpFee;
        _cachedTax = tax;

        if (totalFee > 0) poolManager.take(key.currency0, address(this), totalFee);

        // Positive deltaSpecified means the hook is taking from the specified currency (currency0/ETH
        // on both legs handled here). On the exact-input buy it shrinks the ETH the pool receives; on
        // the exact-output sell it grosses the ETH the pool pays out up by `totalFee`, so the pool
        // releases `request + totalFee` and the swapper still nets exactly `request`.
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(_toInt128(totalFee), 0), 0);
    }

    /// @notice Settles fees once swap amounts are known: routes the fee withheld in `_beforeSwap`
    ///         (exact-input buy, exact-output sell), or takes it from the ETH leg here (exact-output
    ///         buy, exact-input sell).
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        address token = Currency.unwrap(key.currency1);

        if (!params.zeroForOne) {
            // SELL: exact-input takes its fee from the ETH output here; exact-output was withheld in
            // beforeSwap and only needs routing.
            int128 sellDelta = params.amountSpecified < 0
                ? _settleSellExactInput(key, token, delta)
                : _settleSellExactOutput(token, delta);
            return (IHooks.afterSwap.selector, sellDelta);
        } else {
            // BUY: currency1 (token) is the output. `delta.amount1()` is the tokens received.
            uint256 tokensOut = _abs(delta.amount1());
            int128 buyDelta = params.amountSpecified < 0
                ? _settleBuyExactInput(token, _exactInputAmount(params.amountSpecified), tokensOut)
                : _settleBuyExactOutput(key, token, delta, tokensOut);
            return (IHooks.afterSwap.selector, buyDelta);
        }
    }

    ////////////////////////// FEE SETTLEMENT (PER LEG) ///////////////////////

    /// @dev Exact-input buy: the fee was already withheld from the input in `_beforeSwap`, so here
    ///      we only route it and emit. Returns a zero afterSwap delta (nothing left to settle).
    function _settleBuyExactInput(address token, uint256 ethIn, uint256 tokensOut) private returns (int128) {
        uint256 lpFee = _cachedLpFee;
        uint256 tax = _cachedTax;
        uint256 totalFee = lpFee + tax;

        // `ethIn - totalFee` is the ETH that actually crossed into the pool against `tokensOut`.
        _route(token, lpFee, tax, ethIn - totalFee, tokensOut);
        emit LivoSwapBuy(token, tx.origin, ethIn, tokensOut, totalFee);
        return 0;
    }

    /// @dev Exact-output buy: the pool consumed `ethInPool` to produce `tokensOut`; the fee is
    ///      settled separately via the returned afterSwap delta, so the swapper's total ETH out is
    ///      `ethInPool + totalFee`.
    ///
    ///      Parity with exact-input: the fee must be `X%` of the swapper's TOTAL ETH out, not `X%`
    ///      of the pool-consumed ETH. So we gross `ethInPool` up to the equivalent exact-input
    ///      input `grossEth = ethInPool * 10000 / (10000 - totalBps)` and charge the fee on that;
    ///      without the gross-up, exact-output undercharges versus exact-input by ~feeBps² order.
    function _settleBuyExactOutput(PoolKey calldata key, address token, BalanceDelta delta, uint256 tokensOut)
        private
        returns (int128)
    {
        // `delta.amount0()` is negative for buys (ETH paid into the pool).
        uint256 ethInPool = _abs(delta.amount0());
        (uint256 lpFeeBps, uint256 taxBps) = _currentFeeBps(token, true);
        uint256 grossEth = _grossUp(ethInPool, lpFeeBps + taxBps);
        (uint256 lpFee, uint256 tax) = _feeAmounts(grossEth, lpFeeBps, taxBps);
        uint256 totalFee = lpFee + tax;

        if (totalFee > 0) poolManager.take(key.currency0, address(this), totalFee);

        // The fee never crossed the pool, so route the avg price on the pool-consumed amount only,
        // mirroring exact-input's "pool-consumed amount" semantics.
        _route(token, lpFee, tax, ethInPool, tokensOut);

        // Report the swapper's total ETH outflow (pool input + hook fee) so the event matches
        // exact-input's `ethIn` semantics.
        emit LivoSwapBuy(token, tx.origin, ethInPool + totalFee, tokensOut, totalFee);
        return _toInt128(totalFee);
    }

    /// @dev Exact-input sell: the pool paid out `ethGross` for `tokensIn`; the fee is taken from that
    ///      output here and returned as the afterSwap delta. The swapper nets `ethGross - totalFee`.
    function _settleSellExactInput(PoolKey calldata key, address token, BalanceDelta delta) private returns (int128) {
        // On a sell, `delta.amount0()` is positive (ETH out) and `delta.amount1()` negative (tokens in).
        uint256 ethGross = _abs(delta.amount0());
        uint256 tokensIn = _abs(delta.amount1());
        (uint256 lpFee, uint256 tax) = _computeFees(ethGross, token, false);
        uint256 totalFee = lpFee + tax;

        if (totalFee > 0) poolManager.take(key.currency0, address(this), totalFee);

        // `ethGross` is the ETH the pool actually paid out for `tokensIn`; the hook fee is skimmed
        // from it *after* the swap and never changed the pool's execution price. Feed the full
        // `ethGross` (the pool-side ETH the buy legs also forward) so the router reads the same avg
        // price a buy at this pool state would, not an under-stated net-of-fee one.
        _route(token, lpFee, tax, ethGross, tokensIn);
        emit LivoSwapSell(token, tx.origin, tokensIn, ethGross, totalFee);
        return _toInt128(totalFee);
    }

    /// @dev Exact-output sell: the fee was computed and withheld via the beforeSwap delta, which also
    ///      grossed the pool output up so the swapper receives exactly the ETH they requested. Here
    ///      we only route the withheld fee and emit; the afterSwap delta is zero (already settled).
    ///
    ///      `ethGross = -delta.amount0()` is the full ETH the pool paid out (`request + totalFee`);
    ///      it carries the same "full pool ETH" meaning as the exact-input sell's `ethGross`, so the
    ///      router and the `LivoSwapSell.ethOut` field stay consistent across both sell legs.
    function _settleSellExactOutput(address token, BalanceDelta delta) private returns (int128) {
        uint256 ethGross = _abs(delta.amount0());
        uint256 tokensIn = _abs(delta.amount1());
        uint256 lpFee = _cachedLpFee;
        uint256 tax = _cachedTax;

        _route(token, lpFee, tax, ethGross, tokensIn);
        emit LivoSwapSell(token, tx.origin, tokensIn, ethGross, lpFee + tax);
        return 0;
    }

    ////////////////////////////////// FEE MATH ///////////////////////////////

    /// @notice Resolves the LP-fee and tax bps the token charges on this leg and enforces the cap.
    /// @dev `getSwapFees(isBuy)` already windows the tax (zero outside the post-graduation period) and
    ///      returns only the requested direction. No individual cap is placed on either component — a
    ///      token is free to split the budget — but the combined `lpFeeBps + taxBps` must stay within
    ///      `MAX_OVERALL_FEE_BPS` or the swap reverts with `FeeTooHigh`. The token's `uint16` rates are
    ///      widened to `uint256` so a misreporting token reverts with `FeeTooHigh` rather than a panic.
    function _currentFeeBps(address token, bool isBuy) private view returns (uint256 lpFeeBps, uint256 taxBps) {
        IRealmToken.RealmTradeFees memory fees = IRealmToken(token).getSwapFees(isBuy);
        lpFeeBps = fees.lpFeeBps;
        taxBps = fees.taxBps;
        if (lpFeeBps + taxBps > MAX_OVERALL_FEE_BPS) revert FeeTooHigh();
    }

    /// @notice Resolves the rates (enforcing the cap) and splits `grossEth` into LP fee + tax.
    function _computeFees(uint256 grossEth, address token, bool isBuy)
        private
        view
        returns (uint256 lpFee, uint256 tax)
    {
        (uint256 lpFeeBps, uint256 taxBps) = _currentFeeBps(token, isBuy);
        return _feeAmounts(grossEth, lpFeeBps, taxBps);
    }

    /// @notice Exact-output sell: the swapper asked for exactly `ethOut` ETH. To still charge the fee
    ///         on the ETH leg without shorting them, we gross the pool's output up to
    ///         `ethOut * 10000 / (10000 - totalBps)` and charge the fee on that gross. The swapper
    ///         sells the extra tokens needed and receives exactly `ethOut`, mirroring the
    ///         exact-output buy gross-up on the output side.
    function _grossedUpSellFee(address token, uint256 ethOut) private view returns (uint256 lpFee, uint256 tax) {
        (uint256 lpFeeBps, uint256 taxBps) = _currentFeeBps(token, false);
        uint256 grossEth = _grossUp(ethOut, lpFeeBps + taxBps);
        return _feeAmounts(grossEth, lpFeeBps, taxBps);
    }

    /// @dev Splits a gross ETH amount into the LP fee and tax slices at the given bps.
    function _feeAmounts(uint256 grossEth, uint256 lpFeeBps, uint256 taxBps)
        private
        pure
        returns (uint256 lpFee, uint256 tax)
    {
        lpFee = (grossEth * lpFeeBps) / BASIS_POINTS;
        tax = (grossEth * taxBps) / BASIS_POINTS;
    }

    /// @dev Grosses up an exact-output amount into the equivalent gross that yields it net of fee:
    ///      `amount * 10000 / (10000 - totalBps)`. Used on the ETH input of an exact-output buy and
    ///      the ETH output of an exact-output sell. Division is safe: `_currentFeeBps` caps
    ///      `totalBps` at `MAX_OVERALL_FEE_BPS` (2000), well below `BASIS_POINTS` (10000), so the
    ///      denominator never reaches zero.
    function _grossUp(uint256 amount, uint256 totalBps) private pure returns (uint256) {
        if (totalBps == 0) return amount;
        return (amount * BASIS_POINTS) / (BASIS_POINTS - totalBps);
    }

    ///////////////////////////////// FEE ROUTING /////////////////////////////

    /// @notice Forwards the LP fee through the router and the tax slice to the token's master fee
    ///         handler (which distributes it to the token's configured fee receivers).
    /// @dev The router call is the only place this contract trusts external code. It is hardened
    ///      against every failure mode `RealmLpFeeRouter.depositLpFees` can return:
    ///      - **Revert with data** (custom error, `require`, `revert(string)`): caught; the LP fee
    ///        falls through to the treasury.
    ///      - **Out-of-gas inside the router**: forwarded gas is capped at `ROUTER_GAS_LIMIT`, so
    ///        the post-catch frame keeps `gasleft() - ROUTER_GAS_LIMIT` for the fallback. Defends
    ///        against gas griefing by a hostile upgrade.
    ///      - **Router proxy has no code / impl missing `depositLpFees`**: the high-level call's
    ///        `extcodesize` check (or the router shipping without a `fallback()`) reverts and is
    ///        caught. *Router upgrades MUST keep shipping without a payable fallback* — adding one
    ///        would silently strand the LP fee on the proxy.
    ///
    ///      The fallback pushes the LP fee to the treasury (set at construction, independent of the
    ///      router), keeping it under protocol control and out of this contract instead of handing the whole
    ///      amount to the token's fee receivers. The treasury is the protocol's own address, so the
    ///      push is safe. If that transfer also fails the whole swap reverts — by design: a router
    ///      outage AND a treasury that rejects ETH is a protocol-wide failure that warrants a clear
    ///      revert rather than silently stranding ETH in this contract.
    /// @param ethSwapAmount   ETH the pool exchanged on this leg: the input net of the pre-pool fee
    ///                        on a buy, the full ETH output on a sell (the hook fee is skimmed after
    ///                        the pool and excluded). With `tokenSwapAmount` it lets the router
    ///                        derive the avg price without reading slot0.
    /// @param tokenSwapAmount Token amount that crossed the pool during this leg.
    function _route(address token, uint256 lpFee, uint256 tax, uint256 ethSwapAmount, uint256 tokenSwapAmount) private {
        if (lpFee > 0) {
            // LP fees forwarded to the router, which splits them between the treasury and the token's
            // fee receivers (and, in future, liquidity additions).
            emit LpFeesForwarded(token, lpFee);
            try FEE_ROUTER.depositLpFees{value: lpFee, gas: ROUTER_GAS_LIMIT}(token, ethSwapAmount, tokenSwapAmount) {
            // happy path — router emitted its own `LpFeesRouted` with the breakdown.
            }
            catch {
                // Fallback: the router is unavailable, so send the LP fee to the treasury instead of
                // handing the whole amount to the token's fee receivers. Keeps the fee under protocol
                // control. The treasury is a protocol-owned address, so the push is safe.
                (bool ok,) = TREASURY.call{value: lpFee}("");
                require(ok, TreasuryTransferFailed());
            }
        }
        if (tax > 0) {
            emit CreatorTaxesAccrued(token, tax);
            IRealmToken(token).accrueFees{value: tax}();
        }
    }

    //////////////////////////////// CASTING UTILS ////////////////////////////

    /// @dev Magnitude of a swap-delta component. Each call site knows the component's sign from the
    ///      swap direction; centralizing the unsafe int→uint cast here keeps the call sites clean.
    function _abs(int128 x) private pure returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(uint128(x < 0 ? -x : x));
    }

    /// @dev Unsigned size of an exact-input swap, whose `amountSpecified` is negative by convention.
    function _exactInputAmount(int256 amountSpecified) private pure returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(-amountSpecified);
    }

    /// @dev Unsigned size of an exact-output swap, whose `amountSpecified` is positive by convention.
    function _exactOutputAmount(int256 amountSpecified) private pure returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(amountSpecified);
    }

    /// @dev Narrows a fee (always ≤ the swap amount, far below int128 max) to the signed delta the
    ///      pool-manager callbacks return.
    function _toInt128(uint256 fee) private pure returns (int128) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return int128(uint128(fee));
    }
}
