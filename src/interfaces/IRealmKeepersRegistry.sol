// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IRealmKeepersRegistry
/// @notice The one question a token asks the keeper allowlist.
/// @dev Deliberately a single view. Tokens are clones that bake this registry in as a constant, so the
///      surface they depend on has to be the smallest thing that answers the question — everything about
///      how the set is administered stays on the concrete contract, where it can change freely.
interface IRealmKeepersRegistry {
    /// @notice Whether `account` may trigger the protocol's out-of-band earnings conversions.
    function isKeeper(address account) external view returns (bool);
}
