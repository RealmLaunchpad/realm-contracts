// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRealmMasterFeeHandler} from "src/interfaces/IRealmMasterFeeHandler.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {TokenFeeConfigLib} from "src/libraries/TokenFeeConfigLib.sol";
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

    mapping(address token => TokenFeeConfigLib.Config) internal _configs;

    /// @notice BPS share for every recipient (direct and claimable alike). `isDirectReceiver`
    ///         distinguishes the two classes.
    mapping(address token => mapping(address account => uint256)) internal _sharesBpsOf;

    /// @notice True iff `account` is currently a direct receiver for `token`.
    mapping(address token => mapping(address account => bool)) public isDirectReceiver;

    /// @notice Snapshot of `_configs[token].ethPerBps` at the time of the account's last claim
    ///         or share update. Used in the claimable accumulator formula.
    mapping(address token => mapping(address account => uint256)) internal _claimedPerBps;

    /// @notice Residual claimable ETH for an account: carried over from share updates
    ///         (claimable recipients) or from failed direct forwards (direct recipients).
    mapping(address token => mapping(address account => uint256)) internal _pendingClaims;

    constructor() Ownable(msg.sender) {}

    ////////////////////////////// EXTERNAL FUNCTIONS ///////////////////////////////////

    /// @notice Deposits ETH fees for `token`. For direct receivers the slice is forwarded
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
        TokenFeeConfigLib.Config storage cfg = _configs[token];

        if (msg.value == 0) return;
        emit CreatorFeesDeposited(token, msg.value);

        if (!cfg.isSplit) {
            _depositSingle(token, cfg);
        } else {
            _depositSplit(token, cfg);
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

    /// @notice Claims accumulated ETH fees for `msg.sender` across the given tokens.
    function claim(address[] calldata tokens) external nonReentrant {
        uint256 total;
        uint256 nTokens = tokens.length;

        for (uint256 i = 0; i < nTokens; i++) {
            address token = tokens[i];
            TokenFeeConfigLib.Config storage cfg = _configs[token];
            if (!cfg.isRegistered()) continue;

            uint256 claimable = _getAndClearClaimable(token, cfg, msg.sender);
            if (claimable == 0) continue;

            total += claimable;
            emit CreatorClaimed(token, msg.sender, claimable);
        }

        if (total == 0) return;
        _transferEth(msg.sender, total);
    }

    ////////////////////////////// VIEW FUNCTIONS ///////////////////////////////////

    /// @notice Returns the pending claimable ETH for `account` across the given tokens.
    function getClaimable(address[] calldata tokens, address account) external view returns (uint256[] memory amounts) {
        uint256 nTokens = tokens.length;
        amounts = new uint256[](nTokens);

        for (uint256 i = 0; i < nTokens; i++) {
            address token = tokens[i];
            TokenFeeConfigLib.Config storage cfg = _configs[token];
            if (!cfg.isRegistered()) continue;
            amounts[i] = _claimableView(token, cfg, account);
        }
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
    ///      `depositFees`) instead of `directReceivers.length` to avoid a cold SLOAD.
    function _depositSingle(address token, TokenFeeConfigLib.Config storage cfg) internal {
        if (cfg.totalDirectBps > 0) {
            address receiver = cfg.directReceivers[0];
            (bool ok,) = receiver.call{value: msg.value, gas: DIRECT_FORWARD_GAS}("");
            if (ok) {
                emit CreatorClaimed(token, receiver, msg.value);
                return;
            }
            _pendingClaims[token][receiver] += msg.value;
        } else {
            _pendingClaims[token][cfg.claimableRecipients[0]] += msg.value;
        }
    }

    /// @dev Multi-receiver deposit path. Forwards direct slices and accumulates the rest.
    function _depositSplit(address token, TokenFeeConfigLib.Config storage cfg) internal {
        uint256 directAmountTotal;

        uint256 directLen = cfg.directReceivers.length;
        for (uint256 i = 0; i < directLen; i++) {
            address dr = cfg.directReceivers[i];
            uint256 directAmount = (msg.value * _sharesBpsOf[token][dr]) / BPS_TOTAL;
            directAmountTotal += directAmount;
            if (directAmount == 0) continue;

            (bool ok,) = dr.call{value: directAmount, gas: DIRECT_FORWARD_GAS}("");
            if (ok) {
                emit CreatorClaimed(token, dr, directAmount);
            } else {
                _pendingClaims[token][dr] += directAmount;
            }
        }

        uint256 claimableBpsTot = cfg.claimableBpsTotal();
        if (claimableBpsTot > 0) {
            uint256 toAccumulate = msg.value - directAmountTotal;
            cfg.ethPerBps += (toAccumulate * PRECISION) / claimableBpsTot;
        }
    }

    /// @dev Returns and clears all claimable ETH for `account` on `token`.
    function _getAndClearClaimable(address token, TokenFeeConfigLib.Config storage cfg, address account)
        internal
        returns (uint256 claimable)
    {
        if (isDirectReceiver[token][account]) {
            claimable = _pendingClaims[token][account];
            _pendingClaims[token][account] = 0;
        } else {
            claimable = _accruedClaimableFor(token, cfg, account) + _pendingClaims[token][account];
            _claimedPerBps[token][account] = cfg.ethPerBps;
            _pendingClaims[token][account] = 0;
        }
    }

    /// @dev View counterpart of `_getAndClearClaimable` — no state mutation.
    function _claimableView(address token, TokenFeeConfigLib.Config storage cfg, address account)
        internal
        view
        returns (uint256)
    {
        if (isDirectReceiver[token][account]) {
            return _pendingClaims[token][account];
        }
        return _accruedClaimableFor(token, cfg, account) + _pendingClaims[token][account];
    }

    /// @dev Accumulator-based claimable for a claimable (non-direct) account.
    function _accruedClaimableFor(address token, TokenFeeConfigLib.Config storage cfg, address account)
        internal
        view
        returns (uint256)
    {
        return (cfg.ethPerBps - _claimedPerBps[token][account]) * _sharesBpsOf[token][account] / PRECISION;
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
            // `cfg.ethPerBps` is cached once outside the loop to avoid re-reading the storage slot.
            uint256 cachedEthPerBps = cfg.ethPerBps;
            uint256 oldClaimableLen = cfg.claimableRecipients.length;
            for (uint256 i = 0; i < oldClaimableLen; i++) {
                address r = cfg.claimableRecipients[i];
                _pendingClaims[token][r] += (cachedEthPerBps - _claimedPerBps[token][r]) * _sharesBpsOf[token][r]
                    / PRECISION;
                delete _sharesBpsOf[token][r];
                // _claimedPerBps[token][r] is stale but harmless: sharesBps==0 zeroes the accumulator term.
            }
            delete cfg.claimableRecipients;

            // Wipe direct per-account state.
            uint256 oldDirectLen = oldDirects.length;
            for (uint256 i = 0; i < oldDirectLen; i++) {
                address r = oldDirects[i];
                delete _sharesBpsOf[token][r];
                delete isDirectReceiver[token][r];
            }
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
        // Cache `cfg.ethPerBps` once: read N times by the loop otherwise. Also lets us skip the
        // SSTORE entirely when zero (which is always the case at `registerToken`, and avoids a
        // wasted cold 0→0 write per claimable on init).
        uint256 cachedEthPerBps = cfg.ethPerBps;

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
                if (cachedEthPerBps != 0) {
                    _claimedPerBps[token][acc] = cachedEthPerBps;
                }
            }
        }
        require(total == BPS_TOTAL, InvalidShares());
        require(cfg.directReceivers.length <= MAX_DIRECT_RECEIVERS, TooManyDirectReceivers());
        // Safe cast: `directSum <= total == BPS_TOTAL == 10_000`, fits in uint16.
        cfg.totalDirectBps = uint16(directSum);
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
