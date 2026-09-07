// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";

import {Script, console} from "forge-std/Script.sol";

import {RealmFactoryAbstract} from "src/factories/RealmFactoryAbstract.sol";
import {CreatorVaultScriptConfig} from "script/CreatorVaultScriptConfig.sol";
import {RealmFactoryUniV2Unified} from "src/factories/RealmFactoryUniV2Unified.sol";
import {RealmFactoryUniV4Unified} from "src/factories/RealmFactoryUniV4Unified.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DeploymentAddresses as AddressesFromRealmTaxableToken} from "src/tokens/RealmTaxableTokenUniV4.sol";

import {
    DeploymentAddressesEthereumMainnet,
    DeploymentAddressesEthereumSepolia,
    DeploymentAddressesArcTestnet
} from "src/config/DeploymentAddresses.sol";
import {DeploymentsEthereumMainnet} from "src/config/manifest.ethereum.mainnet.sol";
import {DeploymentsEthereumSepolia} from "src/config/manifest.ethereum.sepolia.sol";
import {DeploymentsArcTestnet} from "src/config/manifest.arc.testnet.sol";

/// @title Deploy the unified factory implementations and their UUPS proxies
/// @notice Deploys ONLY the four contracts that are net-new for this run:
///         1. `RealmFactoryUniV2Unified` (implementation) + its `ERC1967Proxy`
///         2. `RealmFactoryUniV4Unified` (implementation) + its `ERC1967Proxy`
///
///         Every other dependency — launchpad, bonding curve, graduators, master fee handler,
///         and every token implementation — is sourced from the per-chain manifest in
///         `src/config/manifest.{mainnet,sepolia}.sol`. To redeploy any of those, use the
///         dedicated script for that component, not this one.
///
///         The proxy is the address the launchpad whitelists and that integrators track —
///         it stays stable across future implementation upgrades that don't break the ABI.
///
///         Whitelisting on the launchpad is intentionally NOT done here — the launchpad
///         owner (`livo.admin`) must whitelist the proxy address after broadcast finishes
///         (see "Next steps").
///
/// @dev    Run with:
///         forge script DeploymentsUnifiedFactories --rpc-url <mainnet|sepolia> --verify --account livo.dev --slow --broadcast
contract DeploymentsUnifiedFactories is Script {
    /// @dev Pre-deployed core addresses sourced from the per-chain manifest. None of these are
    ///      redeployed by this script.
    struct Deps {
        address launchpad;
        address bondingCurve;
        address graduatorV2;
        address graduatorV4;
        address masterFeeHandler;
        address tokenImpl;
        address taxTokenImpl;
        address taxTokenV2Impl;
    }

    /// @dev Freshly-deployed addresses emitted by this script.
    struct FreshDeployments {
        address factoryV2Impl;
        address factoryV2;
        address factoryV4Impl;
        address factoryV4;
    }

    /// @notice Resolves core dependency addresses for the active chain.
    /// @dev Asserts that `RealmTaxableTokenUniV4`'s hardcoded chain import matches the active chain
    ///      (run `just chain-sepolia` before deploying to sepolia).
    function _getDeps() internal view returns (Deps memory d) {
        if (block.chainid == DeploymentsEthereumMainnet.BLOCKCHAIN_ID) {
            d = Deps({
                launchpad: DeploymentsEthereumMainnet.LAUNCHPAD,
                bondingCurve: DeploymentsEthereumMainnet.BONDING_CURVE,
                graduatorV2: DeploymentsEthereumMainnet.GRADUATOR_UNIV2,
                graduatorV4: DeploymentsEthereumMainnet.GRADUATOR_UNIV4,
                masterFeeHandler: DeploymentsEthereumMainnet.MASTER_FEE_HANDLER,
                tokenImpl: DeploymentsEthereumMainnet.TOKEN_IMPL,
                taxTokenImpl: DeploymentsEthereumMainnet.TAXABLE_TOKEN_V4_IMPL,
                taxTokenV2Impl: DeploymentsEthereumMainnet.TAXABLE_TOKEN_V2_IMPL
            });
            require(
                AddressesFromRealmTaxableToken.UNIV4_POOL_MANAGER
                    == DeploymentAddressesEthereumMainnet.UNIV4_POOL_MANAGER,
                "RealmTaxableTokenUniV4 import is not Mainnet"
            );
        } else if (block.chainid == DeploymentsEthereumSepolia.BLOCKCHAIN_ID) {
            d = Deps({
                launchpad: DeploymentsEthereumSepolia.LAUNCHPAD,
                bondingCurve: DeploymentsEthereumSepolia.BONDING_CURVE,
                graduatorV2: DeploymentsEthereumSepolia.GRADUATOR_UNIV2,
                graduatorV4: DeploymentsEthereumSepolia.GRADUATOR_UNIV4,
                masterFeeHandler: DeploymentsEthereumSepolia.MASTER_FEE_HANDLER,
                tokenImpl: DeploymentsEthereumSepolia.TOKEN_IMPL,
                taxTokenImpl: DeploymentsEthereumSepolia.TAXABLE_TOKEN_V4_IMPL,
                taxTokenV2Impl: DeploymentsEthereumSepolia.TAXABLE_TOKEN_V2_IMPL
            });
            require(
                AddressesFromRealmTaxableToken.UNIV4_POOL_MANAGER
                    == DeploymentAddressesEthereumSepolia.UNIV4_POOL_MANAGER,
                "RealmTaxableTokenUniV4 import is not Sepolia (run `just chain-sepolia`)"
            );
        } else if (block.chainid == DeploymentsArcTestnet.BLOCKCHAIN_ID) {
            d = Deps({
                launchpad: DeploymentsArcTestnet.LAUNCHPAD,
                bondingCurve: DeploymentsArcTestnet.BONDING_CURVE,
                graduatorV2: DeploymentsArcTestnet.GRADUATOR_UNIV2,
                graduatorV4: DeploymentsArcTestnet.GRADUATOR_UNIV4,
                masterFeeHandler: DeploymentsArcTestnet.MASTER_FEE_HANDLER,
                tokenImpl: DeploymentsArcTestnet.TOKEN_IMPL,
                taxTokenImpl: DeploymentsArcTestnet.TAXABLE_TOKEN_V4_IMPL,
                taxTokenV2Impl: DeploymentsArcTestnet.TAXABLE_TOKEN_V2_IMPL
            });
            require(
                AddressesFromRealmTaxableToken.UNIV4_POOL_MANAGER == DeploymentAddressesArcTestnet.UNIV4_POOL_MANAGER,
                "RealmTaxableTokenUniV4 import is not ARC testnet (run `just chain-arc-testnet`)"
            );
        } else {
            revert("Unsupported chain");
        }

        // Belt-and-braces: catch a stale or zero address in the manifest before we waste a deploy.
        require(d.launchpad != address(0), "manifest: LAUNCHPAD missing");
        require(d.bondingCurve != address(0), "manifest: BONDING_CURVE missing");
        require(d.graduatorV2 != address(0), "manifest: GRADUATOR_UNIV2 missing");
        require(d.graduatorV4 != address(0), "manifest: GRADUATOR_UNIV4 missing");
        require(d.masterFeeHandler != address(0), "manifest: MASTER_FEE_HANDLER missing");
        require(d.tokenImpl != address(0), "manifest: TOKEN_IMPL missing");
        require(d.taxTokenImpl != address(0), "manifest: TAXABLE_TOKEN_V4_IMPL missing");
        require(d.taxTokenV2Impl != address(0), "manifest: TAXABLE_TOKEN_V2_IMPL missing");
    }

    function run() public {
        Deps memory d = _getDeps();
        FreshDeployments memory fresh;

        console.log("=== Realm Unified Factories Deployment ===");
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", msg.sender);
        console.log("Launchpad:", d.launchpad);
        console.log("");

        vm.startBroadcast();

        console.log("| Contract Name                          | Address |");
        console.log("| -------------------------------------- | --- |");

        fresh.factoryV2Impl = address(
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
        console.log("| RealmFactoryUniV2Unified (impl)        |", fresh.factoryV2Impl);

        fresh.factoryV2 =
            address(new ERC1967Proxy(fresh.factoryV2Impl, abi.encodeCall(RealmFactoryAbstract.initialize, ())));
        console.log("| RealmFactoryUniV2Unified (proxy)       |", fresh.factoryV2);

        fresh.factoryV4Impl = address(
            new RealmFactoryUniV4Unified(
                d.launchpad,
                IRealmFactory.TokenImpls({base: d.tokenImpl, tax: d.taxTokenImpl}),
                d.bondingCurve,
                d.graduatorV4,
                d.masterFeeHandler,
                CreatorVaultScriptConfig.factoryFor(),
                CreatorVaultScriptConfig.curvesFor(),
                CreatorVaultScriptConfig.v4TierConfigFor()
            )
        );
        console.log("| RealmFactoryUniV4Unified (impl)        |", fresh.factoryV4Impl);

        fresh.factoryV4 =
            address(new ERC1967Proxy(fresh.factoryV4Impl, abi.encodeCall(RealmFactoryAbstract.initialize, ())));
        console.log("| RealmFactoryUniV4Unified (proxy)       |", fresh.factoryV4);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("Next steps:");
        console.log("1. Update FACTORY_UNIV2_UNIFIED and FACTORY_UNIV4_UNIFIED in");
        console.log("   src/config/manifest.{mainnet,sepolia}.sol with the proxy addresses above.");
        console.log("2. Run `just export-deployments` to refresh the .md manifests and commit them.");
        console.log("3. Whitelist both factory PROXIES on the launchpad with the launchpad-owner account:");
        console.log("   cast send <LAUNCHPAD> 'whitelistFactory(address)' <factoryV2 proxy> --account livo.admin");
        console.log("   cast send <LAUNCHPAD> 'whitelistFactory(address)' <factoryV4 proxy> --account livo.admin");
    }
}
