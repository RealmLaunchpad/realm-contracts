// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Utils} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol";

import {SwapLpFeeRouter} from "src/feeRouters/SwapLpFeeRouter.sol";
import {ChainConfig} from "script/ChainConfig.sol";

/// @title Ship a new `SwapLpFeeRouter` policy to the live proxy
/// @notice Deploys a fresh `SwapLpFeeRouter` implementation from the current build (treasury from
///         `DeploymentAddresses`) and points the manifest's `LP_FEE_ROUTER` proxy at it. The proxy
///         address — the one the hook holds as an immutable — never moves, so the hook keeps its Uniswap
///         whitelisting and nothing else is touched. The broadcaster must own the proxy (`realm.dev`).
///
/// @dev    Run: just upgrade-lp-fee-router-<sepolia|robinhood|robinhood-testnet>
///         Dry-run first: the same `forge script` without --broadcast, plus --sender <realm.dev address>
///         so the owner check passes in simulation.
contract UpgradeSwapLpFeeRouter is Script {
    function run() external {
        address proxy = ChainConfig.lpFeeRouter();
        address treasury = ChainConfig.infra().treasury;
        address oldImpl = address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));

        console.log("=== Upgrade SwapLpFeeRouter ===");
        console.log("Chain ID: ", block.chainid);
        console.log("Deployer: ", msg.sender);
        console.log("Proxy:    ", proxy);
        console.log("Old impl: ", oldImpl);
        console.log("Treasury: ", treasury);
        console.log("");

        vm.startBroadcast();
        address newImpl = address(new SwapLpFeeRouter(treasury));
        UUPSUpgradeable(proxy).upgradeToAndCall(newImpl, "");
        vm.stopBroadcast();

        // The proxy now answers with the new implementation's baked policy.
        require(SwapLpFeeRouter(proxy).TREASURY() == treasury, "post-upgrade: treasury mismatch");
        require(SwapLpFeeRouter(proxy).TREASURY_BPS() == 3_000, "post-upgrade: split mismatch");

        console.log("=== Upgraded. Paste into src/config/manifest.%s.sol ===", ChainConfig.name());
        console.log("  LP_FEE_ROUTER_IMPL =", newImpl);
        console.log("");
        console.log("Then: just export-deployments");
    }
}
