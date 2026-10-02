// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The token-side read every contract that keys a Realm token's V4 pool needs.
/// @dev Its own file rather than a function on `IRealmToken`: the whitelisted hooks import that file, and
///      editing it would change their compiled metadata.
interface IRealmPoolFee {
    /// @notice The token's V4 pool fee tier in pips (10000 = 1%, 5000 = 0.5%). 0 on V2.
    function poolFee() external view returns (uint24);
}
