// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "lib/forge-std/src/Script.sol";
import {console} from "lib/forge-std/src/console.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "lib/v4-periphery/src/utils/HookMiner.sol";
import {LivoSwapHook} from "src/hooks/LivoSwapHook.sol";
import {DeploymentAddressesMainnet} from "src/config/DeploymentAddresses.sol";
import {DeploymentAddressesSepolia} from "src/config/DeploymentAddresses.sol";

/// @notice Simple script to mine a hook address for testing purposes
/// @dev Run this once to get a valid hook address and salt, then hardcode in tests
contract MineHookAddressForTests is Script {
    // this is the livo.dev address
    address constant CREATE2_DEPLOYER = address(0xBa489180Ea6EEB25cA65f123a46F3115F388f181);

    function run() public view {
        console.log("=== Mining Hook Address for Tests ===");
        console.log("Chain ID: %d", block.chainid);
        console.log("");

        // Get addresses based on chain ID
        (address poolManager, address weth) = _getAddresses();
        console.log("Pool Manager: %s", poolManager);
        console.log("WETH: %s", weth);
        console.log("");

        // Hook permission flags: AFTER_SWAP_FLAG | AFTER_SWAP_RETURNS_DELTA_FLAG | BEFORE_SWAP_FLAG
        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_SWAP_FLAG);

        bytes memory constructorArgs = abi.encode(IPoolManager(poolManager), weth);
        bytes memory creationCode = type(LivoSwapHook).creationCode;

        console.log("Mining... (this may take 30-60 seconds)");
        (address hookAddress, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, flags, creationCode, constructorArgs);

        console.log("");
        console.log("=== MINED ADDRESS ===");
        console.log("ChainId: %d", block.chainid);
        console.log("Hook Address: %s", hookAddress);
        console.log("Salt: %x", uint256(salt));
        // console.log("");
        // console.log("=== Copy this to your test file ===");
        // console.log("address constant PRECOMPUTED_HOOK_ADDRESS = %s;", hookAddress);
        // console.log("bytes32 constant HOOK_SALT = bytes32(uint256(%x));", uint256(salt));

        // Verify the address has the correct flags
        uint160 addressFlags = uint160(hookAddress);
        uint160 expectedFlags = flags;
        require((addressFlags & expectedFlags) == expectedFlags, "Address flags mismatch");
    }

    /// @notice Get deployment addresses based on chain ID
    /// @return poolManager The Uniswap V4 Pool Manager address
    /// @return weth The WETH address
    function _getAddresses() internal view returns (address poolManager, address weth) {
        if (block.chainid == DeploymentAddressesMainnet.BLOCKCHAIN_ID) {
            poolManager = DeploymentAddressesMainnet.UNIV4_POOL_MANAGER;
            weth = DeploymentAddressesMainnet.WETH;
        } else if (block.chainid == DeploymentAddressesSepolia.BLOCKCHAIN_ID) {
            poolManager = DeploymentAddressesSepolia.UNIV4_POOL_MANAGER;
            weth = DeploymentAddressesSepolia.WETH;
        } else {
            revert("Unsupported chain ID");
        }
    }
}
