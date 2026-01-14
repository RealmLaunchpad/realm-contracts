// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "lib/forge-std/src/Script.sol";
import {console} from "lib/forge-std/src/console.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "lib/v4-periphery/src/utils/HookMiner.sol";
import {LivoTaxSwapHook} from "src/hooks/LivoTaxSwapHook.sol";

/// @notice Simple script to mine a hook address for testing purposes
/// @dev Run this once to get a valid hook address and salt, then hardcode in tests
contract MineHookAddressForTests is Script {
    address constant CREATE2_DEPLOYER = address(0xBa489180Ea6EEB25cA65f123a46F3115F388f181);
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90; // Mainnet pool manager

    function run() public view {
        console.log("=== Mining Hook Address for Tests ===");
        console.log("");

        // Hook permission flags: AFTER_SWAP_FLAG | AFTER_SWAP_RETURNS_DELTA_FLAG
        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        console.log("Required flags: 0x%x", flags);
        console.log("");

        bytes memory constructorArgs = abi.encode(IPoolManager(POOL_MANAGER));
        bytes memory creationCode = type(LivoTaxSwapHook).creationCode;

        console.log("Mining... (this may take 30-60 seconds)");
        (address hookAddress, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, flags, creationCode, constructorArgs);

        console.log("");
        console.log("=== MINED ADDRESS ===");
        console.log("Hook Address: %s", hookAddress);
        console.log("Salt: %x", uint256(salt));
        console.log("");
        console.log("=== Copy this to your test file ===");
        console.log("address constant PRECOMPUTED_HOOK_ADDRESS = %s;", hookAddress);
        console.log("bytes32 constant HOOK_SALT = bytes32(uint256(%x));", uint256(salt));
        console.log("");
        console.log("=== Verification ===");
        console.log("Address has correct permission flags: true");

        // Verify the address has the correct flags
        uint160 addressFlags = uint160(uint256(uint160(hookAddress)));
        uint160 expectedFlags = flags;
        require((addressFlags & expectedFlags) == expectedFlags, "Address flags mismatch");
    }
}
