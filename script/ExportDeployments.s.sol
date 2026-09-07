// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {DeploymentsEthereumSepolia} from "src/config/manifest.ethereum.sepolia.sol";
import {DeploymentsRobinhoodMainnet} from "src/config/manifest.robinhood.mainnet.sol";
import {
    DeploymentAddressesEthereumSepolia,
    DeploymentAddressesRobinhoodMainnet
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
        // --- Realm core ---
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
        address realmDev;
        address realmTreasury;
        address realmTokenDeployer;
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
        _write("deployments.ethereum.sepolia.md", _render(_ethereumSepolia()));
        _write("deployments.robinhood.mainnet.md", _render(_robinhoodMainnet()));
    }

    function _write(string memory path, string memory content) internal {
        vm.writeFile(path, content);
        console.log("Wrote %s (%d bytes)", path, bytes(content).length);
    }

    // ---------------------------------------------------------------- Per-chain collectors

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
        d.realmDev = DeploymentsEthereumSepolia.REALM_DEV;
        d.realmTreasury = DeploymentAddressesEthereumSepolia.REALM_TREASURY;
        d.realmTokenDeployer = DeploymentsEthereumSepolia.REALM_TOKEN_DEPLOYER;
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
        d.realmDev = DeploymentsRobinhoodMainnet.REALM_DEV;
        d.realmTreasury = DeploymentAddressesRobinhoodMainnet.REALM_TREASURY;
        d.realmTokenDeployer = DeploymentsRobinhoodMainnet.REALM_TOKEN_DEPLOYER;
        d.weth = DeploymentAddressesRobinhoodMainnet.WETH;
        d.univ2Router = DeploymentAddressesRobinhoodMainnet.UNIV2_ROUTER;
        d.univ2Factory = DeploymentAddressesRobinhoodMainnet.UNIV2_FACTORY;
        d.univ4PoolManager = DeploymentAddressesRobinhoodMainnet.UNIV4_POOL_MANAGER;
        d.univ4PositionManager = DeploymentAddressesRobinhoodMainnet.UNIV4_POSITION_MANAGER;
        d.univ4UniversalRouter = DeploymentAddressesRobinhoodMainnet.UNIV4_UNIVERSAL_ROUTER;
        d.permit2 = DeploymentAddressesRobinhoodMainnet.PERMIT2;
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

        s = string.concat(s, "## Realm\n\n", _tableHeader("Contract"));
        s = string.concat(s, _row("RealmLaunchpad", d.launchpad));
        s = string.concat(s, _row("ConstantProductBondingCurve", d.bondingCurve));
        s = string.concat(s, _row("RealmGraduatorUniswapV2", d.graduatorUniV2));
        s = string.concat(s, _row("RealmGraduatorUniswapV4", d.graduatorUniV4));
        s = string.concat(s, _row("RealmMasterFeeHandler", d.masterFeeHandler));
        s = string.concat(s, _row("RealmUniV4LiquidityAdder", d.univ4LiquidityAdder));
        s = string.concat(s, _row("LivoSwapHook", d.swapHook));
        s = string.concat(s, _row("RealmLpFeeRouter (proxy)", d.lpFeeRouter));
        s = string.concat(s, _row("RealmLpFeeRouter (impl)", d.lpFeeRouterImpl));
        s = string.concat(s, _row("RealmQuoter", d.quoter));
        s = string.concat(s, _row("RealmToken (impl)", d.tokenImpl));
        s = string.concat(s, _row("RealmTaxableTokenUniV4 (impl)", d.taxableTokenImpl));
        s = string.concat(s, _row("RealmTaxableTokenUniV2 (impl)", d.taxableTokenV2Impl));
        s = string.concat(s, _row("RealmFactoryUniV2Unified (proxy)", d.factoryUniV2Unified));
        s = string.concat(s, _row("RealmFactoryUniV2Unified (impl)", d.factoryUniV2UnifiedImpl));
        s = string.concat(s, _row("RealmFactoryUniV4Unified (proxy)", d.factoryUniV4Unified));
        s = string.concat(s, _row("RealmFactoryUniV4Unified (impl)", d.factoryUniV4UnifiedImpl));
        s = string.concat(s, _row("RealmCreatorVaultFactory (proxy)", d.creatorVaultFactory));
        s = string.concat(s, _row("RealmCreatorVaultFactory (impl)", d.creatorVaultFactoryImpl));
        s = string.concat(s, _row("RealmCreatorVault (impl)", d.creatorVaultImpl));
        s = string.concat(s, _row("Creator-vault curve 5%", d.vaultCurves[0]));
        s = string.concat(s, _row("Creator-vault curve 10%", d.vaultCurves[1]));
        s = string.concat(s, _row("Creator-vault curve 15%", d.vaultCurves[2]));
        s = string.concat(s, _row("Creator-vault curve 20%", d.vaultCurves[3]));
        s = string.concat(s, _row("Creator-vault curve 25%", d.vaultCurves[4]));
        s = string.concat(s, _row("Creator-vault curve 30%", d.vaultCurves[5]));
        s = string.concat(s, _row("RealmGraduatorUniV4 THIN", d.graduatorThin));
        s = string.concat(s, _row("RealmGraduatorUniV4 THICK", d.graduatorThick));
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
        s = string.concat(s, _row("Realm Deployer", d.realmDev));
        s = string.concat(s, _row("Realm Treasury", d.realmTreasury));
        s = string.concat(s, _row("Realm Token Deployer", d.realmTokenDeployer));

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
    ///      Longest name today is `RealmGraduatorUniswapV4 (0.5% hook)` = 34 chars, so 44 leaves
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
