// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import {RealmFactoryUniV2Unified} from "src/factories/RealmFactoryUniV2Unified.sol";
import {RealmFactoryUniV4Unified} from "src/factories/RealmFactoryUniV4Unified.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {ChainConfig} from "script/ChainConfig.sol";

/// @title Rewire the unified factories to whatever the manifest currently says
/// @notice Deploys a fresh implementation for each unified factory from the CURRENT manifest and points
///         the two live proxies at them. This is the one upgrade path for the factory layer: every
///         dependency a factory holds — launchpad, bonding curves, graduators, master fee handler, token
///         implementations, creator-vault factory, tier config — is a constructor immutable, so changing
///         any of them means a new implementation and this script.
///
///         Typical use: deploy new token implementations or new graduators with their own one-off
///         script, paste them into `src/config/manifest.<chain>.sol`, run `just export-deployments`,
///         then run this. The proxy addresses never move, so integrators need no changes.
///
///         Deploys nothing but the two implementations, and touches no other contract. The broadcaster
///         must own both proxies.
///
/// @dev    Run: just chain-<sepolia|robinhood> && forge script UpgradeRealmFactories \
///                  --rpc-url <sepolia|robinhood-mainnet> --account realm.dev --slow --broadcast --verify
contract UpgradeRealmFactories is Script {
    function run() public {
        ChainConfig.Manifest memory m = ChainConfig.manifest();
        _require(m);

        console.log("=== Upgrade the unified factories ===");
        console.log("Chain ID: ", block.chainid);
        console.log("Deployer: ", msg.sender);
        console.log("");

        vm.startBroadcast();

        address v2Impl = address(
            new RealmFactoryUniV2Unified(
                m.launchpad,
                IRealmFactory.TokenImpls({base: m.tokenImpl, tax: m.taxTokenV2Impl}),
                m.bondingCurve,
                m.graduatorV2,
                m.masterFeeHandler,
                ChainConfig.creatorVaultFactory(),
                ChainConfig.defaultVaultCurves(),
                ChainConfig.tierCurves()
            )
        );
        address v4Impl = address(
            new RealmFactoryUniV4Unified(
                m.launchpad,
                IRealmFactory.TokenImpls({base: m.tokenImpl, tax: m.taxTokenV4Impl}),
                m.bondingCurve,
                m.graduatorV4,
                m.masterFeeHandler,
                ChainConfig.creatorVaultFactory(),
                ChainConfig.defaultVaultCurves(),
                ChainConfig.v4TierConfig()
            )
        );

        UUPSUpgradeable(m.factoryV2Proxy).upgradeToAndCall(v2Impl, "");
        UUPSUpgradeable(m.factoryV4Proxy).upgradeToAndCall(v4Impl, "");

        vm.stopBroadcast();

        console.log("=== Upgraded. Paste into src/config/manifest.%s.sol ===", ChainConfig.name());
        console.log("  FACTORY_UNIV2_UNIFIED_IMPL =", v2Impl);
        console.log("  FACTORY_UNIV4_UNIFIED_IMPL =", v4Impl);
        console.log("");
        console.log("Then: just export-deployments");
    }

    /// @dev A zero in any of these means the manifest was not refreshed after the last deploy; the
    ///      resulting implementation would be permanently mis-wired, so refuse before broadcasting.
    function _require(ChainConfig.Manifest memory m) internal pure {
        require(m.launchpad != address(0), "manifest: LAUNCHPAD missing");
        require(m.bondingCurve != address(0), "manifest: BONDING_CURVE missing");
        require(m.graduatorV2 != address(0), "manifest: GRADUATOR_UNIV2 missing");
        require(m.graduatorV4 != address(0), "manifest: GRADUATOR_UNIV4 missing");
        require(m.masterFeeHandler != address(0), "manifest: MASTER_FEE_HANDLER missing");
        require(m.tokenImpl != address(0), "manifest: TOKEN_IMPL missing");
        require(m.taxTokenV2Impl != address(0), "manifest: TAXABLE_TOKEN_V2_IMPL missing");
        require(m.taxTokenV4Impl != address(0), "manifest: TAXABLE_TOKEN_V4_IMPL missing");
        require(m.factoryV2Proxy != address(0), "manifest: FACTORY_UNIV2_UNIFIED missing");
        require(m.factoryV4Proxy != address(0), "manifest: FACTORY_UNIV4_UNIFIED missing");
    }
}
