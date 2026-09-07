// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {DeploymentsEthereumMainnet} from "src/config/manifest.ethereum.mainnet.sol";
import {DeploymentsEthereumSepolia} from "src/config/manifest.ethereum.sepolia.sol";
import {DeploymentsRobinhoodMainnet} from "src/config/manifest.robinhood.mainnet.sol";
import {DeploymentsRobinhoodTestnet} from "src/config/manifest.robinhood.testnet.sol";
import {DeploymentsArcMainnet} from "src/config/manifest.arc.mainnet.sol";
import {DeploymentsArcTestnet} from "src/config/manifest.arc.testnet.sol";
import {
    DeploymentAddressesEthereumMainnet,
    DeploymentAddressesEthereumSepolia,
    DeploymentAddressesRobinhoodMainnet,
    DeploymentAddressesRobinhoodTestnet,
    DeploymentAddressesArcMainnet,
    DeploymentAddressesArcTestnet
} from "src/config/DeploymentAddresses.sol";

/// @title ExportDeployments
/// @notice Renders `deployments.<chain>.md` from the Solidity manifests, one file per chain.
/// @dev Run with `just export-deployments` (or `forge script ExportDeployments`). The
///      output `.md` files are generated artifacts — never edit them by hand. CI runs
///      this script and fails if the result differs from what is committed.
contract ExportDeployments is Script {
    /// @dev All addresses of a single chain, collected from that chain's manifest +
    ///      `DeploymentAddresses` library, so one renderer serves every chain.
    struct ChainDeployments {
        string title; // markdown heading, e.g. "Robinhood Chain Mainnet"
        string manifestFile; // for the "do not hand-edit" banner
        // --- Livo core ---
        address launchpad;
        address bondingCurve;
        address graduatorUniV2;
        address graduatorUniV4;
        address masterFeeHandler;
        address univ4LiquidityAdder;
        address swapHook;
        address lpFeeRouter;
        address lpFeeRouterImpl;
        address quoter;
        address tokenImpl;
        address taxableTokenImpl;
        address taxableTokenV2Impl;
        address factoryUniV2Unified;
        address factoryUniV2UnifiedImpl;
        address factoryUniV4Unified;
        address factoryUniV4UnifiedImpl;
        address creatorVaultFactory;
        address creatorVaultFactoryImpl;
        address creatorVaultImpl;
        address[6] vaultCurves;
        address graduatorThin;
        address graduatorThick;
        address thinCurveBase;
        address[6] thinVaultCurves;
        address thickCurveBase;
        address[6] thickVaultCurves;
        // --- Accounts ---
        address livoDev;
        address livoTreasury;
        address livoTokenDeployer;
        // --- Integrations ---
        address weth;
        address univ2Router;
        address univ2Factory;
        address univ4PoolManager;
        address univ4PositionManager;
        address univ4UniversalRouter;
        address permit2;
    }

    function run() public {
        _write("deployments.ethereum.mainnet.md", _render(_ethereumMainnet()));
        _write("deployments.ethereum.sepolia.md", _render(_ethereumSepolia()));
        _write("deployments.robinhood.mainnet.md", _render(_robinhoodMainnet()));
        _write("deployments.robinhood.testnet.md", _render(_robinhoodTestnet()));
        _write("deployments.arc.mainnet.md", _render(_arcMainnet()));
        _write("deployments.arc.testnet.md", _render(_arcTestnet()));
    }

    function _write(string memory path, string memory content) internal {
        vm.writeFile(path, content);
        console.log("Wrote %s (%d bytes)", path, bytes(content).length);
    }

    // ---------------------------------------------------------------- Per-chain collectors

    function _ethereumMainnet() internal pure returns (ChainDeployments memory d) {
        d.title = "Mainnet";
        d.manifestFile = "manifest.ethereum.mainnet.sol";
        d.launchpad = DeploymentsEthereumMainnet.LAUNCHPAD;
        d.bondingCurve = DeploymentsEthereumMainnet.BONDING_CURVE;
        d.graduatorUniV2 = DeploymentsEthereumMainnet.GRADUATOR_UNIV2;
        d.graduatorUniV4 = DeploymentsEthereumMainnet.GRADUATOR_UNIV4;
        d.masterFeeHandler = DeploymentsEthereumMainnet.MASTER_FEE_HANDLER;
        d.univ4LiquidityAdder = DeploymentsEthereumMainnet.UNIV4_LIQUIDITY_ADDER;
        d.swapHook = DeploymentsEthereumMainnet.SWAP_HOOK;
        d.lpFeeRouter = DeploymentsEthereumMainnet.LP_FEE_ROUTER;
        d.lpFeeRouterImpl = DeploymentsEthereumMainnet.LP_FEE_ROUTER_IMPL;
        d.quoter = DeploymentsEthereumMainnet.QUOTER;
        d.tokenImpl = DeploymentsEthereumMainnet.TOKEN_IMPL;
        d.taxableTokenImpl = DeploymentsEthereumMainnet.TAXABLE_TOKEN_V4_IMPL;
        d.taxableTokenV2Impl = DeploymentsEthereumMainnet.TAXABLE_TOKEN_V2_IMPL;
        d.factoryUniV2Unified = DeploymentsEthereumMainnet.FACTORY_UNIV2_UNIFIED;
        d.factoryUniV2UnifiedImpl = DeploymentsEthereumMainnet.FACTORY_UNIV2_UNIFIED_IMPL;
        d.factoryUniV4Unified = DeploymentsEthereumMainnet.FACTORY_UNIV4_UNIFIED;
        d.factoryUniV4UnifiedImpl = DeploymentsEthereumMainnet.FACTORY_UNIV4_UNIFIED_IMPL;
        d.creatorVaultFactory = DeploymentsEthereumMainnet.CREATOR_VAULT_FACTORY;
        d.creatorVaultFactoryImpl = DeploymentsEthereumMainnet.CREATOR_VAULT_FACTORY_IMPL;
        d.creatorVaultImpl = DeploymentsEthereumMainnet.CREATOR_VAULT_IMPL;
        d.vaultCurves = DeploymentsEthereumMainnet.vaultBondingCurves();
        d.graduatorThin = DeploymentsEthereumMainnet.GRADUATOR_UNIV4_THIN;
        d.graduatorThick = DeploymentsEthereumMainnet.GRADUATOR_UNIV4_THICK;
        d.thinCurveBase = DeploymentsEthereumMainnet.THIN_CURVE_BASE;
        d.thinVaultCurves = DeploymentsEthereumMainnet.thinVaultCurves();
        d.thickCurveBase = DeploymentsEthereumMainnet.THICK_CURVE_BASE;
        d.thickVaultCurves = DeploymentsEthereumMainnet.thickVaultCurves();
        d.livoDev = DeploymentsEthereumMainnet.LIVO_DEV;
        d.livoTreasury = DeploymentAddressesEthereumMainnet.LIVO_TREASURY;
        d.livoTokenDeployer = DeploymentsEthereumMainnet.LIVO_TOKEN_DEPLOYER;
        d.weth = DeploymentAddressesEthereumMainnet.WETH;
        d.univ2Router = DeploymentAddressesEthereumMainnet.UNIV2_ROUTER;
        d.univ2Factory = DeploymentAddressesEthereumMainnet.UNIV2_FACTORY;
        d.univ4PoolManager = DeploymentAddressesEthereumMainnet.UNIV4_POOL_MANAGER;
        d.univ4PositionManager = DeploymentAddressesEthereumMainnet.UNIV4_POSITION_MANAGER;
        d.univ4UniversalRouter = DeploymentAddressesEthereumMainnet.UNIV4_UNIVERSAL_ROUTER;
        d.permit2 = DeploymentAddressesEthereumMainnet.PERMIT2;
    }

    function _ethereumSepolia() internal pure returns (ChainDeployments memory d) {
        d.title = "Sepolia";
        d.manifestFile = "manifest.ethereum.sepolia.sol";
        d.launchpad = DeploymentsEthereumSepolia.LAUNCHPAD;
        d.bondingCurve = DeploymentsEthereumSepolia.BONDING_CURVE;
        d.graduatorUniV2 = DeploymentsEthereumSepolia.GRADUATOR_UNIV2;
        d.graduatorUniV4 = DeploymentsEthereumSepolia.GRADUATOR_UNIV4;
        d.masterFeeHandler = DeploymentsEthereumSepolia.MASTER_FEE_HANDLER;
        d.univ4LiquidityAdder = DeploymentsEthereumSepolia.UNIV4_LIQUIDITY_ADDER;
        d.swapHook = DeploymentsEthereumSepolia.SWAP_HOOK;
        d.lpFeeRouter = DeploymentsEthereumSepolia.LP_FEE_ROUTER;
        d.lpFeeRouterImpl = DeploymentsEthereumSepolia.LP_FEE_ROUTER_IMPL;
        d.quoter = DeploymentsEthereumSepolia.QUOTER;
        d.tokenImpl = DeploymentsEthereumSepolia.TOKEN_IMPL;
        d.taxableTokenImpl = DeploymentsEthereumSepolia.TAXABLE_TOKEN_V4_IMPL;
        d.taxableTokenV2Impl = DeploymentsEthereumSepolia.TAXABLE_TOKEN_V2_IMPL;
        d.factoryUniV2Unified = DeploymentsEthereumSepolia.FACTORY_UNIV2_UNIFIED;
        d.factoryUniV2UnifiedImpl = DeploymentsEthereumSepolia.FACTORY_UNIV2_UNIFIED_IMPL;
        d.factoryUniV4Unified = DeploymentsEthereumSepolia.FACTORY_UNIV4_UNIFIED;
        d.factoryUniV4UnifiedImpl = DeploymentsEthereumSepolia.FACTORY_UNIV4_UNIFIED_IMPL;
        d.creatorVaultFactory = DeploymentsEthereumSepolia.CREATOR_VAULT_FACTORY;
        d.creatorVaultFactoryImpl = DeploymentsEthereumSepolia.CREATOR_VAULT_FACTORY_IMPL;
        d.creatorVaultImpl = DeploymentsEthereumSepolia.CREATOR_VAULT_IMPL;
        d.vaultCurves = DeploymentsEthereumSepolia.vaultBondingCurves();
        d.graduatorThin = DeploymentsEthereumSepolia.GRADUATOR_UNIV4_THIN;
        d.graduatorThick = DeploymentsEthereumSepolia.GRADUATOR_UNIV4_THICK;
        d.thinCurveBase = DeploymentsEthereumSepolia.THIN_CURVE_BASE;
        d.thinVaultCurves = DeploymentsEthereumSepolia.thinVaultCurves();
        d.thickCurveBase = DeploymentsEthereumSepolia.THICK_CURVE_BASE;
        d.thickVaultCurves = DeploymentsEthereumSepolia.thickVaultCurves();
        d.livoDev = DeploymentsEthereumSepolia.LIVO_DEV;
        d.livoTreasury = DeploymentAddressesEthereumSepolia.LIVO_TREASURY;
        d.livoTokenDeployer = DeploymentsEthereumSepolia.LIVO_TOKEN_DEPLOYER;
        d.weth = DeploymentAddressesEthereumSepolia.WETH;
        d.univ2Router = DeploymentAddressesEthereumSepolia.UNIV2_ROUTER;
        d.univ2Factory = DeploymentAddressesEthereumSepolia.UNIV2_FACTORY;
        d.univ4PoolManager = DeploymentAddressesEthereumSepolia.UNIV4_POOL_MANAGER;
        d.univ4PositionManager = DeploymentAddressesEthereumSepolia.UNIV4_POSITION_MANAGER;
        d.univ4UniversalRouter = DeploymentAddressesEthereumSepolia.UNIV4_UNIVERSAL_ROUTER;
        d.permit2 = DeploymentAddressesEthereumSepolia.PERMIT2;
    }

    function _robinhoodMainnet() internal pure returns (ChainDeployments memory d) {
        d.title = "Robinhood Chain Mainnet";
        d.manifestFile = "manifest.robinhood.mainnet.sol";
        d.launchpad = DeploymentsRobinhoodMainnet.LAUNCHPAD;
        d.bondingCurve = DeploymentsRobinhoodMainnet.BONDING_CURVE;
        d.graduatorUniV2 = DeploymentsRobinhoodMainnet.GRADUATOR_UNIV2;
        d.graduatorUniV4 = DeploymentsRobinhoodMainnet.GRADUATOR_UNIV4;
        d.masterFeeHandler = DeploymentsRobinhoodMainnet.MASTER_FEE_HANDLER;
        d.univ4LiquidityAdder = DeploymentsRobinhoodMainnet.UNIV4_LIQUIDITY_ADDER;
        d.swapHook = DeploymentsRobinhoodMainnet.SWAP_HOOK;
        d.lpFeeRouter = DeploymentsRobinhoodMainnet.LP_FEE_ROUTER;
        d.lpFeeRouterImpl = DeploymentsRobinhoodMainnet.LP_FEE_ROUTER_IMPL;
        d.quoter = DeploymentsRobinhoodMainnet.QUOTER;
        d.tokenImpl = DeploymentsRobinhoodMainnet.TOKEN_IMPL;
        d.taxableTokenImpl = DeploymentsRobinhoodMainnet.TAXABLE_TOKEN_V4_IMPL;
        d.taxableTokenV2Impl = DeploymentsRobinhoodMainnet.TAXABLE_TOKEN_V2_IMPL;
        d.factoryUniV2Unified = DeploymentsRobinhoodMainnet.FACTORY_UNIV2_UNIFIED;
        d.factoryUniV2UnifiedImpl = DeploymentsRobinhoodMainnet.FACTORY_UNIV2_UNIFIED_IMPL;
        d.factoryUniV4Unified = DeploymentsRobinhoodMainnet.FACTORY_UNIV4_UNIFIED;
        d.factoryUniV4UnifiedImpl = DeploymentsRobinhoodMainnet.FACTORY_UNIV4_UNIFIED_IMPL;
        d.creatorVaultFactory = DeploymentsRobinhoodMainnet.CREATOR_VAULT_FACTORY;
        d.creatorVaultFactoryImpl = DeploymentsRobinhoodMainnet.CREATOR_VAULT_FACTORY_IMPL;
        d.creatorVaultImpl = DeploymentsRobinhoodMainnet.CREATOR_VAULT_IMPL;
        d.vaultCurves = DeploymentsRobinhoodMainnet.vaultBondingCurves();
        d.graduatorThin = DeploymentsRobinhoodMainnet.GRADUATOR_UNIV4_THIN;
        d.graduatorThick = DeploymentsRobinhoodMainnet.GRADUATOR_UNIV4_THICK;
        d.thinCurveBase = DeploymentsRobinhoodMainnet.THIN_CURVE_BASE;
        d.thinVaultCurves = DeploymentsRobinhoodMainnet.thinVaultCurves();
        d.thickCurveBase = DeploymentsRobinhoodMainnet.THICK_CURVE_BASE;
        d.thickVaultCurves = DeploymentsRobinhoodMainnet.thickVaultCurves();
        d.livoDev = DeploymentsRobinhoodMainnet.LIVO_DEV;
        d.livoTreasury = DeploymentAddressesRobinhoodMainnet.LIVO_TREASURY;
        d.livoTokenDeployer = DeploymentsRobinhoodMainnet.LIVO_TOKEN_DEPLOYER;
        d.weth = DeploymentAddressesRobinhoodMainnet.WETH;
        d.univ2Router = DeploymentAddressesRobinhoodMainnet.UNIV2_ROUTER;
        d.univ2Factory = DeploymentAddressesRobinhoodMainnet.UNIV2_FACTORY;
        d.univ4PoolManager = DeploymentAddressesRobinhoodMainnet.UNIV4_POOL_MANAGER;
        d.univ4PositionManager = DeploymentAddressesRobinhoodMainnet.UNIV4_POSITION_MANAGER;
        d.univ4UniversalRouter = DeploymentAddressesRobinhoodMainnet.UNIV4_UNIVERSAL_ROUTER;
        d.permit2 = DeploymentAddressesRobinhoodMainnet.PERMIT2;
    }

    function _robinhoodTestnet() internal pure returns (ChainDeployments memory d) {
        d.title = "Robinhood Chain Testnet";
        d.manifestFile = "manifest.robinhood.testnet.sol";
        d.launchpad = DeploymentsRobinhoodTestnet.LAUNCHPAD;
        d.bondingCurve = DeploymentsRobinhoodTestnet.BONDING_CURVE;
        d.graduatorUniV2 = DeploymentsRobinhoodTestnet.GRADUATOR_UNIV2;
        d.graduatorUniV4 = DeploymentsRobinhoodTestnet.GRADUATOR_UNIV4;
        d.masterFeeHandler = DeploymentsRobinhoodTestnet.MASTER_FEE_HANDLER;
        d.univ4LiquidityAdder = DeploymentsRobinhoodTestnet.UNIV4_LIQUIDITY_ADDER;
        d.swapHook = DeploymentsRobinhoodTestnet.SWAP_HOOK;
        d.lpFeeRouter = DeploymentsRobinhoodTestnet.LP_FEE_ROUTER;
        d.lpFeeRouterImpl = DeploymentsRobinhoodTestnet.LP_FEE_ROUTER_IMPL;
        d.quoter = DeploymentsRobinhoodTestnet.QUOTER;
        d.tokenImpl = DeploymentsRobinhoodTestnet.TOKEN_IMPL;
        d.taxableTokenImpl = DeploymentsRobinhoodTestnet.TAXABLE_TOKEN_V4_IMPL;
        d.taxableTokenV2Impl = DeploymentsRobinhoodTestnet.TAXABLE_TOKEN_V2_IMPL;
        d.factoryUniV2Unified = DeploymentsRobinhoodTestnet.FACTORY_UNIV2_UNIFIED;
        d.factoryUniV2UnifiedImpl = DeploymentsRobinhoodTestnet.FACTORY_UNIV2_UNIFIED_IMPL;
        d.factoryUniV4Unified = DeploymentsRobinhoodTestnet.FACTORY_UNIV4_UNIFIED;
        d.factoryUniV4UnifiedImpl = DeploymentsRobinhoodTestnet.FACTORY_UNIV4_UNIFIED_IMPL;
        d.creatorVaultFactory = DeploymentsRobinhoodTestnet.CREATOR_VAULT_FACTORY;
        d.creatorVaultFactoryImpl = DeploymentsRobinhoodTestnet.CREATOR_VAULT_FACTORY_IMPL;
        d.creatorVaultImpl = DeploymentsRobinhoodTestnet.CREATOR_VAULT_IMPL;
        d.vaultCurves = DeploymentsRobinhoodTestnet.vaultBondingCurves();
        d.graduatorThin = DeploymentsRobinhoodTestnet.GRADUATOR_UNIV4_THIN;
        d.graduatorThick = DeploymentsRobinhoodTestnet.GRADUATOR_UNIV4_THICK;
        d.thinCurveBase = DeploymentsRobinhoodTestnet.THIN_CURVE_BASE;
        d.thinVaultCurves = DeploymentsRobinhoodTestnet.thinVaultCurves();
        d.thickCurveBase = DeploymentsRobinhoodTestnet.THICK_CURVE_BASE;
        d.thickVaultCurves = DeploymentsRobinhoodTestnet.thickVaultCurves();
        d.livoDev = DeploymentsRobinhoodTestnet.LIVO_DEV;
        d.livoTreasury = DeploymentAddressesRobinhoodTestnet.LIVO_TREASURY;
        d.livoTokenDeployer = DeploymentsRobinhoodTestnet.LIVO_TOKEN_DEPLOYER;
        d.weth = DeploymentAddressesRobinhoodTestnet.WETH;
        d.univ2Router = DeploymentAddressesRobinhoodTestnet.UNIV2_ROUTER;
        d.univ2Factory = DeploymentAddressesRobinhoodTestnet.UNIV2_FACTORY;
        d.univ4PoolManager = DeploymentAddressesRobinhoodTestnet.UNIV4_POOL_MANAGER;
        d.univ4PositionManager = DeploymentAddressesRobinhoodTestnet.UNIV4_POSITION_MANAGER;
        d.univ4UniversalRouter = DeploymentAddressesRobinhoodTestnet.UNIV4_UNIVERSAL_ROUTER;
        d.permit2 = DeploymentAddressesRobinhoodTestnet.PERMIT2;
    }

    function _arcMainnet() internal pure returns (ChainDeployments memory d) {
        d.title = "ARC Chain Mainnet";
        d.manifestFile = "manifest.arc.mainnet.sol";
        d.launchpad = DeploymentsArcMainnet.LAUNCHPAD;
        d.bondingCurve = DeploymentsArcMainnet.BONDING_CURVE;
        d.graduatorUniV2 = DeploymentsArcMainnet.GRADUATOR_UNIV2;
        d.graduatorUniV4 = DeploymentsArcMainnet.GRADUATOR_UNIV4;
        d.masterFeeHandler = DeploymentsArcMainnet.MASTER_FEE_HANDLER;
        d.univ4LiquidityAdder = DeploymentsArcMainnet.UNIV4_LIQUIDITY_ADDER;
        d.swapHook = DeploymentsArcMainnet.SWAP_HOOK;
        d.lpFeeRouter = DeploymentsArcMainnet.LP_FEE_ROUTER;
        d.lpFeeRouterImpl = DeploymentsArcMainnet.LP_FEE_ROUTER_IMPL;
        d.quoter = DeploymentsArcMainnet.QUOTER;
        d.tokenImpl = DeploymentsArcMainnet.TOKEN_IMPL;
        d.taxableTokenImpl = DeploymentsArcMainnet.TAXABLE_TOKEN_V4_IMPL;
        d.taxableTokenV2Impl = DeploymentsArcMainnet.TAXABLE_TOKEN_V2_IMPL;
        d.factoryUniV2Unified = DeploymentsArcMainnet.FACTORY_UNIV2_UNIFIED;
        d.factoryUniV2UnifiedImpl = DeploymentsArcMainnet.FACTORY_UNIV2_UNIFIED_IMPL;
        d.factoryUniV4Unified = DeploymentsArcMainnet.FACTORY_UNIV4_UNIFIED;
        d.factoryUniV4UnifiedImpl = DeploymentsArcMainnet.FACTORY_UNIV4_UNIFIED_IMPL;
        d.creatorVaultFactory = DeploymentsArcMainnet.CREATOR_VAULT_FACTORY;
        d.creatorVaultFactoryImpl = DeploymentsArcMainnet.CREATOR_VAULT_FACTORY_IMPL;
        d.creatorVaultImpl = DeploymentsArcMainnet.CREATOR_VAULT_IMPL;
        d.vaultCurves = DeploymentsArcMainnet.vaultBondingCurves();
        d.graduatorThin = DeploymentsArcMainnet.GRADUATOR_UNIV4_THIN;
        d.graduatorThick = DeploymentsArcMainnet.GRADUATOR_UNIV4_THICK;
        d.thinCurveBase = DeploymentsArcMainnet.THIN_CURVE_BASE;
        d.thinVaultCurves = DeploymentsArcMainnet.thinVaultCurves();
        d.thickCurveBase = DeploymentsArcMainnet.THICK_CURVE_BASE;
        d.thickVaultCurves = DeploymentsArcMainnet.thickVaultCurves();
        d.livoDev = DeploymentsArcMainnet.LIVO_DEV;
        d.livoTreasury = DeploymentAddressesArcMainnet.LIVO_TREASURY;
        d.livoTokenDeployer = DeploymentsArcMainnet.LIVO_TOKEN_DEPLOYER;
        d.weth = DeploymentAddressesArcMainnet.WETH;
        d.univ2Router = DeploymentAddressesArcMainnet.UNIV2_ROUTER;
        d.univ2Factory = DeploymentAddressesArcMainnet.UNIV2_FACTORY;
        d.univ4PoolManager = DeploymentAddressesArcMainnet.UNIV4_POOL_MANAGER;
        d.univ4PositionManager = DeploymentAddressesArcMainnet.UNIV4_POSITION_MANAGER;
        d.univ4UniversalRouter = DeploymentAddressesArcMainnet.UNIV4_UNIVERSAL_ROUTER;
        d.permit2 = DeploymentAddressesArcMainnet.PERMIT2;
    }

    function _arcTestnet() internal pure returns (ChainDeployments memory d) {
        d.title = "ARC Chain Testnet";
        d.manifestFile = "manifest.arc.testnet.sol";
        d.launchpad = DeploymentsArcTestnet.LAUNCHPAD;
        d.bondingCurve = DeploymentsArcTestnet.BONDING_CURVE;
        d.graduatorUniV2 = DeploymentsArcTestnet.GRADUATOR_UNIV2;
        d.graduatorUniV4 = DeploymentsArcTestnet.GRADUATOR_UNIV4;
        d.masterFeeHandler = DeploymentsArcTestnet.MASTER_FEE_HANDLER;
        d.univ4LiquidityAdder = DeploymentsArcTestnet.UNIV4_LIQUIDITY_ADDER;
        d.swapHook = DeploymentsArcTestnet.SWAP_HOOK;
        d.lpFeeRouter = DeploymentsArcTestnet.LP_FEE_ROUTER;
        d.lpFeeRouterImpl = DeploymentsArcTestnet.LP_FEE_ROUTER_IMPL;
        d.quoter = DeploymentsArcTestnet.QUOTER;
        d.tokenImpl = DeploymentsArcTestnet.TOKEN_IMPL;
        d.taxableTokenImpl = DeploymentsArcTestnet.TAXABLE_TOKEN_V4_IMPL;
        d.taxableTokenV2Impl = DeploymentsArcTestnet.TAXABLE_TOKEN_V2_IMPL;
        d.factoryUniV2Unified = DeploymentsArcTestnet.FACTORY_UNIV2_UNIFIED;
        d.factoryUniV2UnifiedImpl = DeploymentsArcTestnet.FACTORY_UNIV2_UNIFIED_IMPL;
        d.factoryUniV4Unified = DeploymentsArcTestnet.FACTORY_UNIV4_UNIFIED;
        d.factoryUniV4UnifiedImpl = DeploymentsArcTestnet.FACTORY_UNIV4_UNIFIED_IMPL;
        d.creatorVaultFactory = DeploymentsArcTestnet.CREATOR_VAULT_FACTORY;
        d.creatorVaultFactoryImpl = DeploymentsArcTestnet.CREATOR_VAULT_FACTORY_IMPL;
        d.creatorVaultImpl = DeploymentsArcTestnet.CREATOR_VAULT_IMPL;
        d.vaultCurves = DeploymentsArcTestnet.vaultBondingCurves();
        d.graduatorThin = DeploymentsArcTestnet.GRADUATOR_UNIV4_THIN;
        d.graduatorThick = DeploymentsArcTestnet.GRADUATOR_UNIV4_THICK;
        d.thinCurveBase = DeploymentsArcTestnet.THIN_CURVE_BASE;
        d.thinVaultCurves = DeploymentsArcTestnet.thinVaultCurves();
        d.thickCurveBase = DeploymentsArcTestnet.THICK_CURVE_BASE;
        d.thickVaultCurves = DeploymentsArcTestnet.thickVaultCurves();
        d.livoDev = DeploymentsArcTestnet.LIVO_DEV;
        d.livoTreasury = DeploymentAddressesArcTestnet.LIVO_TREASURY;
        d.livoTokenDeployer = DeploymentsArcTestnet.LIVO_TOKEN_DEPLOYER;
        d.weth = DeploymentAddressesArcTestnet.WETH;
        d.univ2Router = DeploymentAddressesArcTestnet.UNIV2_ROUTER;
        d.univ2Factory = DeploymentAddressesArcTestnet.UNIV2_FACTORY;
        d.univ4PoolManager = DeploymentAddressesArcTestnet.UNIV4_POOL_MANAGER;
        d.univ4PositionManager = DeploymentAddressesArcTestnet.UNIV4_POSITION_MANAGER;
        d.univ4UniversalRouter = DeploymentAddressesArcTestnet.UNIV4_UNIVERSAL_ROUTER;
        d.permit2 = DeploymentAddressesArcTestnet.PERMIT2;
    }

    // ---------------------------------------------------------------- Renderer

    function _render(ChainDeployments memory d) internal pure returns (string memory s) {
        s = string.concat(
            "<!-- generated by `just export-deployments` from `",
            d.manifestFile,
            "` - do not hand-edit -->\n\n# ",
            d.title,
            " deployments\n\n"
        );

        s = string.concat(s, "## Livo\n\n", _tableHeader("Contract"));
        s = string.concat(s, _row("LivoLaunchpad", d.launchpad));
        s = string.concat(s, _row("ConstantProductBondingCurve", d.bondingCurve));
        s = string.concat(s, _row("LivoGraduatorUniswapV2", d.graduatorUniV2));
        s = string.concat(s, _row("LivoGraduatorUniswapV4", d.graduatorUniV4));
        s = string.concat(s, _row("LivoMasterFeeHandler", d.masterFeeHandler));
        s = string.concat(s, _row("LivoUniV4LiquidityAdder", d.univ4LiquidityAdder));
        s = string.concat(s, _row("LivoSwapHook", d.swapHook));
        s = string.concat(s, _row("LivoLpFeeRouter (proxy)", d.lpFeeRouter));
        s = string.concat(s, _row("LivoLpFeeRouter (impl)", d.lpFeeRouterImpl));
        s = string.concat(s, _row("LivoQuoter", d.quoter));
        s = string.concat(s, _row("LivoToken (impl)", d.tokenImpl));
        s = string.concat(s, _row("LivoTaxableTokenUniV4 (impl)", d.taxableTokenImpl));
        s = string.concat(s, _row("LivoTaxableTokenUniV2 (impl)", d.taxableTokenV2Impl));
        s = string.concat(s, _row("LivoFactoryUniV2Unified (proxy)", d.factoryUniV2Unified));
        s = string.concat(s, _row("LivoFactoryUniV2Unified (impl)", d.factoryUniV2UnifiedImpl));
        s = string.concat(s, _row("LivoFactoryUniV4Unified (proxy)", d.factoryUniV4Unified));
        s = string.concat(s, _row("LivoFactoryUniV4Unified (impl)", d.factoryUniV4UnifiedImpl));
        s = string.concat(s, _row("LivoCreatorVaultFactory (proxy)", d.creatorVaultFactory));
        s = string.concat(s, _row("LivoCreatorVaultFactory (impl)", d.creatorVaultFactoryImpl));
        s = string.concat(s, _row("LivoCreatorVault (impl)", d.creatorVaultImpl));
        s = string.concat(s, _row("Creator-vault curve 5%", d.vaultCurves[0]));
        s = string.concat(s, _row("Creator-vault curve 10%", d.vaultCurves[1]));
        s = string.concat(s, _row("Creator-vault curve 15%", d.vaultCurves[2]));
        s = string.concat(s, _row("Creator-vault curve 20%", d.vaultCurves[3]));
        s = string.concat(s, _row("Creator-vault curve 25%", d.vaultCurves[4]));
        s = string.concat(s, _row("Creator-vault curve 30%", d.vaultCurves[5]));
        s = string.concat(s, _row("LivoGraduatorUniV4 THIN", d.graduatorThin));
        s = string.concat(s, _row("LivoGraduatorUniV4 THICK", d.graduatorThick));
        s = string.concat(s, _row("THIN-tier curve base", d.thinCurveBase));
        s = string.concat(s, _row("THIN-tier curve 5%", d.thinVaultCurves[0]));
        s = string.concat(s, _row("THIN-tier curve 10%", d.thinVaultCurves[1]));
        s = string.concat(s, _row("THIN-tier curve 15%", d.thinVaultCurves[2]));
        s = string.concat(s, _row("THIN-tier curve 20%", d.thinVaultCurves[3]));
        s = string.concat(s, _row("THIN-tier curve 25%", d.thinVaultCurves[4]));
        s = string.concat(s, _row("THIN-tier curve 30%", d.thinVaultCurves[5]));
        s = string.concat(s, _row("THICK-tier curve base", d.thickCurveBase));
        s = string.concat(s, _row("THICK-tier curve 5%", d.thickVaultCurves[0]));
        s = string.concat(s, _row("THICK-tier curve 10%", d.thickVaultCurves[1]));
        s = string.concat(s, _row("THICK-tier curve 15%", d.thickVaultCurves[2]));
        s = string.concat(s, _row("THICK-tier curve 20%", d.thickVaultCurves[3]));
        s = string.concat(s, _row("THICK-tier curve 25%", d.thickVaultCurves[4]));
        s = string.concat(s, _row("THICK-tier curve 30%", d.thickVaultCurves[5]));

        s = string.concat(s, "\n## Accounts\n\n", _tableHeader("Name"));
        s = string.concat(s, _row("Livo Deployer", d.livoDev));
        s = string.concat(s, _row("Livo Treasury", d.livoTreasury));
        s = string.concat(s, _row("Livo Token Deployer", d.livoTokenDeployer));

        s = string.concat(s, "\n## Integrations\n\n", _tableHeader("Name"));
        s = string.concat(s, _row("WETH", d.weth));
        s = string.concat(s, _row("Uniswap V2 router", d.univ2Router));
        s = string.concat(s, _row("Uniswap V2 factory", d.univ2Factory));
        s = string.concat(s, _row("Uniswap V4 Pool Manager", d.univ4PoolManager));
        s = string.concat(s, _row("Uniswap V4 Position Manager", d.univ4PositionManager));
        s = string.concat(s, _row("Uniswap V4 Universal router", d.univ4UniversalRouter));
        s = string.concat(s, _row("Permit2", d.permit2));
    }

    // ---------------------------------------------------------------- Helpers

    /// @dev Inner column widths (content + padding, excluding the surrounding `| ` and ` |`).
    ///      Longest name today is `LivoGraduatorUniswapV4 (0.5% hook)` = 34 chars, so 44 leaves
    ///      ample buffer. Backticked addresses are exactly 44 chars
    ///      (`0x` + 40 hex + 2 backticks), so the same width fits the address column too.
    uint256 private constant COL1_WIDTH = 44;
    uint256 private constant COL2_WIDTH = 44;

    function _tableHeader(string memory firstCol) private pure returns (string memory) {
        return string.concat(
            "| ",
            _padRight(firstCol, COL1_WIDTH),
            " | ",
            _padRight("Address", COL2_WIDTH),
            " |\n",
            "| ",
            _repeat(0x2d, COL1_WIDTH),
            " | ",
            _repeat(0x2d, COL2_WIDTH),
            " |\n"
        );
    }

    function _row(string memory name, address a) private pure returns (string memory) {
        string memory addr = (a == address(0)) ? "_(not deployed)_" : string.concat("`", vm.toString(a), "`");
        return string.concat("| ", _padRight(name, COL1_WIDTH), " | ", _padRight(addr, COL2_WIDTH), " |\n");
    }

    function _padRight(string memory s, uint256 width) private pure returns (string memory) {
        bytes memory original = bytes(s);
        if (original.length >= width) return s;
        bytes memory result = new bytes(width);
        for (uint256 i = 0; i < original.length; i++) {
            result[i] = original[i];
        }
        for (uint256 i = original.length; i < width; i++) {
            result[i] = 0x20;
        }
        return string(result);
    }

    function _repeat(bytes1 ch, uint256 n) private pure returns (string memory) {
        bytes memory result = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            result[i] = ch;
        }
        return string(result);
    }
}
