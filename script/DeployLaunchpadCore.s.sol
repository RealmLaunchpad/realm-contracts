// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {LivoQuoter} from "src/LivoQuoter.sol";
import {LivoMasterFeeHandler} from "src/feeHandlers/LivoMasterFeeHandler.sol";
import {LivoGraduatorUniswapV2} from "src/graduators/LivoGraduatorUniswapV2.sol";
import {LivoGraduatorUniswapV2Arc} from "src/graduators/LivoGraduatorUniswapV2Arc.sol";
import {LivoGraduatorUniswapV4} from "src/graduators/LivoGraduatorUniswapV4.sol";
import {LivoUniV4LiquidityAdder} from "src/liquidity/LivoUniV4LiquidityAdder.sol";
import {UniswapV4PoolConstantsArc} from "src/libraries/UniswapV4PoolConstantsArc.sol";
import {DeploymentAddressesArcTestnet} from "src/config/DeploymentAddresses.sol";
import {DeploymentsArcTestnet} from "src/config/manifest.arc.testnet.sol";

/// @title Deploy the from-scratch launchpad core for a brand-new chain
/// @notice Deploys the core Livo contracts that no other current script bootstraps — the pieces the
///         removed `DeployFullStack` used to seed. On a fresh chain these must exist before the
///         creator-vault / tier / factory scripts can run:
///           1. `LivoMasterFeeHandler`
///           2. `LivoLaunchpad` (owner = broadcaster, treasury from `DeploymentAddresses*`)
///           3. `LivoQuoter`
///           4. `LivoGraduatorUniswapV2` (DEFAULT tier / V2 venue)
///           5. `LivoUniV4LiquidityAdder` (shared singleton consumed by the V4 graduator)
///           6. `LivoGraduatorUniswapV4` (DEFAULT tier / V4 venue)
///
///         It does NOT deploy the DEFAULT `BONDING_CURVE`: `DeployTierLiquiditySystem` (re)deploys that
///         (and every tier curve) and is the source of truth for it — and on ARC the base curve is a
///         configurable instance, not the hardcoded `ConstantProductBondingCurve`.
///
/// @dev    Ordering: run `DeployLivoLpFeeRouter` then `DeployLivoSwapHook` FIRST — the DEFAULT V4
///         graduator takes the hook as a constructor immutable, so `SWAP_HOOK` must already be in the
///         manifest. After this: paste the printed addresses into `src/config/manifest.arc.testnet.sol`,
///         `just export-deployments`, then the vault/tier/factory scripts.
///
///         Build for ARC first: `just chain-arc-testnet && forge build`
///         (the graduators bake ARC pool geometry + fees via import-swap).
///
///         Run: forge script DeployLaunchpadCore --rpc-url arc-testnet --account livo.dev --slow \
///                  --broadcast --gas-estimate-multiplier 300
contract DeployLaunchpadCore is Script {
    struct Deps {
        address treasury;
        address swapHook;
        address univ2Router;
        bytes32 univ2PairInitCodeHash;
        address univ4PoolManager;
        address univ4PositionManager;
        address permit2;
        uint160 defaultGradSqrtPrice; // DEFAULT-tier graduation price
        int24 defaultTickUpper; // DEFAULT/THICK primary-range upper tick
    }

    function run() public {
        Deps memory d = _resolveDeps();
        require(d.swapHook != address(0), "manifest: SWAP_HOOK missing (deploy the hook first)");
        require(d.treasury != address(0), "LIVO_TREASURY not set");
        // The graduators self-guard against a build/target mismatch in their constructors
        // (GraduationFeeConstants.assertDeployableOn) — no per-script check needed.

        console.log("=== Deploy Livo launchpad core (from-scratch bootstrap) ===");
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", msg.sender);
        console.log("Treasury:", d.treasury);
        console.log("Swap hook:", d.swapHook);
        console.log("");

        vm.startBroadcast();

        address feeHandler = address(new LivoMasterFeeHandler());
        address launchpad = address(new LivoLaunchpad(d.treasury, msg.sender));
        address quoter = address(new LivoQuoter(launchpad));
        // Pick the V2 graduator by chain: ARC (native = USDC) pairs `<token, USDC-ERC20>` via a
        // behaviorally different contract, not an import-swapped constant. Both self-guard in their ctor.
        address graduatorV2 = block.chainid == DeploymentAddressesArcTestnet.BLOCKCHAIN_ID
            ? address(new LivoGraduatorUniswapV2Arc(d.univ2Router, launchpad, d.univ2PairInitCodeHash))
            : address(new LivoGraduatorUniswapV2(d.univ2Router, launchpad, d.univ2PairInitCodeHash));
        // Chain-shared singleton; the V4 graduator and taxable tokens' `processLiquidity` both need it.
        address liquidityAdder = address(new LivoUniV4LiquidityAdder(d.univ4PositionManager, d.univ4PoolManager));
        address graduatorV4 = address(
            new LivoGraduatorUniswapV4(
                launchpad,
                d.univ4PoolManager,
                d.univ4PositionManager,
                d.permit2,
                d.swapHook,
                d.defaultGradSqrtPrice,
                d.defaultTickUpper,
                liquidityAdder
            )
        );

        vm.stopBroadcast();

        console.log("=== Deployed. Paste into src/config/manifest.arc.testnet.sol ===");
        console.log("MASTER_FEE_HANDLER  ", feeHandler);
        console.log("LAUNCHPAD           ", launchpad);
        console.log("QUOTER              ", quoter);
        console.log("GRADUATOR_UNIV2     ", graduatorV2);
        console.log("GRADUATOR_UNIV4     ", graduatorV4);
        console.log("UNIV4_LIQUIDITY_ADDER", liquidityAdder);
        console.log("");
        console.log("Next: update the manifest, `just export-deployments`, then the vault/tier/factory scripts.");
    }

    function _resolveDeps() internal view returns (Deps memory d) {
        if (block.chainid == DeploymentAddressesArcTestnet.BLOCKCHAIN_ID) {
            d = Deps({
                treasury: DeploymentAddressesArcTestnet.LIVO_TREASURY,
                swapHook: DeploymentsArcTestnet.SWAP_HOOK,
                univ2Router: DeploymentAddressesArcTestnet.UNIV2_ROUTER,
                univ2PairInitCodeHash: DeploymentAddressesArcTestnet.UNIV2_PAIR_INIT_CODE_HASH,
                univ4PoolManager: DeploymentAddressesArcTestnet.UNIV4_POOL_MANAGER,
                univ4PositionManager: DeploymentAddressesArcTestnet.UNIV4_POSITION_MANAGER,
                permit2: DeploymentAddressesArcTestnet.PERMIT2,
                defaultGradSqrtPrice: UniswapV4PoolConstantsArc.SQRT_PRICEX96_GRADUATION_DEFAULT,
                defaultTickUpper: UniswapV4PoolConstantsArc.TICK_UPPER
            });
        } else {
            revert("Unsupported chain (this is a new-chain bootstrap; existing chains are already deployed)");
        }
    }
}
