// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRealmClaims} from "src/interfaces/IRealmClaims.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";

/// @notice Unified singleton fee handler supporting single and multi-receiver tokens, with optional
///         synchronous ETH forwarding (direct fees) per receiver. Replaces both `RealmFeeHandler`
///         (single-receiver) and `RealmFeeSplitter` (multi-receiver clone) in the new token family.
interface IRealmMasterFeeHandler is IRealmClaims {
    ////////////////// Errors //////////////////

    error AlreadyRegistered();
    error NotRegistered();
    error Unauthorized();
    error InvalidFeeShares();
    error InvalidShares();
    error TooManyDirectReceivers();
    error TooManyFeeReceivers();

    ////////////////// Events //////////////////

    /// @notice Emitted on every `depositFees` call, before any direct forward attempt.
    event CreatorFeesDeposited(address indexed token, uint256 amount);

    /// @notice Emitted when shares are (re)configured via `registerToken` or `setShares`. `token`
    ///         distinguishes per-token configs since this is a singleton handler.
    event SharesUpdated(address indexed token, address[] recipients, uint256[] sharesBps);

    /// @notice Emitted for each address that becomes a direct receiver — at `registerToken` for
    ///         every direct entry in the init payload, and from `setShares` for every address that
    ///         was not direct beforehand and is direct in the new payload.
    event DirectReceiverRegistered(address indexed token, address indexed receiver);

    /// @notice Emitted from `setShares` for each address that was direct beforehand and is no
    ///         longer direct in the new payload (demoted to claimable or removed entirely). Any
    ///         failed-forward residue in pending claims is preserved and recoverable via `claim()`.
    event DirectReceiverRemoved(address indexed token, address indexed receiver);

    ////////////////// Functions //////////////////

    /// @notice Deposits ETH fees for `token`. Routes to the appropriate single or multi-receiver
    ///         path based on the token's registered config. Direct receivers are forwarded
    ///         synchronously; forward failures silently fall back to pending-claim accounting so
    ///         swap and graduation hot paths cannot be DoS'd.
    /// @dev `CreatorFeesDeposited` is emitted before any forward attempt for non-zero deposits;
    ///      zero-value calls are no-ops and emit nothing.
    function depositFees(address token) external payable;

    /// @notice Registers initial fee-receiver config for a newly-deployed token. One-shot per
    ///         token. Callable only by the token itself; the token address is inferred from
    ///         `msg.sender`.
    function registerToken(IRealmFactory.FeeShare[] calldata feeShares) external;

    /// @notice Replaces the fee-receiver config for `token`. Callable only by the admin or the
    ///         token's current non-zero owner. Snapshots claimable accrual into pending before
    ///         overwriting so no ETH is lost on transitions. The direct-receiver set is fully mutable.
    function setShares(address token, IRealmFactory.FeeShare[] calldata feeShares) external;

    ////////////////// Views //////////////////

    /// @notice Returns all current recipients and their BPS shares for `token`.
    function getRecipients(address token) external view returns (address[] memory, uint256[] memory);

    /// @notice Returns the current direct-receiver addresses for `token`.
    function getDirectReceivers(address token) external view returns (address[] memory);

    /// @notice Returns whether `account` is currently a direct receiver for `token`.
    function isDirectReceiver(address token, address account) external view returns (bool);
}
