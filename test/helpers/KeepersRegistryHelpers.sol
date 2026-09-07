// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {RealmKeepersRegistry} from "src/access/RealmKeepersRegistry.sol";
import {DeploymentAddressesEthereumMainnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";

Vm constant KEEPERS_VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

/// @dev OpenZeppelin v5 `Ownable` keeps `_owner` in slot 0 of a non-upgradeable contract, and
///      `Ownable2Step` appends `_pendingOwner` after it. `etch` copies runtime code only, so the
///      constructor's owner write is lost and has to be replayed here.
bytes32 constant OWNABLE_OWNER_SLOT = bytes32(uint256(0));

/// @notice Puts a working `RealmKeepersRegistry` at the address the token implementations bake in, and
///         appoints `keeper`.
/// @dev Token implementations reach the registry through a compile-time constant, so a test cannot
///      deploy one and pass the address — it has to appear AT that address. Same shape and same reason
///      as `installDividendSwapRegistry`.
/// @dev `owner` is set by `vm.store` rather than by a call, because this contract takes its owner in the
///      constructor and `etch` does not run constructors. The `require` below is what turns a wrong slot
///      into an immediate, obvious failure instead of a confusing `OwnableUnauthorizedAccount` later.
function installKeepersRegistry(address owner, address keeper) returns (RealmKeepersRegistry registry) {
    RealmKeepersRegistry deployed = new RealmKeepersRegistry(owner);
    KEEPERS_VM.etch(DeploymentAddresses.REALM_KEEPERS_REGISTRY, address(deployed).code);
    KEEPERS_VM.label(DeploymentAddresses.REALM_KEEPERS_REGISTRY, "KeepersRegistry");

    registry = RealmKeepersRegistry(DeploymentAddresses.REALM_KEEPERS_REGISTRY);
    KEEPERS_VM.store(address(registry), OWNABLE_OWNER_SLOT, bytes32(uint256(uint160(owner))));
    require(registry.owner() == owner, "KeepersRegistryHelpers: Ownable owner slot moved");

    KEEPERS_VM.prank(owner);
    registry.setKeeper(keeper, true);
}
