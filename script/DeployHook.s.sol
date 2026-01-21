// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "lib/v4-periphery/src/utils/HookMiner.sol";
import {LivoSwapHook} from "src/hooks/LivoSwapHook.sol";
import {DeploymentAddressesMainnet, DeploymentAddressesSepolia} from "src/config/DeploymentAddresses.sol";

/// @title LivoSwapHook Deployment Script
/// @notice Mines a valid hook address and deploys the LivoSwapHook contract
/// @dev Run with: forge script script/DeployHook.s.sol --rpc-url <mainnet|sepolia> --broadcast --verify
contract DeployHook is Script {
    // Foundry's deterministic deployment proxy (Create2 deployer)
    address constant FOUNDRY_CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() public {
        // Get deployment addresses based on chain ID
        (address poolManager, address weth) = _getDeploymentAddresses();

        console.log("Deploying on chain ID:", block.chainid);
        console.log("Pool Manager:", poolManager);
        console.log("WETH:", weth);

        // Hook permission flags: AFTER_SWAP_FLAG | AFTER_SWAP_RETURNS_DELTA_FLAG | BEFORE_SWAP_FLAG
        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_SWAP_FLAG);

        bytes memory constructorArgs = abi.encode(IPoolManager(poolManager), weth);
        bytes memory creationCode = type(LivoSwapHook).creationCode;

        console.log("Mining hook address...");
        console.log("Using Foundry CREATE2 deployer:", FOUNDRY_CREATE2_DEPLOYER);

        // Mine a salt using the Foundry CREATE2 deployer address
        (address hookAddress, bytes32 salt) =
            HookMiner.find(FOUNDRY_CREATE2_DEPLOYER, flags, creationCode, constructorArgs);

        console.log("Mined hook address:", hookAddress);
        console.log("Salt:", uint256(salt));

        // Deploy the hook using CREATE2
        vm.broadcast();
        LivoSwapHook livoSwapHook = new LivoSwapHook{salt: salt}(IPoolManager(poolManager), weth);

        console.log("Deployed hook at:", address(livoSwapHook));
        require(address(livoSwapHook) == hookAddress, "DeployHook: hook address mismatch");

        uint160 addressFlags = uint160(hookAddress);
        uint160 expectedFlags = flags;
        require((addressFlags & expectedFlags) == expectedFlags, "Address flags mismatch");

        console.log("LivoSwapHook successfully deployed at:", address(livoSwapHook));
    }

    function _getDeploymentAddresses() internal view returns (address poolManager, address weth) {
        if (block.chainid == DeploymentAddressesMainnet.BLOCKCHAIN_ID) {
            poolManager = DeploymentAddressesMainnet.UNIV4_POOL_MANAGER;
            weth = DeploymentAddressesMainnet.WETH;
        } else if (block.chainid == DeploymentAddressesSepolia.BLOCKCHAIN_ID) {
            poolManager = DeploymentAddressesSepolia.UNIV4_POOL_MANAGER;
            weth = DeploymentAddressesSepolia.WETH;
        } else {
            revert("DeployHook: unsupported chain");
        }
    }
}
