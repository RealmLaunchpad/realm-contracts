// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseHook} from "lib/v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {RealmEtf} from "src/etf/RealmEtf.sol";
import {RealmEtfFactory} from "src/etf/RealmEtfFactory.sol";
import {RealmEtfJitMath} from "src/etf/RealmEtfJitMath.sol";

/// @title RealmEtfHook
/// @notice Makes ETF shares tradable as a normal V4 token: a shares/USDG pool where every swap is filled by
///         the ETF itself. A buy deposits the USDG into the ETF and pays out the minted shares; a sell redeems
///         the shares and pays out the USDG. Same code, same price as calling the ETF directly; this is only a
///         second entrance, the one routers reach.
///
/// @dev JIT LIQUIDITY, so the pool looks like any other. Once the ETF has filled the trade, `beforeSwap`
///      moves the empty pool's price to a one-tick range next to the trade price, places the ETF's output
///      there, and lets the core curve fill all but a few raw units of the trade against it; the hook's own
///      delta covers the rest. `afterSwap` checks the curve did exactly what was predicted and removes the
///      position. The pool manager thus emits a real `Swap` and `slot0` ends at the trade price; `HookSwap`
///      reports the hook's part. Sizing and proofs: `RealmEtfJitMath`, `docs/etf-jit-math.md`. The pool
///      holds no liquidity between swaps; nobody else may add any. Pools must have fee 0 and tick spacing 1.
///      With a protocol fee on the pool, a trade the math cannot place, a swapper's price limit inside the
///      range, or a price more than `MAX_WALK_TICKS` from the range, the hook's delta covers the whole trade
///      and the curve swaps 0.
///
/// @dev EXACT INPUT both ways, mirroring the ETF's `deposit`/`redeem`; EXACT OUTPUT for buys only, through its
///      `mint`. The ETF has no `withdraw`, so exact-output sells revert.
///
/// @dev THE INPUT ARRIVES AFTER THE SWAP. Standard routers pay what they owe once the swap returns.
///      - A buy `take`s the USDG from the pool manager before it is paid. An ETF that buys through V3
///        pools therefore needs the pool manager to hold that much USDG from other pools (V4 legs hand it
///        straight back). On Robinhood, where USDG is the main V4 quote, that ceiling is high, but it is one.
///      - An exact-output buy learns its price only once `mint` has bought every holding, so it `take`s twice
///        `mint`'s spot estimate (plus `MINT_LOAN_PAD`) first, lets `mint` pull what it spends, and settles the
///        rest straight back. Not the pool manager's whole USDG: a route pool's hook that moves USDG mid-swap
///        would find none. Same ceiling: the mint's whole cost.
///      - A sell cannot do the same: the pool manager holds no shares. The ETF pays out on credit
///        (`redeemOnCredit`) and, once the swap is done, the hook mints itself claims on the incoming shares,
///        which locks them in the pool manager for good and takes them out of the ETF's `totalSupply`.
///
/// @dev ROUNDING DUST. The core rounds the JIT position's removal down, so the hook gets back a few raw units
///      less than the curve took. The swapper absorbs that on the side the hook does not specify; on the side
///      it does, `USDG_BUFFER` / `SHARES_BUFFER` cover it, or the trade falls back to no JIT.
contract RealmEtfHook is BaseHook {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using ProtocolFeeLibrary for uint24;

    /// @notice Pools are accepted only for ETFs this factory deployed with this hook.
    RealmEtfFactory public immutable FACTORY;

    /// @notice The other side of every ETF pool.
    address public immutable USDG;

    /// @notice Raw USDG an exact-input buy keeps out of its deposit, to cover what removing the JIT position
    ///         rounds away (at most 2 at any realistic price); the rest goes to the ETF.
    uint256 public constant USDG_BUFFER = 3;

    /// @notice Extra shares an exact-output buy mints (plus 1 per 2^40 bought), for the same rounding; the
    ///         unused rest is locked as claims, out of `totalSupply`.
    uint256 public constant SHARES_BUFFER = 4;

    /// @notice Raw USDG (1 USDG) an exact-output buy lends `mint` on top of twice its spot estimate, which
    ///         rounds a dust buy's legs to 0. Fees and impact past 2x revert the trade, as they should.
    uint256 public constant MINT_LOAN_PAD = 1e6;

    /// @notice Farthest a swap moves the empty pool's price to reach its JIT range (~50%). The core walks it
    ///         one 256-tick bitmap word per loop, so a price parked far from NAV costs each swap at most this
    ///         much walking, without JIT, until the range is back in reach.
    int24 public constant MAX_WALK_TICKS = 4096;

    /// @dev The JIT position of the swap in flight; zero liquidity: none.
    int24 private transient _jitTickLower;
    uint128 private transient _jitLiquidity;
    /// @dev The `BalanceDelta` the curve must produce.
    int256 private transient _jitDelta;
    /// @dev The hook's own part of the swap in flight, booked to it only after `afterSwap` returns.
    uint256 private transient _hookIn;
    uint256 private transient _hookOut;

    /// @notice The part of a swap the hook filled itself, outside the curve. Same signs as the pool manager's
    ///         `Swap` (negative: paid by the swapper); the two events sum to the whole trade.
    event HookSwap(
        bytes32 indexed id,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint128 hookLPfeeAmount0,
        uint128 hookLPfeeAmount1
    );

    error NotEtfPool();
    error InvalidPoolKey();
    error LiquidityNotAccepted();
    error ExactOutputNotSupported();
    /// @notice The curve did not fill what the JIT position was sized for. A safety check: the hook already skips
    ///         JIT when the swapper's price limit falls inside the range.
    error JitMismatch();

    constructor(IPoolManager manager, RealmEtfFactory factory) BaseHook(manager) {
        FACTORY = factory;
        USDG = factory.REGISTRY().USDG();
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @dev Only a fee-0, tick-spacing-1 ETF/USDG pool may use this hook (the JIT math assumes both).
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        _etfOf(key);
        require(key.fee == 0 && key.tickSpacing == 1, InvalidPoolKey());
        return this.beforeInitialize.selector;
    }

    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert LiquidityNotAccepted();
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bool exactIn = params.amountSpecified < 0;
        (uint256 x, uint256 y, uint256 buffer) = _fill(key, params, exactIn);
        return (this.beforeSwap.selector, _hookDelta(key, sender, params, exactIn, x, y, buffer), 0);
    }

    /// @dev Fills the whole trade from the ETF, the swapper paying `x` and receiving `y`, and settles the output
    ///      in the pool manager. `buffer`: what the hook holds back, on the side where it alone covers the JIT
    ///      position's rounding (exact-input buys: USDG kept out of the deposit; exact-output buys: extra shares
    ///      minted). Sells need none: their rounding only trims the hook's claims.
    function _fill(PoolKey calldata key, SwapParams calldata params, bool exactIn)
        private
        returns (uint256 x, uint256 y, uint256 buffer)
    {
        RealmEtf etf = _etfOf(key);
        (Currency cIn, Currency cOut) =
            params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        require(exactIn || Currency.unwrap(cIn) == USDG, ExactOutputNotSupported());

        uint256 settled;
        if (!exactIn) {
            y = uint256(params.amountSpecified);
            buffer = SHARES_BUFFER + (y >> 40);
            settled = y + buffer;
            uint256 taken =
                Math.min(2 * etf.previewMint(settled) + MINT_LOAN_PAD, IERC20(USDG).balanceOf(address(poolManager)));
            poolManager.take(cIn, address(this), taken);
            IERC20(USDG).forceApprove(address(etf), taken);
            x = etf.mint(settled, address(this));
            poolManager.sync(cIn);
            IERC20(USDG).safeTransfer(address(poolManager), taken - x);
            poolManager.settle();
        } else if (Currency.unwrap(cIn) == USDG) {
            x = uint256(-params.amountSpecified);
            buffer = USDG_BUFFER;
            poolManager.take(cIn, address(this), x - buffer);
            IERC20(USDG).forceApprove(address(etf), x - buffer);
            settled = y = etf.deposit(x - buffer, address(this));
        } else {
            x = uint256(-params.amountSpecified);
            settled = y = etf.redeemOnCredit(x, address(this));
            buffer = type(uint256).max;
        }
        poolManager.sync(cOut);
        IERC20(Currency.unwrap(cOut)).safeTransfer(address(poolManager), settled);
        poolManager.settle();
    }

    /// @dev Places the JIT position and returns the delta covering the part of the trade the curve will not fill.
    function _hookDelta(
        PoolKey calldata key,
        address sender,
        SwapParams calldata params,
        bool exactIn,
        uint256 x,
        uint256 y,
        uint256 buffer
    ) private returns (BeforeSwapDelta) {
        (uint256 hookIn, uint256 hookOut) = _placeJit(key, params, exactIn, x, y, buffer);
        (_hookIn, _hookOut) = (hookIn, hookOut);
        _emitHookSwap(key, sender, params.zeroForOne, hookIn, hookOut);

        // The specified side is the input on exact-input swaps and the output on exact-output ones.
        (int128 inDelta, int128 outDelta) = (hookIn.toInt256().toInt128(), -hookOut.toInt256().toInt128());
        return exactIn ? toBeforeSwapDelta(inDelta, outDelta) : toBeforeSwapDelta(outDelta, inDelta);
    }

    function _emitHookSwap(PoolKey calldata key, address sender, bool zeroForOne, uint256 hookIn, uint256 hookOut)
        private
    {
        (int128 paid, int128 received) = (-hookIn.toInt256().toInt128(), hookOut.toInt256().toInt128());
        (int128 amount0, int128 amount1) = zeroForOne ? (paid, received) : (received, paid);
        emit HookSwap(PoolId.unwrap(key.toId()), sender, amount0, amount1, 0, 0);
    }

    /// @dev Removes the JIT position once the curve has filled exactly its predicted part, then clears what the
    ///      hook is still owed: USDG to the ETF (for `reinvest`), shares as claims (out of `totalSupply`).
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        uint128 liquidity = _jitLiquidity;
        if (liquidity != 0) {
            require(BalanceDelta.unwrap(delta) == _jitDelta, JitMismatch());
            _jitLiquidity = 0;
            int24 tickLower = _jitTickLower;
            poolManager.modifyLiquidity(
                key, ModifyLiquidityParams(tickLower, tickLower + 1, -int256(uint256(liquidity)), 0), ""
            );
        }
        // What the hook is owed once the pool manager books its own part (input +`_hookIn`, output -`_hookOut`).
        (Currency cIn, Currency cOut) =
            params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        _clear(cIn, poolManager.currencyDelta(address(this), cIn) + _hookIn.toInt256(), cOut);
        _clear(cOut, poolManager.currencyDelta(address(this), cOut) - _hookOut.toInt256(), cIn);
        return (this.afterSwap.selector, 0);
    }

    /// @dev Takes what the hook is owed in `currency`: USDG to the ETF (`other`), shares as claims.
    function _clear(Currency currency, int256 owed, Currency other) private {
        if (owed <= 0) return;
        if (Currency.unwrap(currency) == USDG) poolManager.take(currency, Currency.unwrap(other), uint256(owed));
        else poolManager.mint(address(this), currency.toId(), uint256(owed));
    }

    /// @dev Places the JIT position for a trade the ETF filled with `x` in and `y` out, and returns the hook's
    ///      own part of the trade, all of it (`x`, `y`) without JIT. With JIT, the swapper absorbs the removal's
    ///      rounding on the side the hook does not specify, and `buffer` must cover it on the other.
    function _placeJit(
        PoolKey calldata key,
        SwapParams calldata params,
        bool exactIn,
        uint256 x,
        uint256 y,
        uint256 buffer
    ) private returns (uint256 hookIn, uint256 hookOut) {
        bool zeroForOne = params.zeroForOne;
        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee,) = poolManager.getSlot0(key.toId());
        if ((zeroForOne ? protocolFee.getZeroForOneFee() : protocolFee.getOneForZeroFee()) != 0) return (x, y);
        RealmEtfJitMath.Plan memory p = RealmEtfJitMath.plan(zeroForOne, exactIn, x, y);
        if (p.liquidity == 0) return (x, y);
        if (exactIn ? p.inC - p.removedIn > buffer : p.cost - p.outC - p.removedOut > buffer) return (x, y);
        // A swapper's price limit inside the range would stop the curve short of the plan.
        if (zeroForOne
                ? params.sqrtPriceLimitX96 > TickMath.getSqrtPriceAtTick(p.tickLower)
                : params.sqrtPriceLimitX96 < TickMath.getSqrtPriceAtTick(p.tickLower + 1)) return (x, y);

        if (!_walk(key, sqrtPriceX96, tick, p.startSqrtPriceX96, zeroForOne ? p.tickLower + 1 : p.tickLower)) {
            return (x, y);
        }
        poolManager.modifyLiquidity(
            key, ModifyLiquidityParams(p.tickLower, p.tickLower + 1, int256(uint256(p.liquidity)), 0), ""
        );
        (_jitTickLower, _jitLiquidity) = (p.tickLower, p.liquidity);
        (int128 paid, int128 received) = (-p.inC.toInt256().toInt128(), p.outC.toInt256().toInt128());
        _jitDelta = BalanceDelta.unwrap(zeroForOne ? toBalanceDelta(paid, received) : toBalanceDelta(received, paid));
        return exactIn ? (x - p.inC, y - p.cost + p.removedOut) : (x - p.removedIn, y - p.outC);
    }

    /// @dev Moves the empty pool's price from `sqrtPriceX96` (tick `tick`) to `start` (tick `startTick`), or only
    ///      `MAX_WALK_TICKS` towards it when it is farther. The pool is empty, so this exchanges nothing. Returns
    ///      whether the price reached `start`.
    function _walk(PoolKey calldata key, uint160 sqrtPriceX96, int24 tick, uint160 start, int24 startTick)
        private
        returns (bool)
    {
        if (sqrtPriceX96 == start) return true;
        uint160 target = start;
        if (tick > startTick + MAX_WALK_TICKS) target = TickMath.getSqrtPriceAtTick(tick - MAX_WALK_TICKS);
        else if (tick < startTick - MAX_WALK_TICKS) target = TickMath.getSqrtPriceAtTick(tick + MAX_WALK_TICKS);
        poolManager.swap(key, SwapParams(target < sqrtPriceX96, -1, target), "");
        return target == start;
    }

    function _etfOf(PoolKey calldata key) private view returns (RealmEtf etf) {
        (address c0, address c1) = (Currency.unwrap(key.currency0), Currency.unwrap(key.currency1));
        address other = c0 == USDG ? c1 : c1 == USDG ? c0 : address(0);
        require(other != address(0) && FACTORY.isEtf(other) && RealmEtf(other).HOOK() == address(this), NotEtfPool());
        return RealmEtf(other);
    }
}
