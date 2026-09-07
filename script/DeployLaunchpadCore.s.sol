// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {RealmLaunchpad} from "src/RealmLaunchpad.sol";
import {RealmQuoter} from "src/RealmQuoter.sol";
import {RealmMasterFeeHandler} from "src/feeHandlers/RealmMasterFeeHandler.sol";
import {RealmGraduatorUniswapV2} from "src/graduators/RealmGraduatorUniswapV2.sol";
import {RealmGraduatorUniswapV4} from "src/graduators/RealmGraduatorUniswapV4.sol";
import {RealmUniV4LiquidityAdder} from "src/liquidity/RealmUniV4LiquidityAdder.sol";
import {UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants.sol";
import {
    DeploymentAddressesEthereumSepolia,
    DeploymentAddressesRobinhoodMainnet
} from "src/config/DeploymentAddresses.sol";
import {DeploymentsEthereumSepolia} from "src/config/manifest.ethereum.sepolia.sol";
import {DeploymentsRobinhoodMainnet} from "src/config/manifest.robinhood.mainnet.sol";

/// @title Deploy the from-scratch launchpad core for a brand-new chain
/// @notice Deploys the core Realm contracts that no other current script bootstraps — the pieces the
///         removed `DeployFullStack` used to seed. On a fresh chain these must exist before the
///         creator-vault / tier / factory scripts can run:
///           1. `RealmMasterFeeHandler`
///           2. `RealmLaunchpad` (owner = broadcaster, treasury from `DeploymentAddresses*`)
///           3. `RealmQuoter`
///           4. `RealmGraduatorUniswapV2` (DEFAULT tier / V2 venue)
///           5. `RealmUniV4LiquidityAdder` (shared singleton consumed by the V4 graduator)
///           6. `RealmGraduatorUniswapV4` (DEFAULT tier / V4 venue)
///
///         It does NOT deploy the DEFAULT `BONDING_CURVE`: `DeployTierLiquiditySystem` (re)deploys that
///         (and every tier curve) and is the source of truth for it.
///
///         Realm inherits only `SWAP_HOOK` from the Livo deployment; every other manifest slot on both
///         supported chains is `address(0)`, so this script is the FIRST one to run on each of them.
///
/// @dev    Ordering: run `DeployRealmLpFeeRouter` then `DeployLivoSwapHook` FIRST unless the manifest
///         already carries an inherited `SWAP_HOOK` — the DEFAULT V4 graduator takes the hook as a
///         constructor immutable. After this: paste the printed addresses into
///         `src/config/manifest.<chain>.sol`, `just export-deployments`, then the vault/tier/factory
///         scripts.
///
///         Retarget the build first: `just chain-sepolia` / `just chain-robinhood`, then `forge build`
///         (the graduators bake pool geometry + fees via import-swap).
///
///         Run: forge script DeployLaunchpadCore --rpc-url <sepolia|robinhood-mainnet> \
///                  --account livo.dev --slow --broadcast
contract DeployLaunchpadCore is Script {
    /// @dev DEFAULT-tier graduation price (12.25 ETH mcap), from `simulations/script/uniswapV4Settings.py`.
    ///      Same value `RedeployUniV4Graduators` and `DeployTierLiquiditySystem` use.
    uint160 internal constant DEFAULT_GRAD_SQRT_PRICE_X96 = 715832709642994126662528799866880;

    struct Deps {
        address treasury;
        address swapHook;
        address univ2Router;
        bytes32 univ2PairInitCodeHash;
        address univ4PoolManager;
        address univ4PositionManager;
        address permit2;
    }

    function run() public {
        Deps memory d = _resolveDeps();
        require(d.swapHook != address(0), "manifest: SWAP_HOOK missing (deploy the hook first)");
        require(d.treasury != address(0), "REALM_TREASURY not set");
        // The graduators self-guard against a build/target mismatch in their constructors
        // (GraduationFeeConstants.assertDeployableOn) — no per-script check needed.

        console.log("=== Deploy Realm launchpad core (from-scratch bootstrap) ===");
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", msg.sender);
        console.log("Treasury:", d.treasury);
        console.log("Swap hook:", d.swapHook);
        console.log("");

        vm.startBroadcast();

        address feeHandler = address(new RealmMasterFeeHandler());
        address launchpad = address(new RealmLaunchpad(d.treasury, msg.sender));
        address quoter = address(new RealmQuoter(launchpad));
        address graduatorV2 = address(new RealmGraduatorUniswapV2(d.univ2Router, launchpad, d.univ2PairInitCodeHash));
        // Chain-shared singleton; the V4 graduator and taxable tokens' `processLiquidity` both need it.
        address liquidityAdder = address(new RealmUniV4LiquidityAdder(d.univ4PositionManager, d.univ4PoolManager));
        address graduatorV4 = address(
            new RealmGraduatorUniswapV4(
                launchpad,
                d.univ4PoolManager,
                d.univ4PositionManager,
                d.permit2,
                d.swapHook,
                DEFAULT_GRAD_SQRT_PRICE_X96,
                UniswapV4PoolConstants.TICK_UPPER,
                liquidityAdder
            )
        );

        vm.stopBroadcast();

        console.log("=== Deployed. Paste into src/config/manifest.<chain>.sol ===");
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
        if (block.chainid == DeploymentAddressesEthereumSepolia.BLOCKCHAIN_ID) {
            d = Deps({
                treasury: DeploymentAddressesEthereumSepolia.REALM_TREASURY,
                swapHook: DeploymentsEthereumSepolia.SWAP_HOOK,
                univ2Router: DeploymentAddressesEthereumSepolia.UNIV2_ROUTER,
                univ2PairInitCodeHash: DeploymentAddressesEthereumSepolia.UNIV2_PAIR_INIT_CODE_HASH,
                univ4PoolManager: DeploymentAddressesEthereumSepolia.UNIV4_POOL_MANAGER,
                univ4PositionManager: DeploymentAddressesEthereumSepolia.UNIV4_POSITION_MANAGER,
                permit2: DeploymentAddressesEthereumSepolia.PERMIT2
            });
        } else if (block.chainid == DeploymentAddressesRobinhoodMainnet.BLOCKCHAIN_ID) {
            d = Deps({
                treasury: DeploymentAddressesRobinhoodMainnet.REALM_TREASURY,
                swapHook: DeploymentsRobinhoodMainnet.SWAP_HOOK,
                univ2Router: DeploymentAddressesRobinhoodMainnet.UNIV2_ROUTER,
                univ2PairInitCodeHash: DeploymentAddressesRobinhoodMainnet.UNIV2_PAIR_INIT_CODE_HASH,
                univ4PoolManager: DeploymentAddressesRobinhoodMainnet.UNIV4_POOL_MANAGER,
                univ4PositionManager: DeploymentAddressesRobinhoodMainnet.UNIV4_POSITION_MANAGER,
                permit2: DeploymentAddressesRobinhoodMainnet.PERMIT2
            });
        } else {
            revert("Unsupported chain (Realm deploys on Sepolia and Robinhood mainnet only)");
        }
    }
}
