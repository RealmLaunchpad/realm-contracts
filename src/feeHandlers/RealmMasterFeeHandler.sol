// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRealmMasterFeeHandler} from "src/interfaces/IRealmMasterFeeHandler.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {TokenFeeConfigLib} from "src/libraries/TokenFeeConfigLib.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";

/// @title RealmMasterFeeHandler
/// @notice Unified singleton fee handler for all Realm tokens. Supports single and multi-receiver
///         configs with optional synchronous ETH forwarding (direct fees) per receiver.
///
///         All ETH enters through `depositFees` — there is no `receive()` fallback and no excess
///         ETH can accumulate. Every wei is attributed to a specific token at arrival.
///
///         Two recipient classes coexist:
///           - **direct** recipients have their slice forwarded synchronously on every `depositFees`,
///             with the `.call` gas-capped at `DIRECT_FORWARD_GAS` to bound griefing on swappers.
///             Failed forwards (including out-of-gas inside the receiver) fall back to per-account
///             pending claims so a hostile receiver cannot DoS swap or graduation hot paths.
///           - **claimable** recipients accumulate ETH via a per-token cumulative accumulator
///             (`ethPerBps`) that scales O(1) per deposit regardless of recipient count.
///
///         The direct-receiver set is mutable via `setShares` (admin or token-owner gated).
contract RealmMasterFeeHandler is IRealmMasterFeeHandler, Ownable2Step, ReentrancyGuardTransient {
    using TokenFeeConfigLib for TokenFeeConfigLib.Config;
    using SafeERC20 for IERC20;

    uint256 internal constant BPS_TOTAL = 10_000;
    uint256 internal constant PRECISION = 1e18;
    /// @notice Hard cap on direct receivers per token, enforced on every `_setSharesInternal` call.
    ///         Bounds per-deposit gas in `_depositSplit` (one external `.call` per direct receiver).
    uint256 internal constant MAX_DIRECT_RECEIVERS = 4;
    /// @notice Hard cap on total fee receivers per token (direct + claimable). Bounds the O(n²)
    ///         duplicate-check in `_requireNoDuplicates` and the linear loops in `_setSharesInternal`.
    uint256 internal constant MAX_FEE_RECEIVERS = 32;
    /// @notice Gas forwarded to a direct receiver's `.call` in `_depositSingle` / `_depositSplit`.
    ///         Caps griefing on swappers if a malicious receiver burns gas on `receive`. Failures
    ///         (including out-of-gas inside the receiver) fall back to per-account pending claims,
    ///         so legitimate receivers needing more gas can still recover via `claim`.
    uint256 internal constant DIRECT_FORWARD_GAS = 100_000;
    /// @notice Gas forwarded to a direct receiver's ERC20 `transfer`. Far larger than the native
    ///         stipend for the same reason `DividendDistribution.ASSET_PAYOUT_GAS` is: the asset is a
    ///         pool's quote currency, not something this protocol vets, so a token whose `transfer`
    ///         burns unbounded gas must return `false` here rather than take the swap down. Sized to be
    ///         unreachable by any honest ERC20 — a bomb bound, not an eligibility gate.
    uint256 internal constant DIRECT_FORWARD_GAS_ASSET = 400_000;
    /// @notice Max distinct assets one token may ever be paid in. A ceiling on the `setShares` snapshot
    ///         loop, which must visit every one of them. Comfortably above `MAX_PAIRS + 1` (its real
    ///         bound: a token only accrues in the quotes it registered, plus native).
    uint256 internal constant MAX_FEE_ASSETS = 8;

    mapping(address token => TokenFeeConfigLib.Config) internal _configs;

    /// @notice BPS share for every recipient (direct and claimable alike). `isDirectReceiver`
    ///         distinguishes the two classes.
    mapping(address token => mapping(address account => uint256)) internal _sharesBpsOf;

    /// @notice True iff `account` is currently a direct receiver for `token`.
    mapping(address token => mapping(address account => bool)) public isDirectReceiver;

    /// @notice Cumulative amount deposited per bps of claimable share, PER ASSET. `address(0)` is
    ///         native; anything else is the ERC20 a token's pool is quoted in.
    /// @dev Lives here rather than on the config because it is the one piece of per-token fee state
    ///      that is also per-ASSET. A token launched against several quotes earns in several
    ///      currencies, and each one needs its own accumulator or a claim in one would draw on
    ///      another's balance.
    mapping(address token => mapping(address asset => uint256)) internal _accPerBps;

    /// @notice Snapshot of `_accPerBps[token][asset]` at the time of the account's last claim
    ///         or share update. Used in the claimable accumulator formula.
    mapping(address token => mapping(address asset => mapping(address account => uint256))) internal _claimedPerBps;

    /// @notice Residual claimable amount for an account, per asset: carried over from share updates
    ///         (claimable recipients) or from failed direct forwards (direct recipients).
    mapping(address token => mapping(address asset => mapping(address account => uint256))) internal _pendingClaims;

    /// @notice True once `asset` has been recorded in `_configs[token].assets`. Keeps the first-payment
    ///         bookkeeping O(1) instead of scanning the array on every deposit.
    mapping(address token => mapping(address asset => bool)) internal _assetSeen;

    constructor() Ownable(msg.sender) {}

    ////////////////////////////// EXTERNAL FUNCTIONS ///////////////////////////////////

    /// @notice Deposits native fees for `token`. For direct receivers the slice is forwarded
    ///         synchronously; for claimable recipients the accumulator is advanced.
    /// @dev `CreatorFeesDeposited` is emitted before any forward attempt for non-zero deposits;
    ///      zero-value calls are no-ops and emit nothing. There is intentionally no explicit
    ///      registration check on this swap-hot path: registered configs always contain at least one
    ///      recipient, while an unregistered positive-value deposit reaches `_depositSingle` and
    ///      reverts with Solidity's array-out-of-bounds panic when reading `claimableRecipients[0]`.
    ///      The transient `nonReentrant` guard is shared with `setShares` and `claim` — any nested
    ///      call from a direct-receiver hook into those functions reverts, which prevents iteration
    ///      corruption in `_depositSplit`.
    function depositFees(address token) external payable nonReentrant {
        if (msg.value == 0) return;
        emit CreatorFeesDeposited(token, msg.value);
        _deposit(token, address(0), msg.value);
    }

    /// @notice Deposits ERC20 fees for `token`, in whichever currency its pool is quoted in. Pulls
    ///         `amount` of `asset` from the caller and splits it by exactly the same rules the native
    ///         path uses, against that asset's own accumulator.
    /// @dev ONLY THE TOKEN MAY CALL THIS, unlike the native `depositFees` above, which is deliberately
    ///      permissionless (a caller there is splitting their own ETH and nothing is at risk). Here the
    ///      asset becomes a permanent entry in the token's `assets` list, which `setShares` must walk;
    ///      leaving it open would let anyone stuff that list with worthless tokens until a share update
    ///      no longer fits in a block. The token is also the only caller that knows which quotes it is
    ///      actually registered for. The LP-fee router and the hook reach this the same way they reach
    ///      the native path: through the token's own `accrueFees`.
    /// @dev A fee-on-transfer asset delivers less than `amount`; the split is computed on what actually
    ///      ARRIVED, so recipients are never credited with more than this contract holds.
    function depositFees(address token, address asset, uint256 amount) external nonReentrant {
        require(msg.sender == token, Unauthorized());
        require(asset != address(0), InvalidAsset());
        if (amount == 0) return;

        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(asset).balanceOf(address(this)) - balanceBefore;
        if (received == 0) return;

        emit CreatorAssetFeesDeposited(token, asset, received);
        _deposit(token, asset, received);
    }

    /// @dev Shared body of both deposit entry points: record the asset the first time it is seen, then
    ///      forward the direct slices and accumulate the rest.
    function _deposit(address token, address asset, uint256 amount) internal {
        TokenFeeConfigLib.Config storage cfg = _configs[token];

        if (!_assetSeen[token][asset]) {
            require(cfg.assets.length < MAX_FEE_ASSETS, TooManyFeeAssets());
            _assetSeen[token][asset] = true;
            cfg.assets.push(asset);
        }

        if (!cfg.isSplit) {
            _depositSingle(token, cfg, asset, amount);
        } else {
            _depositSplit(token, cfg, asset, amount);
        }
    }

    /// @notice One-shot registration of fee-receiver config for a freshly-deployed token.
    ///         Callable only by the token itself. Factories should call the token's `registerFees`,
    ///         which then self-registers here.
    function registerToken(IRealmFactory.FeeShare[] calldata feeShares) external {
        address token = msg.sender;
        require(token.code.length > 0, Unauthorized());
        require(IRealmToken(token).feeHandler() == address(this), Unauthorized());

        TokenFeeConfigLib.Config storage cfg = _configs[token];
        require(!cfg.isRegistered(), AlreadyRegistered());
        _setSharesInternal(token, cfg, feeShares, false);
    }

    /// @notice Replaces the fee-receiver config for `token`. Callable only by the admin or the
    ///         token's current non-zero owner. V2 tokens and V4 tokens with `renounceOwnership = true`
    ///         have `owner() == address(0)`, so only the admin can update their shares.
    /// @dev `nonReentrant` shares the transient guard with `depositFees` and `claim`; this
    ///      prevents a malicious direct receiver from reentering `setShares` mid-deposit and
    ///      corrupting `_depositSplit`'s iteration over `cfg.directReceivers`.
    function setShares(address token, IRealmFactory.FeeShare[] calldata feeShares) external nonReentrant {
        TokenFeeConfigLib.Config storage cfg = _configs[token];
        require(cfg.isRegistered(), NotRegistered());

        address tokenOwner = IRealmToken(token).owner();
        require(msg.sender == owner() || (msg.sender == tokenOwner), Unauthorized());

        // Snapshotting of accumulated claimable ETH happens inside `_setSharesInternal`'s
        // claimable wipe loop, so no ETH is lost on transitions.
        _setSharesInternal(token, cfg, feeShares, true);
    }

    /// @notice Claims accumulated NATIVE fees for `msg.sender` across the given tokens.
    function claim(address[] calldata tokens) external nonReentrant {
        uint256 total;
        uint256 nTokens = tokens.length;

        for (uint256 i = 0; i < nTokens; i++) {
            address token = tokens[i];
            TokenFeeConfigLib.Config storage cfg = _configs[token];
            if (!cfg.isRegistered()) continue;

            uint256 claimable = _getAndClearClaimable(token, cfg, address(0), msg.sender);
            if (claimable == 0) continue;

            total += claimable;
            emit CreatorClaimed(token, msg.sender, claimable);
        }

        if (total == 0) return;
        _transferEth(msg.sender, total);
    }

    /// @notice Claims accumulated fees for `msg.sender` in ONE ERC20 asset across the given tokens.
    /// @dev One asset per call rather than a matrix: the amounts are summed into a single transfer, and
    ///      a matrix would either need a transfer per asset anyway or an inner loop whose gas nobody can
    ///      bound. `assetsOf(token)` tells a caller which assets a token has paid in.
    function claim(address[] calldata tokens, address asset) external nonReentrant {
        require(asset != address(0), InvalidAsset());
        uint256 total;
        uint256 nTokens = tokens.length;

        for (uint256 i = 0; i < nTokens; i++) {
            address token = tokens[i];
            TokenFeeConfigLib.Config storage cfg = _configs[token];
            if (!cfg.isRegistered()) continue;

            uint256 claimable = _getAndClearClaimable(token, cfg, asset, msg.sender);
            if (claimable == 0) continue;

            total += claimable;
            emit CreatorAssetClaimed(token, asset, msg.sender, claimable);
        }

        if (total == 0) return;
        IERC20(asset).safeTransfer(msg.sender, total);
    }

    ////////////////////////////// VIEW FUNCTIONS ///////////////////////////////////

    /// @notice Returns the pending claimable NATIVE fees for `account` across the given tokens.
    function getClaimable(address[] calldata tokens, address account) external view returns (uint256[] memory amounts) {
        return getClaimable(tokens, address(0), account);
    }

    /// @notice Returns the pending claimable fees in `asset` for `account` across the given tokens.
    ///         `address(0)` is native, reproducing the two-argument overload exactly.
    function getClaimable(address[] calldata tokens, address asset, address account)
        public
        view
        returns (uint256[] memory amounts)
    {
        uint256 nTokens = tokens.length;
        amounts = new uint256[](nTokens);

        for (uint256 i = 0; i < nTokens; i++) {
            address token = tokens[i];
            TokenFeeConfigLib.Config storage cfg = _configs[token];
            if (!cfg.isRegistered()) continue;
            amounts[i] = _claimableView(token, cfg, asset, account);
        }
    }

    /// @notice Every asset `token` has ever been paid fees in, native (`address(0)`) included, in
    ///         first-payment order. What a claimer iterates to find everything it is owed.
    function assetsOf(address token) external view returns (address[] memory) {
        return _configs[token].assets;
    }

    /// @notice Returns all current recipients and their BPS shares for `token`.
    function getRecipients(address token) external view returns (address[] memory, uint256[] memory) {
        TokenFeeConfigLib.Config storage cfg = _configs[token];
        uint256 directLen = cfg.directReceivers.length;
        uint256 claimableLen = cfg.claimableRecipients.length;
        uint256 totalLen = directLen + claimableLen;

        address[] memory addrs = new address[](totalLen);
        uint256[] memory bps = new uint256[](totalLen);

        for (uint256 i = 0; i < directLen; i++) {
            address dr = cfg.directReceivers[i];
            addrs[i] = dr;
            bps[i] = _sharesBpsOf[token][dr];
        }
        for (uint256 i = 0; i < claimableLen; i++) {
            address cr = cfg.claimableRecipients[i];
            addrs[directLen + i] = cr;
            bps[directLen + i] = _sharesBpsOf[token][cr];
        }

        return (addrs, bps);
    }

    /// @notice Returns the current direct-receiver addresses for `token`.
    function getDirectReceivers(address token) external view returns (address[] memory) {
        return _configs[token].directReceivers;
    }

    ///////////////////////// INTERNAL //////////////////////////

    /// @dev Single-receiver deposit path. Either forwards directly or credits pending claims.
    ///      Branches on `totalDirectBps` (warm slot — packed with `isSplit` already read in
    ///      `_deposit`) instead of `directReceivers.length` to avoid a cold SLOAD.
    function _depositSingle(address token, TokenFeeConfigLib.Config storage cfg, address asset, uint256 amount)
        internal
    {
        if (cfg.totalDirectBps > 0) {
            address receiver = cfg.directReceivers[0];
            if (_forwardDirect(token, asset, receiver, amount)) return;
            _pendingClaims[token][asset][receiver] += amount;
        } else {
            _pendingClaims[token][asset][cfg.claimableRecipients[0]] += amount;
        }
    }

    /// @dev Multi-receiver deposit path. Forwards direct slices and accumulates the rest.
    function _depositSplit(address token, TokenFeeConfigLib.Config storage cfg, address asset, uint256 amount)
        internal
    {
        uint256 directAmountTotal;

        uint256 directLen = cfg.directReceivers.length;
        for (uint256 i = 0; i < directLen; i++) {
            address dr = cfg.directReceivers[i];
            uint256 directAmount = (amount * _sharesBpsOf[token][dr]) / BPS_TOTAL;
            directAmountTotal += directAmount;
            if (directAmount == 0) continue;

            if (!_forwardDirect(token, asset, dr, directAmount)) {
                _pendingClaims[token][asset][dr] += directAmount;
            }
        }

        uint256 claimableBpsTot = cfg.claimableBpsTotal();
        if (claimableBpsTot > 0) {
            uint256 toAccumulate = amount - directAmountTotal;
            _accPerBps[token][asset] += (toAccumulate * PRECISION) / claimableBpsTot;
        }
    }

    /// @dev One direct receiver's synchronous payout, in whichever currency the deposit arrived in.
    ///      Reports failure instead of reverting — a hostile or merely expensive receiver must never be
    ///      able to take down a swap — and the caller books the slice as a pending claim instead.
    /// @dev The ERC20 leg is a RAW gas-capped `call` with a one-word output window, not
    ///      `SafeERC20.safeTransfer`: `safeTransfer` reverts on failure, which is exactly what this
    ///      function exists not to do, and the capped window keeps an asset that expands memory before
    ///      returning from making the copy unaffordable. The success test is `SafeERC20`'s minus the
    ///      revert: empty returndata is success (non-standard ERC20s), and a return too short to decode
    ///      is failure rather than a panic.
    function _forwardDirect(address token, address asset, address receiver, uint256 amount) internal returns (bool ok) {
        if (asset == address(0)) {
            (ok,) = receiver.call{value: amount, gas: DIRECT_FORWARD_GAS}("");
            if (ok) emit CreatorClaimed(token, receiver, amount);
            return ok;
        }

        bytes memory payload = abi.encodeCall(IERC20.transfer, (receiver, amount));
        uint256 size;
        uint256 word;
        assembly ("memory-safe") {
            mstore(0, 0)
            ok := call(DIRECT_FORWARD_GAS_ASSET, asset, 0, add(payload, 32), mload(payload), 0, 32)
            size := returndatasize()
            word := mload(0)
        }
        ok = ok && (size == 0 || (size >= 32 && word != 0));
        if (ok) emit CreatorAssetClaimed(token, asset, receiver, amount);
    }

    /// @dev Returns and clears all claimable `asset` for `account` on `token`.
    function _getAndClearClaimable(address token, TokenFeeConfigLib.Config storage cfg, address asset, address account)
        internal
        returns (uint256 claimable)
    {
        if (isDirectReceiver[token][account]) {
            claimable = _pendingClaims[token][asset][account];
            _pendingClaims[token][asset][account] = 0;
        } else {
            claimable = _accruedClaimableFor(token, cfg, asset, account) + _pendingClaims[token][asset][account];
            _claimedPerBps[token][asset][account] = _accPerBps[token][asset];
            _pendingClaims[token][asset][account] = 0;
        }
    }

    /// @dev View counterpart of `_getAndClearClaimable` — no state mutation.
    function _claimableView(address token, TokenFeeConfigLib.Config storage cfg, address asset, address account)
        internal
        view
        returns (uint256)
    {
        if (isDirectReceiver[token][account]) {
            return _pendingClaims[token][asset][account];
        }
        return _accruedClaimableFor(token, cfg, asset, account) + _pendingClaims[token][asset][account];
    }

    /// @dev Accumulator-based claimable for a claimable (non-direct) account, in one asset.
    function _accruedClaimableFor(
        address token,
        TokenFeeConfigLib.Config storage, /* cfg */
        address asset,
        address account
    )
        internal
        view
        returns (uint256)
    {
        return
            (_accPerBps[token][asset] - _claimedPerBps[token][asset][account]) * _sharesBpsOf[token][account]
                / PRECISION;
    }

    /// @dev Banks every current claimable recipient's accumulator-based accrual into `_pendingClaims`,
    ///      for EVERY asset the token has been paid in. Its own function only because inlining it in
    ///      `_setSharesInternal` puts that function over the stack limit without `via_ir`.
    /// @dev `_claimedPerBps` is deliberately left stale afterwards: the caller zeroes `_sharesBpsOf`,
    ///      which zeroes the accumulator term, so a recipient re-added by the same update starts from
    ///      the fresh checkpoint `_populateNewShares` writes and never double-earns.
    function _snapshotClaimables(address token, TokenFeeConfigLib.Config storage cfg) private {
        address[] memory seenAssets = cfg.assets;
        uint256 nRecipients = cfg.claimableRecipients.length;
        for (uint256 a = 0; a < seenAssets.length; a++) {
            address asset = seenAssets[a];
            uint256 cachedAccPerBps = _accPerBps[token][asset];
            for (uint256 i = 0; i < nRecipients; i++) {
                address r = cfg.claimableRecipients[i];
                _pendingClaims[token][asset][r] += (cachedAccPerBps - _claimedPerBps[token][asset][r])
                    * _sharesBpsOf[token][r] / PRECISION;
            }
        }
    }

    /// @dev Rebuilds the per-token config from `feeShares`. When `isUpdate = true`, wipes previous
    ///      per-account state and emits diff-style direct-set events before the final `SharesUpdated`.
    function _setSharesInternal(
        address token,
        TokenFeeConfigLib.Config storage cfg,
        IRealmFactory.FeeShare[] calldata feeShares,
        bool isUpdate
    ) internal {
        uint256 len = feeShares.length;
        require(len > 0, InvalidFeeShares());
        require(len <= MAX_FEE_RECEIVERS, TooManyFeeReceivers());
        _requireNoDuplicates(feeShares);

        address[] memory oldDirects;

        if (isUpdate) {
            // Capture old direct set for diff events before wiping.
            oldDirects = cfg.directReceivers;

            // Wipe claimable per-account state, snapshotting accumulator-based accrual into pending
            // first so removals keep their residue (and re-registered recipients don't double-earn).
            // Across EVERY asset the token has been paid in, not just native: a recipient dropped here
            // keeps whatever it accrued in each of them, and one left out would silently lose that
            // asset's accrual. `cfg.assets` is what makes the set knowable — see its docstring.
            _snapshotClaimables(token, cfg);
            uint256 oldClaimableLen = cfg.claimableRecipients.length;
            for (uint256 i = 0; i < oldClaimableLen; i++) {
                delete _sharesBpsOf[token][cfg.claimableRecipients[i]];
            }
            delete cfg.claimableRecipients;

            // Wipe direct per-account state.
            uint256 oldDirectLen = oldDirects.length;
            for (uint256 i = 0; i < oldDirectLen; i++) {
                address r = oldDirects[i];
                delete _sharesBpsOf[token][r];
                delete isDirectReceiver[token][r];
            }
            // A direct receiver's residue lives in `_pendingClaims`, which is never wiped, so nothing
            // has to be snapshotted for them here — in any asset.
            delete cfg.directReceivers;
        }

        // Build new config (extracted to reduce stack depth).
        (address[] memory newRecipients, uint256[] memory newShares) = _populateNewShares(token, cfg, feeShares, len);

        cfg.isSplit = len > 1;

        // Diff-style direct-set events (only on updates).
        if (isUpdate) {
            uint256 oldDirectLen = oldDirects.length;

            // Removals: old direct whose new isDirectReceiver entry is false.
            for (uint256 i = 0; i < oldDirectLen; i++) {
                if (!isDirectReceiver[token][oldDirects[i]]) {
                    emit DirectReceiverRemoved(token, oldDirects[i]);
                }
            }

            // Additions: new direct that wasn't in the old set.
            for (uint256 i = 0; i < len; i++) {
                if (!feeShares[i].directFeesEnabled) continue;
                address acc = feeShares[i].account;
                bool wasDirectBefore;
                for (uint256 j = 0; j < oldDirectLen; j++) {
                    if (oldDirects[j] == acc) {
                        wasDirectBefore = true;
                        break;
                    }
                }
                if (!wasDirectBefore) {
                    emit DirectReceiverRegistered(token, acc);
                }
            }
        } else {
            // At init: emit DirectReceiverRegistered for every direct entry.
            for (uint256 i = 0; i < len; i++) {
                if (feeShares[i].directFeesEnabled) {
                    emit DirectReceiverRegistered(token, feeShares[i].account);
                }
            }
        }

        emit SharesUpdated(token, newRecipients, newShares);
    }

    /// @dev Populates per-account mappings and config arrays from `feeShares`. Separated from
    ///      `_setSharesInternal` to avoid a stack-too-deep error in that function.
    function _populateNewShares(
        address token,
        TokenFeeConfigLib.Config storage cfg,
        IRealmFactory.FeeShare[] calldata feeShares,
        uint256 len
    ) private returns (address[] memory recipients, uint256[] memory shares) {
        recipients = new address[](len);
        shares = new uint256[](len);
        uint256 total;
        uint256 directSum;

        for (uint256 i = 0; i < len; i++) {
            address acc = feeShares[i].account;
            uint256 sh = feeShares[i].shares;
            require(acc != address(0), InvalidFeeShares());
            require(sh > 0, InvalidShares());

            recipients[i] = acc;
            shares[i] = sh;
            total += sh;

            _sharesBpsOf[token][acc] = sh;

            if (feeShares[i].directFeesEnabled) {
                isDirectReceiver[token][acc] = true;
                cfg.directReceivers.push(acc);
                directSum += sh;
            } else {
                cfg.claimableRecipients.push(acc);
                _checkpointNewClaimable(token, cfg, acc);
            }
        }
        require(total == BPS_TOTAL, InvalidShares());
        require(cfg.directReceivers.length <= MAX_DIRECT_RECEIVERS, TooManyDirectReceivers());
        // Safe cast: `directSum <= total == BPS_TOTAL == 10_000`, fits in uint16.
        cfg.totalDirectBps = uint16(directSum);
    }

    /// @dev Starts an incoming claimable recipient at the CURRENT accumulator of every asset the token
    ///      has been paid in, so it earns from this update forward and not out of a history it was not
    ///      part of. A token that has never been paid — always the case at `registerToken` — writes
    ///      nothing, which is what keeps a fresh token's registration free of cold 0→0 writes.
    ///      Its own function for the same stack reason as `_snapshotClaimables`.
    function _checkpointNewClaimable(address token, TokenFeeConfigLib.Config storage cfg, address account) private {
        address[] memory seenAssets = cfg.assets;
        for (uint256 a = 0; a < seenAssets.length; a++) {
            uint256 acc = _accPerBps[token][seenAssets[a]];
            if (acc != 0) _claimedPerBps[token][seenAssets[a]][account] = acc;
        }
    }

    /// @dev Reverts if any two `feeShares` entries share the same `account`.
    function _requireNoDuplicates(IRealmFactory.FeeShare[] calldata feeShares) internal pure {
        uint256 len = feeShares.length;
        for (uint256 i = 0; i < len; i++) {
            for (uint256 j = i + 1; j < len; j++) {
                require(feeShares[i].account != feeShares[j].account, InvalidFeeShares());
            }
        }
    }

    /// @dev Transfers ETH to `recipient`, reverting on failure.
    function _transferEth(address recipient, uint256 amount) internal {
        if (amount == 0) return;
        (bool success,) = recipient.call{value: amount}("");
        require(success, EthTransferFailed());
    }
}
