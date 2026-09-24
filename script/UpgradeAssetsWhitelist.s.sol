// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Utils} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol";

import {RealmAssetsWhitelist} from "src/access/RealmAssetsWhitelist.sol";
import {ChainConfig} from "script/ChainConfig.sol";

/// @title Repoint the live `RealmAssetsWhitelist` at the current build
/// @notice Deploys a fresh `RealmAssetsWhitelist` implementation and points the manifest's `ASSETS_WHITELIST`
///         proxy at it. Listings, approvers and ownership live in proxy storage and are kept; the proxy
///         address never moves, so the direct factory that bakes it and the indexer are untouched.
///
/// @dev    Refuses if the new implementation's Uniswap immutables differ from the live ones: those decide
///         which pools a listing is priced against, and moving them under existing listings is not an upgrade.
///
/// @dev    Run: just upgrade-assets-whitelist-<rh|rh-testnet>
///         Dry-run first: the same `forge script` without --broadcast, plus --sender <realm.dev address>
///         so the owner check passes in simulation.
contract UpgradeAssetsWhitelist is Script {
    function run() external {
        address proxy = ChainConfig.assetsWhitelist();
        ChainConfig.Infra memory infra = ChainConfig.infra();
        address wrappedNative = ChainConfig.wrappedNative();
        (address univ2Factory, address univ3Factory) = ChainConfig.univ2And3Factories();
        address oldImpl = address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));

        RealmAssetsWhitelist whitelist = RealmAssetsWhitelist(proxy);
        require(address(whitelist.POOL_MANAGER()) == infra.univ4PoolManager, "live POOL_MANAGER differs");
        require(whitelist.WETH() == wrappedNative, "live WETH differs");
        require(whitelist.UNIV2_FACTORY() == univ2Factory, "live UNIV2_FACTORY differs");
        require(whitelist.UNIV3_FACTORY() == univ3Factory, "live UNIV3_FACTORY differs");

        console.log("=== Upgrade RealmAssetsWhitelist ===");
        console.log("Chain ID: ", block.chainid);
        console.log("Deployer: ", msg.sender);
        console.log("Proxy:    ", proxy);
        console.log("Old impl: ", oldImpl);
        console.log("");

        vm.startBroadcast();
        address newImpl =
            address(new RealmAssetsWhitelist(infra.univ4PoolManager, wrappedNative, univ2Factory, univ3Factory));
        UUPSUpgradeable(proxy).upgradeToAndCall(newImpl, "");
        vm.stopBroadcast();

        require(
            address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT)))) == newImpl,
            "post-upgrade: impl not set"
        );

        console.log("=== Upgraded. Paste into src/config/manifest.%s.sol ===", ChainConfig.name());
        console.log("  ASSETS_WHITELIST_IMPL =", newImpl);
        console.log("");
        console.log("Then: just export-deployments");
    }
}
