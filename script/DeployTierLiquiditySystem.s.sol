// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {ConstantProductBondingCurve} from "src/bondingCurves/ConstantProductBondingCurve.sol";
import {ConstantProductBondingCurveConfigurable} from "src/bondingCurves/ConstantProductBondingCurveConfigurable.sol";
import {CreatorVaultCurveConstants} from "src/config/CreatorVaultCurveConstants.sol";
import {CreatorVaultCurveConstantsArc} from "src/config/CreatorVaultCurveConstantsArc.sol";
import {LivoGraduatorUniswapV4} from "src/graduators/LivoGraduatorUniswapV4.sol";
import {UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants.sol";
import {UniswapV4PoolConstantsArc} from "src/libraries/UniswapV4PoolConstantsArc.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {
    DeploymentAddressesEthereumMainnet,
    DeploymentAddressesEthereumSepolia,
    DeploymentAddressesArcTestnet,
    DeploymentAddressesArcMainnet
} from "src/config/DeploymentAddresses.sol";
import {DeploymentsEthereumMainnet} from "src/config/manifest.ethereum.mainnet.sol";
import {DeploymentsEthereumSepolia} from "src/config/manifest.ethereum.sepolia.sol";
import {DeploymentsArcTestnet} from "src/config/manifest.arc.testnet.sol";

/// @title Deploy the liquidity-tier system (DEFAULT redeploy + THIN + THICK)
/// @notice Deploys the net-new on-chain pieces the deployer-selectable liquidity tiers need:
///         1. The DEFAULT, THIN and THICK tier bonding curves — each a no-vault base curve plus six
///            vault curves (5%..30%), 21 curve instances total. The DEFAULT tier curves are now
///            REDEPLOYED too (not reused): the originally-deployed instances predate the
///            `LivoBondingCurveDeployed` constructor event, so they are re-created here to emit it for
///            the indexer. DEFAULT's base is the hardcoded `ConstantProductBondingCurve`
///            (manifest slot `BONDING_CURVE`); its six vault curves are `ConstantProductBondingCurveConfigurable`
///            (`VAULT_CURVE_5..30`). THIN/THICK are all `ConstantProductBondingCurveConfigurable`.
///         2. The two THIN/THICK Uniswap V4 graduators, one per tier: the single `SWAP_HOOK` is
///            fee-agnostic (it reads the LP fee from the token), so a tier needs only one graduator.
///            The DEFAULT graduator (`GRADUATOR_UNIV4`) is reused as-is.
///
///         Curves are venue-agnostic: the same addresses feed both the V2 and V4 factory tier
///         configs (V2 needs no tier graduators — its depth is set entirely by the curve).
///
///         After running, paste the printed addresses into `src/config/manifest.{mainnet,sepolia}.sol`
///         (the `BONDING_CURVE` + `VAULT_CURVE_*`, the `GRADUATOR_UNIV4_{THIN,THICK}`, and the
///         `{THIN,THICK}_*_CURVE_*` slots), run `just export-deployments`, and only THEN upgrade the
///         unified factories so they pick the new curves/tier config up (`RedeployUnifiedFactoriesOnly`,
///         or a `Redeploy*Tokens*` variant).
///
/// @dev    Run with:
///         forge script DeployTierLiquiditySystem --rpc-url <mainnet|sepolia> --verify --account livo.dev --slow --broadcast
contract DeployTierLiquiditySystem is Script {
    /// @dev THIN-tier graduation price (6.125 ETH mcap). Mirrors the value in `LivoGraduatorUniswapV4`.
    uint160 internal constant THIN_GRAD_SQRT_PRICE_X96 = 1012340326367404053977557838594048;
    /// @dev THICK-tier graduation price (24.5 ETH mcap).
    uint160 internal constant THICK_GRAD_SQRT_PRICE_X96 = 506170163183702026988778919297024;

    struct Deps {
        address launchpad;
        address poolManager;
        address positionManager;
        address permit2;
        address hook; // fee-agnostic LivoSwapHook (reads the LP fee from the token)
        address liquidityAdder; // shared LivoUniV4LiquidityAdder singleton
    }

    function run() public {
        Deps memory d = _resolveDeps();

        console.log("=== Deploy Livo liquidity-tier system (DEFAULT + THIN + THICK) ===");
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", msg.sender);
        console.log("");

        // bpsList[0] == 0 is the no-vault base curve; bpsList[1..6] are the 5%..30% vault curves.
        uint256[7] memory bpsList = [uint256(0), 500, 1000, 1500, 2000, 2500, 3000];

        vm.startBroadcast();

        address[7] memory def = _deployDefaultCurves(bpsList);
        address[7] memory thin = _deployTierCurves(LiquidityTier.THIN, bpsList);
        address[7] memory thick = _deployTierCurves(LiquidityTier.THICK, bpsList);

        (uint160 thinSqrt, uint160 thickSqrt, int24 thinTickUpper, int24 thickTickUpper) = _graduationSetpoints();
        address gradSmall = _deployGraduator(d, d.hook, thinSqrt, thinTickUpper);
        address gradLarge = _deployGraduator(d, d.hook, thickSqrt, thickTickUpper);

        vm.stopBroadcast();

        console.log("=== Deployed. Paste into src/config/manifest.<chain>.sol ===");
        console.log("");
        _printDefaultCurves(def);
        _printTierCurves("THIN", thin);
        _printTierCurves("THICK", thick);
        console.log("GRADUATOR_UNIV4_THIN ", gradSmall);
        console.log("GRADUATOR_UNIV4_THICK", gradLarge);
        console.log("");
        console.log("Next: update the manifest, `just export-deployments`, then RedeployUnifiedFactoriesOnly.");
    }

    /// @dev Redeploys the DEFAULT-tier curves so they emit `LivoBondingCurveDeployed` (the originally
    ///      deployed instances predate that event). Index 0 is the hardcoded `ConstantProductBondingCurve`
    ///      base (manifest slot `BONDING_CURVE`); 1..6 are the 5%..30% configurable vault curves
    ///      (`VAULT_CURVE_5..30`). DEFAULT has no `(DEFAULT, 0)` entry in `CreatorVaultCurveConstants`
    ///      (its base is the hardcoded curve, not a configurable instance), so index 0 is special-cased.
    function _deployDefaultCurves(uint256[7] memory bpsList) internal returns (address[7] memory curves) {
        (uint256 threshold, uint256 maxExcess) = _grad(LiquidityTier.DEFAULT);
        // On ARC every curve — including the base — is a configurable instance (there is no hardcoded
        // ARC base curve), so index 0 uses the (DEFAULT, 0) params instead of `ConstantProductBondingCurve`.
        if (_isArc()) {
            (uint256 k0, uint256 t00, uint256 e00) = _params(LiquidityTier.DEFAULT, 0);
            curves[0] = address(new ConstantProductBondingCurveConfigurable(k0, t00, e00, threshold, maxExcess));
        } else {
            curves[0] = address(new ConstantProductBondingCurve());
        }
        for (uint256 i = 1; i < 7; ++i) {
            (uint256 k, uint256 t0, uint256 e0) = _params(LiquidityTier.DEFAULT, bpsList[i]);
            curves[i] = address(new ConstantProductBondingCurveConfigurable(k, t0, e0, threshold, maxExcess));
        }
    }

    /// @dev Deploys a tier's seven curves: index 0 is the no-vault base, 1..6 are the 5%..30% vaults.
    function _deployTierCurves(LiquidityTier tier, uint256[7] memory bpsList)
        internal
        returns (address[7] memory curves)
    {
        (uint256 threshold, uint256 maxExcess) = _grad(tier);
        for (uint256 i = 0; i < 7; ++i) {
            (uint256 k, uint256 t0, uint256 e0) = _params(tier, bpsList[i]);
            curves[i] = address(new ConstantProductBondingCurveConfigurable(k, t0, e0, threshold, maxExcess));
        }
    }

    /// @dev True on ARC (native = USDC), which uses the re-solved ×2000 curve/pool constants. Covers
    ///      BOTH ARC chain-ids: unlike the graduators, the configurable curves have no constructor
    ///      chain-guard, so an ARC chain missing here would silently deploy ETH-priced curves.
    function _isArc() internal view returns (bool) {
        return block.chainid == DeploymentsArcTestnet.BLOCKCHAIN_ID
            || block.chainid == DeploymentAddressesArcMainnet.BLOCKCHAIN_ID;
    }

    /// @dev Curve (k, t0, e0) for a (tier, bps) on the active chain.
    function _params(LiquidityTier tier, uint256 bps) internal view returns (uint256 k, uint256 t0, uint256 e0) {
        if (_isArc()) return CreatorVaultCurveConstantsArc.paramsFor(tier, bps);
        return CreatorVaultCurveConstants.paramsFor(tier, bps);
    }

    /// @dev Graduation threshold + max-excess for a tier on the active chain.
    function _grad(LiquidityTier tier) internal view returns (uint256 threshold, uint256 maxExcess) {
        if (_isArc()) return CreatorVaultCurveConstantsArc.tierGraduation(tier);
        return CreatorVaultCurveConstants.tierGraduation(tier);
    }

    /// @dev THIN/THICK graduation sqrtPrices + primary-range upper ticks for the active chain. These feed
    ///      the tier graduators' constructors; the graduator bytecode itself bakes ARC pool geometry via
    ///      the `just chain-arc-testnet` import-swap.
    function _graduationSetpoints()
        internal
        view
        returns (uint160 thinSqrt, uint160 thickSqrt, int24 thinTickUpper, int24 thickTickUpper)
    {
        if (_isArc()) {
            return (
                UniswapV4PoolConstantsArc.SQRT_PRICEX96_GRADUATION_THIN,
                UniswapV4PoolConstantsArc.SQRT_PRICEX96_GRADUATION_THICK,
                UniswapV4PoolConstantsArc.TICK_UPPER_THIN,
                UniswapV4PoolConstantsArc.TICK_UPPER
            );
        }
        return (
            THIN_GRAD_SQRT_PRICE_X96,
            THICK_GRAD_SQRT_PRICE_X96,
            UniswapV4PoolConstants.TICK_UPPER_THIN,
            UniswapV4PoolConstants.TICK_UPPER
        );
    }

    function _deployGraduator(Deps memory d, address hook, uint160 sqrtPriceGraduation, int24 tickUpper)
        internal
        returns (address)
    {
        LivoGraduatorUniswapV4 graduator = new LivoGraduatorUniswapV4(
            d.launchpad,
            d.poolManager,
            d.positionManager,
            d.permit2,
            hook,
            sqrtPriceGraduation,
            tickUpper,
            d.liquidityAdder
        );
        require(graduator.HOOK_ADDRESS() == hook, "graduator hook mismatch");
        return address(graduator);
    }

    /// @dev DEFAULT curves print under their (un-prefixed) manifest slot names: `BONDING_CURVE` for the
    ///      base and `VAULT_CURVE_5..30` for the vault curves.
    function _printDefaultCurves(address[7] memory c) internal pure {
        string[7] memory slot;
        slot[0] = "BONDING_CURVE ";
        slot[1] = "VAULT_CURVE_5 ";
        slot[2] = "VAULT_CURVE_10";
        slot[3] = "VAULT_CURVE_15";
        slot[4] = "VAULT_CURVE_20";
        slot[5] = "VAULT_CURVE_25";
        slot[6] = "VAULT_CURVE_30";
        for (uint256 i = 0; i < 7; ++i) {
            console.log(slot[i], c[i]);
        }
    }

    function _printTierCurves(string memory tier, address[7] memory c) internal pure {
        string[7] memory suffix;
        suffix[0] = "_CURVE_BASE   ";
        suffix[1] = "_VAULT_CURVE_5 ";
        suffix[2] = "_VAULT_CURVE_10";
        suffix[3] = "_VAULT_CURVE_15";
        suffix[4] = "_VAULT_CURVE_20";
        suffix[5] = "_VAULT_CURVE_25";
        suffix[6] = "_VAULT_CURVE_30";
        for (uint256 i = 0; i < 7; ++i) {
            console.log(string.concat(tier, suffix[i]), c[i]);
        }
    }

    function _resolveDeps() internal view returns (Deps memory d) {
        if (block.chainid == DeploymentAddressesEthereumMainnet.BLOCKCHAIN_ID) {
            d = Deps({
                launchpad: DeploymentsEthereumMainnet.LAUNCHPAD,
                poolManager: DeploymentAddressesEthereumMainnet.UNIV4_POOL_MANAGER,
                positionManager: DeploymentAddressesEthereumMainnet.UNIV4_POSITION_MANAGER,
                permit2: DeploymentAddressesEthereumMainnet.PERMIT2,
                hook: DeploymentsEthereumMainnet.SWAP_HOOK,
                liquidityAdder: DeploymentsEthereumMainnet.UNIV4_LIQUIDITY_ADDER
            });
        } else if (block.chainid == DeploymentAddressesEthereumSepolia.BLOCKCHAIN_ID) {
            d = Deps({
                launchpad: DeploymentsEthereumSepolia.LAUNCHPAD,
                poolManager: DeploymentAddressesEthereumSepolia.UNIV4_POOL_MANAGER,
                positionManager: DeploymentAddressesEthereumSepolia.UNIV4_POSITION_MANAGER,
                permit2: DeploymentAddressesEthereumSepolia.PERMIT2,
                hook: DeploymentsEthereumSepolia.SWAP_HOOK,
                liquidityAdder: DeploymentsEthereumSepolia.UNIV4_LIQUIDITY_ADDER
            });
        } else if (block.chainid == DeploymentAddressesArcTestnet.BLOCKCHAIN_ID) {
            d = Deps({
                launchpad: DeploymentsArcTestnet.LAUNCHPAD,
                poolManager: DeploymentAddressesArcTestnet.UNIV4_POOL_MANAGER,
                positionManager: DeploymentAddressesArcTestnet.UNIV4_POSITION_MANAGER,
                permit2: DeploymentAddressesArcTestnet.PERMIT2,
                hook: DeploymentsArcTestnet.SWAP_HOOK,
                liquidityAdder: DeploymentsArcTestnet.UNIV4_LIQUIDITY_ADDER
            });
        } else {
            revert("Unsupported chain ID");
        }

        require(d.launchpad != address(0), "manifest: LAUNCHPAD missing");
        require(d.hook != address(0), "manifest: SWAP_HOOK missing");
        require(d.liquidityAdder != address(0), "manifest: UNIV4_LIQUIDITY_ADDER missing");
    }
}
