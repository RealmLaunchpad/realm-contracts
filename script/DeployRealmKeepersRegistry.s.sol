// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "lib/forge-std/src/Script.sol";
import {console} from "lib/forge-std/src/console.sol";

import {RealmKeepersRegistry} from "src/access/RealmKeepersRegistry.sol";
import {
    DeploymentAddressesEthereumMainnet,
    DeploymentAddressesEthereumSepolia,
    DeploymentAddressesRobinhoodMainnet,
    DeploymentAddressesRobinhoodTestnet,
    DeploymentAddressesArcMainnet,
    DeploymentAddressesArcTestnet
} from "src/config/DeploymentAddresses.sol";

/// @notice Deploys the `RealmKeepersRegistry`.
///
/// @dev ⚠️ DEPLOY ORDER. This must land BEFORE the taxable token implementations on a given chain: they
///      bake the address into their bytecode as `DeploymentAddresses.REALM_KEEPERS_REGISTRY`, which today
///      still holds a placeholder. Run this, paste the address into that chain's constant, then deploy
///      the token implementations. An impl compiled against the placeholder fails closed — every
///      `processDividends`, `processBurn` and `processLiquidity` reverts, for good, on every clone.
///
/// @dev No proxy, unlike `RealmDividendSwapRegistry`. This contract is a mapping and two setters with no
///      rules that could turn out to be wrong; see the contract docstring.
///
/// @dev The owner is the treasury multisig, which manages admins and nothing else. Appoint operational
///      admins with `setAdmin` afterwards, then let those admins rotate keeper keys with `setKeeper` —
///      key rotation is frequent and must not need the cold key.
///
/// Usage (dry run):  forge script DeployRealmKeepersRegistry --rpc-url sepolia --account livo.dev
/// Usage (deploy):   forge script DeployRealmKeepersRegistry --rpc-url sepolia --account livo.dev --slow --broadcast --verify
contract DeployRealmKeepersRegistry is Script {
    function run() external {
        address owner = _resolveOwner();

        console.log("=== Deploy RealmKeepersRegistry ===");
        console.log("Chain ID: %d", block.chainid);
        console.log("Owner:    %s", owner);

        vm.startBroadcast();
        address registry = address(new RealmKeepersRegistry(owner));
        vm.stopBroadcast();

        console.log("");
        console.log("RealmKeepersRegistry: %s", registry);
        console.log("");
        console.log("Next: paste it into REALM_KEEPERS_REGISTRY in src/config/DeploymentAddresses.sol,");
        console.log("      then redeploy the taxable token impls, then setAdmin + setKeeper.");
    }

    function _resolveOwner() internal view returns (address owner) {
        if (block.chainid == DeploymentAddressesEthereumMainnet.BLOCKCHAIN_ID) {
            owner = DeploymentAddressesEthereumMainnet.REALM_TREASURY;
        } else if (block.chainid == DeploymentAddressesEthereumSepolia.BLOCKCHAIN_ID) {
            owner = DeploymentAddressesEthereumSepolia.REALM_TREASURY;
        } else if (block.chainid == DeploymentAddressesRobinhoodMainnet.BLOCKCHAIN_ID) {
            owner = DeploymentAddressesRobinhoodMainnet.REALM_TREASURY;
        } else if (block.chainid == DeploymentAddressesRobinhoodTestnet.BLOCKCHAIN_ID) {
            owner = DeploymentAddressesRobinhoodTestnet.REALM_TREASURY;
        } else if (block.chainid == DeploymentAddressesArcMainnet.BLOCKCHAIN_ID) {
            owner = DeploymentAddressesArcMainnet.REALM_TREASURY;
        } else if (block.chainid == DeploymentAddressesArcTestnet.BLOCKCHAIN_ID) {
            owner = DeploymentAddressesArcTestnet.REALM_TREASURY;
        } else {
            revert("Unsupported chain ID");
        }
    }
}
