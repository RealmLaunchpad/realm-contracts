// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Immutable, fixed-supply ERC20: no mint, no burn, no owner. All supply is minted once to the launcher.
//
// Optional restrictions:
//   * MAX WALLET, if the creator opted in at launch: caps any single EOA's holdings until a timestamp fixed
//     in the constructor. Off by default; a coin without it costs one immutable read per transfer.
//   * Holder rewards can be switched on post-launch, once, by the tax hook's admin ({attachTracker}).
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IRealmAnyPairsLauncherBase {
    function baseTokenURI() external view returns (string memory);
}

/// @dev The launcher's V4 tax hook pointer, read once at construction. See {RealmAnyPairsTokenPlain.rewardsHook}.
interface IRealmAnyPairsLauncherHook {
    function pairTaxHook() external view returns (address);
}

/// @dev The hook's admin key. Unlike `owner`, it survives `renounceOwnership()`, which is why
/// {RealmAnyPairsTokenPlain.attachTracker} is gated on it.
interface IRealmAnyPairsHookAdmin {
    function admin() external view returns (address);
}

/// @dev Identical to {RealmAnyPairsTokenDividend}'s copy, so a coin that turns rewards on behaves exactly like
/// one that launched with them.
interface IDividendTracker {
    function setBalance(address account, uint256 newBalance) external;
    function process(uint256 gasBudget) external returns (uint256);
}

/// @dev Reports the gas a tracker's {setBalance} needs. See {RealmAnyPairsTokenDividend.trackerSyncGas}.
interface IBalanceSyncGas {
    function balanceSyncGas() external view returns (uint256);
}

contract RealmAnyPairsTokenPlain is ERC20 {
    using SafeERC20 for IERC20;

    address public immutable launcher;
    address public immutable creator;

    /// @notice The holder-rewards tracker notified on every transfer, or `address(0)` (the launch default).
    /// @dev Write-once: no detach or re-point, since the tracker owns holders' accrued rewards. While zero,
    /// the rewards path costs one SLOAD and none of the mandatory-debit gas floor applies.
    address public tracker;

    /// @notice Stipend forwarded to `tracker.setBalance`, read from the tracker at {attachTracker}.
    /// Zero means the flat {SET_BALANCE_GAS} constants apply.
    /// @dev Packed into {tracker}'s slot so the transfer path reads both with one SLOAD.
    uint96 public trackerSyncGas;

    /// @notice The most any ONE address may hold while the cap is live, in token units. Zero = no cap.
    uint256 public immutable maxWallet;

    /// @notice Wallets named at launch that the max-wallet cap does not apply to (buys and transfers alike).
    /// Set once in the constructor; no setter.
    mapping(address => bool) public maxWalletExempt;

    /// @notice Unix time at which {maxWallet} stops being enforced, forever. Cannot be extended or re-armed.
    /// @dev Derived from a duration rather than passed in: constructor args are part of the CREATE2 init-code
    /// hash, so an absolute timestamp would make the vanity-mined address unpredictable.
    uint40 public immutable maxWalletUntil;

    /// @notice The launcher's LP locker (`lpLocker()`, read at construction). Transfers FROM it inside the
    /// deploying transaction (the dev-buy payout) skip the max-wallet cap. Zero disables the exemption.
    /// @dev Read by raw staticcall: a typed call to a codeless launcher would revert in this frame.
    address public immutable devBuySource;

    /// @notice The V4 tax hook this coin launched under, snapshotted from {launcher} at construction. Its
    /// live `admin` is the only key that may call {attachTracker}. Zero disables {attachTracker} permanently.
    /// @dev Snapshotted per coin because the launcher's hook pointer is mutable; the admin is read at call
    /// time so hook admin rotations keep working.
    address public immutable rewardsHook;

    // ── gas constants for the rewards path. Copied from {RealmAnyPairsTokenDividend} (see there); they must
    // not drift, so a coin that turns rewards on behaves exactly like one that launched with them.
    uint256 private constant SET_BALANCE_GAS = 230_000;
    uint256 private constant MIN_NOTIFY_GAS = 175_000;
    uint256 private constant MIN_DEBIT_GAS = 250_000;
    uint256 private constant PROCESS_GAS = 300_000;
    uint256 private constant PROCESS_BUDGET = 200_000;
    uint256 private constant PROCESS_FLOOR = 400_000;
    uint256 private constant MAX_TRACKER_SYNC_GAS = 1_100_000;

    /// @notice The smallest total supply that may ever be given a rewards tracker.
    /// @dev Overflow bound for the trackers' magnified per-share arithmetic; matches the launcher's check on
    /// rewards launches.
    uint256 public constant MIN_REWARDS_TOTAL_SUPPLY = 1e9;

    error MaxWalletExceeded();
    /// @dev Caller is not the hook's live `admin`, or the hook reports `admin == address(0)`.
    error NotHookAdmin();
    /// @dev No hook was recorded at construction, or the admin read failed. Fail-closed.
    error RewardsHookUnavailable();
    error TrackerAlreadySet();
    error ZeroTracker();
    /// @dev The tracker has code but did not report {IBalanceSyncGas.balanceSyncGas}.
    error TrackerSyncGasUnavailable();
    /// @notice The tracker address has no code. Refused because {_update}'s typed calls to a codeless
    /// tracker would revert every transfer forever.
    error TrackerCodeless();
    /// @dev Supply below {MIN_REWARDS_TOTAL_SUPPLY}.
    error SupplyTooSmallForRewards();
    error InsufficientGasForBalanceSync();

    /// @notice Holder rewards were switched on for this coin, permanently.
    event TrackerAttached(address indexed tracker, address indexed by);
    /// @notice What {attachTracker} read out of the tracker, and what it stored (0 = the flat constants).
    event TrackerSyncGasRead(address indexed tracker, uint256 reported, uint256 stored);

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 totalSupply_,
        address launcher_,
        address creator_,
        uint256 maxWallet_,
        uint32 maxWalletSecs_,
        address[] memory exempt_
    ) ERC20(name_, symbol_) {
        require(totalSupply_ > 0, "supply=0");
        require(launcher_ != address(0), "launcher=0");
        launcher = launcher_;
        creator = creator_;
        // Bounds are validated by the launcher; here we only require the cap and its duration to come together.
        require((maxWallet_ == 0) == (maxWalletSecs_ == 0), "maxwallet pair");
        maxWallet = maxWallet_;
        maxWalletUntil = maxWalletSecs_ == 0 ? 0 : uint40(block.timestamp + maxWalletSecs_);
        // Mark the deploying transaction so the dev-buy payout is exempt from the cap. See {_LAUNCH_TX_SLOT}.
        bytes32 launchSlot = _LAUNCH_TX_SLOT;
        assembly ("memory-safe") { tstore(launchSlot, 1) }
        // See {devBuySource}. Bounded raw staticcall; on failure the exemption stays disabled (fail-closed).
        (bool pmOk, bytes memory pmRet) = launcher_.staticcall{gas: 30_000}(abi.encodeWithSignature("lpLocker()"));
        devBuySource = (pmOk && pmRet.length >= 32) ? address(uint160(uint256(bytes32(pmRet)))) : address(0);
        // See {rewardsHook}. Same bounded raw staticcall; on failure {attachTracker} is disabled (fail-closed).
        (bool hkOk, bytes memory hkRet) =
            launcher_.staticcall{gas: 30_000}(abi.encodeWithSelector(IRealmAnyPairsLauncherHook.pairTaxHook.selector));
        rewardsHook = (hkOk && hkRet.length >= 32) ? address(uint160(uint256(bytes32(hkRet)))) : address(0);
        for (uint256 i; i < exempt_.length; ++i) {
            maxWalletExempt[exempt_[i]] = true;
        }
        _mint(launcher_, totalSupply_);
    }

    /// @dev Transient (EIP-1153) marker for "inside the deploying transaction"; cleared automatically when
    /// the transaction ends. Not a block/timestamp check, which would span several L2 blocks.
    bytes32 private constant _LAUNCH_TX_SLOT = keccak256("realm.maxwallet.launchtx");

    /// @dev Enforces the holdings cap. Skipped when: no cap or expired; mint (`from == 0`); self-transfer;
    /// burn; recipient has code (pools, lockers and routers must receive freely, so the cap applies to EOAs
    /// only -- contracts and EIP-7702 delegated EOAs are uncapped); recipient is exempt; or the LP locker is
    /// paying out the dev buy inside the deploying transaction.
    function _checkMaxWallet(address from, address to, uint256 value) private {
        uint256 cap = maxWallet;
        if (cap == 0) {
            return;
        }
        if (block.timestamp >= maxWalletUntil) {
            return;
        }
        if (from == address(0) || from == to) {
            return;
        }
        if (to == address(0) || to.code.length != 0) {
            return;
        }
        if (maxWalletExempt[to]) {
            return; // whitelisted at launch; applies to buys and transfers alike
        }
        if (from == devBuySource && devBuySource != address(0)) {
            // Dev-buy payout from the locker, only inside the deploying transaction. Coins taken from the
            // PoolManager are still capped. A keccak constant cannot be named in inline assembly, hence the local.
            bytes32 slot = _LAUNCH_TX_SLOT;
            bool inLaunchTx;
            assembly ("memory-safe") { inLaunchTx := tload(slot) }
            if (inLaunchTx) {
                return;
            }
        }
        if (balanceOf(to) + value > cap) {
            revert MaxWalletExceeded();
        }
    }

    /// @notice Switch holder rewards ON for this already-launched coin, once and forever. Callable only by
    /// the live `admin` of the V4 tax hook this coin launched under.
    /// @dev The hook side must also be wired (`rewardsTracker` set before `rewardsBps`). A tracker attached
    /// post-launch starts empty: sync existing holders via the tracker's permissionless `syncBalances`
    /// before enabling `rewardsBps`, otherwise income buffers in `pending` until enough supply is registered.
    /// Irreversible, and from then on transfers need at least `syncGasParams().minDebit` gas.
    function attachTracker(address tracker_) external {
        // ── the gate. `admin` is read at call time, so hook admin rotations keep working.
        address h = rewardsHook;
        if (h == address(0)) {
            revert RewardsHookUnavailable();
        }
        // Raw staticcall: a typed call to a codeless address would revert uncatchably in this frame.
        (bool aOk, bytes memory aRet) =
            h.staticcall{gas: 30_000}(abi.encodeWithSelector(IRealmAnyPairsHookAdmin.admin.selector));
        if (!aOk || aRet.length < 32) {
            revert RewardsHookUnavailable();
        }
        address hookAdmin = address(uint160(uint256(bytes32(aRet))));
        if (hookAdmin == address(0) || msg.sender != hookAdmin) {
            revert NotHookAdmin();
        }

        // ── the refusals.
        if (tracker != address(0)) {
            revert TrackerAlreadySet();
        }
        // A zero would not consume the one-shot and would leave rewards silently off.
        if (tracker_ == address(0)) {
            revert ZeroTracker();
        }
        if (tracker_.code.length == 0) {
            revert TrackerCodeless();
        }
        // Supply is fixed, so a sub-minimum coin is refused forever.
        if (totalSupply() < MIN_REWARDS_TOTAL_SUPPLY) {
            revert SupplyTooSmallForRewards();
        }

        (bool ok, bytes memory ret) =
            tracker_.staticcall{gas: 100_000}(abi.encodeWithSelector(IBalanceSyncGas.balanceSyncGas.selector));
        if (!ok || ret.length < 32) {
            revert TrackerSyncGasUnavailable();
        }
        uint256 g = abi.decode(ret, (uint256));
        if (g == 0) {
            revert TrackerSyncGasUnavailable();
        }
        uint256 stored = g > SET_BALANCE_GAS ? (g > MAX_TRACKER_SYNC_GAS ? MAX_TRACKER_SYNC_GAS : g) : 0;

        tracker = tracker_;
        trackerSyncGas = uint96(stored);
        emit TrackerSyncGasRead(tracker_, g, stored);
        emit TrackerAttached(tracker_, msg.sender);
    }

    /// @dev Identical to {RealmAnyPairsTokenDividend._syncGas}; see there.
    function _syncGas() private view returns (uint256 g, uint256 minDebit, uint256 minNotify) {
        g = trackerSyncGas;
        if (g <= SET_BALANCE_GAS) {
            g = SET_BALANCE_GAS;
            return (g, MIN_DEBIT_GAS, MIN_NOTIFY_GAS);
        }
        minDebit = g + g / 63 + 16_349;
        minNotify = g + g / 63 + 12_000;
    }

    /// @notice Gas figures a transfer is measured against once a tracker is attached (stipend, minimum gas
    /// for the mandatory debit, credit threshold). Meaningless while {tracker} is zero.
    function syncGasParams() external view returns (uint256 stipend, uint256 minDebit, uint256 minNotify) {
        return _syncGas();
    }

    /// @dev With no tracker this is a plain ERC20 transfer plus one SLOAD. With a tracker it matches
    /// {RealmAnyPairsTokenDividend._update}: the debit is mandatory (a skipped debit leaves unbacked reward
    /// weight), the credit is skippable (self-heals), and the auto-push is best-effort.
    function _update(address from, address to, uint256 value) internal override {
        _checkMaxWallet(from, to, value);
        super._update(from, to, value);
        address t = tracker;
        if (t == address(0)) {
            return;
        }
        (uint256 syncGas, uint256 minDebit, uint256 minNotify) = _syncGas();
        if (from != address(0)) {
            if (gasleft() < minDebit) {
                revert InsufficientGasForBalanceSync();
            }
            try IDividendTracker(t).setBalance{gas: syncGas}(from, balanceOf(from)) {} catch {}
        }
        if (to != address(0) && gasleft() >= minNotify) {
            try IDividendTracker(t).setBalance{gas: syncGas}(to, balanceOf(to)) {} catch {}
        }
        if (gasleft() > PROCESS_FLOOR) {
            try IDividendTracker(t).process{gas: PROCESS_GAS}(PROCESS_BUDGET) returns (uint256) {} catch {}
        }
    }

    // The only privileged function is {attachTracker}. Nothing here can mint, burn, move, freeze or tax a
    // balance, change the cap or extend `maxWalletUntil`. {rescue} is permissionless.

    /// @notice Metadata URI: `<base><address>.json`, with the base read from the launcher so a domain move
    /// repairs every coin at once. Returns "" if no base is set or the launcher call reverts.
    /// @dev Not total: against a codeless launcher the empty-returndata decode reverts in this frame.
    function tokenURI() external view returns (string memory) {
        try IRealmAnyPairsLauncherBase(launcher).baseTokenURI() returns (string memory base) {
            if (bytes(base).length == 0) {
                return "";
            }
            return string.concat(base, Strings.toHexString(address(this)), ".json");
        } catch {
            return "";
        }
    }

    /// @notice Nothing to rescue.
    error NothingToRescue();

    /// @notice Same signature as the hook's, locker's and launchers' {Rescued}, so one topic0 covers every rescue.
    event Rescued(address indexed token, address indexed to, uint256 amount);

    /// @notice Permissionless: sends this contract's whole balance of `asset` (its own coin or any ERC20)
    /// to {launcher}, where the owner/admin can return it.
    /// @dev The destination is fixed and the launcher is excluded from rewards, so this cannot move holder
    /// balances or shift reward weight. The own-coin leg goes through {_update} like any transfer.
    function rescue(address asset) external returns (uint256 amount) {
        address to = launcher;
        if (asset == address(this)) {
            amount = balanceOf(address(this));
            if (amount == 0) {
                revert NothingToRescue();
            }
            _transfer(address(this), to, amount);
        } else {
            amount = IERC20(asset).balanceOf(address(this));
            if (amount == 0) {
                revert NothingToRescue();
            }
            IERC20(asset).safeTransfer(to, amount);
        }
        emit Rescued(asset, to, amount);
    }
}
