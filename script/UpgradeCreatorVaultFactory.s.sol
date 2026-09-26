// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Utils} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol";

import {RealmCreatorVaultFactory} from "src/vaults/RealmCreatorVaultFactory.sol";
import {ChainConfig} from "script/ChainConfig.sol";

/// @title Ship a new `RealmCreatorVaultFactory` implementation to the live proxy
/// @notice Deploys a fresh factory implementation from the current build, reusing the vault
///         implementation the proxy already clones, and points the manifest's `CREATOR_VAULT_FACTORY`
///         proxy at it. The proxy address (held as an immutable by the token factories) never moves.
///         The broadcaster must own the proxy (`realm.dev`).
///
/// @dev    Run: just upgrade-vault-factory-<rh|rh-testnet>
///         Dry-run first: the same `forge script` without --broadcast, plus --sender <realm.dev address>.
contract UpgradeCreatorVaultFactory is Script {
    function run() external {
        address proxy = ChainConfig.creatorVaultFactory();
        require(proxy != address(0), "vault factory not deployed on this chain");
        address oldImpl = address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
        address vaultImpl = RealmCreatorVaultFactory(proxy).VAULT_IMPLEMENTATION();

        console.log("=== Upgrade RealmCreatorVaultFactory ===");
        console.log("Chain ID:   ", block.chainid);
        console.log("Deployer:   ", msg.sender);
        console.log("Proxy:      ", proxy);
        console.log("Old impl:   ", oldImpl);
        console.log("Vault impl: ", vaultImpl);
        console.log("");

        vm.startBroadcast();
        address newImpl = address(new RealmCreatorVaultFactory(vaultImpl));
        UUPSUpgradeable(proxy).upgradeToAndCall(newImpl, "");
        vm.stopBroadcast();

        require(
            RealmCreatorVaultFactory(proxy).VAULT_IMPLEMENTATION() == vaultImpl, "post-upgrade: vault impl mismatch"
        );

        console.log("=== Upgraded. Paste into src/config/manifest.%s.sol ===", ChainConfig.name());
        console.log("  CREATOR_VAULT_FACTORY_IMPL =", newImpl);
        console.log("");
        console.log("Then: just export-deployments");
    }
}
