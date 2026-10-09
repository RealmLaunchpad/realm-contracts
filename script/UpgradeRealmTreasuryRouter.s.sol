// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Utils} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol";

import {RealmTreasuryRouter} from "src/treasury/RealmTreasuryRouter.sol";
import {ChainConfig} from "script/ChainConfig.sol";

/// @title Repoint the live `RealmTreasuryRouter` at the current manifest
/// @notice Deploys a fresh `RealmTreasuryRouter` implementation from the current build and points the
///         manifest's `TREASURY_ROUTER` proxy at it. The team treasury is an implementation immutable, so
///         changing it means running this. The proxy address never moves, so the launchpad, the
///         `SwapLpFeeRouter` and the token impls that bake it as `DIVIDEND_TREASURY` are untouched.
///
/// @dev    This is the counterpart to `DeployRealmTreasuryStack`, which is deploy-once and refuses while
///         `TREASURY_ROUTER` is set: first-time wiring goes there, every later change comes here.
///
/// @dev    Run: just upgrade-treasury-router-<rh|rh-testnet>
///         Dry-run first: the same `forge script` without --broadcast, plus --sender <realm.dev address>
///         so the owner check passes in simulation.
contract UpgradeRealmTreasuryRouter is Script {
    function run() external {
        address proxy = ChainConfig.treasuryRouter();
        address teamTreasury = ChainConfig.teamTreasury();
        require(proxy != address(0), "manifest: TREASURY_ROUTER missing (run DeployRealmTreasuryStack first)");
        // Once the router is live, this chain's REALM_TREASURY IS the proxy, so a config that resolves the
        // treasury to it would have the router forwarding to itself and the funds never leaving.
        require(teamTreasury != proxy, "team treasury resolves to the router itself");
        address oldImpl = address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));

        console.log("=== Upgrade RealmTreasuryRouter ===");
        console.log("Chain ID: ", block.chainid);
        console.log("Deployer: ", msg.sender);
        console.log("Proxy:    ", proxy);
        console.log("Old impl: ", oldImpl);
        console.log("Treasury: ", teamTreasury);
        console.log("");

        vm.startBroadcast();
        address newImpl = address(new RealmTreasuryRouter(teamTreasury));
        UUPSUpgradeable(proxy).upgradeToAndCall(newImpl, "");
        vm.stopBroadcast();

        RealmTreasuryRouter router = RealmTreasuryRouter(payable(proxy));
        require(router.TREASURY() == teamTreasury, "post-upgrade: treasury mismatch");
        require(router.VERSION() == 2, "post-upgrade: version mismatch");

        console.log("=== Upgraded. Paste into src/config/manifest.%s.sol ===", ChainConfig.name());
        console.log("  TREASURY_ROUTER_IMPL =", newImpl);
        console.log("");
        console.log("Then: just export-deployments");
    }
}
