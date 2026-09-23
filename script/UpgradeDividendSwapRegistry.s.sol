// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Utils} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol";

import {RealmDividendSwapRegistry} from "src/dividends/RealmDividendSwapRegistry.sol";
import {DeploymentAddresses as RegistryBuild} from "src/dividends/RealmDividendSwapRegistry.sol";
import {BuildTarget} from "script/BuildTarget.sol";

/// @title Repoint the live `RealmDividendSwapRegistry` at the current build
/// @notice Deploys a fresh `RealmDividendSwapRegistry` implementation and points this chain's
///         `DIVIDEND_SWAP_REGISTRY` proxy (from `DeploymentAddresses.sol`) at it. Routes, thresholds and the
///         keeper wallet live in proxy storage and are kept; the proxy never moves, so the token masters
///         that bake it are untouched.
///
/// @dev    The registry's venue addresses are compile-time constants from the `just chain-*` retarget, so
///         the script refuses to broadcast a build targeted at another chain.
///
/// @dev    Run: just upgrade-dividend-registry-<sepolia|rh|rh-testnet>
///         Dry-run first: the same `forge script` without --broadcast, plus --sender <realm.dev address>
///         so the owner check passes in simulation.
contract UpgradeDividendSwapRegistry is Script {
    function run() external {
        BuildTarget.assertBuiltFor(block.chainid);
        address proxy = RegistryBuild.DIVIDEND_SWAP_REGISTRY;
        address oldImpl = address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));

        console.log("=== Upgrade RealmDividendSwapRegistry ===");
        console.log("Chain ID: ", block.chainid);
        console.log("Deployer: ", msg.sender);
        console.log("Proxy:    ", proxy);
        console.log("Old impl: ", oldImpl);
        console.log("");

        vm.startBroadcast();
        address newImpl = address(new RealmDividendSwapRegistry());
        UUPSUpgradeable(proxy).upgradeToAndCall(newImpl, "");
        vm.stopBroadcast();

        require(
            address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT)))) == newImpl,
            "post-upgrade: impl not set"
        );

        console.log("=== Upgraded ===");
        console.log("  RealmDividendSwapRegistry impl =", newImpl, "(not in the manifest; proxy unchanged)");
    }
}
