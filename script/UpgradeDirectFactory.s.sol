// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import {RealmFactoryUniV4Direct} from "src/factories/RealmFactoryUniV4Direct.sol";
import {RealmFactoryAbstract} from "src/factories/RealmFactoryAbstract.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {ChainConfig} from "script/ChainConfig.sol";
import {UpgradeRealmFactories} from "script/UpgradeRealmFactories.s.sol";

/// @title Upgrade only the direct-launch factory
/// @notice Deploys a fresh `RealmFactoryUniV4Direct` implementation from the CURRENT manifest (same
///         graduator, whitelist and token impls) and points `FACTORY_UNIV4_DIRECT` at it. For changes to
///         the factory's own code or constants; touches no other contract. `UpgradeRealmFactories` also
///         redeploys the V2 factory, `UpgradeDirectVenue` also redeploys the graduator.
/// @dev    Run: just upgrade-direct-factory-<rh|rh-testnet>
///         Dry-run first: the same `forge script` without --broadcast, plus --sender <owner address>.
contract UpgradeDirectFactory is UpgradeRealmFactories {
    function run() public override {
        ChainConfig.Manifest memory m = ChainConfig.manifest();
        _require(m);
        address whitelist = ChainConfig.assetsWhitelist();

        console.log("=== Upgrade the direct factory ===");
        console.log("Chain ID: ", block.chainid);
        console.log("Deployer: ", msg.sender);
        console.log("");

        vm.startBroadcast();
        address impl = address(
            new RealmFactoryUniV4Direct(
                IRealmFactory.TokenImpls({base: m.tokenImpl, tax: m.taxTokenV4Impl}),
                m.graduatorV4Direct,
                m.masterFeeHandler,
                ChainConfig.creatorVaultFactory(),
                ChainConfig.wrappedNative(),
                whitelist
            )
        );
        UUPSUpgradeable(m.factoryV4DirectProxy)
            .upgradeToAndCall(impl, abi.encodeCall(RealmFactoryAbstract.announceGraduator, ()));
        vm.stopBroadcast();

        RealmFactoryUniV4Direct factory = RealmFactoryUniV4Direct(payable(m.factoryV4DirectProxy));
        require(address(factory.GRADUATOR()) == m.graduatorV4Direct, "post-upgrade: graduator moved");
        require(address(factory.ASSETS_WHITELIST()) == whitelist, "post-upgrade: whitelist moved");

        console.log("=== Upgraded. Paste into src/config/manifest.%s.sol ===", ChainConfig.name());
        console.log("  FACTORY_UNIV4_DIRECT_IMPL =", impl);
        console.log("");
        console.log("Then: just export-deployments");
    }
}
