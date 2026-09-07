// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";

import {Script, console} from "forge-std/Script.sol";

import {LivoTaxableTokenUniV2} from "src/tokens/LivoTaxableTokenUniV2.sol";
import {LivoFactoryUniV2Unified} from "src/factories/LivoFactoryUniV2Unified.sol";
import {CreatorVaultScriptConfig} from "script/CreatorVaultScriptConfig.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import {DeploymentAddresses as AddressesFromLivoTaxableTokenV2} from "src/tokens/LivoTaxableTokenUniV2.sol";

import {
    DeploymentAddressesEthereumMainnet,
    DeploymentAddressesEthereumSepolia
} from "src/config/DeploymentAddresses.sol";
import {DeploymentsEthereumMainnet} from "src/config/manifest.ethereum.mainnet.sol";
import {DeploymentsEthereumSepolia} from "src/config/manifest.ethereum.sepolia.sol";

/// @title Redeploy the V2 taxable token implementation and upgrade the V2 unified factory proxy
/// @notice Three-step deploy, all in a single broadcast:
///         1. Deploys a fresh `LivoTaxableTokenUniV2` implementation.
///         2. Deploys a fresh `LivoFactoryUniV2Unified` implementation wired to the new token impl
///            (plus the unchanged non-tax base token impl + bonding curve + V2 graduator + master
///            fee handler + launchpad pulled from the per-chain manifest).
///         3. Calls `upgradeToAndCall(newFactoryImpl, "")` on the existing V2 factory UUPS proxy.
///
///         The proxy address — and therefore the launchpad's `whitelistedFactories` entry — does
///         NOT change. No init data is passed; there are no new storage variables to populate.
///
///         The broadcaster MUST be the proxy owner. If not, `_authorizeUpgrade` reverts with
///         `OwnableUnauthorizedAccount(broadcaster)` and no state changes.
///
///         Pre-broadcast sanity: confirms the V2 token implementation file imports the right
///         per-chain `DeploymentAddresses` (run `just chain-sepolia` before deploying to Sepolia).
///
///         Post-broadcast: update `TAXABLE_TOKEN_V2_IMPL` and the V2 factory impl address in
///         `src/config/manifest.<chain>.sol`, then run `just export-deployments`.
///
/// @dev    Run with:
///         forge script RedeployV2TaxTokensAndUpgradeFactory --rpc-url <mainnet|sepolia> \
///             --verify --account livo.dev --slow --broadcast
contract RedeployV2TaxTokensAndUpgradeFactory is Script {
    /// @dev Per-chain addresses needed to wire the new factory implementation. `factoryV2Proxy` is
    ///      the existing UUPS proxy whose impl we're swapping; everything else is constructor input
    ///      to the fresh factory implementation.
    struct Deps {
        address factoryV2Proxy;
        address launchpad;
        address bondingCurve;
        address graduatorV2;
        address masterFeeHandler;
        address tokenImpl;
    }

    /// @dev Addresses emitted by this script (for logging + manifest updates).
    struct FreshDeployments {
        address taxTokenV2Impl;
        address factoryV2Impl;
    }

    function _getDeps() internal view returns (Deps memory d) {
        if (block.chainid == DeploymentsEthereumMainnet.BLOCKCHAIN_ID) {
            d = Deps({
                factoryV2Proxy: DeploymentsEthereumMainnet.FACTORY_UNIV2_UNIFIED,
                launchpad: DeploymentsEthereumMainnet.LAUNCHPAD,
                bondingCurve: DeploymentsEthereumMainnet.BONDING_CURVE,
                graduatorV2: DeploymentsEthereumMainnet.GRADUATOR_UNIV2,
                masterFeeHandler: DeploymentsEthereumMainnet.MASTER_FEE_HANDLER,
                tokenImpl: DeploymentsEthereumMainnet.TOKEN_IMPL
            });
            require(
                AddressesFromLivoTaxableTokenV2.BLOCKCHAIN_ID == DeploymentAddressesEthereumMainnet.BLOCKCHAIN_ID,
                "LivoTaxableTokenUniV2 import is not Mainnet (run `just chain-sepolia` only for sepolia)"
            );
        } else if (block.chainid == DeploymentsEthereumSepolia.BLOCKCHAIN_ID) {
            d = Deps({
                factoryV2Proxy: DeploymentsEthereumSepolia.FACTORY_UNIV2_UNIFIED,
                launchpad: DeploymentsEthereumSepolia.LAUNCHPAD,
                bondingCurve: DeploymentsEthereumSepolia.BONDING_CURVE,
                graduatorV2: DeploymentsEthereumSepolia.GRADUATOR_UNIV2,
                masterFeeHandler: DeploymentsEthereumSepolia.MASTER_FEE_HANDLER,
                tokenImpl: DeploymentsEthereumSepolia.TOKEN_IMPL
            });
            require(
                AddressesFromLivoTaxableTokenV2.BLOCKCHAIN_ID == DeploymentAddressesEthereumSepolia.BLOCKCHAIN_ID,
                "LivoTaxableTokenUniV2 import is not Sepolia (run `just chain-sepolia`)"
            );
        } else {
            revert("Unsupported chain");
        }

        // The registry address is a compile-time constant baked into every taxable-token implementation,
        // and clones are not upgradeable: an impl deployed while the constant still points at the
        // placeholder (or at a chain where the proxy is not up yet) reverts EVERY third-asset dividend
        // token creation, for good. Deploy the registry proxy first, retarget the constant, then this.
        require(
            AddressesFromLivoTaxableTokenV2.DIVIDEND_SWAP_REGISTRY.code.length != 0,
            "DIVIDEND_SWAP_REGISTRY has no code on this chain: deploy the registry proxy first"
        );

        // Same reasoning, same failure mode: `processDividends`, `processBurn` and `processLiquidity`
        // all fail closed against a codeless keeper registry, so an impl deployed before it exists can
        // never run a conversion.
        require(
            AddressesFromLivoTaxableTokenV2.LIVO_KEEPERS_REGISTRY.code.length != 0,
            "LIVO_KEEPERS_REGISTRY has no code on this chain: deploy the keepers registry first"
        );

        require(d.factoryV2Proxy != address(0), "manifest: FACTORY_UNIV2_UNIFIED missing");
        require(d.launchpad != address(0), "manifest: LAUNCHPAD missing");
        require(d.bondingCurve != address(0), "manifest: BONDING_CURVE missing");
        require(d.graduatorV2 != address(0), "manifest: GRADUATOR_UNIV2 missing");
        require(d.masterFeeHandler != address(0), "manifest: MASTER_FEE_HANDLER missing");
        require(d.tokenImpl != address(0), "manifest: TOKEN_IMPL missing");
    }

    function run() public {
        Deps memory d = _getDeps();
        FreshDeployments memory fresh;

        // Catch a wrong manifest address pointing at a non-Livo contract before we waste a deploy.
        address proxyOwner = LivoFactoryUniV2Unified(d.factoryV2Proxy).owner();
        require(proxyOwner != address(0), "V2 proxy not initialized");

        console.log("=== Livo V2 Tax Stack Redeploy ===");
        console.log("Chain ID:                ", block.chainid);
        console.log("Broadcaster:             ", msg.sender);
        console.log("Required proxy owner:    ", proxyOwner);
        console.log("V2 factory proxy:        ", d.factoryV2Proxy);
        console.log("");

        vm.startBroadcast();

        console.log("| Contract Name                                  | Address |");
        console.log("| ---------------------------------------------- | --- |");

        fresh.taxTokenV2Impl = address(new LivoTaxableTokenUniV2());
        console.log("| LivoTaxableTokenUniV2 (new impl)              |", fresh.taxTokenV2Impl);

        fresh.factoryV2Impl = address(
            new LivoFactoryUniV2Unified(
                d.launchpad,
                ILivoFactory.TokenImpls({base: d.tokenImpl, tax: fresh.taxTokenV2Impl}),
                d.bondingCurve,
                d.graduatorV2,
                d.masterFeeHandler,
                CreatorVaultScriptConfig.factoryFor(),
                CreatorVaultScriptConfig.curvesFor(),
                CreatorVaultScriptConfig.tierConfigFor()
            )
        );
        console.log("| LivoFactoryUniV2Unified (new impl)            |", fresh.factoryV2Impl);

        UUPSUpgradeable(d.factoryV2Proxy).upgradeToAndCall(fresh.factoryV2Impl, "");
        console.log("| V2 proxy upgraded to                          |", fresh.factoryV2Impl);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Redeploy Complete ===");
        console.log("Proxy address is UNCHANGED - no launchpad whitelisting or integrator action needed.");
        console.log("Update the per-chain manifest with these addresses, then run `just export-deployments`:");
        console.log("  TAXABLE_TOKEN_V2_IMPL                  :", fresh.taxTokenV2Impl);
        console.log("  LivoFactoryUniV2Unified impl           :", fresh.factoryV2Impl);
    }
}
