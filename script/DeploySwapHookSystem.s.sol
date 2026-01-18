// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "lib/forge-std/src/Script.sol";
import {console} from "lib/forge-std/src/console.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "lib/v4-periphery/src/utils/HookMiner.sol";
import {LivoSwapHook} from "src/hooks/LivoSwapHook.sol";
import {LivoTaxTokenUniV4} from "src/tokens/LivoTaxTokenUniV4.sol";
import {LivoGraduatorUniswapV4} from "src/graduators/LivoGraduatorUniswapV4.sol";
import {HookAddresses} from "src/config/HookAddresses.sol";

/// @notice Deploys the complete tax hook system including hook, token implementation, and graduator
/// @dev This script mines the hook address and deploys all necessary contracts for taxable tokens
contract DeploySwapHookSystem is Script {
    // review this
    /// @notice Standard CREATE2 deployer address (same on all chains)
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    /// @notice Configuration struct for deployment parameters
    struct DeployConfig {
        address launchpad;
        address liquidityLock;
        address poolManager;
        address positionManager;
        address permit2;
    }

    /// @notice Mainnet configuration
    function getMainnetConfig() internal pure returns (DeployConfig memory) {
        return DeployConfig({
            launchpad: address(0), // TODO: Set LivoLaunchpad address
            liquidityLock: address(0), // TODO: Set LiquidityLockUniv4WithFees address
            poolManager: 0x000000000004444c5dc75cB358380D2e3dE08A90, // Uniswap V4 Pool Manager
            positionManager: 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e, // Uniswap V4 Position Manager
            permit2: 0x000000000022D473030F116dDEE9F6B43aC78BA3 // Permit2
        });
    }

    /// @notice Sepolia testnet configuration
    function getSepoliaConfig() internal pure returns (DeployConfig memory) {
        return DeployConfig({
            launchpad: address(0), // TODO: Set LivoLaunchpad address on Sepolia
            liquidityLock: address(0), // TODO: Set LiquidityLockUniv4WithFees address on Sepolia
            poolManager: address(0), // TODO: Set Pool Manager address on Sepolia
            positionManager: address(0), // TODO: Set Position Manager address on Sepolia
            permit2: address(0) // TODO: Set Permit2 address on Sepolia
        });
    }

    function run() public {
        revert("Review this before deploying");

        // Determine configuration based on chain
        DeployConfig memory config;
        if (block.chainid == 1) {
            config = getMainnetConfig();
            console.log("Deploying to Ethereum Mainnet");
        } else if (block.chainid == 11155111) {
            config = getSepoliaConfig();
            console.log("Deploying to Sepolia Testnet");
        } else {
            revert("Unsupported chain");
        }

        // Validate configuration
        require(config.launchpad != address(0), "Launchpad address not set");
        require(config.liquidityLock != address(0), "LiquidityLock address not set");
        require(config.poolManager != address(0), "PoolManager address not set");
        require(config.positionManager != address(0), "PositionManager address not set");
        require(config.permit2 != address(0), "Permit2 address not set");

        console.log("=== Swap Hook System Deployment ===");
        console.log("");

        // Step 1: Mine hook address
        console.log("Step 1: Mining hook address...");
        (address hookAddress, bytes32 salt) = mineHookAddress(config.poolManager);
        console.log("  Mined hook address:", hookAddress);
        console.log("  Salt:", uint256(salt));
        console.log("");

        // Step 2: Deploy hook
        console.log("Step 2: Deploying LivoSwapHook...");
        vm.startBroadcast();
        LivoSwapHook hook = new LivoSwapHook{salt: salt}(IPoolManager(config.poolManager));
        require(address(hook) == hookAddress, "Hook address mismatch");
        vm.stopBroadcast();
        console.log("  Deployed at:", address(hook));
        console.log("");

        // Step 3: Deploy token implementation
        console.log("Step 3: Deploying LivoTaxTokenUniV4 implementation...");
        vm.broadcast();
        LivoTaxTokenUniV4 tokenImpl = new LivoTaxTokenUniV4();
        console.log("  Deployed at:", address(tokenImpl));
        console.log("");

        // Step 4: Deploy graduator
        console.log("Step 4: Deploying LivoGraduatorUniswapV4...");
        vm.startBroadcast();
        LivoGraduatorUniswapV4 graduator = new LivoGraduatorUniswapV4(
            config.launchpad,
            config.liquidityLock,
            config.poolManager,
            config.positionManager,
            config.permit2,
            HookAddresses.LIVO_SWAP_HOOK
        );
        console.log("  Deployed at:", address(graduator));
        console.log("");

        // Summary
        console.log("=== Deployment Summary ===");
        console.log("LivoSwapHook:", address(hook));
        console.log("LivoTaxTokenUniV4 (impl):", address(tokenImpl));
        console.log("LivoGraduatorUniswapV4:", address(graduator));
        console.log("");
        console.log("=== Next Steps ===");
        console.log("1. Whitelist components in LivoLaunchpad:");
        console.log("   launchpad.whitelistComponents(");
        console.log("     ", address(tokenImpl), ",");
        console.log("     ", "<bonding_curve_address>", ",");
        console.log("     ", address(graduator), ",");
        console.log("     ", "<ethGraduationThreshold>", ",");
        console.log("     ", "<maxExcessOverThreshold>", ",");
        console.log("     ", "<graduationEthFee>");
        console.log("   )");
    }

    /// @notice Mines a hook address with the required permission flags
    /// @param poolManager The pool manager address to use in constructor args
    /// @return hookAddress The mined hook address
    /// @return salt The salt used to generate the address
    function mineHookAddress(address poolManager) internal view returns (address hookAddress, bytes32 salt) {
        // Hook permission flags
        // BEFORE_SWAP_FLAG = 1 << 7 = 0x80
        // AFTER_SWAP_FLAG = 1 << 6 = 0x40
        // AFTER_SWAP_RETURNS_DELTA_FLAG = 1 << 2 = 0x04
        // Combined = 0xC4
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);

        bytes memory constructorArgs = abi.encode(IPoolManager(poolManager));
        bytes memory creationCode = type(LivoSwapHook).creationCode;

        // Mine the salt
        (hookAddress, salt) = HookMiner.find(CREATE2_DEPLOYER, flags, creationCode, constructorArgs);

        console.log("  Required flags: 0x%x", flags);
        console.log("  Found address with correct flags");
    }
}
