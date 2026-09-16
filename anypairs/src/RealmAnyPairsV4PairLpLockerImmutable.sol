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
 * @notice Non-upgradeable locker that seeds V4 pools and holds their LP positions permanently.
 * @dev AUDIT ROUND 13 (informational): this title used to say it "compounds their fees back into locked LP". It does
 * not, and has not since round 12 -- Realm pools are zero-fee, so the locked position accrues no trading fees and
 * there is nothing to compound. Locked liquidity grows only from the tax's LP slice, which the HOOK deploys.
 *         Liquidity is only ever added (there is no removal path), so the LP is locked permanently.
 */
contract RealmAnyPairsV4PairLpLockerImmutable is IUnlockCallback, RealmAnyPairsImmutableBase {
    using CurrencySettler for Currency;
    using SafeERC20 for IERC20;


    IPoolManager public immutable poolManager;
    /// @notice Launchers allowed to seed pools. An allowlist, so a replacement launcher can be admitted
    /// without migrating the locker.
    mapping(address => bool) public isLauncher;
    uint256 public launcherCount;

    struct PoolInfo {
        /// @dev AUDIT ROUND 15 (informational): WRITE-ONLY. These were the compounding anchors; compounding was
        /// deleted in round 12 and nothing reads them now. Kept rather than removed because {poolInfo} is a public
        /// getter an indexer may already be reading, but they are NOT authoritative for anything on chain.
        int24 tickLower;
        int24 tickUpper;
        bool seeded;
    }

    mapping(PoolId => PoolInfo) public poolInfo;
    /// @notice Pull-based fallback for dev-buy refunds whose push failed (e.g. the creator is paused or
    /// blacklisted by the quote token), keyed by (creator, quote token).
    /// @dev Withdrawn by THE CREATOR ONLY, via {withdrawQuoteRefund} (to themselves) or {withdrawQuoteRefundTo} (to
    /// a destination of their choosing, the escape hatch when their own address is frozen). Round 16 removed the
    /// third-party/keeper sweep by decision; see {withdrawQuoteRefund}.
    mapping(address => mapping(address => uint256)) public pendingQuoteRefund;

    /// @notice Everything this locker already owes, per token (`address(0)` = native): the sum of every
    /// {pendingQuoteRefund} entry.
    /// @dev AUDIT ROUND 13 (informational): this used to say "the sum of every pool's `carried0`/`carried1` and every
    /// {pendingQuoteRefund} entry", and to name `{_setCarried}` as a writer. Both were removed in round 12 with
    /// compounding -- the seed's rounding dust is no longer reserved, so queued refunds are all that is left here.
    /// @dev One balance per token is shared by all refunds, so spends are bounded by {availableOf} (balance minus
    /// this). Kept in sync by {_reserve} and {_releaseReserved}.
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
    event QuoteRefundQueued(address indexed creator, address indexed quote, uint256 amount);
    event QuoteRefundWithdrawn(address indexed creator, address indexed quote, uint256 amount);
    /// @notice The dev buy of `token` was paid out: `amounts[i]` to `recipients[i]`, summing to the coin bought.
    event DevBuyDistributed(address indexed token, address[] recipients, uint256[] amounts);


    error NotLauncher();
    error ZeroAddress();
    error LauncherNotSet();
    error AlreadySeeded();
    error NotPoolManager();
    /// @notice {unlockCallback} received an unlock payload whose leading opcode is not {Op.SEED}. Unreachable from
    /// this contract's own code; a loud, accurate error rather than a misleading one. (Audit round 13.)
    error BadUnlockOp(uint8 op);
    error BadLiquidity();
    /// @dev {setLauncher}/{setAdmin} called by neither the owner nor the admin.
    error NotOwnerOrAdmin();
    /// @dev Renounce attempted while `admin == address(0)`. See {_requireRenounceReady}.
    error AdminZero();
    /// @dev {setAdmin}(address(this)): this contract never calls itself, so that admin would be a dead key.
    error SelfAddress();
    /// @notice Refused: clearing the admin after ownership is renounced would leave nobody able to configure or
    /// rescue, permanently. Rotate to a new admin instead. (Audit round 12.)
    error AdminWouldBeUnrecoverable();
    /// @dev Gas stipend for the best-effort ERC20 dev-buy refund push. Sized with headroom for compliance-gated,
    /// issuer-upgradeable quote tokens; a failed push falls back to the pull queue.
    uint256 internal constant REFUND_PUSH_GAS = 150_000;

    /// @dev Gas stipend for the native refund push. Enough for EOAs and simple contract wallets; failures fall
    /// back to the pull queue. The push runs after the unlock closes, and a native refund implies the seeded
    /// range is exhausted, so an in-transaction snipe gains nothing. Do not lower it.
    uint256 internal constant NATIVE_REFUND_PUSH_GAS = 60_000;

    /// @dev Carries the amounts because an event emitted in a reverting frame is rolled back with it.
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
    /// @notice No rescue while the PoolManager is unlocked (a seed is mid-flight).
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
    /// @dev A queued refund withdrawal delivered nothing: the native send failed, or the ERC20 transfer moved no
    /// balance out of this locker. Reverting rolls the zeroing back, so the claim survives.
    error RefundWithdrawFailed();

    /// @dev A dev-buy payout moved no coin out of this locker even though the transfer reported success (a soft
    /// blocklist). See {_distributeDevBuy}.
    error DevBuyPayoutFailed();

    /// @dev {withdrawQuoteRefund} called by anyone other than the creator whose refund it is. Only the owner of a
    /// queued refund may trigger its delivery. See {withdrawQuoteRefund} for why this is not a keeper entry point.
    error NotRefundOwner();

    /// @dev The seed's `modifyLiquidity` charged more of `currency` than {availableOf} it, i.e. it would spend
    /// balance owed to other pools or creators. Reported per currency, independent of the coin/quote labels.
    error SeedSettleUnbacked(address currency, uint256 required, uint256 available);

    /// @notice The seed consumed more coin than `coinAmountIn` declared, so no rounding dust was credited.
    /// @dev Emitted rather than reverted: the charge is already bounded by {availableOf}, and a revert on a
    /// one-wei rounding disagreement would permanently block launches.
    event SeedUnderDeclaredCoin(PoolId indexed poolId, uint256 declared, uint256 consumed);

    /// @dev Round 12: `COMPOUND` is gone with compounding itself. The enum is kept (rather than replaced by a bare
    /// constant) so the unlock payload's first word keeps its meaning and a future operation can be added without
    /// renumbering SEED.
    enum Op { SEED }

    /// @dev The payload one {launch} passes through {IPoolManager.unlock} to {_seed}.
    struct SeedData {
        PoolKey key;
        uint128 liquidity;
        /// @dev AUDIT ROUND 15 (informational): WRITE-ONLY. These were the compounding anchors; compounding was
        /// deleted in round 12 and nothing reads them now. Kept rather than removed because {poolInfo} is a public
        /// getter an indexer may already be reading, but they are NOT authoritative for anything on chain.
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
        if (msg.sender != owner && (msg.sender != admin || admin == address(0))) revert NotOwnerOrAdmin();
        _;
    }

    constructor(IPoolManager pm, address owner_) RealmAnyPairsImmutableBase(owner_) {
        // Immutable with no setter, so a zero address would be unrecoverable.
        if (address(pm) == address(0)) revert ZeroAddress();
        poolManager = pm;
        // The deployer is the first admin, so the contract is renounce-ready without a {setAdmin} call.
        admin = owner_;
    }

    /// @notice Hand the surviving config key to `admin_`. Owner OR admin -- the admin may rotate itself.
    /// @dev `address(0)` is allowed while the owner holds the key; {_requireRenounceReady} refuses to renounce over it.
    /// @dev AUDIT ROUND 12 (Low). Once ownership is renounced the admin is the ONLY remaining authority, so
    /// `setAdmin(address(0))` would permanently freeze configuration and rescue while this locker still holds every locked LP position, and would leave it unable to ever admit a replacement launcher -- with no owner left to appoint a
    /// replacement. It is refused after renounce. Handing the role to a NEW admin stays allowed, because that is
    /// the rotation path a renounced deployment still needs; only the one-way trip to nobody is closed.
    function setAdmin(address admin_) external onlyOwnerOrAdmin {
        if (admin_ == address(this)) revert SelfAddress();
        if (admin_ == address(0) && owner == address(0)) revert AdminWouldBeUnrecoverable();
        admin = admin_;
        emit AdminSet(admin_);
    }

    /// @notice Allow or disallow a launcher. Owner or admin.
    /// @dev `launcherCount` changes only on an actual state change; {_requireRenounceReady} reads it.
    function setLauncher(address launcher_, bool allowed) external onlyOwnerOrAdmin {
        if (launcher_ == address(0)) revert NotLauncher();
        if (allowed != isLauncher[launcher_]) {
            if (allowed) launcherCount += 1;
            else launcherCount -= 1;
        }
        isLauncher[launcher_] = allowed;
        emit LauncherSet(launcher_, allowed);
    }

    /// @dev Blocks {renounceOwnership} until a launcher is allowlisted and an admin is set; otherwise no launcher
    /// could ever be authorised again.
    function _requireRenounceReady() internal view override {
        if (launcherCount == 0) revert LauncherNotSet();
        if (admin == address(0)) revert AdminZero();
    }

    /// @notice Seed a new pool's single-sided LP and perform the dev buy, paid entirely to `creator`.
    /// @param coinAmountIn the exact coin amount the caller transferred to this locker for this seed.
    /// @return devBuySpent the quote the dev buy actually consumed; any leftover is refunded to `creator`.
    /// @dev Allowlisted launchers only. For an ERC20 quote the launcher transfers `devBuyQuote` beforehand and
    /// sends no value; for a native quote `msg.value` must equal `devBuyQuote`.
    function launch(
        PoolKey calldata key, uint128 liquidity, int24 tickLower, int24 tickUpper,
        address creator, bool quoteIsC0, uint256 devBuyQuote, uint256 coinAmountIn
    ) external payable nonReentrant returns (uint256 devBuySpent) {
        // The whole dev buy goes to `creator` through the same distribution path as a split.
        address[] memory recipients = new address[](1);
        uint16[] memory bps = new uint16[](1);
        recipients[0] = creator;
        bps[0] = DEV_BUY_BPS;
        return _launch(key, liquidity, tickLower, tickUpper, creator, quoteIsC0, devBuyQuote, coinAmountIn, recipients, bps);
    }

    /// @notice {launch} with the dev buy's coin split across up to {MAX_DEV_BUY_RECIPIENTS} wallets. Still one swap;
    /// each recipient gets `bps / 10,000` and the last takes the rounding remainder. Leftover quote goes to `creator`.
    function launch(
        PoolKey calldata key, uint128 liquidity, int24 tickLower, int24 tickUpper,
        address creator, bool quoteIsC0, uint256 devBuyQuote, uint256 coinAmountIn,
        address[] calldata devBuyRecipients, uint16[] calldata devBuyBps
    ) external payable nonReentrant returns (uint256 devBuySpent) {
        return _launch(
            key, liquidity, tickLower, tickUpper, creator, quoteIsC0, devBuyQuote, coinAmountIn, devBuyRecipients, devBuyBps
        );
    }

    function _launch(
        PoolKey calldata key, uint128 liquidity, int24 tickLower, int24 tickUpper,
        address creator, bool quoteIsC0, uint256 devBuyQuote, uint256 coinAmountIn,
        address[] memory recipients, uint16[] memory bps
    ) internal returns (uint256 devBuySpent) {
        if (!isLauncher[msg.sender]) revert NotLauncher();
        // `msg.value` must match the quote side exactly: an unfunded native dev buy would be paid out of the pooled
        // balance backing other pools and refunds. Orientation is derived from the key, not trusted from the caller.
        _requireOrientation(key, quoteIsC0);
        // `creator` is a `take` destination and a refund owner, so the refund-destination rules apply here too.
        if (creator == address(0) || creator == address(this) || creator == address(poolManager)) {
            revert BadRefundDestination();
        }
        // Native ETH can only be currency0, and {_requireOrientation} has established it is then the quote.
        uint256 needValue = Currency.unwrap(key.currency0) == address(0) ? devBuyQuote : 0;
        if (msg.value != needValue) revert BadDevBuyValue(msg.value, needValue);
        // Checked after the guards above so they report the real problem first, and before any state is written.
        _requireDevBuySplit(recipients, bps, key, quoteIsC0, creator);
        PoolId id = key.toId();
        if (poolInfo[id].seeded) revert AlreadySeeded();
        if (liquidity == 0) revert BadLiquidity();
        poolInfo[id] = PoolInfo({tickLower: tickLower, tickUpper: tickUpper, seeded: true});
        bytes memory ret = poolManager.unlock(
            abi.encode(
                uint8(Op.SEED),
                SeedData({key: key, liquidity: liquidity, tickLower: tickLower, tickUpper: tickUpper,
                          creator: creator, quoteIsC0: quoteIsC0, devBuyQuote: devBuyQuote, coinAmountIn: coinAmountIn})
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
        if (coinOut > 0) _distributeDevBuy(key, quoteIsC0, coinOut, recipients, bps);
        emit Seeded(id, liquidity, tickLower, tickUpper);
    }

    /// @dev Dev-buy split rules, enforced here so no launcher can skip them. Recipients must be distinct and not
    /// zero, this locker, the PoolManager, the coin or the pool's hook; the calling launcher is refused unless it
    /// is also the creator. Bps must be non-zero and sum to 10,000.
    function _requireDevBuySplit(
        address[] memory recipients, uint16[] memory bps, PoolKey calldata key, bool quoteIsC0, address creator
    ) internal view {
        address coin = Currency.unwrap(quoteIsC0 ? key.currency1 : key.currency0);
        uint256 n = recipients.length;
        if (n == 0 || n > MAX_DEV_BUY_RECIPIENTS || n != bps.length) revert BadDevBuySplit();
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            address r = recipients[i];
            if (r == address(0) || r == address(this) || r == address(poolManager) || bps[i] == 0) revert BadDevBuySplit();
            if (r == coin || (r == msg.sender && r != creator) || r == address(key.hooks)) revert BadDevBuySplit();
            for (uint256 j; j < i; ++j) {
                if (recipients[j] == r) revert BadDevBuySplit();
            }
            sum += bps[i];
        }
        if (sum != DEV_BUY_BPS) revert BadDevBuySplit();
    }

    /// @dev Pays `coinOut` of the coin (taken to this contract by {_seed}) to the recipients. A failed transfer
    /// reverts the launch: leftover coin would read as unreserved surplus in the shared balance.
    /// @dev AUDIT ROUND 16 (F-2, Medium) -- uniform sender-side measurement. `safeTransfer` already reverts on a HARD
    /// blocklist, which is the intended outcome here; it cannot see the SOFT variant that returns true and moves
    /// nothing. Unmeasured, such a coin would emit {DevBuyDistributed} claiming a payout that never happened and
    /// leave the coin on this locker as unreserved surplus. Measured, the launch reverts and nothing is misreported.
    function _distributeDevBuy(
        PoolKey calldata key, bool quoteIsC0, uint256 coinOut, address[] memory recipients, uint16[] memory bps
    ) internal {
        address coin = Currency.unwrap(quoteIsC0 ? key.currency1 : key.currency0);
        uint256 n = recipients.length;
        uint256[] memory amounts = new uint256[](n);
        uint256 sent;
        for (uint256 i; i < n; ++i) {
            uint256 amt = i + 1 == n ? coinOut - sent : coinOut * bps[i] / DEV_BUY_BPS;
            amounts[i] = amt;
            sent += amt;
            // Measure OUR OWN decrease, never the callee's claim. See {_sendMeasured}.
            if (amt != 0 && !_sendMeasured(coin, recipients[i], amt)) revert DevBuyPayoutFailed();
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
        if (c1 == address(0)) revert BadPoolKey();
        if (c0 == address(0)) {
            if (!quoteIsC0) revert OrientationMismatch(quoteIsC0, true);
            return;
        }
        if (_isCallerCoin(quoteIsC0 ? c0 : c1)) revert OrientationMismatch(quoteIsC0, !quoteIsC0);
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
            // AUDIT ROUND 16 (F-2): DELIBERATELY UNMEASURED, and it must stay that way. A native send either moves
            // the wei or reverts the callee's frame -- there is no "returned true and moved nothing" variant to
            // catch, because there is no return word to lie with. `success` here is the EVM's own report, not a
            // token's claim about itself. Do not add a balance check: `address(this).balance` can also be moved by
            // a forced send (SELFDESTRUCT) inside the callee's frame, so a balance comparison would be LESS
            // reliable than the call status, not more.
            (success,) = to.call{value: amount, gas: NATIVE_REFUND_PUSH_GAS}("");
        } else {
            uint256 before = IERC20(quote).balanceOf(address(this));
            (bool ok, bytes memory ret) =
                quote.call{gas: REFUND_PUSH_GAS}(abi.encodeCall(IERC20.transfer, (to, amount)));
            // Compare the raw word rather than abi.decode(ret,(bool)): the decoder REVERTS on a word that is
            // neither 0 nor 1, from inside the very raw-call construct chosen to survive malformed returns.
            success = ok && (ret.length == 0 || (ret.length >= 32 && uint256(bytes32(ret)) != 0));
            // Round 16 (F-2): the same comparison {_sendMeasured} makes, open-coded because this exit MUST NOT
            // REVERT -- it has to survive a hostile token so the refund can fall through to the pull queue, which
            // rules out both `safeTransfer` and a shared helper that uses it.
            // The return word is the token's own claim about itself, and a soft blocklist lies. Trust
            // the balance instead, so a push that moved nothing reports FAILURE and the refund stays queued for the
            // pull path rather than being marked delivered.
            if (success && IERC20(quote).balanceOf(address(this)) >= before) success = false;
        }
    }

    function _reserve(address token, uint256 amount) internal {
        if (amount != 0) reservedOf[token] += amount;
    }

    /// @dev Saturating for the same reason {availableOf} is: a permanent revert here would brick every
    /// future withdrawal.
    function _releaseReserved(address token, uint256 amount) internal {
        uint256 r = reservedOf[token];
        reservedOf[token] = r > amount ? r - amount : 0;
    }

    // ─────────────────────── NO COMPOUNDING (audit round 12) ───────────────────────
    //
    // Every Realm pool is a ZERO-FEE pool ({RealmAnyPairsTaxHookPairImmutable.POOL_FEE} == 0), so the locked position
    // accrues no trading fees and there is nothing to reinvest. `compound()`, `_compound`, `_harvest`, `_pickRange`,
    // the fallback-range machinery and the price anchor are all gone.
    //
    // WHY THE ENTRY POINT IS REMOVED RATHER THAN ADMIN-GATED. A permissionless `compound()` sized its add against
    // LIVE spot with a large accumulated pot, which is the whole of the round-12 Critical: the first caller founded
    // the price anchor at any tick they liked, and afterwards the anchor walked a full drift per block, so the
    // constant bounded the RATE of movement and not its magnitude (measured: 1,751e18 of profit at a 50,000-tick
    // rig). Keeping the function for an admin would keep that shape alive for no benefit -- with a zero-fee pool
    // there is never a pot to reinvest, so a forced compound would do nothing. Deleting it removes the finding
    // outright instead of bounding it, and takes the fallback-band wedge (four bands planted away from market,
    // after which every future compound deposited into liquidity that could not earn) with it.
    //
    // The tax's LP slice still grows locked liquidity -- that path is the hook's in-swap auto-liquidity step and is
    // untouched.

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        // Seeding is the only operation that unlocks the PoolManager now that compounding is gone. The opcode is
        // still read and checked so a malformed payload is refused loudly rather than silently treated as a seed.
        uint8 op = abi.decode(data[:32], (uint8));
        // AUDIT ROUND 13 (informational): a malformed opcode is its OWN error. It reverted `NotPoolManager()` after
        // round 12 collapsed the two-op dispatch, which was actively misleading -- the caller IS the PoolManager at
        // that point, and the only way here is this contract's own `unlock`.
        if (op != uint8(Op.SEED)) revert BadUnlockOp(op);
        (uint256 sp, uint256 rf, address qa, uint256 co) = _seed(abi.decode(data[32:], (SeedData)));
        return abi.encode(sp, rf, qa, co);
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
            if (s.coinAmountIn > availCoin) revert BadCoinAmountIn(s.coinAmountIn, availCoin);
            uint256 availQuote = availableOf(quoteAddr);
            if (s.devBuyQuote > availQuote) revert BadDevBuyBacking(s.devBuyQuote, availQuote);
        }
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            s.key,
            ModifyLiquidityParams({tickLower: s.tickLower, tickUpper: s.tickUpper, liquidityDelta: int256(uint256(s.liquidity)), salt: 0}),
            ""
        );
        int128 owed0 = delta.amount0();
        int128 owed1 = delta.amount1();
        // Single-sided by construction: a non-zero quote leg would be settled out of the shared quote balance.
        // Current launchers cannot reach this (price pin and {_requireOrientation}); kept for future launchers.
        if (s.quoteIsC0 ? owed0 != 0 : owed1 != 0) revert SeedNotSingleSided();
        // Bound the ACTUAL settle charge per currency (from the key, not the caller's labels), so the seed can never
        // spend balance reserved for other pools or refunds. Declared amounts do not bound what `modifyLiquidity` charges.
        {
            if (owed0 < 0) {
                uint256 need0 = uint256(uint128(-owed0));
                address cur0 = Currency.unwrap(s.key.currency0);
                uint256 have0 = availableOf(cur0);
                if (need0 > have0) revert SeedSettleUnbacked(cur0, need0, have0);
            }
            if (owed1 < 0) {
                uint256 need1 = uint256(uint128(-owed1));
                address cur1 = Currency.unwrap(s.key.currency1);
                uint256 have1 = availableOf(cur1);
                if (need1 > have1) revert SeedSettleUnbacked(cur1, need1, have1);
            }
        }
        // AUDIT ROUND 16 (F-2): the two settles below are value LEAVING this locker, and they are N/A for sender-side
        // measurement because THE CALLEE ALREADY MEASURES. V4's `settle` credits the delta from the PoolManager's own
        // balance delta since `sync`, so a quote that returns true and moves nothing credits nothing, the currency
        // stays unsettled and the unlock closes with `CurrencyNotSettled` -- the whole launch reverts. A duplicate
        // check here would be dead code. (`burn: false` throughout, so no ERC-6909 claim path exists in this file.)
        if (owed0 < 0) s.key.currency0.settle(poolManager, address(this), uint256(uint128(-owed0)), false);
        if (owed1 < 0) s.key.currency1.settle(poolManager, address(this), uint256(uint128(-owed1)), false);

        if (s.devBuyQuote > 0) {
            bool zeroForOne = s.quoteIsC0;
            uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
            BalanceDelta d = poolManager.swap(
                s.key,
                SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(s.devBuyQuote), sqrtPriceLimitX96: limit}),
                ""
            );
            (Currency quoteCur, Currency coinCur) = zeroForOne
                ? (s.key.currency0, s.key.currency1)
                : (s.key.currency1, s.key.currency0);
            int128 quoteDelta = zeroForOne ? d.amount0() : d.amount1();
            int128 coinDelta = zeroForOne ? d.amount1() : d.amount0();
            uint256 quoteSpent = quoteDelta < 0 ? uint256(uint128(-quoteDelta)) : 0;
            spentQuote = quoteSpent;
            // Bound the quote the swap actually charged as well, so an overcharge can never be paid out of balance
            // reserved for others.
            if (quoteSpent > 0) {
                uint256 haveQuote = availableOf(quoteAddr);
                if (quoteSpent > haveQuote) revert SeedSettleUnbacked(quoteAddr, quoteSpent, haveQuote);
                // N/A for sender-side measurement for the same reason as the two settles above: the PoolManager
                // measures what it actually received, and an unsettled currency reverts the unlock.
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
        if (consumed > s.coinAmountIn) emit SeedUnderDeclaredCoin(s.key.toId(), s.coinAmountIn, consumed);
        // AUDIT ROUND 17: the leftover -- `s.coinAmountIn - consumed` when the seed consumed less than it declared --
        // used to be computed into a local `dust` that nothing ever read. Write-only state is how a reader concludes
        // a value is handled somewhere, so the computation is gone and the reason it has no consumer is the comment
        // below. Nothing else changes: the branch structure above was `>= then >`, which is `>`.
        // AUDIT ROUND 12. This dust used to be booked to `carried0`/`carried1` and RESERVED, so that a later
        // `compound()` would deploy it. Compounding is gone (zero-fee pools have nothing to reinvest), so reserving
        // it would strand it permanently: nothing would ever deploy it, and `rescue` is bounded by `availableOf`
        // (balance - reservedOf) so nothing could ever recover it either. It is therefore left UNRESERVED -- it
        // sits in the locker's balance as ordinary surplus, which `rescue` can sweep. The emitted event still
        // records the under-declaration case.
    }

    /// @notice Pull YOUR queued dev-buy refund in `quote` to your own address. `creator` must be the caller.
    ///
    /// @dev AUDIT ROUND 16 (F-2), PRODUCT DECISION -- THE PERMISSIONLESS ENTRY POINT WAS REMOVED ON PURPOSE. This
    /// used to be callable by ANYONE for any creator ("funds always go to `creator`, so a keeper can sweep on their
    /// behalf"). It is not missing and it is not an oversight: a stranger being able to trigger delivery of someone
    /// else's money is the shape EVERY grief found in this file started from, and round 16 measured one that cost
    /// the attacker nothing. Against a quote token that soft-blocks the creator, a bystander could fire this, have
    /// it "succeed", and zero `pendingQuoteRefund` and `reservedOf` while the creator received nothing -- front-
    /// running the very escape hatch {withdrawQuoteRefundTo} documents. Measuring the transfer (below) defeats that
    /// instance; restricting the caller removes the class.
    ///
    /// The convenience given up is small: the creator is already transacting at launch, and a queued refund only
    /// exists because the automatic push inside their own launch failed. No keeper depends on this. DO NOT reopen
    /// it to third parties without re-deciding that trade.
    ///
    /// The `creator` parameter is kept rather than dropped so the ABI and every existing integration keep working;
    /// it is now an assertion about the caller instead of a target.
    ///
    /// @dev NOT the same thing as the push inside {_launch}: that runs in the creator's OWN launch transaction and
    /// stays automatic and non-reverting, so a hostile quote still falls through to this queue instead of bricking
    /// the launch.
    function withdrawQuoteRefund(address creator, address quote) external nonReentrant {
        if (msg.sender != creator) revert NotRefundOwner();
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
        if (to == address(0)) revert ZeroAddress();
        if (to == address(this) || to == address(poolManager)) revert BadRefundDestination();
        uint256 amount = pendingQuoteRefund[creator][quote];
        if (amount == 0) revert NothingToWithdraw();
        pendingQuoteRefund[creator][quote] = 0;
        _releaseReserved(quote, amount);
        // Native withdrawal is uncapped (there is no launch to protect); a failure reverts, keeping the claim intact.
        // AUDIT ROUND 16 (F-2): UNMEASURED BY DESIGN, for the same reason as the native branch of {_pushRefund} --
        // a native send has no return word to lie with, so `ok` is the EVM's own verdict and a balance comparison
        // would only add a forced-send false negative. The revert below is the measurement.
        if (quote == address(0)) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) revert RefundWithdrawFailed();
        } else {
            // AUDIT ROUND 16 (F-2, Medium). MEASURE, and revert on a silent no-op. This was the one ledger the
            // round-15 sender-side sweep never reached. `safeTransfer` catches a HARD blocklist -- it reverts and the
            // zeroing above rolls back, which is what the native branch reasons about explicitly -- but it cannot
            // catch the SOFT variant that returns true and moves nothing.
            //
            // And {withdrawQuoteRefund} is PERMISSIONLESS, so it was zero-cost grief that front-ran the documented
            // recovery path: a bystander calls it against a soft-frozen creator, it "succeeds", emits
            // {QuoteRefundWithdrawn}, the creator receives 0, and `pendingQuoteRefund` and `reservedOf` both go to
            // zero -- after which the creator's own `withdrawQuoteRefundTo(quote, backupWallet)`, the escape hatch
            // this contract documents "for a creator address the quote token has frozen", reverts
            // `NothingToWithdraw`. Measured at 7e18. The money became unreserved surplus reachable only by
            // owner/admin `rescue`.
            //
            // Reverting restores the claim, so the grief fails and the real escape hatch still works. A genuine
            // fee-on-transfer quote debits in full and is unaffected: the fee left, and it is not ours to re-credit.
            if (!_sendMeasured(quote, to, amount)) revert RefundWithdrawFailed();
        }
        emit QuoteRefundWithdrawn(creator, quote, amount);
    }

    /// @dev Accepts native ETH only from the PoolManager (takes of dev-buy leftovers and native fees). Value can
    /// still be forced in (e.g. SELFDESTRUCT), so no bound may rely on `address(this).balance` alone.
    receive() external payable {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
    }

    /// @dev The OUTBOUND twin of {_takeMeasured}: transfer `amount` of `token` out and report whether this locker's
    /// own balance actually fell. `safeTransfer` already reverts on a HARD failure; this catches the SOFT one -- a
    /// token that returns `true` and moves nothing -- which no return word can be trusted to reveal.
    ///
    /// AUDIT ROUND 16 (F-2, Medium). ONE helper, deliberately: the round-15 rule ("when you deliver value, measure
    /// the SENDER's decrease") was missed here precisely because it lived as a hand-copied idiom at each site rather
    /// than as a thing you call. Every ERC20 exit in this file that is allowed to revert goes through this. The one
    /// exit that is NOT allowed to revert -- {_pushRefund}, which must survive a hostile token to reach the pull
    /// queue -- does the same comparison around a gas-capped raw call, and says so there.
    ///
    /// Reports rather than reverts so each caller raises its own error; a fee-on-transfer token still debits us in
    /// full, so only a transfer that moved nothing at all is reported false.
    function _sendMeasured(address token, address to, uint256 amount) internal returns (bool moved) {
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, amount);
        moved = IERC20(token).balanceOf(address(this)) < before;
    }

    /// @dev `take` one currency into this locker and return what actually arrived (balance delta), never the amount
    /// asked for. Saturates at zero so a fee-on-transfer or rebasing currency that shrinks our balance cannot brick a
    /// seed. Survived the round-12 removal of compounding because {_seed} takes the dev-buy leg through it too.
    function _takeMeasured(Currency cur, uint256 amount) internal returns (uint256 received) {
        if (amount == 0) return 0;
        address t = Currency.unwrap(cur);
        uint256 before = t == address(0) ? address(this).balance : IERC20(t).balanceOf(address(this));
        cur.take(poolManager, address(this), amount, false);
        uint256 aft = t == address(0) ? address(this).balance : IERC20(t).balanceOf(address(this));
        received = aft > before ? aft - before : 0;
    }

    // AUDIT ROUND 13 (informational): the vendored LiquidityAmounts subset (`_liquidityForAmount0`,
    // `_liquidityForAmount1`, `_liquidityForAmounts`) is gone. Its only callers were each other -- the last real one
    // was `_compound`, removed in round 12 with compounding. `Q96` and the `Pool`, `FullMath` and `StateLibrary`
    // imports went with it.

    // ─────────────────────────── rescue ───────────────────────────

    /// @dev V4's `Lock` unlocked-flag transient slot, read the same way {RealmAnyPairsTaxHookPairImmutable} reads it.
    bytes32 internal constant V4_IS_UNLOCKED_SLOT_R96 = 0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23;

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
        if (to == address(0) || to == address(this) || to == address(poolManager)) revert BadRefundDestination();
        if (_managerUnlockedR96()) revert RescueWhileUnlocked();
        uint256 avail = availableOf(token);
        if (amount == 0 || amount > avail) revert RescueExceedsAvailable(amount, avail);
        // AUDIT ROUND 16 (F-2): DELIBERATELY UNMEASURED, both branches. `rescue` is an owner/admin action over
        // SURPLUS ONLY -- it is bounded by {availableOf}, so by construction it can never touch a queued refund or
        // any other ledgered claim, and there is no per-claimant accounting for a soft-blocked transfer to corrupt.
        // Nothing is zeroed here that a silent no-op could destroy: a rescue that moves nothing simply leaves the
        // surplus where it was, and the admin can observe that and retry elsewhere. Adding a revert-on-zero would
        // only take away the admin's ability to probe. Do not "fix" this to match the refund paths.
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert RescueFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit Rescued(token, to, amount);
    }
}
