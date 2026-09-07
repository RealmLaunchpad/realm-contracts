// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {RealmFactoryUniV2Unified} from "src/factories/RealmFactoryUniV2Unified.sol";
import {RealmFactoryUniV4Unified} from "src/factories/RealmFactoryUniV4Unified.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {CreatorVaultScriptConfig} from "script/CreatorVaultScriptConfig.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import {DeploymentsEthereumSepolia} from "src/config/manifest.ethereum.sepolia.sol";
import {DeploymentsRobinhoodMainnet} from "src/config/manifest.robinhood.mainnet.sol";

/// @title Redeploy BOTH unified factory implementations and upgrade their proxies — factories only
/// @notice For changes that live in `RealmFactoryAbstract` / the concrete factories ONLY, leaving every
///         token implementation untouched (e.g. a tweak to `_validateTaxConfig`). Unlike
///         `RedeployTaxTokensAndUpgradeFactories`, this deploys NO token impls: it reuses the existing
///         `TOKEN_IMPL`, `TAXABLE_TOKEN_V2_IMPL` and `TAXABLE_TOKEN_V4_IMPL` recorded in the per-chain
///         manifest, wiring the fresh factory impls to them.
///
///         Single broadcast, two new deployments + two proxy upgrades:
///         1. `RealmFactoryUniV2Unified` impl wired to the manifest's V2 token + tax-token impls.
///         2. `RealmFactoryUniV4Unified` impl wired to the manifest's V4 token + tax-token impls
///            (both graduators: 100 bps + 50 bps).
///         3. `upgradeToAndCall(newV2FactoryImpl, "")` on the existing V2 UUPS proxy.
///         4. `upgradeToAndCall(newV4FactoryImpl, "")` on the existing V4 UUPS proxy.
///
///         Proxy addresses are UNCHANGED — launchpad's `whitelistedFactories` entries stay valid;
///         integrators see no address change. No init data is passed; the factories add no storage
///         (their config is constructor immutables, baked into the bytecode).
///
///         The broadcaster MUST be the proxy owner on BOTH proxies. If not, `_authorizeUpgrade`
///         reverts with `OwnableUnauthorizedAccount(broadcaster)` and the whole script reverts.
///
///         Token impls are NOT deployed here, so there is no `DeploymentAddresses` chain-guard to run
///         (`just chain-sepolia` is unnecessary). Pre-flight only sanity-checks the proxies; the
///         fresh impls' `LAUNCHPAD()` is asserted against the manifest before and after the flip.
///
///         Post-broadcast: update `FACTORY_UNIV2_UNIFIED_IMPL` and `FACTORY_UNIV4_UNIFIED_IMPL` in
///         `src/config/manifest.<chain>.sol`, then run `just export-deployments`.
///
/// @dev    Run with:
///         forge script RedeployUnifiedFactoriesOnly --rpc-url <mainnet|sepolia> \
///             --verify --account livo.dev --slow --broadcast
contract RedeployUnifiedFactoriesOnly is Script {
    /// @dev Per-chain addresses needed to wire the new factory implementations and target the proxy
    ///      upgrades. Pulled from `src/config/manifest.<chain>.sol`. Every token impl is reused as-is.
    struct Deps {
        // Proxies to upgrade
        address factoryV2Proxy;
        address factoryV4Proxy;
        // Shared inputs reused by both fresh factory impls
        address launchpad;
        address bondingCurve;
        address graduatorV2;
        address graduatorV4;
        address masterFeeHandler;
        // Existing token impls — reused as-is when wiring the new factories
        address tokenImpl;
        address taxTokenV2Impl;
        address taxTokenV4Impl;
    }

    function _getDeps() internal view returns (Deps memory d) {
        if (block.chainid == DeploymentsEthereumSepolia.BLOCKCHAIN_ID) {
            d = Deps({
                factoryV2Proxy: DeploymentsEthereumSepolia.FACTORY_UNIV2_UNIFIED,
                factoryV4Proxy: DeploymentsEthereumSepolia.FACTORY_UNIV4_UNIFIED,
                launchpad: DeploymentsEthereumSepolia.LAUNCHPAD,
                bondingCurve: DeploymentsEthereumSepolia.BONDING_CURVE,
                graduatorV2: DeploymentsEthereumSepolia.GRADUATOR_UNIV2,
                graduatorV4: DeploymentsEthereumSepolia.GRADUATOR_UNIV4,
                masterFeeHandler: DeploymentsEthereumSepolia.MASTER_FEE_HANDLER,
                tokenImpl: DeploymentsEthereumSepolia.TOKEN_IMPL,
                taxTokenV2Impl: DeploymentsEthereumSepolia.TAXABLE_TOKEN_V2_IMPL,
                taxTokenV4Impl: DeploymentsEthereumSepolia.TAXABLE_TOKEN_V4_IMPL
            });
        } else if (block.chainid == DeploymentsRobinhoodMainnet.BLOCKCHAIN_ID) {
            d = Deps({
                factoryV2Proxy: DeploymentsRobinhoodMainnet.FACTORY_UNIV2_UNIFIED,
                factoryV4Proxy: DeploymentsRobinhoodMainnet.FACTORY_UNIV4_UNIFIED,
                launchpad: DeploymentsRobinhoodMainnet.LAUNCHPAD,
                bondingCurve: DeploymentsRobinhoodMainnet.BONDING_CURVE,
                graduatorV2: DeploymentsRobinhoodMainnet.GRADUATOR_UNIV2,
                graduatorV4: DeploymentsRobinhoodMainnet.GRADUATOR_UNIV4,
                masterFeeHandler: DeploymentsRobinhoodMainnet.MASTER_FEE_HANDLER,
                tokenImpl: DeploymentsRobinhoodMainnet.TOKEN_IMPL,
                taxTokenV2Impl: DeploymentsRobinhoodMainnet.TAXABLE_TOKEN_V2_IMPL,
                taxTokenV4Impl: DeploymentsRobinhoodMainnet.TAXABLE_TOKEN_V4_IMPL
            });
        } else {
            revert("Unsupported chain");
        }

        require(d.factoryV2Proxy != address(0), "manifest: FACTORY_UNIV2_UNIFIED missing");
        require(d.factoryV4Proxy != address(0), "manifest: FACTORY_UNIV4_UNIFIED missing");
        require(d.launchpad != address(0), "manifest: LAUNCHPAD missing");
        require(d.bondingCurve != address(0), "manifest: BONDING_CURVE missing");
        require(d.graduatorV2 != address(0), "manifest: GRADUATOR_UNIV2 missing");
        require(d.graduatorV4 != address(0), "manifest: GRADUATOR_UNIV4 missing");
        require(d.masterFeeHandler != address(0), "manifest: MASTER_FEE_HANDLER missing");
        require(d.tokenImpl != address(0), "manifest: TOKEN_IMPL missing");
        require(d.taxTokenV2Impl != address(0), "manifest: TAXABLE_TOKEN_V2_IMPL missing");
        require(d.taxTokenV4Impl != address(0), "manifest: TAXABLE_TOKEN_V4_IMPL missing");
    }

    function run() public {
        Deps memory d = _getDeps();

        // Catch wrong manifest addresses pointing at non-Realm contracts before we waste deploys.
        address v2ProxyOwner = RealmFactoryUniV2Unified(d.factoryV2Proxy).owner();
        address v4ProxyOwner = RealmFactoryUniV4Unified(d.factoryV4Proxy).owner();
        require(v2ProxyOwner != address(0), "V2 proxy not initialized");
        require(v4ProxyOwner != address(0), "V4 proxy not initialized");
        // Same key is expected to own both proxies; soft sanity check, not a hard protocol invariant.
        require(v2ProxyOwner == v4ProxyOwner, "V2 and V4 proxy owners differ; review before upgrading");

        console.log("=== Realm Unified Factories Redeploy (factories only, tokens reused) ===");
        console.log("Chain ID:                ", block.chainid);
        console.log("Broadcaster:             ", msg.sender);
        console.log("Required proxy owner:    ", v2ProxyOwner);
        console.log("V2 factory proxy:        ", d.factoryV2Proxy);
        console.log("V4 factory proxy:        ", d.factoryV4Proxy);
        console.log("");

        vm.startBroadcast();

        console.log("| Contract Name                                  | Address |");
        console.log("| ---------------------------------------------- | --- |");

        // --- Factory implementations (2) wired to the EXISTING token impls from the manifest ---
        address factoryV2Impl = address(
            new RealmFactoryUniV2Unified(
                d.launchpad,
                IRealmFactory.TokenImpls({base: d.tokenImpl, tax: d.taxTokenV2Impl}),
                d.bondingCurve,
                d.graduatorV2,
                d.masterFeeHandler,
                CreatorVaultScriptConfig.factoryFor(),
                CreatorVaultScriptConfig.curvesFor(),
                CreatorVaultScriptConfig.tierConfigFor()
            )
        );
        console.log("| RealmFactoryUniV2Unified (new impl)            |", factoryV2Impl);

        address factoryV4Impl = address(
            new RealmFactoryUniV4Unified(
                d.launchpad,
                IRealmFactory.TokenImpls({base: d.tokenImpl, tax: d.taxTokenV4Impl}),
                d.bondingCurve,
                d.graduatorV4,
                d.masterFeeHandler,
                CreatorVaultScriptConfig.factoryFor(),
                CreatorVaultScriptConfig.curvesFor(),
                CreatorVaultScriptConfig.v4TierConfigFor()
            )
        );
        console.log("| RealmFactoryUniV4Unified (new impl)            |", factoryV4Impl);

        // --- Proxy upgrades (2) ---
        UUPSUpgradeable(d.factoryV2Proxy).upgradeToAndCall(factoryV2Impl, "");
        console.log("| V2 proxy upgraded to                          |", factoryV2Impl);

        UUPSUpgradeable(d.factoryV4Proxy).upgradeToAndCall(factoryV4Impl, "");
        console.log("| V4 proxy upgraded to                          |", factoryV4Impl);

        vm.stopBroadcast();

        // Post-broadcast: both proxies now delegate to the new impls, so they report the manifest launchpad.
        require(address(RealmFactoryUniV2Unified(d.factoryV2Proxy).LAUNCHPAD()) == d.launchpad, "V2 upgrade failed");
        require(address(RealmFactoryUniV4Unified(d.factoryV4Proxy).LAUNCHPAD()) == d.launchpad, "V4 upgrade failed");

        console.log("");
        console.log("=== Redeploy Complete ===");
        console.log("Proxy addresses are UNCHANGED - no launchpad whitelisting or integrator action needed.");
        console.log("Update the per-chain manifest with these addresses, then run `just export-deployments`:");
        console.log("  FACTORY_UNIV2_UNIFIED_IMPL :", factoryV2Impl);
        console.log("  FACTORY_UNIV4_UNIFIED_IMPL :", factoryV4Impl);
    }
}
