// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRealmClaims} from "src/interfaces/IRealmClaims.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";

interface IRealmFeeSplitter is IRealmClaims {
    event FeesAccrued(uint256 amount);

    event SharesUpdated(address[] recipients, uint256[] sharesBps);

    /// @notice Emitted for each address that becomes a direct receiver — at `initialize` for every
    ///         direct entry in the init payload, and from `setShares` for every address that was
    ///         **not** direct beforehand and is direct in the new payload (newly added or promoted
    ///         from claimable).
    event DirectReceiverRegistered(address indexed token, address indexed receiver);

    /// @notice Emitted from `setShares` for each address that **was** direct beforehand and is no
    ///         longer direct in the new payload (demoted to claimable or removed entirely). The
    ///         former direct's failed-forward residue parked in pending claims is preserved and
    ///         remains recoverable via `claim()`.
    event DirectReceiverRemoved(address indexed token, address indexed receiver);

    error InvalidRecipients();
    error InvalidShares();
    error Unauthorized();

    /// @notice Initializes a freshly-cloned splitter.
    /// @param token The token whose fees this splitter splits.
    /// @param feeShares Initial recipients with their BPS shares and per-entry direct-fees flag.
    ///                  Entries with `directFeesEnabled = true` get their slice forwarded
    ///                  synchronously on every accrual instead of accumulating for `claim()`.
    function initialize(address token, IRealmFactory.FeeShare[] calldata feeShares) external;

    /// @notice Replaces the recipient list and per-recipient shares. The direct-receiver set is
    ///         **not** frozen: any address may become direct or claimable, be added, or be removed,
    ///         subject to the standard share-sum and uniqueness validations. Transitions preserve
    ///         every recipient's accrued / residue balance:
    ///         - claimable → direct: prior accumulator share is snapshotted into pending claims
    ///         - direct → claimable: future accruals credit via the accumulator from the call
    ///           forward; failed-forward residue is preserved
    ///         - removed entirely: residue / snapshotted claimable remains in pending and can be
    ///           recovered via `claim()`.
    function setShares(IRealmFactory.FeeShare[] calldata feeShares) external;

    function getRecipients() external view returns (address[] memory, uint256[] memory);

    /// @notice Returns the current list of direct-receiver addresses. The set is mutable via
    ///         `setShares`.
    function getDirectReceivers() external view returns (address[] memory);
}
