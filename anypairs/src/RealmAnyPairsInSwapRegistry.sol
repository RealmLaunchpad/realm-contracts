// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title RealmAnyPairsInSwapRegistry
/// @notice Kill switch for in-swap payouts: a denylist of quote tokens that must NOT be paid out during a
///         swap. Every quote not listed here is paid in-swap; a denied quote's share goes to the pull
///         ledger instead and stays claimable, so denying loses nobody money.
/// @dev `address(0)` IS A VALID KEY AND MEANS THE NATIVE QUOTE (audit round 10). It used to be rejected, which
/// left native-quote pools as the only coin type with no kill switch at all: the hook and the two native-paying
/// trackers simply never consulted this registry. `address(0)` never means "unset" here -- this contract has no
/// such state, and the hook's own `inSwapRegistry == address(0)` ("no registry, allow everything") is a REGISTRY
/// address, not a quote, so the two readings never meet.
/// @dev A separate contract because the hooks and trackers that read it are immutable. Deny a quote whose
/// transfer hands control to the recipient (ERC777/1363-style hooks), reflects or rebases balances, or calls
/// out to third parties; any of these can corrupt V4 settlement mid-swap. None of this is checkable on chain.
contract RealmAnyPairsInSwapRegistry {
    address public owner;
    address public pendingOwner;

    /// @notice `true` means this quote is banned from in-swap payouts. The default `false` is the normal state.
    /// The key `address(0)` is the native quote.
    mapping(address => bool) public denied;

    event DeniedSet(address indexed quote, bool denied);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    /// @dev Emitted instead of {OwnershipTransferStarted} when {transferOwnership} is called with
    /// `address(0)` (cancel), so a cancel never looks like a handoff to zero.
    event OwnershipTransferCanceled(address indexed owner, address indexed canceledPendingOwner);
    event OwnershipTransferred(address indexed from, address indexed to);

    error NotOwner();
    error ZeroAddress();
    error NotPendingOwner();

    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Ban `quote` from in-swap payouts (`on == true`), or lift the ban (`on == false`).
    /// @dev Pass `address(0)` to ban the NATIVE quote; see the note on this contract.
    function setDenied(address quote, bool on) public onlyOwner {
        denied[quote] = on;
        emit DeniedSet(quote, on);
    }

    /// @notice Batch form of {setDenied}.
    function setDeniedBatch(address[] calldata quotes, bool on) external onlyOwner {
        for (uint256 i; i < quotes.length; i++) setDenied(quotes[i], on);
    }

    /// @notice Start a two-step ownership transfer, or pass `address(0)` to cancel a pending one.
    function transferOwnership(address to) external onlyOwner {
        address cleared = pendingOwner;
        pendingOwner = to;
        if (to == address(0)) emit OwnershipTransferCanceled(owner, cleared);
        else emit OwnershipTransferStarted(owner, to);
    }

    /// @notice The pending owner accepts ownership.
    /// @dev The zero-pending guard makes it impossible for ownership to ever reach `address(0)` (this
    /// contract has no renounce).
    function acceptOwnership() external {
        if (pendingOwner == address(0) || msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }
}
