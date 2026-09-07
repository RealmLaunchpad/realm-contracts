// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {LivoToken} from "src/tokens/LivoToken.sol";
import {LivoGraduatorUniswapV4} from "src/graduators/LivoGraduatorUniswapV4.sol";
import {LivoUniV4LiquidityAdder} from "src/liquidity/LivoUniV4LiquidityAdder.sol";
import {ConstantProductBondingCurveConfigurable} from "src/bondingCurves/ConstantProductBondingCurveConfigurable.sol";
import {LivoFactoryUniV4Unified} from "src/factories/LivoFactoryUniV4Unified.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {CreatorVaultCurveConstants} from "src/config/CreatorVaultCurveConstants.sol";
import {UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants.sol";
import {
    DeploymentAddressesEthereumMainnet,
    DeploymentAddressesEthereumSepolia,
    DeploymentAddressesRobinhoodMainnet,
    DeploymentAddressesRobinhoodTestnet
} from "src/config/DeploymentAddresses.sol";
import {DeploymentsEthereumMainnet} from "src/config/manifest.ethereum.mainnet.sol";
import {DeploymentsEthereumSepolia} from "src/config/manifest.ethereum.sepolia.sol";
import {DeploymentsRobinhoodMainnet} from "src/config/manifest.robinhood.mainnet.sol";
import {DeploymentsRobinhoodTestnet} from "src/config/manifest.robinhood.testnet.sol";

/// @title One-off: THIN-tier V4 graduator + minimal factory around an already-deployed `LivoSwapHook`
/// @notice Targeted, throwaway deployment for graduating a single barebone V4 token (no tax / no decay /
///         no anti-sniper / no creator vaults) through the THIN liquidity tier with a given hook. Deploys
///         the four pieces that a THIN barebone token actually needs and wires everything else in the
///         factory constructor to `address(0)` — the factory ctor has no `require`s and `_createToken`
///         never reads the DEFAULT/THICK graduators, the vault machinery, or the non-base token impls for
///         this path. The factory is deployed as a bare IMPLEMENTATION (no proxy): `createToken` only
///         reads constructor immutables, so no `initialize()` is needed; whitelist the impl directly.
///
///         Deploys:
///         1. `LivoToken`                          — base token impl (this branch's bytecode, with the
///                                                    `swapLpFeeBps` the hook reads back via `getSwapFees`)
///         2. `ConstantProductBondingCurveConfigurable` — THIN no-vault base curve (params from
///                                                    `CreatorVaultCurveConstants`)
///         3. `LivoGraduatorUniswapV4`             — THIN graduator pointing at `HOOK_ADDRESS`
///         4. `LivoFactoryUniV4Unified` (impl)     — wired to 1/2/3 + existing launchpad/fee handler
///
///         Reuses (read per-chain, not deployed): `LAUNCHPAD`, `MASTER_FEE_HANDLER`, and the Uniswap V4
///         pool/position managers + Permit2. Does NOT touch the manifest or the tier machinery.
///
///         Env vars:
///         - `HOOK_ADDRESS` (required)  the already-deployed `LivoSwapHook` (deploy it first with
///                                      `DeployLivoSwapHook`; its LP-fee-router dependency is not needed here).
///
/// @dev    Runs against Mainnet (1), Sepolia (11155111) or Robinhood (4663 / 46630).
///
/// @dev    Run with:
///         HOOK_ADDRESS=<hook> forge script DeployHookGraduatorFactory \
///             --rpc-url <mainnet|sepolia|robinhood-mainnet|robinhood-testnet> \
///             --account livo.dev --slow --broadcast
///         On Robinhood add `--gas-estimate-multiplier 300` (Arbitrum L2: forge under-provisions
///         contract-creation gas) and verify via Blockscout rather than the `[etherscan]` table.
contract DeployHookGraduatorFactory is Script {
    /// @dev THIN-tier graduation price (6.125 ETH mcap), from `simulations/script/uniswapV4Settings.py`.
    ///      Mirrors `DeployTierLiquiditySystem` / `RedeployUniV4Graduators`.
    uint160 internal constant THIN_GRAD_SQRT_PRICE_X96 = 1012340326367404053977557838594048;

    struct Infra {
        address launchpad;
        address masterFeeHandler;
        address poolManager;
        address positionManager;
        address permit2;
    }

    function run() external {
        address hook = vm.envAddress("HOOK_ADDRESS");
        require(hook.code.length > 0, "HOOK_ADDRESS has no code");
        Infra memory infra = _infra();

        console.log("=== One-off: THIN graduator + minimal V4 factory ===");
        console.log("Chain ID:", block.chainid);
        console.log("Hook:    ", hook);
        console.log("");

        vm.startBroadcast();

        // 1. Base token implementation (barebone V4 token clones this).
        address baseImpl = address(new LivoToken());

        // 2. THIN no-vault base bonding curve. Params mirror `DeployTierLiquiditySystem`. Scoped in a
        //    block so the five curve-param locals free up before the graduator/factory construction below
        //    (keeps `run()` under the stack-too-deep limit without via-ir).
        address thinCurve;
        {
            (uint256 threshold, uint256 maxExcess) = CreatorVaultCurveConstants.tierGraduation(LiquidityTier.THIN);
            (uint256 k, uint256 t0, uint256 e0) = CreatorVaultCurveConstants.paramsFor(LiquidityTier.THIN, 0);
            thinCurve = address(new ConstantProductBondingCurveConfigurable(k, t0, e0, threshold, maxExcess));
        }

        // 3. THIN graduator, pointing at the hook. This one-off barebone factory is self-contained, so
        //    it deploys its OWN liquidity adder inline (the main-stack scripts share the manifest one).
        LivoGraduatorUniswapV4 graduator = new LivoGraduatorUniswapV4(
            infra.launchpad,
            infra.poolManager,
            infra.positionManager,
            infra.permit2,
            hook,
            THIN_GRAD_SQRT_PRICE_X96,
            UniswapV4PoolConstants.TICK_UPPER_THIN,
            address(new LivoUniV4LiquidityAdder(infra.positionManager, infra.poolManager))
        );
        require(graduator.HOOK_ADDRESS() == hook, "graduator hook mismatch");

        // 4. Minimal V4 factory implementation. Only base impl + THIN base curve + THIN graduator are
        //    wired; everything a no-vault THIN base token never reads is address(0).
        address factory = address(
            new LivoFactoryUniV4Unified(
                infra.launchpad,
                ILivoFactory.TokenImpls({base: baseImpl, tax: address(0)}),
                address(0), // DEFAULT bonding curve — unused by THIN
                address(0), // DEFAULT graduator — unused by THIN
                infra.masterFeeHandler,
                address(0), // creator vault factory — no vaults
                _emptyVaults(), // vault bonding curves — no vaults
                LivoFactoryUniV4Unified.V4TierConfig({
                    curves: ILivoFactory.LiquidityTierConfig({
                        thin: ILivoFactory.TierCurves({base: thinCurve, vaults: _emptyVaults()}),
                        thick: ILivoFactory.TierCurves({base: address(0), vaults: _emptyVaults()})
                    }),
                    graduators: LivoFactoryUniV4Unified.TierGraduators({thin: address(graduator), thick: address(0)})
                })
            )
        );

        vm.stopBroadcast();

        console.log("=== Deployed ===");
        console.log("Base LivoToken impl :", baseImpl);
        console.log("THIN bonding curve  :", thinCurve);
        console.log("THIN graduator      :", address(graduator));
        console.log("V4 factory (impl)   :", factory);
        console.log("");
        console.log("Next:");
        console.log("1. Whitelist the factory IMPL on the launchpad (launchpad owner = livo.admin):");
        console.log("   cast send", infra.launchpad, "'whitelistFactory(address)'");
        console.log("   <factory> --account livo.admin");
        console.log("2. Create a THIN token through it (THIN is CreateV4Token's default):");
        console.log("   FACTORY_ADDRESS=<factory> forge script CreateV4Token --account livo.dev --slow --broadcast");
        console.log("3. Buy through the launchpad until it crosses the graduation threshold.");
    }

    function _emptyVaults() internal pure returns (address[6] memory v) {}

    function _infra() internal view returns (Infra memory infra) {
        if (block.chainid == DeploymentAddressesEthereumMainnet.BLOCKCHAIN_ID) {
            infra = Infra({
                launchpad: DeploymentsEthereumMainnet.LAUNCHPAD,
                masterFeeHandler: DeploymentsEthereumMainnet.MASTER_FEE_HANDLER,
                poolManager: DeploymentAddressesEthereumMainnet.UNIV4_POOL_MANAGER,
                positionManager: DeploymentAddressesEthereumMainnet.UNIV4_POSITION_MANAGER,
                permit2: DeploymentAddressesEthereumMainnet.PERMIT2
            });
        } else if (block.chainid == DeploymentAddressesEthereumSepolia.BLOCKCHAIN_ID) {
            infra = Infra({
                launchpad: DeploymentsEthereumSepolia.LAUNCHPAD,
                masterFeeHandler: DeploymentsEthereumSepolia.MASTER_FEE_HANDLER,
                poolManager: DeploymentAddressesEthereumSepolia.UNIV4_POOL_MANAGER,
                positionManager: DeploymentAddressesEthereumSepolia.UNIV4_POSITION_MANAGER,
                permit2: DeploymentAddressesEthereumSepolia.PERMIT2
            });
        } else if (block.chainid == DeploymentAddressesRobinhoodMainnet.BLOCKCHAIN_ID) {
            infra = Infra({
                launchpad: DeploymentsRobinhoodMainnet.LAUNCHPAD,
                masterFeeHandler: DeploymentsRobinhoodMainnet.MASTER_FEE_HANDLER,
                poolManager: DeploymentAddressesRobinhoodMainnet.UNIV4_POOL_MANAGER,
                positionManager: DeploymentAddressesRobinhoodMainnet.UNIV4_POSITION_MANAGER,
                permit2: DeploymentAddressesRobinhoodMainnet.PERMIT2
            });
        } else if (block.chainid == DeploymentAddressesRobinhoodTestnet.BLOCKCHAIN_ID) {
            infra = Infra({
                launchpad: DeploymentsRobinhoodTestnet.LAUNCHPAD,
                masterFeeHandler: DeploymentsRobinhoodTestnet.MASTER_FEE_HANDLER,
                poolManager: DeploymentAddressesRobinhoodTestnet.UNIV4_POOL_MANAGER,
                positionManager: DeploymentAddressesRobinhoodTestnet.UNIV4_POSITION_MANAGER,
                permit2: DeploymentAddressesRobinhoodTestnet.PERMIT2
            });
        } else {
            revert("Unsupported chain ID");
        }
        require(infra.launchpad != address(0), "manifest: LAUNCHPAD missing");
        require(infra.masterFeeHandler != address(0), "manifest: MASTER_FEE_HANDLER missing");
    }
}
