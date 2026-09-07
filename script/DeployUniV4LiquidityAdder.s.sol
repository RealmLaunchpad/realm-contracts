// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {LivoUniV4LiquidityAdder} from "src/liquidity/LivoUniV4LiquidityAdder.sol";
import {
    DeploymentAddressesEthereumMainnet,
    DeploymentAddressesEthereumSepolia,
    DeploymentAddressesRobinhoodMainnet,
    DeploymentAddressesRobinhoodTestnet
} from "src/config/DeploymentAddresses.sol";

/// @title DeployUniV4LiquidityAdder
/// @notice Deploys the single, shared, permissionless `LivoUniV4LiquidityAdder` for a chain. It is a
///         stateless immutable singleton reused by every V4 graduator (secondary position) and by taxable
///         tokens' `processLiquidity`. Deploy it ONCE per chain, paste the address into
///         `UNIV4_LIQUIDITY_ADDER` in `src/config/manifest.<chain>.sol`, run `just export-deployments`,
///         and only then run the graduator scripts (which read it back from the manifest).
contract DeployUniV4LiquidityAdder is Script {
    function run() external {
        (address positionManager, address poolManager) = _infra();

        console.log("=== Deploy LivoUniV4LiquidityAdder ===");
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", msg.sender);

        vm.startBroadcast();
        address adder = address(new LivoUniV4LiquidityAdder(positionManager, poolManager));
        vm.stopBroadcast();

        console.log("=== Deployed. Paste into src/config/manifest.<chain>.sol ===");
        console.log("UNIV4_LIQUIDITY_ADDER", adder);
    }

    function _infra() internal view returns (address positionManager, address poolManager) {
        if (block.chainid == DeploymentAddressesEthereumMainnet.BLOCKCHAIN_ID) {
            return (
                DeploymentAddressesEthereumMainnet.UNIV4_POSITION_MANAGER,
                DeploymentAddressesEthereumMainnet.UNIV4_POOL_MANAGER
            );
        } else if (block.chainid == DeploymentAddressesEthereumSepolia.BLOCKCHAIN_ID) {
            return (
                DeploymentAddressesEthereumSepolia.UNIV4_POSITION_MANAGER,
                DeploymentAddressesEthereumSepolia.UNIV4_POOL_MANAGER
            );
        } else if (block.chainid == DeploymentAddressesRobinhoodMainnet.BLOCKCHAIN_ID) {
            return (
                DeploymentAddressesRobinhoodMainnet.UNIV4_POSITION_MANAGER,
                DeploymentAddressesRobinhoodMainnet.UNIV4_POOL_MANAGER
            );
        } else if (block.chainid == DeploymentAddressesRobinhoodTestnet.BLOCKCHAIN_ID) {
            return (
                DeploymentAddressesRobinhoodTestnet.UNIV4_POSITION_MANAGER,
                DeploymentAddressesRobinhoodTestnet.UNIV4_POOL_MANAGER
            );
        }
        revert("Unsupported chain ID");
    }
}
