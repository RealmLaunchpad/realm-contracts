// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseHook} from "lib/v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {ISwapLpFeeRouter} from "src/interfaces/ISwapLpFeeRouter.sol";

/// @title RealmHookAnyPair
/// @notice `RealmHook` for a pool quoted in an ERC20 instead of the chain's native currency. Same fee
///         formula, same destinations, same per-leg matrix — the only thing that changes is that the
///         fee is collected in the pool's QUOTE, whichever side of the pair that sorted on.
///
/// @dev WHY A SECOND HOOK AT ALL. `RealmHook` is whitelisted by Uniswap and its bytecode must not
///      change, and it hardcodes two things this cannot: that `currency0` is native, and that
///      `currency1` is the token. Against an arbitrary ERC20 quote the token sorts either way, so both
///      assumptions have to become per-pool lookups. Native pools keep using `RealmHook` unchanged; a
///      pool this hook serves is always ERC20-quoted, which is enforced on the first swap.
///
/// @dev POOL IDENTITY IS RESOLVED, NOT ASSUMED. On a pool's first swap the hook asks each side of the
///      pair which one is the Realm token: the token is the side that reports a `pair` of this pool
///      manager AND lists the OTHER side among its own registered `quotes`. Both halves matter — the
///      first is what a non-Realm ERC20 cannot answer, and the second is what stops a token being
///      charged fees on a pool it never authorised. The answer is cached against the pool id, so every
///      subsequent swap pays one warm SLOAD instead of two external calls.
///
/// @dev FEES ARE CHARGED ON THE QUOTE LEG, as they are on the native one, and which callback withholds
///      them depends on whether the quote amount is already known in `beforeSwap`:
///      - exact-input buy:   quote is the input, its size is `amountSpecified` -> withheld in
///                           `beforeSwap` (the pool sees a smaller effective input).
///      - exact-output sell: quote is the output, its size is `amountSpecified` -> withheld in
///                           `beforeSwap`, grossing the pool output up by the fee so the swapper still
///                           receives the exact quote they requested.
///      - exact-output buy:  quote is the input, size unknown until the swap -> settled in `afterSwap`.
///      - exact-input sell:  quote is the output, size unknown until the swap -> settled in `afterSwap`.
///      On every one of those the QUOTE is the specified currency exactly when the fee is withheld
///      early, which is why the `beforeSwap` delta below is always on `deltaSpecified` — the same shape
///      the native hook uses, and the reason the matrix did not have to be rewritten per orientation.
contract RealmHookAnyPair is BaseHook, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    uint256 public constant VERSION = 1;

    /// @notice LP fee router that splits forwarded fees between treasury and creator.
    ISwapLpFeeRouter public immutable FEE_ROUTER;

    /// @notice Protocol treasury. Receives the LP fee on the router-failure fallback path so the fee
    ///         stays under protocol control.
    address public immutable TREASURY;

    uint256 private constant BASIS_POINTS = 10000;

    /// @notice Hard ceiling on the COMBINED fee (LP fee + active tax) charged on a single swap leg, so a
    ///         misconfigured token can never overcharge users. Identical to `RealmSwapHook`'s.
    uint16 private constant MAX_OVERALL_FEE_BPS = 2000; // 20%

    /// @notice Gas budget forwarded to the router on `depositLpFees`. Sized as `RealmSwapHook`'s is, and
    ///         capped for the same reason: a misbehaving router must not be able to drain the remaining
    ///         gas and starve the fallback.
    uint256 private constant ROUTER_GAS_LIMIT = 1_000_000;

    /// @notice What this hook resolved about a pool the first time it was swapped.
    /// @dev `token` doubles as the "resolved yet?" flag: it is never `address(0)` once written.
    struct PoolInfo {
        address token;
        bool quoteIsC0;
    }

    /// @notice Cached pool identity, keyed by pool id. Written once, on a pool's first swap, and never
    ///         again: a pool key is immutable, so what it resolves to cannot change.
    mapping(PoolId => PoolInfo) public poolInfo;

    /// @notice Fees this hook has claimed but not yet redeemed, per token and per quote. Split into the
    ///         two destinations at accrual time so a redemption does not have to re-derive them.
    /// @dev THE FEE IS CLAIMED, NOT TAKEN. A hook's delta has to be zeroed before the unlock ends, and
    ///      the two ways to do that are `take` — which physically moves the currency out of the pool
    ///      manager and therefore needs the manager to be HOLDING it — and `mint`, which issues an
    ///      ERC-6909 claim and is pure accounting. `take` is what the native hook does and it works
    ///      there because the manager is the singleton custodian of every pool's native. It does NOT
    ///      generalise: a swapper settles their input AFTER the swap callbacks run, so on the first buy
    ///      of a freshly seeded ERC20-quoted pool the manager holds none of the quote and the take
    ///      reverts — the launch would be untradeable until someone else funded it. Claiming always
    ///      works, so the fee is booked here and redeemed by `settleFees`, which anyone may call.
    mapping(address token => mapping(address quote => uint256)) public pendingLpFees;

    /// @notice The tax half of the same ledger. See `pendingLpFees`.
    mapping(address token => mapping(address quote => uint256)) public pendingTaxes;

    /// @notice LP fee withheld on the quote leg in `beforeSwap`, carried to `afterSwap`.
    uint256 private transient _cachedLpFee;

    /// @notice Tax withheld on the quote leg in `beforeSwap`, carried to `afterSwap`.
    uint256 private transient _cachedTax;

    /////////////////////////// ERRORS & EVENTS ///////////////////////////

    error NoSwapsBeforeGraduation();
    /// @notice Thrown when a token's combined fee (`lpFeeBps + taxBps`) for this leg exceeds the cap.
    error FeeTooHigh();
    /// @notice Thrown when neither side of the pair is a Realm token that named the other as a quote —
    ///         i.e. this hook was attached to a pool it has no business mediating.
    error NotARealmPool();
    /// @notice Thrown when the pool is quoted in the chain's native currency. Those pools belong to
    ///         `RealmHook`, which Uniswap whitelisted; routing them here would take a well-tested path
    ///         and run it through an untested one for no gain.
    error NativeQuoteNotSupported();
    /// @notice Thrown when the router-failure fallback cannot push the LP fee to the treasury.
    error TreasuryTransferFailed();
    /// @notice Thrown when `unlockCallback` is reached from anywhere but the pool manager.
    error OnlyPoolManager();

    /// @notice Emitted when swap taxes are forwarded to the token, which splits them across its
    ///         earnings allocation and its fee receivers.
    event CreatorTaxesAccrued(address indexed token, address indexed quote, uint256 amount);
    /// @notice Emitted when LP fees are forwarded out of the hook on a swap leg.
    /// @dev The split is reported by the router in `SwapLpFeeRouter.LpAssetFeesRouted`; on the fallback
    ///      path (router reverts) that event is absent and the full amount goes to the treasury, which
    ///      is how indexers detect the fallback.
    event LpFeesForwarded(address indexed token, address indexed quote, uint256 amount);
    /// @notice Post-swap state of the token's pool, emitted once per swap leg, BEFORE the buy/sell event
    ///         so an indexer has fresh reserves in hand when it processes the trade. Mirrors
    ///         `RealmHook.RealmPoolState`, which is what lets an indexer drop its subscription to the
    ///         singleton `PoolManager.Swap`.
    event RealmPoolState(address indexed token, bytes32 poolId, uint160 sqrtPriceX96, uint128 liquidity);
    /// @notice Emitted on every buy. The quote-denominated twin of `RealmSwapHook.RealmSwapBuy`; a
    ///         separate event rather than a widened one so an indexer cannot read a USDC amount as wei.
    event RealmQuoteSwapBuy(
        address indexed token,
        address indexed quote,
        address indexed txOrigin,
        uint256 quoteIn,
        uint256 tokensOut,
        uint256 quoteFees
    );
    /// @notice Emitted when a token's claimed fees in one quote are redeemed and forwarded. The fee
    ///         itself was already reported, at the trade that produced it, by `LpFeesForwarded` /
    ///         `CreatorTaxesAccrued`; this records the (later, batched) moment the currency moved.
    event FeesSettled(address indexed token, address indexed quote, uint256 lpFee, uint256 tax);
    /// @notice Emitted on every sell. See `RealmQuoteSwapBuy`.
    event RealmQuoteSwapSell(
        address indexed token,
        address indexed quote,
        address indexed txOrigin,
        uint256 tokensIn,
        uint256 quoteOut,
        uint256 quoteFees
    );

    //////////////////////////////////////////////////////////////////////

    constructor(IPoolManager _poolManager, address _router, address _treasury) BaseHook(_poolManager) {
        FEE_ROUTER = ISwapLpFeeRouter(_router);
        TREASURY = _treasury;
    }

    /// @notice Never expected to hold native — every pool this hook serves is ERC20-quoted — but
    ///         accepted rather than reverting a swap over a stray wei.
    receive() external payable {}

    /// @inheritdoc BaseHook
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

    /// @notice Enforces graduation and withholds the fee on the legs whose quote size is known here.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (address token, bool quoteIsC0) = _resolve(key);
        if (!IRealmToken(token).graduated()) revert NoSwapsBeforeGraduation();

        // A buy moves quote -> token, so its direction is whichever way the QUOTE sorted.
        bool isBuy = params.zeroForOne == quoteIsC0;
        uint256 lpFee;
        uint256 tax;
        if (isBuy) {
            // Only exact-input is charged here; exact-output does not know the quote input yet.
            if (params.amountSpecified >= 0) {
                return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
            }
            (lpFee, tax) = _computeFees(_exactInputAmount(params.amountSpecified), token, true);
        } else {
            // Only exact-output is charged here; exact-input does not know the quote output yet.
            if (params.amountSpecified <= 0) {
                return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
            }
            (lpFee, tax) = _grossedUpSellFee(token, _exactOutputAmount(params.amountSpecified));
        }

        uint256 totalFee = lpFee + tax;
        _cachedLpFee = lpFee;
        _cachedTax = tax;

        if (totalFee > 0) _claim(key, quoteIsC0, totalFee);

        // On both legs handled here the QUOTE is the specified currency, so the whole fee rides on
        // `deltaSpecified`: it shrinks the quote the pool receives on an exact-input buy, and grosses
        // the quote the pool pays out up on an exact-output sell so the swapper still nets what they
        // asked for. Identical in shape to the native hook, which is why orientation does not appear.
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(_toInt128(totalFee), 0), 0);
    }

    /// @notice Settles fees once swap amounts are known, and reports the post-swap pool state.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        Leg memory leg = _leg(key, params, delta);
        _emitPoolState(key, leg.token);
        return (IHooks.afterSwap.selector, _settle(key, leg));
    }

    /// @dev One swap leg, re-labelled out of POOL orientation into quote/token space. Everything below
    ///      reads the same regardless of which side the token sorted on, and bundling it keeps each
    ///      settlement function inside the stack limit without `via_ir`.
    struct Leg {
        address token;
        bool quoteIsC0;
        /// @dev A buy moves quote -> token, so its direction is whichever way the QUOTE sorted.
        bool isBuy;
        bool exactInput;
        /// @dev Quote the POOL exchanged on this leg, unsigned. Excludes any fee skimmed after it.
        uint256 quoteAmount;
        /// @dev Token amount that crossed the pool on this leg, unsigned.
        uint256 tokenAmount;
        /// @dev `|amountSpecified|`, i.e. the exact side the swapper pinned.
        uint256 specified;
    }

    function _leg(PoolKey calldata key, SwapParams calldata params, BalanceDelta delta)
        private
        returns (Leg memory leg)
    {
        (leg.token, leg.quoteIsC0) = _resolve(key);
        (int128 quoteDelta, int128 tokenDelta) =
            leg.quoteIsC0 ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        leg.isBuy = params.zeroForOne == leg.quoteIsC0;
        leg.exactInput = params.amountSpecified < 0;
        leg.quoteAmount = _abs(quoteDelta);
        leg.tokenAmount = _abs(tokenDelta);
        leg.specified =
            leg.exactInput ? _exactInputAmount(params.amountSpecified) : _exactOutputAmount(params.amountSpecified);
    }

    /// @dev Post-swap price and active liquidity, emitted BEFORE the buy/sell event so an indexer has
    ///      fresh reserves in hand when it processes the trade — the ordering `PoolManager.Swap` had.
    function _emitPoolState(PoolKey calldata key, address token) private {
        PoolId id = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        emit RealmPoolState(token, PoolId.unwrap(id), sqrtPriceX96, poolManager.getLiquidity(id));
    }

    function _settle(PoolKey calldata key, Leg memory leg) private returns (int128) {
        if (leg.isBuy) {
            return leg.exactInput ? _settleBuyExactInput(key, leg) : _settleBuyExactOutput(key, leg);
        }
        return leg.exactInput ? _settleSellExactInput(key, leg) : _settleSellExactOutput(key, leg);
    }

    ////////////////////////// FEE SETTLEMENT (PER LEG) ///////////////////////

    /// @dev Exact-input buy: the fee was already withheld from the input in `_beforeSwap`, so here we
    ///      only route it and emit. Returns a zero afterSwap delta (nothing left to settle).
    function _settleBuyExactInput(PoolKey calldata key, Leg memory leg) private returns (int128) {
        uint256 lpFee = _cachedLpFee;
        uint256 tax = _cachedTax;
        uint256 totalFee = lpFee + tax;

        // `specified - totalFee` is the quote that actually crossed into the pool against the tokens.
        _route(key, leg, lpFee, tax, leg.specified - totalFee, leg.tokenAmount);
        emit RealmQuoteSwapBuy(
            leg.token, _quote(key, leg.quoteIsC0), tx.origin, leg.specified, leg.tokenAmount, totalFee
        );
        return 0;
    }

    /// @dev Exact-output buy: the pool consumed `quoteAmount` to produce the tokens; the fee is settled
    ///      separately via the returned afterSwap delta, so the swapper's total quote out is
    ///      `quoteAmount + totalFee`. Grossed up first so the fee is `X%` of the swapper's TOTAL, not of
    ///      the pool-consumed amount — without it exact-output undercharges exact-input by ~feeBps².
    function _settleBuyExactOutput(PoolKey calldata key, Leg memory leg) private returns (int128) {
        (uint256 lpFeeBps, uint256 taxBps) = _currentFeeBps(leg.token, true);
        (uint256 lpFee, uint256 tax) = _feeAmounts(_grossUp(leg.quoteAmount, lpFeeBps + taxBps), lpFeeBps, taxBps);
        uint256 totalFee = lpFee + tax;

        if (totalFee > 0) _claim(key, leg.quoteIsC0, totalFee);

        // The fee never crossed the pool, so route the avg price on the pool-consumed amount only.
        _route(key, leg, lpFee, tax, leg.quoteAmount, leg.tokenAmount);
        emit RealmQuoteSwapBuy(
            leg.token, _quote(key, leg.quoteIsC0), tx.origin, leg.quoteAmount + totalFee, leg.tokenAmount, totalFee
        );
        return _toInt128(totalFee);
    }

    /// @dev Exact-input sell: the pool paid out `quoteAmount` for the tokens; the fee is taken from that
    ///      output here and returned as the afterSwap delta. The swapper nets the remainder.
    function _settleSellExactInput(PoolKey calldata key, Leg memory leg) private returns (int128) {
        (uint256 lpFee, uint256 tax) = _computeFees(leg.quoteAmount, leg.token, false);
        uint256 totalFee = lpFee + tax;

        if (totalFee > 0) _claim(key, leg.quoteIsC0, totalFee);

        // `quoteAmount` is what the pool actually paid out; the hook fee is skimmed from it AFTER the
        // swap and never changed the pool's execution price, so the router sees the same avg price a
        // buy at this pool state would.
        _route(key, leg, lpFee, tax, leg.quoteAmount, leg.tokenAmount);
        emit RealmQuoteSwapSell(
            leg.token, _quote(key, leg.quoteIsC0), tx.origin, leg.tokenAmount, leg.quoteAmount, totalFee
        );
        return _toInt128(totalFee);
    }

    /// @dev Exact-output sell: the fee was computed and withheld via the beforeSwap delta, which also
    ///      grossed the pool output up so the swapper receives exactly what they requested. Here we only
    ///      route and emit; the afterSwap delta is zero.
    function _settleSellExactOutput(PoolKey calldata key, Leg memory leg) private returns (int128) {
        uint256 lpFee = _cachedLpFee;
        uint256 tax = _cachedTax;

        _route(key, leg, lpFee, tax, leg.quoteAmount, leg.tokenAmount);
        emit RealmQuoteSwapSell(
            leg.token, _quote(key, leg.quoteIsC0), tx.origin, leg.tokenAmount, leg.quoteAmount, lpFee + tax
        );
        return 0;
    }

    ///////////////////////////////// FEE ROUTING /////////////////////////////

    /// @notice Books this leg's fee against the token and quote it was collected in. The claim minted
    ///         during the swap is the asset; this is the ledger that says whose it is.
    /// @dev Emitting here rather than at redemption keeps every fee event at the instant of the trade
    ///      that produced it, which is the ordering indexers already read on the native hook. What
    ///      changes is only WHEN the currency physically moves — see `pendingLpFees`.
    function _route(
        PoolKey calldata key,
        Leg memory leg,
        uint256 lpFee,
        uint256 tax,
        uint256, /* quoteSwapAmount */
        uint256 /* tokenSwapAmount */
    )
        private
    {
        address quote = _quote(key, leg.quoteIsC0);
        if (lpFee > 0) {
            pendingLpFees[leg.token][quote] += lpFee;
            emit LpFeesForwarded(leg.token, quote, lpFee);
        }
        if (tax > 0) {
            pendingTaxes[leg.token][quote] += tax;
            emit CreatorTaxesAccrued(leg.token, quote, tax);
        }
    }

    ////////////////////////////// FEE REDEMPTION //////////////////////////////

    /// @notice Redeems everything this hook has claimed for `token` in `quote` and sends it where it
    ///         belongs: the LP share through `FEE_ROUTER`, the tax share to the token. Permissionless —
    ///         the destinations are fixed, so a caller can only ever move protocol money to where the
    ///         protocol already decided it goes, and paying the gas for that is a favour.
    /// @dev Separate from the swap because a claim can only become currency once the pool manager is
    ///      actually holding some — see `pendingLpFees`. By the time anyone calls this the swaps that
    ///      produced the fee have settled their inputs, so the redemption is funded by construction.
    /// @dev Hardened exactly as `RealmSwapHook._route` is: a capped-gas `try` on the router, with the LP
    ///      fee falling through to the treasury on any failure so it stays under protocol control and
    ///      never strands here.
    function settleFees(address token, address quote) public {
        uint256 lpFee = pendingLpFees[token][quote];
        uint256 tax = pendingTaxes[token][quote];
        uint256 total = lpFee + tax;
        if (total == 0) return;
        pendingLpFees[token][quote] = 0;
        pendingTaxes[token][quote] = 0;

        // Turns the claims into the currency itself, which needs the manager unlocked.
        poolManager.unlock(abi.encode(quote, total));

        if (lpFee > 0) {
            IERC20(quote).forceApprove(address(FEE_ROUTER), lpFee);
            try FEE_ROUTER.depositLpFees{gas: ROUTER_GAS_LIMIT}(token, quote, lpFee, 0, 0) {
            // happy path — the router emitted its own `LpAssetFeesRouted` with the breakdown.
            }
            catch {
                // Fallback: the router is unavailable, so the LP fee goes to the treasury rather than
                // to the token's fee receivers, keeping it under protocol control.
                IERC20(quote).forceApprove(address(FEE_ROUTER), 0);
                IERC20(quote).safeTransfer(TREASURY, lpFee);
            }
        }
        if (tax > 0) {
            IERC20(quote).forceApprove(token, tax);
            IRealmToken(token).accrueFees(quote, tax);
        }
        emit FeesSettled(token, quote, lpFee, tax);
    }

    /// @notice The pool manager's re-entry for `settleFees`. Burns the claims and takes the currency.
    /// @dev Steers nothing a caller chose beyond which (token, quote) ledger to empty: the amount comes
    ///      from this contract's own storage, and the recipient is this contract.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), OnlyPoolManager());
        (address quote, uint256 amount) = abi.decode(data, (address, uint256));
        Currency currency = Currency.wrap(quote);
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, address(this), amount);
        return "";
    }

    ////////////////////////////// POOL IDENTITY //////////////////////////////

    /// @dev Which side of `key` is the Realm token, cached after the first swap. See the contract
    ///      docstring for why both halves of the test are needed.
    function _resolve(PoolKey calldata key) private returns (address token, bool quoteIsC0) {
        PoolId id = key.toId();
        PoolInfo memory info = poolInfo[id];
        if (info.token != address(0)) return (info.token, info.quoteIsC0);

        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        // Native belongs to `RealmHook`; checked before the duck-typing so the error names the reason.
        if (c0 == address(0)) revert NativeQuoteNotSupported();

        if (_isRealmTokenQuotedIn(c1, c0)) {
            (token, quoteIsC0) = (c1, true);
        } else if (_isRealmTokenQuotedIn(c0, c1)) {
            (token, quoteIsC0) = (c0, false);
        } else {
            revert NotARealmPool();
        }
        poolInfo[id] = PoolInfo({token: token, quoteIsC0: quoteIsC0});
    }

    /// @dev True when `candidate` is a Realm token whose pool lives on this pool manager AND which named
    ///      `quote` as one of its own registered quotes. Anything that is not a Realm token reverts
    ///      somewhere in here, which the `try` turns into `false`.
    function _isRealmTokenQuotedIn(address candidate, address quote) private view returns (bool) {
        if (candidate.code.length == 0) return false;
        try IRealmToken(candidate).pair() returns (address pair) {
            if (pair != address(poolManager)) return false;
        } catch {
            return false;
        }
        try IRealmToken(candidate).quoteCount() returns (uint8 n) {
            for (uint256 i = 0; i < n; ++i) {
                if (IRealmToken(candidate).quotes(i) == quote) return true;
            }
        } catch {}
        return false;
    }

    /// @dev Books `amount` of the pool's quote to this hook as an ERC-6909 claim. See `pendingLpFees`
    ///      for why the fee is claimed rather than taken.
    function _claim(PoolKey calldata key, bool quoteIsC0, uint256 amount) private {
        poolManager.mint(address(this), _quoteCurrency(key, quoteIsC0).toId(), amount);
    }

    /// @dev The pool's quote currency, in v4's own type.
    function _quoteCurrency(PoolKey calldata key, bool quoteIsC0) private pure returns (Currency) {
        return quoteIsC0 ? key.currency0 : key.currency1;
    }

    /// @dev The pool's quote currency as a plain address.
    function _quote(PoolKey calldata key, bool quoteIsC0) private pure returns (address) {
        return Currency.unwrap(_quoteCurrency(key, quoteIsC0));
    }

    ////////////////////////////////// FEE MATH ///////////////////////////////

    /// @notice Resolves the LP-fee and tax bps the token charges on this leg and enforces the cap.
    function _currentFeeBps(address token, bool isBuy) private view returns (uint256 lpFeeBps, uint256 taxBps) {
        IRealmToken.RealmTradeFees memory fees = IRealmToken(token).getSwapFees(isBuy);
        lpFeeBps = fees.lpFeeBps;
        taxBps = fees.taxBps;
        if (lpFeeBps + taxBps > MAX_OVERALL_FEE_BPS) revert FeeTooHigh();
    }

    /// @notice Resolves the rates (enforcing the cap) and splits `gross` into LP fee + tax.
    function _computeFees(uint256 gross, address token, bool isBuy) private view returns (uint256 lpFee, uint256 tax) {
        (uint256 lpFeeBps, uint256 taxBps) = _currentFeeBps(token, isBuy);
        return _feeAmounts(gross, lpFeeBps, taxBps);
    }

    /// @notice Exact-output sell: the swapper asked for exactly `quoteOut`. The pool's output is grossed
    ///         up so the fee can still be charged on the quote leg without shorting them.
    function _grossedUpSellFee(address token, uint256 quoteOut) private view returns (uint256 lpFee, uint256 tax) {
        (uint256 lpFeeBps, uint256 taxBps) = _currentFeeBps(token, false);
        return _feeAmounts(_grossUp(quoteOut, lpFeeBps + taxBps), lpFeeBps, taxBps);
    }

    /// @dev Splits a gross quote amount into the LP fee and tax slices at the given bps.
    function _feeAmounts(uint256 gross, uint256 lpFeeBps, uint256 taxBps)
        private
        pure
        returns (uint256 lpFee, uint256 tax)
    {
        lpFee = (gross * lpFeeBps) / BASIS_POINTS;
        tax = (gross * taxBps) / BASIS_POINTS;
    }

    /// @dev Grosses an exact-output amount up into the equivalent gross that yields it net of fee.
    ///      Division is safe: `_currentFeeBps` caps `totalBps` well below `BASIS_POINTS`.
    function _grossUp(uint256 amount, uint256 totalBps) private pure returns (uint256) {
        if (totalBps == 0) return amount;
        return (amount * BASIS_POINTS) / (BASIS_POINTS - totalBps);
    }

    //////////////////////////////// CASTING UTILS ////////////////////////////

    /// @dev Magnitude of a swap-delta component; each call site knows the sign from the direction.
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

    /// @dev Narrows a fee (always <= the swap amount) to the signed delta the callbacks return.
    function _toInt128(uint256 fee) private pure returns (int128) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return int128(uint128(fee));
    }
}
