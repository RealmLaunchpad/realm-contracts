// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {RealmCreatorVault} from "src/vaults/RealmCreatorVault.sol";
import {RealmCreatorVaultFactory} from "src/vaults/RealmCreatorVaultFactory.sol";
import {DeploymentsEthereumSepolia} from "src/config/manifest.ethereum.sepolia.sol";

/// @title Deploy the creator-vault system
/// @notice Deploys the net-new creator-vault contracts:
///         1. The `RealmCreatorVault` implementation.
///         2. The `RealmCreatorVaultFactory` implementation + its `ERC1967Proxy`.
///
///         The DEFAULT-tier vault bonding curves (`VAULT_CURVE_5..30`) are NOT deployed here — they are
///         owned by `DeployTierLiquiditySystem`, the single source of truth for every bonding curve
///         (DEFAULT + THIN + THICK). Neither the vault nor the factory constructor takes a curve, so
///         there is no ordering dependency between the two scripts.
///
///         After running, set `CREATOR_VAULT_IMPL`, `CREATOR_VAULT_FACTORY` (proxy) and
///         `CREATOR_VAULT_FACTORY_IMPL` in `src/config/manifest.<chain>.sol`, run
///         `just export-deployments`, and only THEN (re)deploy/upgrade the unified factories.
///
/// @dev    Run with:
///         forge script DeployCreatorVaultSystem --rpc-url <chain> --verify --account livo.dev --slow --broadcast
contract DeployCreatorVaultSystem is Script {
    function run() public {
        require(block.chainid == DeploymentsEthereumSepolia.BLOCKCHAIN_ID, "Unsupported chain");

        console.log("=== Realm Creator-Vault System Deployment ===");
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", msg.sender);
        console.log("");

        vm.startBroadcast();

        console.log("| Contract Name                          | Address |");
        console.log("| -------------------------------------- | --- |");

        // 1. The vault implementation cloned for every creator vault.
        address vaultImpl = address(new RealmCreatorVault());
        console.log("| RealmCreatorVault (impl)               |", vaultImpl);

        // 2. The vault factory implementation + UUPS proxy.
        address vaultFactoryImpl = address(new RealmCreatorVaultFactory(vaultImpl));
        console.log("| RealmCreatorVaultFactory (impl)        |", vaultFactoryImpl);

        address vaultFactory =
            address(new ERC1967Proxy(vaultFactoryImpl, abi.encodeCall(RealmCreatorVaultFactory.initialize, ())));
        console.log("| RealmCreatorVaultFactory (proxy)       |", vaultFactory);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("Next steps:");
        console.log("1. In src/config/manifest.<chain>.sol set CREATOR_VAULT_IMPL, CREATOR_VAULT_FACTORY");
        console.log("   (proxy) and CREATOR_VAULT_FACTORY_IMPL to the addresses above.");
        console.log("2. Run `just export-deployments` and commit the refreshed manifest.");
        console.log("3. Deploy/upgrade the unified factories so they pick up the new addresses.");
    }
}
