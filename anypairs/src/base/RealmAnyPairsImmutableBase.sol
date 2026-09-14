// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title RealmAnyPairsImmutableBase
 * @notice Shared base for the non-upgradeable V4 tax-launch contracts (hooks, launchers, lockers):
 *         two-step ownership, single-step renounce, and a reentrancy guard. No proxy; logic can never change.
 */
abstract contract RealmAnyPairsImmutableBase {
    address public owner;
    address public pendingOwner;
    uint256 private _entered; // 1 = not entered, 2 = entered

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    /// @dev Emitted instead of {OwnershipTransferStarted} when {transferOwnership} is called with
    /// `address(0)`, so a cancel never looks like a handoff to zero.
    event OwnershipTransferCanceled(address indexed owner, address indexed canceledPendingOwner);

    error NotOwner();
    error NotPendingOwner();
    error ReentrantCall();
    error ZeroOwner();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_entered == 2) revert ReentrantCall();
        _entered = 2;
        _;
        _entered = 1;
    }

    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroOwner();
        owner = owner_;
        _entered = 1;
        emit OwnershipTransferred(address(0), owner_);
    }

    /// @notice Start a two-step ownership transfer. Pass address(0) to cancel a pending one; to give up
    /// ownership use {renounceOwnership}.
    function transferOwnership(address newOwner) external onlyOwner {
        address cleared = pendingOwner;
        pendingOwner = newOwner;
        if (newOwner == address(0)) emit OwnershipTransferCanceled(owner, cleared);
        else emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice The pending owner accepts ownership, completing the handoff.
    function acceptOwnership() external {
        if (pendingOwner == address(0)) revert NotPendingOwner();
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address old = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(old, owner);
    }

    /// @dev Override to block {renounceOwnership} until required one-time wiring is complete. No-op by default.
    function _requireRenounceReady() internal view virtual {}

    /// @notice Permanently renounce ownership in a single step. Irreversible.
    /// @dev Subclass setters gated `onlyOwnerOrAdmin` keep working from `admin` until it is set to zero.
    function renounceOwnership() external onlyOwner {
        _requireRenounceReady();
        address old = owner;
        owner = address(0);
        pendingOwner = address(0);
        emit OwnershipTransferred(old, address(0));
    }
}
