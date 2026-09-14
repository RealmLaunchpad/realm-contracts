// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title RealmAnyPairsCloneLib
/// @notice EIP-1167 minimal proxies for the creator vesting vaults.
/// @dev Internal-only, so it is inlined (nothing to deploy or link). Assembles the standard EIP-1167 bytecode
/// the same way OpenZeppelin v5 `Clones.clone` does; the vendored OpenZeppelin lacks `proxy/Clones.sol`.
/// Only scratch space (0x00-0x3f) is written, so the assembly is memory-safe.
library RealmAnyPairsCloneLib {
    error CloneFailed();

    function clone(address implementation) internal returns (address instance) {
        assembly ("memory-safe") {
            // The creation prefix + runtime head, then the first 3 bytes of `implementation`.
            mstore(0x00, or(shr(0xe8, shl(0x60, implementation)), 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000))
            // The remaining 17 bytes of `implementation`, then the runtime tail.
            mstore(0x20, or(shl(0x78, implementation), 0x5af43d82803e903d91602b57fd5bf3))
            instance := create(0, 0x09, 0x37)
        }
        if (instance == address(0)) revert CloneFailed();
    }
}
