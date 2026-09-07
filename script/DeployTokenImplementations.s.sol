// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {LivoToken} from "src/tokens/LivoToken.sol";
import {LivoTaxableTokenUniV2} from "src/tokens/LivoTaxableTokenUniV2.sol";
import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";

import {DeploymentAddresses as AddressesFromLivoTaxableTokenV2} from "src/tokens/LivoTaxableTokenUniV2.sol";
import {DeploymentAddresses as AddressesFromLivoTaxableTokenV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {
    DeploymentAddressesEthereumMainnet,
    DeploymentAddressesEthereumSepolia,
    DeploymentAddressesArcTestnet
} from "src/config/DeploymentAddresses.sol";

/// @title Deploy the three token implementations only — no factory deploy, no proxy upgrade
/// @notice All three are no-arg clone masters, so this deploy has no dependency on the manifest: the
///         addresses that reference these implementations (a factory's constructor) are wired up by
///         a separate script (e.g. `DeploymentsUnifiedFactories`), which lets a fresh factory be
///         deployed and whitelisted WITHOUT touching the live factory proxy or its token impls.
///         1. `LivoToken`
///         2. `LivoTaxableTokenUniV2`
///         3. `LivoTaxableTokenUniV4`
///
///         Anti-sniper protection is a gated feature of these impls (a warm-slot flag), not a
///         separate implementation — there is no sniper-protected variant to deploy.
///
///         Pre-broadcast sanity: confirms that `LivoTaxableTokenUniV2` and `LivoTaxableTokenUniV4`
///         have their hardcoded `DeploymentAddresses` import pointing at the active chain (run
///         `just taxtokenaddresses` before deploying to Sepolia).
///
///         Post-broadcast: feed these three addresses into whichever script wires up the factory that
///         will clone them (e.g. `DeploymentsUnifiedFactories`); update the manifest only once that
///         factory is live, so the manifest never points at token impls with no factory using them.
///
/// @dev    Run with:
///         forge script DeployTokenImplementations --rpc-url <mainnet|sepolia> \
///             --verify --account livo.dev --slow --broadcast
contract DeployTokenImplementations is Script {
    struct FreshDeployments {
        address tokenImpl;
        address taxTokenV2Impl;
        address taxTokenV4Impl;
    }

    function _checkTaxableTokenChainAddresses() internal view {
        if (block.chainid == DeploymentAddressesEthereumMainnet.BLOCKCHAIN_ID) {
            require(
                AddressesFromLivoTaxableTokenV2.BLOCKCHAIN_ID == DeploymentAddressesEthereumMainnet.BLOCKCHAIN_ID,
                "LivoTaxableTokenUniV2 import is not Mainnet (run `just taxtokenaddresses` only for sepolia)"
            );
            require(
                AddressesFromLivoTaxableTokenV4.UNIV4_POOL_MANAGER
                    == DeploymentAddressesEthereumMainnet.UNIV4_POOL_MANAGER,
                "LivoTaxableTokenUniV4 import is not Mainnet"
            );
        } else if (block.chainid == DeploymentAddressesEthereumSepolia.BLOCKCHAIN_ID) {
            require(
                AddressesFromLivoTaxableTokenV2.BLOCKCHAIN_ID == DeploymentAddressesEthereumSepolia.BLOCKCHAIN_ID,
                "LivoTaxableTokenUniV2 import is not Sepolia (run `just taxtokenaddresses`)"
            );
            require(
                AddressesFromLivoTaxableTokenV4.UNIV4_POOL_MANAGER
                    == DeploymentAddressesEthereumSepolia.UNIV4_POOL_MANAGER,
                "LivoTaxableTokenUniV4 import is not Sepolia (run `just taxtokenaddresses`)"
            );
        } else if (block.chainid == DeploymentAddressesArcTestnet.BLOCKCHAIN_ID) {
            require(
                AddressesFromLivoTaxableTokenV2.BLOCKCHAIN_ID == DeploymentAddressesArcTestnet.BLOCKCHAIN_ID,
                "LivoTaxableTokenUniV2 import is not ARC testnet (run `just chain-arc-testnet`)"
            );
            require(
                AddressesFromLivoTaxableTokenV4.UNIV4_POOL_MANAGER == DeploymentAddressesArcTestnet.UNIV4_POOL_MANAGER,
                "LivoTaxableTokenUniV4 import is not ARC testnet (run `just chain-arc-testnet`)"
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
    }

    function run() public {
        _checkTaxableTokenChainAddresses();
        FreshDeployments memory fresh;

        console.log("=== Deploy Token Implementations (no factory, no proxy upgrade) ===");
        console.log("Chain ID:   ", block.chainid);
        console.log("Broadcaster:", msg.sender);
        console.log("");

        vm.startBroadcast();

        console.log("| Contract Name                                  | Address |");
        console.log("| ---------------------------------------------- | --- |");

        fresh.tokenImpl = address(new LivoToken());
        console.log("| LivoToken                                     |", fresh.tokenImpl);

        fresh.taxTokenV2Impl = address(new LivoTaxableTokenUniV2());
        console.log("| LivoTaxableTokenUniV2                         |", fresh.taxTokenV2Impl);

        fresh.taxTokenV4Impl = address(new LivoTaxableTokenUniV4());
        console.log("| LivoTaxableTokenUniV4                         |", fresh.taxTokenV4Impl);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deploy Complete ===");
        console.log("No factory was deployed and no proxy was upgraded. These impls are unused until a");
        console.log("factory constructor references them (e.g. `DeploymentsUnifiedFactories`).");
        console.log("  TOKEN_IMPL                              :", fresh.tokenImpl);
        console.log("  TAXABLE_TOKEN_V2_IMPL                   :", fresh.taxTokenV2Impl);
        console.log("  TAXABLE_TOKEN_V4_IMPL                   :", fresh.taxTokenV4Impl);
    }
}
