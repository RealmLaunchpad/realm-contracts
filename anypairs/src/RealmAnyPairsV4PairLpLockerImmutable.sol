// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

import {RealmAnyPairsImmutableBase} from "./base/RealmAnyPairsImmutableBase.sol";

/// @dev The `launcher()` getter every platform token exposes. Only called through a gas-capped low-level
/// staticcall: a typed call to a codeless address reverts uncatchably in the caller's frame.
interface IRealmAnyPairsCoinLauncher {
    function launcher() external view returns (address);
}

/**
 * @title RealmAnyPairsV4PairLpLockerImmutable
 * @notice Non-upgradeable locker that seeds V4 pools and compounds their fees back into locked LP.
 *         Liquidity is only ever added (there is no removal path), so the LP is locked permanently.
 */
contract RealmAnyPairsV4PairLpLockerImmutable is IUnlockCallback, RealmAnyPairsImmutableBase {
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    uint256 private constant Q96 = 0x1000000000000000000000000;

    IPoolManager public immutable poolManager;
    /// @notice Launchers allowed to seed pools. An allowlist, so a replacement launcher can be admitted
    /// without migrating the locker.
    mapping(address => bool) public isLauncher;
    uint256 public launcherCount;

    struct PoolInfo {
        int24 tickLower;
        int24 tickUpper;
        bool seeded;
    }

    mapping(PoolId => PoolInfo) public poolInfo;
    mapping(PoolId => uint256) public carried0;
    mapping(PoolId => uint256) public carried1;
    /// @notice Pull-based fallback for dev-buy refunds whose push failed (e.g. the creator is paused or
    /// blacklisted by the quote token), keyed by (creator, quote token). Withdraw via {withdrawQuoteRefund}.
    mapping(address => mapping(address => uint256)) public pendingQuoteRefund;

    /// @notice Everything this locker already owes, per token (`address(0)` = native): the sum of every pool's
    /// `carried0`/`carried1` and every {pendingQuoteRefund} entry.
    /// @dev One balance per token is shared by all pools and refunds, so spends are bounded by {availableOf}
    /// (balance minus this). Kept in sync by {_setCarried}, {_reserve} and {_releaseReserved}.
    mapping(address => uint256) public reservedOf;

    /// @notice Second key that may call {setLauncher}/{setAdmin}, including after {renounceOwnership}, so later
    /// launchers can still be admitted.
    /// @dev A local slot rather than a read of the hook's admin: the locker holds no hook reference and may serve
    /// several hooks. The admin can rotate itself; it cannot move LP, withdraw refunds or touch ownership.
    address public admin;

    event LauncherSet(address indexed launcher, bool allowed);
    /// @notice The config admin changed. Mirrors the hook's event of the same name.
    event AdminSet(address indexed admin);
    event Seeded(PoolId indexed poolId, uint128 liquidity, int24 tickLower, int24 tickUpper);
    event Compounded(PoolId indexed poolId, uint128 addedLiquidity, uint256 used0, uint256 used1);
    event QuoteRefundQueued(address indexed creator, address indexed quote, uint256 amount);
    event QuoteRefundWithdrawn(address indexed creator, address indexed quote, uint256 amount);
    /// @notice The dev buy of `token` was paid out: `amounts[i]` to `recipients[i]`, summing to the coin bought.
    event DevBuyDistributed(address indexed token, address[] recipients, uint256[] amounts);
    /// @notice {_compound} clamped the liquidity it added because the per-tick liquidity cap at the range
    /// boundaries is nearly full (possibly deliberate griefing liquidity).
    event CompoundClamped(PoolId indexed poolId, uint128 desiredLiquidity, uint128 clampedLiquidity, uint128 headroom);

    error NotLauncher();
    error ZeroAddress();
    error LauncherNotSet();
    error AlreadySeeded();
    error NotSeeded();
    error NotPoolManager();
    error BadLiquidity();
    /// @dev {setLauncher}/{setAdmin} called by neither the owner nor the admin.
    error NotOwnerOrAdmin();
    /// @dev Renounce attempted while `admin == address(0)`. See {_requireRenounceReady}.
    error AdminZero();
    /// @dev {setAdmin}(address(this)): this contract never calls itself, so that admin would be a dead key.
    error SelfAddress();
    /// @dev Gas stipend for the best-effort ERC20 dev-buy refund push. Sized with headroom for compliance-gated,
    /// issuer-upgradeable quote tokens; a failed push falls back to the pull queue.
    uint256 internal constant REFUND_PUSH_GAS = 150_000;

    /// @dev Gas stipend for the native refund push. Enough for EOAs and simple contract wallets; failures fall
    /// back to the pull queue. The push runs after the unlock closes, and a native refund implies the seeded
    /// range is exhausted, so an in-transaction snipe gains nothing. Do not lower it.
    uint256 internal constant NATIVE_REFUND_PUSH_GAS = 60_000;

    /// @dev Carries the amounts because an event emitted in a reverting frame is rolled back with it.
    error CompoundOverspend(uint256 short0, uint256 short1);
    error NothingToWithdraw();
    error SeedNotSingleSided();
    /// @dev {launch}'s `msg.value` does not match what the quote side of `key` requires: exactly
    /// `devBuyQuote` for a NATIVE quote, exactly zero for an ERC20 one. See {launch}.
    error BadDevBuyValue(uint256 sent, uint256 expected);
    /// @dev {launch}'s `coinAmountIn` claims more coin than this locker actually holds. See {_seed}.
    error BadCoinAmountIn(uint256 claimed, uint256 held);
    /// @dev A refund destination that would destroy or donate the refund. See {withdrawQuoteRefundTo}.
    error BadRefundDestination();
    /// @notice A dev-buy split must name 1-{MAX_DEV_BUY_RECIPIENTS} distinct, valid recipients, each with non-zero
    /// bps, summing to exactly 10,000. See {_requireDevBuySplit}.
    error BadDevBuySplit();
    /// @notice A rescue may take at most {availableOf} -- never anything reserved for a pool or a creator.
    error RescueExceedsAvailable(uint256 amount, uint256 available);
    /// @notice No rescue while the PoolManager is unlocked (a seed or compound is mid-flight).
    error RescueWhileUnlocked();
    /// @notice The native transfer of a rescue failed.
    error RescueFailed();
    /// @notice `amount` of `token` (address(0) = native ETH) that no one was owed was sent to `to`.
    event Rescued(address indexed token, address indexed to, uint256 amount);
    /// @notice Most wallets one dev buy may be split across.
    uint8 public constant MAX_DEV_BUY_RECIPIENTS = 10;
    uint16 internal constant DEV_BUY_BPS = 10_000;
    /// @dev {launch}'s `quoteIsC0` disagrees with the orientation derived from `key` itself. See
    /// {_requireOrientation}.
    error OrientationMismatch(bool claimed, bool derived);
    /// @dev `key.currency1 == address(0)`: V4 sorts `currency0 < currency1` and `address(0)` is the smallest
    /// address, so a native side can only ever be currency0. A zero here is a malformed (or zero/zero) key.
    error BadPoolKey();
    /// @dev {launch}'s `devBuyQuote` claims more quote than THIS call actually contributed -- i.e. more than
    /// this locker holds over and above what it already owes other pools and other creators. See {_seed}.
    error BadDevBuyBacking(uint256 claimed, uint256 available);
    /// @dev A queued native refund withdrawal failed. Reverting rolls the zeroing back, so the claim survives.
    error RefundWithdrawFailed();

    /// @dev The seed's `modifyLiquidity` charged more of `currency` than {availableOf} it, i.e. it would spend
    /// balance owed to other pools or creators. Reported per currency, independent of the coin/quote labels.
    error SeedSettleUnbacked(address currency, uint256 required, uint256 available);

    /// @notice The seed consumed more coin than `coinAmountIn` declared, so no rounding dust was credited.
    /// @dev Emitted rather than reverted: the charge is already bounded by {availableOf}, and a revert on a
    /// one-wei rounding disagreement would permanently block launches.
    event SeedUnderDeclaredCoin(PoolId indexed poolId, uint256 declared, uint256 consumed);

    enum Op {
        SEED,
        COMPOUND
    }

    /// @dev An additional tick range this pool's fees have been compounded into, opened only after the
    /// primary range hit the per-tick liquidity cap. See {_pickRange}.
    struct Range {
        int24 lower;
        int24 upper;
    }

    mapping(PoolId => Range[]) internal fallbackRanges;

    /// @dev Hard cap on fallback ranges per pool. Every one of them is harvested on EVERY compound (see
    /// {_compound}), so this bounds that loop -- and in practice one is already more than enough, because
    /// pinning a near-spot tick is not an attack anybody repeats cheaply.
    uint256 internal constant MAX_FALLBACK = 4;

    /// @dev Half-width of a fallback range, in tick spacings. Wide enough to keep earning as the price
    /// moves, narrow enough that its boundary ticks sit near spot -- which is the entire point: filling the
    /// per-tick cap next to the market price costs real capital, filling it at the edge of the tick range
    /// costs dust.
    int256 internal constant FALLBACK_SPAN = 60;

    event FallbackRangeOpened(PoolId indexed poolId, int24 tickLower, int24 tickUpper);

    struct SeedData {
        PoolKey key;
        uint128 liquidity;
        int24 tickLower;
        int24 tickUpper;
        address creator;
        bool quoteIsC0;
        uint256 devBuyQuote;
        /// @dev Exact amount of coin the caller transferred in for THIS seed. Scopes the rounding-dust credit to
        /// this pool, since the same coin may be seeded into several pools in one transaction.
        uint256 coinAmountIn;
    }

    /// @dev Owner, or the admin when it is non-zero. Ownership transfer and renounce stay `onlyOwner`, so the
    /// admin can never reach the owner seat.
    modifier onlyOwnerOrAdmin() {
        if (msg.sender != owner && (msg.sender != admin || admin == address(0))) {
            revert NotOwnerOrAdmin();
        }
        _;
    }

    constructor(IPoolManager pm, address owner_) RealmAnyPairsImmutableBase(owner_) {
        // Immutable with no setter, so a zero address would be unrecoverable.
        if (address(pm) == address(0)) {
            revert ZeroAddress();
        }
        poolManager = pm;
        // The deployer is the first admin, so the contract is renounce-ready without a {setAdmin} call.
        admin = owner_;
    }

    /// @notice Hand the surviving config key to `admin_`. Owner OR admin -- the admin may rotate itself.
    /// @dev `address(0)` is allowed while the owner holds the key; {_requireRenounceReady} refuses to renounce over it.
    function setAdmin(address admin_) external onlyOwnerOrAdmin {
        if (admin_ == address(this)) {
            revert SelfAddress();
        }
        admin = admin_;
        emit AdminSet(admin_);
    }

    /// @notice Allow or disallow a launcher. Owner or admin.
    /// @dev `launcherCount` changes only on an actual state change; {_requireRenounceReady} reads it.
    function setLauncher(address launcher_, bool allowed) external onlyOwnerOrAdmin {
        if (launcher_ == address(0)) {
            revert NotLauncher();
        }
        if (allowed != isLauncher[launcher_]) {
            if (allowed) {
                launcherCount += 1;
            } else {
                launcherCount -= 1;
            }
        }
        isLauncher[launcher_] = allowed;
        emit LauncherSet(launcher_, allowed);
    }

    /// @dev Blocks {renounceOwnership} until a launcher is allowlisted and an admin is set; otherwise no launcher
    /// could ever be authorised again.
    function _requireRenounceReady() internal view override {
        if (launcherCount == 0) {
            revert LauncherNotSet();
        }
        if (admin == address(0)) {
            revert AdminZero();
        }
    }

    /// @notice Seed a new pool's single-sided LP and perform the dev buy, paid entirely to `creator`.
    /// @param coinAmountIn the exact coin amount the caller transferred to this locker for this seed.
    /// @return devBuySpent the quote the dev buy actually consumed; any leftover is refunded to `creator`.
    /// @dev Allowlisted launchers only. For an ERC20 quote the launcher transfers `devBuyQuote` beforehand and
    /// sends no value; for a native quote `msg.value` must equal `devBuyQuote`.
    function launch(
        PoolKey calldata key,
        uint128 liquidity,
        int24 tickLower,
        int24 tickUpper,
        address creator,
        bool quoteIsC0,
        uint256 devBuyQuote,
        uint256 coinAmountIn
    ) external payable nonReentrant returns (uint256 devBuySpent) {
        // The whole dev buy goes to `creator` through the same distribution path as a split.
        address[] memory recipients = new address[](1);
        uint16[] memory bps = new uint16[](1);
        recipients[0] = creator;
        bps[0] = DEV_BUY_BPS;
        return
            _launch(
                key, liquidity, tickLower, tickUpper, creator, quoteIsC0, devBuyQuote, coinAmountIn, recipients, bps
            );
    }

    /// @notice {launch} with the dev buy's coin split across up to {MAX_DEV_BUY_RECIPIENTS} wallets. Still one swap;
    /// each recipient gets `bps / 10,000` and the last takes the rounding remainder. Leftover quote goes to `creator`.
    function launch(
        PoolKey calldata key,
        uint128 liquidity,
        int24 tickLower,
        int24 tickUpper,
        address creator,
        bool quoteIsC0,
        uint256 devBuyQuote,
        uint256 coinAmountIn,
        address[] calldata devBuyRecipients,
        uint16[] calldata devBuyBps
    ) external payable nonReentrant returns (uint256 devBuySpent) {
        return _launch(
            key,
            liquidity,
            tickLower,
            tickUpper,
            creator,
            quoteIsC0,
            devBuyQuote,
            coinAmountIn,
            devBuyRecipients,
            devBuyBps
        );
    }

    function _launch(
        PoolKey calldata key,
        uint128 liquidity,
        int24 tickLower,
        int24 tickUpper,
        address creator,
        bool quoteIsC0,
        uint256 devBuyQuote,
        uint256 coinAmountIn,
        address[] memory recipients,
        uint16[] memory bps
    ) internal returns (uint256 devBuySpent) {
        if (!isLauncher[msg.sender]) {
            revert NotLauncher();
        }
        // `msg.value` must match the quote side exactly: an unfunded native dev buy would be paid out of the pooled
        // balance backing other pools and refunds. Orientation is derived from the key, not trusted from the caller.
        _requireOrientation(key, quoteIsC0);
        // `creator` is a `take` destination and a refund owner, so the refund-destination rules apply here too.
        if (creator == address(0) || creator == address(this) || creator == address(poolManager)) {
            revert BadRefundDestination();
        }
        // Native ETH can only be currency0, and {_requireOrientation} has established it is then the quote.
        uint256 needValue = Currency.unwrap(key.currency0) == address(0) ? devBuyQuote : 0;
        if (msg.value != needValue) {
            revert BadDevBuyValue(msg.value, needValue);
        }
        // Checked after the guards above so they report the real problem first, and before any state is written.
        _requireDevBuySplit(recipients, bps, key, quoteIsC0, creator);
        PoolId id = key.toId();
        if (poolInfo[id].seeded) {
            revert AlreadySeeded();
        }
        if (liquidity == 0) {
            revert BadLiquidity();
        }
        poolInfo[id] = PoolInfo({tickLower: tickLower, tickUpper: tickUpper, seeded: true});
        bytes memory ret = poolManager.unlock(
            abi.encode(
                uint8(Op.SEED),
                SeedData({
                    key: key,
                    liquidity: liquidity,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    creator: creator,
                    quoteIsC0: quoteIsC0,
                    devBuyQuote: devBuyQuote,
                    coinAmountIn: coinAmountIn
                })
            )
        );
        uint256 refundAmount;
        address refundQuote;
        uint256 coinOut;
        if (ret.length == 128) {
            (devBuySpent, refundAmount, refundQuote, coinOut) = abi.decode(ret, (uint256, uint256, address, uint256));
        }
        // The refund push runs after the unlock has closed, so the recipient cannot `take` against our deltas and
        // revert the launch. {_seed} already queued the refund; a successful push clears it, a failed one leaves it
        // in {pendingQuoteRefund}. `nonReentrant` blocks re-entry from the push.
        if (refundAmount > 0) {
            if (_pushRefund(refundQuote, creator, refundAmount)) {
                pendingQuoteRefund[creator][refundQuote] -= refundAmount;
                _releaseReserved(refundQuote, refundAmount);
            } else {
                emit QuoteRefundQueued(creator, refundQuote, refundAmount);
            }
        }
        // Paid out after the lock has closed, for the same reason as the refund push.
        if (coinOut > 0) {
            _distributeDevBuy(key, quoteIsC0, coinOut, recipients, bps);
        }
        emit Seeded(id, liquidity, tickLower, tickUpper);
    }

    /// @dev Dev-buy split rules, enforced here so no launcher can skip them. Recipients must be distinct and not
    /// zero, this locker, the PoolManager, the coin or the pool's hook; the calling launcher is refused unless it
    /// is also the creator. Bps must be non-zero and sum to 10,000.
    function _requireDevBuySplit(
        address[] memory recipients,
        uint16[] memory bps,
        PoolKey calldata key,
        bool quoteIsC0,
        address creator
    ) internal view {
        address coin = Currency.unwrap(quoteIsC0 ? key.currency1 : key.currency0);
        uint256 n = recipients.length;
        if (n == 0 || n > MAX_DEV_BUY_RECIPIENTS || n != bps.length) {
            revert BadDevBuySplit();
        }
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            address r = recipients[i];
            if (r == address(0) || r == address(this) || r == address(poolManager) || bps[i] == 0) {
                revert BadDevBuySplit();
            }
            if (r == coin || (r == msg.sender && r != creator) || r == address(key.hooks)) {
                revert BadDevBuySplit();
            }
            for (uint256 j; j < i; ++j) {
                if (recipients[j] == r) {
                    revert BadDevBuySplit();
                }
            }
            sum += bps[i];
        }
        if (sum != DEV_BUY_BPS) {
            revert BadDevBuySplit();
        }
    }

    /// @dev Pays `coinOut` of the coin (taken to this contract by {_seed}) to the recipients. A failed transfer
    /// reverts the launch: leftover coin would read as unreserved surplus in the shared balance.
    function _distributeDevBuy(
        PoolKey calldata key,
        bool quoteIsC0,
        uint256 coinOut,
        address[] memory recipients,
        uint16[] memory bps
    ) internal {
        address coin = Currency.unwrap(quoteIsC0 ? key.currency1 : key.currency0);
        uint256 n = recipients.length;
        uint256[] memory amounts = new uint256[](n);
        uint256 sent;
        for (uint256 i; i < n; ++i) {
            uint256 amt = i + 1 == n ? coinOut - sent : coinOut * bps[i] / DEV_BUY_BPS;
            amounts[i] = amt;
            sent += amt;
            if (amt != 0) {
                IERC20(coin).safeTransfer(recipients[i], amt);
            }
        }
        emit DevBuyDistributed(coin, recipients, amounts);
    }

    /// @notice What this locker holds of `token` above what it already owes: balance minus {reservedOf}.
    /// For a call that just transferred its own funds in, this is exactly that call's contribution.
    /// @dev Saturates instead of reverting so a balance drop cannot brick launches. Rebasing-down tokens are
    /// unsupported: withdrawals pay nominal amounts first come first served, so the last claimant bears any deficit.
    function availableOf(address token) public view returns (uint256) {
        uint256 bal = token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
        uint256 r = reservedOf[token];
        return bal > r ? bal - r : 0;
    }

    /// @dev Checks the caller's `quoteIsC0` against the key. `currency1 == 0` is malformed; a native currency0 is
    /// always the quote; otherwise the claim is refused if the side called "quote" reports the calling launcher
    /// as its `launcher()`. An inconclusive probe is allowed, since {_seed} bounds both sides by {availableOf}.
    function _requireOrientation(PoolKey calldata key, bool quoteIsC0) internal view {
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (c1 == address(0)) {
            revert BadPoolKey();
        }
        if (c0 == address(0)) {
            if (!quoteIsC0) {
                revert OrientationMismatch(quoteIsC0, true);
            }
            return;
        }
        if (_isCallerCoin(quoteIsC0 ? c0 : c1)) {
            revert OrientationMismatch(quoteIsC0, !quoteIsC0);
        }
    }

    /// @dev True if `t` reports the calling launcher as its `launcher()`. Low-level and gas-capped so a codeless
    /// or non-conforming token yields false instead of reverting.
    function _isCallerCoin(address t) internal view returns (bool) {
        (bool ok, bytes memory ret) =
            t.staticcall{gas: 20_000}(abi.encodeWithSelector(IRealmAnyPairsCoinLauncher.launcher.selector));
        return ok && ret.length >= 32 && address(uint160(uint256(bytes32(ret)))) == msg.sender;
    }

    /// @dev Capped, never-reverting refund push, called by {launch} after the unlock has closed. The caps stop a
    /// hostile recipient or token from burning the launch's gas.
    function _pushRefund(address quote, address to, uint256 amount) internal returns (bool success) {
        if (quote == address(0)) {
            // NATIVE. The failure this guards is a contract/AA `creator` with no plain-ETH receive.
            (success,) = to.call{value: amount, gas: NATIVE_REFUND_PUSH_GAS}("");
        } else {
            (bool ok, bytes memory ret) =
                quote.call{gas: REFUND_PUSH_GAS}(abi.encodeCall(IERC20.transfer, (to, amount)));
            // Compare the raw word rather than abi.decode(ret,(bool)): the decoder REVERTS on a word that is
            // neither 0 nor 1, from inside the very raw-call construct chosen to survive malformed returns.
            success = ok && (ret.length == 0 || (ret.length >= 32 && uint256(bytes32(ret)) != 0));
        }
    }

    function _reserve(address token, uint256 amount) internal {
        if (amount != 0) {
            reservedOf[token] += amount;
        }
    }

    /// @dev Saturating for the same reason {availableOf} is: a permanent revert here would brick every
    /// future {compound} and every future withdrawal.
    function _releaseReserved(address token, uint256 amount) internal {
        uint256 r = reservedOf[token];
        reservedOf[token] = r > amount ? r - amount : 0;
    }

    /// @dev The ONLY place `carried0`/`carried1` are written outside {_seed}'s dust credit, so {reservedOf}
    /// cannot drift away from them.
    function _setCarried(PoolKey memory key, PoolId id, uint256 new0, uint256 new1) internal {
        uint256 old0 = carried0[id];
        if (new0 != old0) {
            carried0[id] = new0;
            if (new0 > old0) {
                _reserve(Currency.unwrap(key.currency0), new0 - old0);
            } else {
                _releaseReserved(Currency.unwrap(key.currency0), old0 - new0);
            }
        }
        uint256 old1 = carried1[id];
        if (new1 != old1) {
            carried1[id] = new1;
            if (new1 > old1) {
                _reserve(Currency.unwrap(key.currency1), new1 - old1);
            } else {
                _releaseReserved(Currency.unwrap(key.currency1), old1 - new1);
            }
        }
    }

    function compound(PoolKey calldata key) external nonReentrant {
        PoolId id = key.toId();
        if (!poolInfo[id].seeded) {
            revert NotSeeded();
        }
        poolManager.unlock(abi.encode(uint8(Op.COMPOUND), key));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) {
            revert NotPoolManager();
        }
        uint8 op = abi.decode(data[:32], (uint8));
        if (op == uint8(Op.SEED)) {
            (uint256 sp, uint256 rf, address qa, uint256 co) = _seed(abi.decode(data[32:], (SeedData)));
            return abi.encode(sp, rf, qa, co);
        }
        _compound(abi.decode(data[32:], (PoolKey)));
        return "";
    }

    // ───────────────────────────── seed ─────────────────────────────

    /// @return spentQuote what the dev buy actually consumed; see {launch}.
    /// @return refundAmount the leftover dev-buy quote, already committed to {pendingQuoteRefund}.
    /// @return quoteAddr this pool's quote currency, as derived here.
    function _seed(SeedData memory s)
        internal
        returns (uint256 spentQuote, uint256 refundAmount, address quoteAddr, uint256 coinOut)
    {
        address coinAddr;
        // Bound both declared amounts by {availableOf}: what this locker holds beyond what it owes other pools and
        // creators is exactly what this call contributed, whichever side is labelled coin or quote.
        (quoteAddr, coinAddr) = s.quoteIsC0
            ? (Currency.unwrap(s.key.currency0), Currency.unwrap(s.key.currency1))
            : (Currency.unwrap(s.key.currency1), Currency.unwrap(s.key.currency0));
        {
            uint256 availCoin = availableOf(coinAddr);
            if (s.coinAmountIn > availCoin) {
                revert BadCoinAmountIn(s.coinAmountIn, availCoin);
            }
            uint256 availQuote = availableOf(quoteAddr);
            if (s.devBuyQuote > availQuote) {
                revert BadDevBuyBacking(s.devBuyQuote, availQuote);
            }
        }
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            s.key,
            ModifyLiquidityParams({
                tickLower: s.tickLower, tickUpper: s.tickUpper, liquidityDelta: int256(uint256(s.liquidity)), salt: 0
            }),
            ""
        );
        int128 owed0 = delta.amount0();
        int128 owed1 = delta.amount1();
        // Single-sided by construction: a non-zero quote leg would be settled out of the shared quote balance.
        // Current launchers cannot reach this (price pin and {_requireOrientation}); kept for future launchers.
        if (s.quoteIsC0 ? owed0 != 0 : owed1 != 0) {
            revert SeedNotSingleSided();
        }
        // Bound the ACTUAL settle charge per currency (from the key, not the caller's labels), so the seed can never
        // spend balance reserved for other pools or refunds. Declared amounts do not bound what `modifyLiquidity` charges.
        {
            if (owed0 < 0) {
                uint256 need0 = uint256(uint128(-owed0));
                address cur0 = Currency.unwrap(s.key.currency0);
                uint256 have0 = availableOf(cur0);
                if (need0 > have0) {
                    revert SeedSettleUnbacked(cur0, need0, have0);
                }
            }
            if (owed1 < 0) {
                uint256 need1 = uint256(uint128(-owed1));
                address cur1 = Currency.unwrap(s.key.currency1);
                uint256 have1 = availableOf(cur1);
                if (need1 > have1) {
                    revert SeedSettleUnbacked(cur1, need1, have1);
                }
            }
        }
        if (owed0 < 0) {
            s.key.currency0.settle(poolManager, address(this), uint256(uint128(-owed0)), false);
        }
        if (owed1 < 0) {
            s.key.currency1.settle(poolManager, address(this), uint256(uint128(-owed1)), false);
        }

        if (s.devBuyQuote > 0) {
            bool zeroForOne = s.quoteIsC0;
            uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
            BalanceDelta d = poolManager.swap(
                s.key,
                SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(s.devBuyQuote), sqrtPriceLimitX96: limit}),
                ""
            );
            (Currency quoteCur, Currency coinCur) =
                zeroForOne ? (s.key.currency0, s.key.currency1) : (s.key.currency1, s.key.currency0);
            int128 quoteDelta = zeroForOne ? d.amount0() : d.amount1();
            int128 coinDelta = zeroForOne ? d.amount1() : d.amount0();
            uint256 quoteSpent = quoteDelta < 0 ? uint256(uint128(-quoteDelta)) : 0;
            spentQuote = quoteSpent;
            // Bound the quote the swap actually charged as well, so an overcharge can never be paid out of balance
            // reserved for others.
            if (quoteSpent > 0) {
                uint256 haveQuote = availableOf(quoteAddr);
                if (quoteSpent > haveQuote) {
                    revert SeedSettleUnbacked(quoteAddr, quoteSpent, haveQuote);
                }
                quoteCur.settle(poolManager, address(this), quoteSpent, false);
            }
            // The coin comes to this contract; {launch} pays it out to the dev-buy recipients after the lock closes.
            if (coinDelta > 0) {
                // Book what arrived, not what the PoolManager reports, in case the coin taxes transfers.
                coinOut = _takeMeasured(coinCur, uint256(uint128(coinDelta)));
            }
            if (quoteSpent < s.devBuyQuote) {
                refundAmount = s.devBuyQuote - quoteSpent;
                // Committed before any external call; {launch} attempts the push after the unlock closes. A partial fill
                // against the fresh single-sided range is an expected outcome.
                pendingQuoteRefund[s.creator][quoteAddr] += refundAmount;
                _reserve(quoteAddr, refundAmount);
            }
        }

        // Rounding dust from THIS seed only (never the whole coin balance, which may include other pools' dust).
        // Saturates rather than reverts: the charge is already bounded above, and a one-wei rounding mismatch must
        // not block launches. An under-declaration is emitted instead.
        int128 owedCoin = s.quoteIsC0 ? owed1 : owed0;
        uint256 consumed = owedCoin < 0 ? uint256(uint128(-owedCoin)) : 0;
        uint256 dust;
        if (consumed >= s.coinAmountIn) {
            if (consumed > s.coinAmountIn) {
                emit SeedUnderDeclaredCoin(s.key.toId(), s.coinAmountIn, consumed);
            }
        } else {
            dust = s.coinAmountIn - consumed;
        }
        if (dust != 0) {
            if (s.quoteIsC0) {
                carried1[s.key.toId()] += dust;
            } else {
                carried0[s.key.toId()] += dust;
            }
            _reserve(coinAddr, dust);
        }
    }

    /// @notice Pull a queued dev-buy refund for `creator` in `quote`. Callable by anyone; funds always go to
    /// `creator`, so a keeper can sweep on their behalf.
    function withdrawQuoteRefund(address creator, address quote) external nonReentrant {
        _withdrawQuoteRefundTo(creator, quote, creator);
    }

    /// @notice Send YOUR queued refund to another address. Creator-only.
    /// @dev Escape hatch for a creator address the quote token has frozen: a frozen address can still call.
    function withdrawQuoteRefundTo(address quote, address to) external nonReentrant {
        _withdrawQuoteRefundTo(msg.sender, quote, to);
    }

    function _withdrawQuoteRefundTo(address creator, address quote, address to) internal {
        // Every withdrawal path rejects these: sending to this locker would destroy the claim, and sending to the
        // PoolManager would donate it to the next settler.
        if (to == address(0)) {
            revert ZeroAddress();
        }
        if (to == address(this) || to == address(poolManager)) {
            revert BadRefundDestination();
        }
        uint256 amount = pendingQuoteRefund[creator][quote];
        if (amount == 0) {
            revert NothingToWithdraw();
        }
        pendingQuoteRefund[creator][quote] = 0;
        _releaseReserved(quote, amount);
        // Native withdrawal is uncapped (there is no launch to protect); a failure reverts, keeping the claim intact.
        if (quote == address(0)) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) {
                revert RefundWithdrawFailed();
            }
        } else {
            IERC20(quote).safeTransfer(to, amount);
        }
        emit QuoteRefundWithdrawn(creator, quote, amount);
    }

    /// @dev Accepts native ETH only from the PoolManager (takes of dev-buy leftovers and native fees). Value can
    /// still be forced in (e.g. SELFDESTRUCT), so no bound may rely on `address(this).balance` alone.
    receive() external payable {
        if (msg.sender != address(poolManager)) {
            revert NotPoolManager();
        }
    }

    // ─────────────────────────── compound ───────────────────────────

    function _compound(PoolKey memory key) internal {
        PoolId id = key.toId();
        PoolInfo memory p = poolInfo[id];

        // Harvest the primary range and every fallback range; skipping one would strand its fees.
        (uint256 fee0, uint256 fee1) = _harvest(key, p.tickLower, p.tickUpper, 0, 0);
        Range[] storage opened = fallbackRanges[id];
        for (uint256 i; i < opened.length; i++) {
            (fee0, fee1) = _harvest(key, opened[i].lower, opened[i].upper, fee0, fee1);
        }
        // Book fees as a measured balance delta, not the nominal amount: a fee-on-transfer currency delivers less,
        // and booking the nominal figure would brick compounding or spend other pools' reserves.
        uint256 got0 = _takeMeasured(key.currency0, fee0);
        uint256 got1 = _takeMeasured(key.currency1, fee1);

        uint256 total0 = carried0[id] + got0;
        uint256 total1 = carried1[id] + got1;

        (uint160 sqrtP, int24 curTick,,) = poolManager.getSlot0(id);
        // One-wei safety margin on sizing. The rounding already guarantees `used <= total`; this is purely defensive,
        // since an uncovered settle would make every future compound for this pool revert.
        uint256 size0 = total0 != 0 ? total0 - 1 : 0;
        uint256 size1 = total1 != 0 ? total1 - 1 : 0;
        // Which range can actually take liquidity right now. The primary is always preferred, so a pool
        // nobody has attacked never touches the fallback machinery at all.
        uint128 maxLiq = Pool.tickSpacingToMaxLiquidityPerTick(key.tickSpacing);
        (int24 lo, int24 hi, uint128 headroom, bool isNew) = _pickRange(id, key, p, curTick, maxLiq);
        uint128 liq =
            _liquidityForAmounts(sqrtP, TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), size0, size1);
        // Clamp to the remaining per-tick liquidity headroom, which is shared by every position on those ticks. An
        // add over the cap would revert every future compound; the remainder stays carried.
        if (liq > headroom) {
            // Emit the post-clamp value so `clampedLiquidity` is what was actually added.
            uint128 desired = liq;
            liq = headroom;
            emit CompoundClamped(id, desired, liq, headroom);
        }
        if (liq == 0) {
            _setCarried(key, id, total0, total1);
            return;
        }

        // Do not add an external call between the `getSlot0` read above and this add: `used <= total` relies on the
        // price not moving in between. The re-entrancy window (`_takeMeasured`) is before the read.

        (BalanceDelta d,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: int256(uint256(liq)), salt: 0}),
            ""
        );
        // Fees accrued between the harvest and this add are netted into `d`; a positive leg is taken below.
        uint256 used0 = d.amount0() < 0 ? uint256(uint128(-d.amount0())) : 0;
        uint256 used1 = d.amount1() < 0 ? uint256(uint128(-d.amount1())) : 0;
        if (used0 > 0) {
            key.currency0.settle(poolManager, address(this), used0, false);
        }
        if (used1 > 0) {
            key.currency1.settle(poolManager, address(this), used1, false);
        }
        // A positive delta is owed to this pool: take it (measured) and credit it to `total` so {_setCarried} reserves
        // it. Done after the settles so it can never cover a shortfall that {CompoundOverspend} must refuse.
        if (d.amount0() > 0) {
            total0 += _takeMeasured(key.currency0, uint256(uint128(d.amount0())));
        }
        if (d.amount1() > 0) {
            total1 += _takeMeasured(key.currency1, uint256(uint128(d.amount1())));
        }

        // `used > total` would mean the settle drew on balance owed to others. Unreachable today, but revert with the
        // amounts rather than let a clamp commit the shortfall.
        if (used0 > total0 || used1 > total1) {
            revert CompoundOverspend(used0 > total0 ? used0 - total0 : 0, used1 > total1 ? used1 - total1 : 0);
        }
        _setCarried(key, id, total0 > used0 ? total0 - used0 : 0, total1 > used1 ? total1 - used1 : 0);
        // Registered only now, with liquidity inside it: harvesting an empty registered band would revert forever.
        if (isNew) {
            fallbackRanges[id].push(Range({lower: lo, upper: hi}));
            emit FallbackRangeOpened(id, lo, hi);
        }
        emit Compounded(id, liq, used0, used1);
    }

    /// @notice How many fallback ranges this pool has opened. Zero unless its primary range was ever pinned.
    /// @dev Anything locating this pool's liquidity (indexers, solvency checks) must enumerate these as well as
    /// {poolInfo}.
    function fallbackRangeCount(PoolId id) external view returns (uint256) {
        return fallbackRanges[id].length;
    }

    /// @notice The `i`th fallback range's tick bounds.
    function fallbackRangeAt(PoolId id, uint256 i) external view returns (int24 lower, int24 upper) {
        Range storage r = fallbackRanges[id][i];
        return (r.lower, r.upper);
    }

    /// @dev Collect (but do not re-deploy) one range's fees with a zero-liquidity poke, accumulating onto
    /// `acc0`/`acc1`. A poke on an empty position reverts, hence the try/catch.
    function _harvest(PoolKey memory key, int24 lower, int24 upper, uint256 acc0, uint256 acc1)
        internal
        returns (uint256, uint256)
    {
        // A revert here would block every future compound, so an empty band (which has no fees) is skipped.
        try poolManager.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: 0, salt: 0}), ""
        ) returns (
            BalanceDelta, BalanceDelta fees
        ) {
            return (
                acc0 + (fees.amount0() > 0 ? uint256(uint128(fees.amount0())) : 0),
                acc1 + (fees.amount1() > 0 ? uint256(uint128(fees.amount1())) : 0)
            );
        } catch {
            return (acc0, acc1);
        }
    }

    /// @dev `take` one currency into this locker and return what actually arrived (balance delta), never the amount
    /// asked for. Saturates at zero so a currency that shrinks our balance cannot brick compounding.
    function _takeMeasured(Currency cur, uint256 amount) internal returns (uint256 received) {
        if (amount == 0) {
            return 0;
        }
        address t = Currency.unwrap(cur);
        uint256 before = t == address(0) ? address(this).balance : IERC20(t).balanceOf(address(this));
        cur.take(poolManager, address(this), amount, false);
        uint256 aft = t == address(0) ? address(this).balance : IERC20(t).balanceOf(address(this));
        received = aft > before ? aft - before : 0;
    }

    /// @dev Remaining per-tick liquidity budget at the tighter of a range's two boundaries. Saturating at
    /// zero rather than subtracting: the pool enforces the cap so `gross > maxLiq` cannot occur today, but
    /// this is unpatchable code and an underflow here would revert every future compound() permanently,
    /// which is the exact failure mode the clamp exists to prevent.
    function _headroomAt(PoolId id, int24 lower, int24 upper, uint128 maxLiq) internal view returns (uint128) {
        (uint128 gl,) = poolManager.getTickLiquidity(id, lower);
        (uint128 gu,) = poolManager.getTickLiquidity(id, upper);
        uint128 g = gl > gu ? gl : gu;
        return g >= maxLiq ? 0 : maxLiq - g;
    }

    /// @dev Picks the range to compound into: the primary if it has headroom, else an in-range fallback, else a new
    /// band at spot, else any band with room. Needed because anyone can fill the per-tick liquidity cap at the
    /// primary range's boundary. View on purpose: the caller registers a new band only after liquidity lands, since
    /// harvesting an empty registered band reverts.
    function _pickRange(PoolId id, PoolKey memory key, PoolInfo memory p, int24 curTick, uint128 maxLiq)
        internal
        view
        returns (int24 lo, int24 hi, uint128 headroom, bool isNew)
    {
        headroom = _headroomAt(id, p.tickLower, p.tickUpper, maxLiq);
        if (headroom != 0) {
            return (p.tickLower, p.tickUpper, headroom, false);
        }

        Range[] storage fb = fallbackRanges[id];
        uint256 n = fb.length;

        // IN-RANGE FIRST. Liquidity outside the active range earns nothing until the price returns, and
        // the primary is pinned, so a band the market has left behind would otherwise keep receiving
        // every future compound forever.
        for (uint256 i; i < n; i++) {
            if (curTick < fb[i].lower || curTick >= fb[i].upper) {
                continue;
            }
            headroom = _headroomAt(id, fb[i].lower, fb[i].upper, maxLiq);
            if (headroom != 0) {
                return (fb[i].lower, fb[i].upper, headroom, false);
            }
        }

        // Nothing open covers spot: open a fresh band there, if the cap still allows one.
        if (n < MAX_FALLBACK) {
            (lo, hi) = _spotRange(curTick, key.tickSpacing);
            // Dedupe: at the top clamp {_spotRange} can return a band that is already open, which would waste a harvest slot.
            if (lo < hi && !_isOpen(fb, lo, hi)) {
                headroom = _headroomAt(id, lo, hi, maxLiq);
                if (headroom != 0) {
                    return (lo, hi, headroom, true);
                }
            }
        }

        // Last resort: any known band with room. Compounding out of range beats not compounding at all.
        for (uint256 i; i < n; i++) {
            headroom = _headroomAt(id, fb[i].lower, fb[i].upper, maxLiq);
            if (headroom != 0) {
                return (fb[i].lower, fb[i].upper, headroom, false);
            }
        }
        return (p.tickLower, p.tickUpper, 0, false);
    }

    /// @dev Is this exact band already registered for the pool? See {_pickRange}'s dedupe.
    function _isOpen(Range[] storage fb, int24 lower, int24 upper) internal view returns (bool) {
        uint256 n = fb.length;
        for (uint256 i; i < n; i++) {
            if (fb[i].lower == lower && fb[i].upper == upper) {
                return true;
            }
        }
        return false;
    }

    /// @dev A spacing-aligned range straddling `curTick`, clamped to the usable tick range. All arithmetic
    /// is widened to int256 first: `spacing * FALLBACK_SPAN` overflows int24 for any spacing above 546.
    function _spotRange(int24 curTick, int24 spacing) internal pure returns (int24 lo, int24 hi) {
        int256 sp = int256(spacing);
        int256 t = int256(curTick);
        // FLOOR, not Solidity's truncate-toward-zero, or a range below spot would be misaligned upward.
        int256 c = (t / sp) * sp;
        if (t < 0 && c != t) {
            c -= sp;
        }
        int256 span = sp * FALLBACK_SPAN;
        int256 minT = (int256(TickMath.MIN_TICK) / sp) * sp;
        if (minT < int256(TickMath.MIN_TICK)) {
            minT += sp;
        }
        int256 maxT = (int256(TickMath.MAX_TICK) / sp) * sp;
        int256 l = c - span;
        int256 h = c + span;
        lo = int24(l < minT ? minT : l);
        hi = int24(h > maxT ? maxT : h);
    }

    // ─────────────────── vendored LiquidityAmounts (subset) ───────────────────

    function _liquidityForAmount0(uint160 sqrtA, uint160 sqrtB, uint256 amount0) internal pure returns (uint128) {
        if (sqrtA > sqrtB) {
            (sqrtA, sqrtB) = (sqrtB, sqrtA);
        }
        uint256 intermediate = FullMath.mulDiv(sqrtA, sqrtB, Q96);
        uint256 l0 = FullMath.mulDiv(amount0, intermediate, sqrtB - sqrtA);
        // Saturate rather than wrap or revert: callers clamp the result again, and a revert in {_compound} is permanent.
        return l0 > type(uint128).max ? type(uint128).max : uint128(l0);
    }

    function _liquidityForAmount1(uint160 sqrtA, uint160 sqrtB, uint256 amount1) internal pure returns (uint128) {
        if (sqrtA > sqrtB) {
            (sqrtA, sqrtB) = (sqrtB, sqrtA);
        }
        uint256 l1 = FullMath.mulDiv(amount1, Q96, sqrtB - sqrtA);
        return l1 > type(uint128).max ? type(uint128).max : uint128(l1);
    }

    function _liquidityForAmounts(uint160 sqrtP, uint160 sqrtA, uint160 sqrtB, uint256 amount0, uint256 amount1)
        internal
        pure
        returns (uint128 liquidity)
    {
        if (sqrtA > sqrtB) {
            (sqrtA, sqrtB) = (sqrtB, sqrtA);
        }
        if (sqrtP <= sqrtA) {
            liquidity = _liquidityForAmount0(sqrtA, sqrtB, amount0);
        } else if (sqrtP < sqrtB) {
            uint128 l0 = _liquidityForAmount0(sqrtP, sqrtB, amount0);
            uint128 l1 = _liquidityForAmount1(sqrtA, sqrtP, amount1);
            liquidity = l0 < l1 ? l0 : l1;
        } else {
            liquidity = _liquidityForAmount1(sqrtA, sqrtB, amount1);
        }
    }

    // ─────────────────────────── rescue ───────────────────────────

    /// @dev V4's `Lock` unlocked-flag transient slot, read the same way {RealmAnyPairsTaxHookPairImmutable} reads it.
    bytes32 internal constant V4_IS_UNLOCKED_SLOT_R96 =
        0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23;

    function _managerUnlockedR96() internal view returns (bool) {
        (bool ok, bytes memory d) =
            address(poolManager).staticcall(abi.encodeWithSignature("exttload(bytes32)", V4_IS_UNLOCKED_SLOT_R96));
        return ok && d.length == 32 && abi.decode(d, (uint256)) != 0;
    }

    /// @notice Send `amount` of `token` (address(0) = native ETH) that this locker holds above what it owes to `to`.
    /// Owner or admin.
    /// @dev Bounded by {availableOf}, so reserved dust and queued refunds cannot leave; LP positions are untouchable.
    /// Refused while the PoolManager is unlocked, when incoming launch funds are held but not yet reserved.
    function rescue(address token, address to, uint256 amount) external onlyOwnerOrAdmin nonReentrant {
        if (to == address(0) || to == address(this) || to == address(poolManager)) {
            revert BadRefundDestination();
        }
        if (_managerUnlockedR96()) {
            revert RescueWhileUnlocked();
        }
        uint256 avail = availableOf(token);
        if (amount == 0 || amount > avail) {
            revert RescueExceedsAvailable(amount, avail);
        }
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) {
                revert RescueFailed();
            }
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit Rescued(token, to, amount);
    }
}
