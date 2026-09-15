// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Immutable, fixed-supply ERC20, identical to RealmAnyPairsTokenPlain in every trading-relevant way (no mint,
// no burn, no owner, same optional expiring max wallet), except that it notifies its dividend tracker of
// balance changes. Tracker faults never revert a transfer (try/catch + bounded stipend).
//
// Reverts this contract adds to the transfer path:
//   * InsufficientGasForBalanceSync -- the caller supplied less gas than the mandatory debit sync needs.
//     A skipped debit leaves a phantom tracked balance that keeps earning and cannot be repaired later.
//   * MaxWalletExceeded -- only for coins that opted into the cap, and only until `maxWalletUntil`.
// Used by the rewards launch flavor; Fair/Tax launches use RealmAnyPairsTokenPlain.
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IRealmAnyPairsLauncherBase {
    function baseTokenURI() external view returns (string memory);
}

interface IDividendTracker {
    function setBalance(address account, uint256 newBalance) external;
    function process(uint256 gasBudget) external returns (uint256);
}

/// @dev Reports the gas a tracker's {setBalance} needs. Multi-denomination trackers need more than the
/// flat default because their cost grows with the denomination count.
interface IBalanceSyncGas {
    function balanceSyncGas() external view returns (uint256);
}

contract RealmAnyPairsTokenDividend is ERC20 {
    using SafeERC20 for IERC20;

    address public immutable launcher;
    address public immutable creator;
    address public tracker; // set ONCE by the launcher at launch, then permanent
    /// @notice Stipend forwarded to `tracker.setBalance`, read from the tracker at {initTracker} and fixed
    /// thereafter. Zero means the tracker needs no more than {SET_BALANCE_GAS} (the flat constants apply).
    /// @dev Packed into `tracker`'s slot so the transfer path reads both with one SLOAD.
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

    error MaxWalletExceeded();

    /// @dev Stipend forwarded to both `setBalance` calls for a single-denomination tracker. Sized with
    /// generous margin over the coldest ADD branch (brand-new holder, empty holder set).
    uint256 private constant SET_BALANCE_GAS = 230_000;
    /// @dev Gas threshold at which the optional credit is attempted. Deliberately a "worth attempting"
    /// threshold, not a guarantee of the full stipend: a skipped credit only under-accrues and self-heals
    /// on the holder's next transfer or `syncBalance`, whereas a skipped debit is theft.
    uint256 private constant MIN_NOTIFY_GAS = 175_000;
    /// @dev Hard floor for the mandatory debit. Guarantees the full {SET_BALANCE_GAS} stipend after EIP-150's
    /// 63/64 rule and the pre-call work, because an OOG inside the try/catch would silently skip the debit.
    uint256 private constant MIN_DEBIT_GAS = 250_000; // >= SET_BALANCE_GAS * 64/63 (233,651), plus pre-call work
    uint256 private constant PROCESS_GAS = 300_000; // stipend handed to the auto-push per transfer
    uint256 private constant PROCESS_BUDGET = 200_000; // gas the push loop is allowed to spend inside it
    uint256 private constant PROCESS_FLOOR = 400_000; // only auto-push when the transfer has ample gas to
    // spare; otherwise skip it (best-effort, never blocks)

    error OnlyLauncher();
    error TrackerAlreadySet();
    error ZeroTracker();
    /// @dev The tracker has code but did not report {IBalanceSyncGas.balanceSyncGas}.
    error TrackerSyncGasUnavailable();
    /// @notice The tracker address has no code. Refused because {_update}'s typed calls to a codeless
    /// tracker would revert every transfer forever.
    error TrackerCodeless();
    error InsufficientGasForBalanceSync();

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
        for (uint256 i; i < exempt_.length; ++i) {
            maxWalletExempt[exempt_[i]] = true;
        }
        _mint(launcher_, totalSupply_); // minted before tracker is set; launcher is excluded anyway
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

    /// @notice One-shot link to the dividend tracker. Called by the launcher inside the launch tx, before
    /// any public trading. Immutable thereafter.
    function initTracker(address tracker_) external {
        if (msg.sender != launcher) {
            revert OnlyLauncher();
        }
        if (tracker != address(0)) {
            revert TrackerAlreadySet();
        }
        // A zero would not consume the one-shot and would silently disable dividends.
        if (tracker_ == address(0)) {
            revert ZeroTracker();
        }
        tracker = tracker_;
        // The tracker must report its setBalance cost. Raw staticcall (a typed call to a codeless address
        // reverts uncatchably), and the result is clamped to MAX_TRACKER_SYNC_GAS so a tracker cannot push
        // the debit floor past what wallets supply and turn the coin into a honeypot.
        if (tracker_.code.length == 0) {
            revert TrackerCodeless();
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
        trackerSyncGas = uint96(stored);
        emit TrackerSyncGasRead(tracker_, g, stored);
    }

    /// @notice What {initTracker} read from the tracker, and what it stored (0 = the flat constants).
    event TrackerSyncGasRead(address indexed tracker, uint256 reported, uint256 stored);

    /// @dev Anti-honeypot ceiling on a tracker's self-reported stipend. The per-launch denomination limit
    /// lives on the launcher; lowering this would silently clamp a legal tracker's stipend instead.
    uint256 private constant MAX_TRACKER_SYNC_GAS = 1_100_000;

    /// @dev Returns the forwarded stipend and the two gas floors derived from it. At or below
    /// {SET_BALANCE_GAS} the flat constants are returned. Above it, both floors guarantee the full stipend
    /// after EIP-150's 63/64 rule; the fixed buffers cover the pre-call overhead with margin.
    function _syncGas() private view returns (uint256 g, uint256 minDebit, uint256 minNotify) {
        g = trackerSyncGas;
        if (g <= SET_BALANCE_GAS) {
            g = SET_BALANCE_GAS;
            return (g, MIN_DEBIT_GAS, MIN_NOTIFY_GAS);
        }
        minDebit = g + g / 63 + 16_349;
        minNotify = g + g / 63 + 12_000;
    }

    /// @notice Gas figures a transfer is measured against: the stipend forwarded to `tracker.setBalance`,
    /// the minimum gas for the mandatory debit, and the gas at which the optional credit is attempted.
    /// @dev Contracts calling `transfer` with a bounded stipend should forward at least `minDebit`.
    function syncGasParams() external view returns (uint256 stipend, uint256 minDebit, uint256 minNotify) {
        return _syncGas();
    }

    /// @dev Mirror balance changes into the tracker. try/catch + gas cap so a tracker revert or gas bomb
    /// can never brick a transfer.
    function _update(address from, address to, uint256 value) internal override {
        _checkMaxWallet(from, to, value);
        super._update(from, to, value);
        address t = tracker;
        if (t == address(0)) {
            return;
        }
        (uint256 syncGas, uint256 minDebit, uint256 minNotify) = _syncGas();
        if (from != address(0)) {
            // The debit is mandatory: revert on a starved caller, since a skipped debit leaves phantom reward
            // weight that never self-heals. A fault inside the tracker itself is still swallowed.
            if (gasleft() < minDebit) {
                revert InsufficientGasForBalanceSync();
            }
            try IDividendTracker(t).setBalance{gas: syncGas}(from, balanceOf(from)) {} catch {}
        }
        // The credit stays skippable: setBalance is absolute, so a missed credit self-heals on the
        // recipient's next full-gas transfer and creates no unbacked reward weight in the meantime.
        if (to != address(0) && gasleft() >= minNotify) {
            try IDividendTracker(t).setBalance{gas: syncGas}(to, balanceOf(to)) {} catch {}
        }
        // Auto-push: pay a batch of holders, strictly best-effort, only when the transfer has ample gas.
        if (gasleft() > PROCESS_FLOOR) {
            try IDividendTracker(t).process{gas: PROCESS_GAS}(PROCESS_BUDGET) returns (uint256) {} catch {}
        }
    }

    /// @notice Off-chain metadata URI: `<base><address>.json`, with the base read from the launcher.
    /// Returns "" if no base is set or the launcher call reverts.
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
