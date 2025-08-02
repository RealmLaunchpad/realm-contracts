// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "../src/LivoLaunchpad.sol";
import "../src/LinearBondingCurve.sol";
import "../src/BasicGraduationManager.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy treasury (for demo, using deployer address)
        address treasury = vm.addr(deployerPrivateKey);
        
        // Deploy contracts
        LivoLaunchpad launchpad = new LivoLaunchpad(treasury);
        LinearBondingCurve bondingCurve = new LinearBondingCurve();
        
        // For demo purposes, we'll use placeholder addresses for Uniswap
        // In real deployment, these should be actual Uniswap addresses
        address uniswapRouter = address(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D); // Mainnet router
        address liquidityLock = treasury; // Placeholder
        
        BasicGraduationManager graduationManager = new BasicGraduationManager(
            uniswapRouter,
            address(launchpad),
            liquidityLock
        );
        
        // Whitelist bonding curve and graduation manager
        launchpad.whitelistBondingCurve(address(bondingCurve), true);
        launchpad.whitelistGraduationManager(address(graduationManager), true);
        launchpad.setGraduationManager(address(graduationManager));
        
        vm.stopBroadcast();
        
        console.log("LivoLaunchpad deployed at:", address(launchpad));
        console.log("LinearBondingCurve deployed at:", address(bondingCurve));
        console.log("BasicGraduationManager deployed at:", address(graduationManager));
    }
}