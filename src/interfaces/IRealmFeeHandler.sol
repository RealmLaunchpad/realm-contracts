// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRealmClaims} from "src/interfaces/IRealmClaims.sol";

/// @notice An interface for contracts that will receive realm-generated ETH fees, and from where receivers can claim
interface IRealmFeeHandler is IRealmClaims {
    /// ERRORS
    error OnlyWhitelistedFactory();

    /// EVENTS
    event CreatorFeesDeposited(address indexed token, address indexed account, uint256 amount);

    /// @notice Emitted once per `(token, receiver)` pair on `registerDirectReceivers`. Indexers
    ///         subscribe to this to maintain the set of direct receivers per token; existing event
    ///         signatures (`CreatorFeesDeposited`, `CreatorClaimed`) are unchanged.
    event DirectReceiverRegistered(address indexed token, address indexed receiver);

    ///////////// EXTERNAL FUNCTIONS //////////////

    /// @notice Deposits msg.value into `feeReceiver` balance for `token`
    function depositFees(address token, address feeReceiver) external payable;

    /// @notice Flags each address in `receivers` for direct ETH forwarding on every `depositFees`
    ///         call targeting `(token, receiver)`. Callable only by whitelisted factories.
    ///         Idempotent — calling again with new addresses simply adds them to the set.
    /// @dev The handler accepts an array even though current factories enforce a single direct
    ///      receiver — keeping the surface flexible lets future factories opt into multi-direct
    ///      configurations without an interface change.
    function registerDirectReceivers(address token, address[] calldata receivers) external;

    ///////////// VIEWS //////////////

    /// @notice Returns whether `(token, account)` was registered as a direct fee receiver.
    function isDirectReceiver(address token, address account) external view returns (bool);
}
