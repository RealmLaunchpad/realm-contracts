// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "lib/openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";

/// @title LivoCreatorVault
/// @notice Minimal-proxy-clonable vesting vault for creator-locked token supply. Each vault holds a
///         fixed token allocation for a single `owner`, who can claim it on a linear vesting
///         schedule with an initial cliff. Nothing can be claimed until the token graduates.
///
/// @dev    Vesting clock: the cliff + linear vesting both start at `startTimestamp`, which is set to
///         `block.timestamp` at initialization, i.e. at TOKEN CREATION (the factory creates and
///         funds the vault in the same tx that deploys the token). This keeps the vault fully
///         self-contained: it never needs to be wired to the graduation process. Claims are simply
///         gated on `token.graduated()`, so a creator cannot pull tokens out of a token that never
///         went live.
///
///         Schedule (cliff is a pure lock-up; linear vesting begins AFTER the cliff):
///           t <  cliffEnd                       -> 0
///           cliffEnd <= t < cliffEnd+vesting    -> total * (t - cliffEnd) / vesting
///           t >= cliffEnd + vesting             -> total
///         where cliffEnd = startTimestamp + cliffSeconds. The owner can only claim the vested
///         amount once `token.graduated()` is true.
///
///         The OZ `VestingWallet` was not reused: it is not clone-initializable and has no
///         graduation gate. This contract mirrors its linear-vesting math in a small, auditable form.
contract LivoCreatorVault is Initializable {
    using SafeERC20 for IERC20;

    /// @notice The token this vault vests. Its `graduated()` flag gates `claim()`.
    address public token;

    /// @notice The sole beneficiary, allowed to claim vested tokens.
    address public owner;

    /// @notice Total token allocation locked in this vault (set once at init).
    uint256 public totalAllocation;

    /// @notice Cliff duration in seconds after `startTimestamp`, before anything vests.
    uint256 public cliffSeconds;

    /// @notice Linear vesting duration in seconds, starting after the cliff.
    uint256 public vestingSeconds;

    /// @notice The vesting-clock anchor: `block.timestamp` at initialization (token creation).
    uint256 public startTimestamp;

    /// @notice Cumulative amount already claimed by the owner.
    uint256 public claimed;

    //////////////////////// Events //////////////////////

    /// @notice Emitted on every successful claim.
    event Claimed(address indexed owner, uint256 amount);

    /// @notice The native leg of `rescueTokens` could not be delivered; the ERC20 legs still completed.
    event NativeRescueFailed(uint256 amount);

    //////////////////////// Errors //////////////////////

    error InvalidOwner();
    error InvalidToken();
    error InvalidAmount();
    error NotOwner();
    error NotGraduated();
    error NothingToClaim();

    /// @dev Locks the implementation so only clones can be initialized.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes a vault clone. Called by `LivoCreatorVaultFactory` right after cloning.
    /// @dev The vesting clock starts now (token-creation time). The vault is funded with `amount`
    ///      tokens by the caller AFTER this call returns.
    function initialize(address token_, address owner_, uint256 amount, uint256 cliffSeconds_, uint256 vestingSeconds_)
        external
        initializer
    {
        require(token_ != address(0), InvalidToken());
        require(owner_ != address(0), InvalidOwner());
        // A 0-allocation vault is meaningless; reject it here too (the token factory already
        // rejects 0-bps vaults, but `LivoCreatorVaultFactory.createVault` is permissionless).
        require(amount > 0, InvalidAmount());
        token = token_;
        owner = owner_;
        totalAllocation = amount;
        cliffSeconds = cliffSeconds_;
        vestingSeconds = vestingSeconds_;
        startTimestamp = block.timestamp;
    }

    /// @notice Claims all newly-vested tokens to the owner. Only callable by the owner, and only
    ///         once the token has graduated.
    function claim() external {
        require(msg.sender == owner, NotOwner());
        require(ILivoToken(token).graduated(), NotGraduated());

        uint256 vested = _vestedAmount(block.timestamp);
        uint256 amount = vested - claimed;
        require(amount > 0, NothingToClaim());

        claimed = vested;
        IERC20(token).safeTransfer(owner, amount);
        emit Claimed(owner, amount);
    }

    /// @notice Accepts native transfers so the vault can receive dividends (and any other airdrop) on
    ///         behalf of its owner. Without this a native dividend push to a vault would fail.
    receive() external payable {}

    /// @notice Sweeps everything the vault holds that is NOT the locked allocation to the `owner`: its
    ///         native balance, plus the balance of each listed ERC20. Owner only.
    /// @dev Vaults are ordinary dividend holders — the locked supply is a real team allocation, merely
    ///      vested — so they get paid like anyone else, in native or in tokens. Sweeping is a separate
    ///      call from `claim()` rather than folded into it, which also means it works during the cliff,
    ///      when there is nothing vested to claim.
    /// @dev ⚠️ The guard on the vested token is a PARTIAL CAP, not a refusal. The obvious rule — "revert
    ///      if `tokens[i]` is the vested token" — strands a self-token dividend forever: it arrives AS
    ///      the locked asset, and `_vestedAmount` is computed from the immutable `totalAllocation`, so
    ///      the extra never vests out either. Only the excess above what is still locked is sweepable,
    ///      which is both unstrandable and impossible to point at the vesting allocation.
    /// @param tokens ERC20s to sweep. May be empty to sweep only the native balance. `address(0)`
    ///        entries are skipped rather than treated as native, which the sweep already covers.
    function rescueTokens(address[] calldata tokens) external {
        require(msg.sender == owner, NotOwner());

        for (uint256 i; i < tokens.length; ++i) {
            address asset = tokens[i];
            if (asset == address(0)) continue;
            uint256 amount = IERC20(asset).balanceOf(address(this));
            if (asset == token) {
                uint256 locked = totalAllocation - claimed;
                amount = amount > locked ? amount - locked : 0;
            }
            if (amount > 0) IERC20(asset).safeTransfer(owner, amount);
        }

        uint256 nativeAmount = address(this).balance;
        if (nativeAmount > 0) {
            // Best-effort, deliberately NOT `require`d: this leg runs AFTER the ERC20 loop, so an owner
            // contract with no payable fallback would otherwise revert the whole call and could never
            // rescue any ERC20 either. A failed send just leaves the native here for a later attempt.
            (bool success,) = owner.call{value: nativeAmount}("");
            if (!success) emit NativeRescueFailed(nativeAmount);
        }
    }

    //////////////////////// view functions //////////////////////

    /// @notice Amount the owner can claim right now: 0 before graduation, else vested minus claimed.
    function claimable() external view returns (uint256) {
        if (!ILivoToken(token).graduated()) return 0;
        return _vestedAmount(block.timestamp) - claimed;
    }

    /// @notice Amount vested so far per the time-based schedule, ignoring the graduation gate.
    function vestedAmount() external view returns (uint256) {
        return _vestedAmount(block.timestamp);
    }

    //////////////////////// internal functions //////////////////////

    /// @dev Linear vesting with a pure-lock-up cliff, anchored at `startTimestamp`.
    function _vestedAmount(uint256 timestamp) internal view returns (uint256) {
        uint256 cliffEnd = startTimestamp + cliffSeconds;
        if (timestamp < cliffEnd) return 0;

        uint256 elapsed = timestamp - cliffEnd;
        // vestingSeconds == 0 => full unlock at the cliff (elapsed >= 0 always true here)
        if (elapsed >= vestingSeconds) return totalAllocation;
        return totalAllocation * elapsed / vestingSeconds;
    }
}
