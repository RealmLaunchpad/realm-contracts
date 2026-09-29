// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title RealmAnyPairsCreatorVault
/// @notice A creator's vesting vault for part of a coin's supply: one beneficiary, one token, one amount. Nothing
/// is claimable before `cliff`; from `start` the amount vests linearly until `end`. No admin, owner or revocation.
/// @dev Deployed as EIP-1167 clones, created and {initialize}d by the launcher in the launch transaction so nobody
/// can initialise one first; the implementation is locked in its constructor. Vaults are excluded from rewards,
/// and a launch with a max wallet requires `cliff` at or after the max-wallet window closes.
contract RealmAnyPairsCreatorVault {
    using SafeERC20 for IERC20;

    error AlreadyInitialized();
    error BadVault();
    error NotBeneficiary();
    error NothingToClaim();

    event VaultClaimed(address indexed beneficiary, uint256 amount);

    /// @notice The coin this vault holds.
    address public token;
    /// @notice The only address that can claim, and the only address claims are paid to.
    address public beneficiary;
    /// @notice The amount this vault vests in total. Set once; the launcher funds exactly this much after initialising.
    uint256 public total;
    /// @notice Already paid to the beneficiary.
    uint256 public claimed;
    /// @notice Vesting starts here (the launch).
    uint64 public start;
    /// @notice Nothing is claimable before this timestamp.
    uint64 public cliff;
    /// @notice Everything is claimable from this timestamp.
    uint64 public end;

    constructor() {
        // Lock the implementation: a non-zero token makes {initialize} revert here forever, and there is no beneficiary.
        token = address(0xdEaD);
    }

    /// @notice One-shot setup, called by the launcher on a fresh clone in the launch transaction.
    /// @dev PERMISSIONLESS BY DESIGN, AND SAFE ONLY BECAUSE THE CLONE'S ADDRESS IS UNPREDICTABLE.
    /// AUDIT ROUND 17 (F-5, latent). There is no caller check here: the guard is that
    /// {RealmAnyPairsCloneLib.clone} uses plain `CREATE`, so this clone's address depends on the launcher's nonce and
    /// cannot be known before the launch transaction, and the launcher calls `initialize` (and funds the vault) in
    /// the same frame as the `CREATE`. Nobody else ever gets a turn. If the clone opcode is ever changed to CREATE2
    /// -- for vanity or pre-computed vault addresses -- that guard disappears and this function becomes an instant
    /// hijack: anyone can `initialize(token, attacker, ...)` the predicted address first and take the creator's whole
    /// vested allocation. Make this permissioned (launcher-only, or an init argument bound into the salt) BEFORE, not
    /// after, any such change.
    /// @param cliffSecs seconds from `start_` until the first claim; must not exceed `vestSecs`.
    /// @param vestSecs seconds from `start_` until everything has vested; must be non-zero.
    function initialize(address token_, address beneficiary_, uint256 total_, uint64 start_, uint32 cliffSecs, uint32 vestSecs)
        external
    {
        if (token != address(0)) revert AlreadyInitialized();
        if (token_ == address(0) || beneficiary_ == address(0) || total_ == 0) revert BadVault();
        if (vestSecs == 0 || cliffSecs > vestSecs) revert BadVault();
        token = token_;
        beneficiary = beneficiary_;
        total = total_;
        start = start_;
        cliff = start_ + cliffSecs;
        end = start_ + vestSecs;
    }

    /// @notice How much has vested by now, claimed or not.
    function vested() public view returns (uint256) {
        if (block.timestamp < cliff) return 0;
        if (block.timestamp >= end) return total;
        return (total * (block.timestamp - start)) / (end - start);
    }

    /// @notice What the beneficiary could claim right now.
    function claimable() public view returns (uint256) {
        return vested() - claimed;
    }

    /// @notice Pay everything vested and not yet claimed to the beneficiary.
    function claim() external returns (uint256 amount) {
        if (msg.sender != beneficiary) revert NotBeneficiary();
        amount = claimable();
        if (amount == 0) revert NothingToClaim();
        claimed += amount;
        IERC20(token).safeTransfer(beneficiary, amount);
        emit VaultClaimed(beneficiary, amount);
    }
}
