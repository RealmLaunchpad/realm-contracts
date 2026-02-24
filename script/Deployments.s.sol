// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {ConstantProductBondingCurve} from "src/bondingCurves/ConstantProductBondingCurve.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {LivoGraduatorUniswapV2} from "src/graduators/LivoGraduatorUniswapV2.sol";
import {LiquidityLockUniv4WithFees} from "src/locks/LiquidityLockUniv4WithFees.sol";
import {LivoGraduatorUniswapV4} from "src/graduators/LivoGraduatorUniswapV4.sol";
import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {DeploymentAddressesMainnet, DeploymentAddressesSepolia} from "src/config/DeploymentAddresses.sol";

import {DeploymentAddresses as AddressesFromLivoTaxableToken} from "src/tokens/LivoTaxableTokenUniV4.sol";

/// @title Livo Protocol Deployment Script
/// @notice Deploys all core Livo contracts and configures whitelisted component sets
/// @dev Run with: forge script script/Deployments.s.sol --rpc-url <mainnet|sepolia> --broadcast --verify
contract Deployments is Script {
    // ========================= Configuration =========================

    // TODO: Set treasury address before deployment (this is livo.dev for now)
    address constant TREASURY = 0xBa489180Ea6EEB25cA65f123a46F3115F388f181; // TODO: Set before deployment

    // Graduation parameters for whitelisting sets
    uint256 constant GRADUATION_THRESHOLD = 8.5 ether;
    uint256 constant MAX_EXCESS_OVER_THRESHOLD = 100000000000000000; // 0.1 ETH

    // ========================= Network Config =========================

    function _getNetworkAddresses()
        internal
        view
        returns (
            address univ2Router,
            address univ4PoolManager,
            address univ4PositionManager,
            address permit2,
            address hookAddress
        )
    {
        if (block.chainid == 1) {
            // Mainnet
            univ2Router = DeploymentAddressesMainnet.UNIV2_ROUTER;
            univ4PoolManager = DeploymentAddressesMainnet.UNIV4_POOL_MANAGER;
            univ4PositionManager = DeploymentAddressesMainnet.UNIV4_POSITION_MANAGER;
            permit2 = DeploymentAddressesMainnet.PERMIT2;
            hookAddress = DeploymentAddressesMainnet.LIVO_SWAP_HOOK;
        } else if (block.chainid == 11155111) {
            // Sepolia
            univ2Router = DeploymentAddressesSepolia.UNIV2_ROUTER;
            univ4PoolManager = DeploymentAddressesSepolia.UNIV4_POOL_MANAGER;
            univ4PositionManager = DeploymentAddressesSepolia.UNIV4_POSITION_MANAGER;
            permit2 = DeploymentAddressesSepolia.PERMIT2;
            hookAddress = DeploymentAddressesSepolia.LIVO_SWAP_HOOK;
        } else {
            revert("Unsupported chain");
        }

        // NOTE: LivoTaxableTokenUniV4 has hardcoded addresses corresponding to the imported configs
        // this makes sure we have the right imports in both places
        // if the pool manager is in the right network, all other addresses are
        require(
            address(AddressesFromLivoTaxableToken.UNIV4_POOL_MANAGER) == univ4PoolManager,
            "Invalid UNIV4_POOL_MANAGER address. Wrong chain id"
        );
    }

    // ========================= Deployment =========================

    function run() public {
        require(TREASURY != address(0), "TREASURY address not set");

        (
            address univ2Router,
            address univ4PoolManager,
            address univ4PositionManager,
            address permit2,
            address hookAddress
        ) = _getNetworkAddresses();

        console.log("=== Livo Protocol Deployment ===");
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", msg.sender);
        console.log("Treasury:", TREASURY);
        console.log("");

        console.log("");
        console.log("Deploying contracts...");

        vm.startBroadcast();

        console.log("| Contract Name | Address |");
        console.log("| ---- | --- | ");

        // 1. Deploy LivoToken (implementation for clones)
        LivoToken livoToken = new LivoToken();
        console.log("| LivoToken | ", address(livoToken));

        // 2. Deploy ConstantProductBondingCurve
        ConstantProductBondingCurve bondingCurve = new ConstantProductBondingCurve();
        console.log("| ConstantProductBondingCurve | ", address(bondingCurve));

        // 3. Deploy LivoLaunchpad
        LivoLaunchpad launchpad = new LivoLaunchpad(TREASURY);
        console.log("| LivoLaunchpad | ", address(launchpad));

        // 4. Deploy LivoGraduatorUniswapV2
        LivoGraduatorUniswapV2 graduatorV2 = new LivoGraduatorUniswapV2(univ2Router, address(launchpad));
        console.log("| LivoGraduatorUniswapV2 | ", address(graduatorV2));

        // 5. Deploy LiquidityLockUniv4WithFees
        LiquidityLockUniv4WithFees liquidityLock = new LiquidityLockUniv4WithFees(univ4PositionManager);
        console.log("| LiquidityLockUniv4WithFees | ", address(liquidityLock));

        // 6. Deploy LivoGraduatorUniswapV4
        // NOTE: Hook address must be mined first and updated in DeploymentAddresses.sol
        LivoGraduatorUniswapV4 graduatorV4 = new LivoGraduatorUniswapV4(
            address(launchpad), address(liquidityLock), univ4PoolManager, univ4PositionManager, permit2, hookAddress
        );
        console.log("| LivoGraduatorUniswapV4 | ", address(graduatorV4));

        // 7. Deploy LivoTaxableTokenUniV4 (implementation for clones)
        // note: the right chainid config is checked when reading configs
        LivoTaxableTokenUniV4 livoTaxableToken = new LivoTaxableTokenUniV4();
        console.log("| LivoTaxableTokenUniV4 | ", address(livoTaxableToken));

        // log the hook, just for completeness
        console.log("| LivoSwapHook | ", hookAddress);

        console.log("");
        console.log("Whitelisting components...");

        // 8. Whitelist component sets on launchpad
        // V2 graduator set
        launchpad.whitelistComponents(
            address(livoToken),
            address(bondingCurve),
            address(graduatorV2),
            GRADUATION_THRESHOLD,
            MAX_EXCESS_OVER_THRESHOLD
        );
        console.log("Whitelisted V2 component set (LivoToken)");

        // V4 graduator set (LivoToken)
        launchpad.whitelistComponents(
            address(livoToken),
            address(bondingCurve),
            address(graduatorV4),
            GRADUATION_THRESHOLD,
            MAX_EXCESS_OVER_THRESHOLD
        );
        console.log("Whitelisted V4 component set (LivoToken)");

        // V4 graduator set (LivoTaxableTokenUniV4)
        launchpad.whitelistComponents(
            address(livoTaxableToken),
            address(bondingCurve),
            address(graduatorV4),
            GRADUATION_THRESHOLD,
            MAX_EXCESS_OVER_THRESHOLD
        );
        console.log("Whitelisted V4 component set (LivoTaxableTokenUniV4)");

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("");
        console.log("Next steps:");
        console.log("1. Update deployed addresses in justfile");
        console.log("2. Update launchpad address in envio");
        console.log("3. (Optional) Transfer ownership if needed");
    }
}
