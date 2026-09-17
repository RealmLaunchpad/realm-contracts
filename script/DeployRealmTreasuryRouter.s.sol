// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Utils} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol";

import {RealmTreasuryRouter} from "src/treasury/RealmTreasuryRouter.sol";
import {SwapLpFeeRouter} from "src/feeRouters/SwapLpFeeRouter.sol";
import {RealmLaunchpad} from "src/RealmLaunchpad.sol";
import {ChainConfig} from "script/ChainConfig.sol";

/// @title Put `RealmTreasuryRouter` in front of the treasury
/// @notice One broadcast, three steps: (1) deploy the `RealmTreasuryRouter` impl + UUPS proxy (2/3 to the
///         team treasury, 1/3 to the manifest's `VOTING`); (2) deploy a `SwapLpFeeRouter` impl whose
///         `TREASURY` is that proxy and upgrade the live `LP_FEE_ROUTER` onto it; (3) `setTreasuryAddress`
///         on the launchpad, which the graduators read. After this every treasury push in the protocol
///         flows through the router — except the hook's own fallback, which stays on the address the hook
///         was built with.
///
/// @dev    Refuses to run until `VOTING` is in the manifest (the router bakes it in) and while
///         `TREASURY_ROUTER` is already set (deploy-once: a policy change is a router upgrade, not a redeploy).
///         The broadcaster must own the launchpad and the LP router proxy (`realm.dev`).
///
/// @dev    Run: just deploy-treasury-router-<sepolia|rh|rh-testnet>
///         Dry-run first: the same `forge script` without --broadcast, plus --sender <realm.dev address>.
contract DeployRealmTreasuryRouter is Script {
    function run() external {
        address voting = ChainConfig.voting();
        address teamTreasury = ChainConfig.teamTreasury();
        address lpFeeRouter = ChainConfig.lpFeeRouter();
        address launchpad = ChainConfig.manifest().launchpad;
        require(voting != address(0), "manifest: VOTING missing (deploy RealmVoting first)");
        require(launchpad != address(0), "manifest: LAUNCHPAD missing");
        require(ChainConfig.treasuryRouter() == address(0), "manifest: TREASURY_ROUTER already set");
        address oldLpImpl = address(uint160(uint256(vm.load(lpFeeRouter, ERC1967Utils.IMPLEMENTATION_SLOT))));

        console.log("=== Deploy RealmTreasuryRouter + repoint treasury ===");
        console.log("Chain ID:        ", block.chainid);
        console.log("Team treasury:   ", teamTreasury);
        console.log("Voting:          ", voting);
        console.log("LP router proxy: ", lpFeeRouter);
        console.log("LP router impl:  ", oldLpImpl, "(old)");
        console.log("Launchpad:       ", launchpad);
        console.log("Launchpad treasury (old):", RealmLaunchpad(launchpad).treasury());
        console.log("");

        vm.startBroadcast();
        (, address broadcaster,) = vm.readCallers();
        console.log("Deployer/owner:  ", broadcaster);
        ChainConfig.Infra memory infra = ChainConfig.infra();
        address routerImpl = address(
            new RealmTreasuryRouter(
                teamTreasury, voting, infra.univ4UniversalRouter, infra.permit2, infra.keepersRegistry
            )
        );
        address routerProxy = address(new ERC1967Proxy(routerImpl, abi.encodeCall(RealmTreasuryRouter.initialize, ())));
        address lpImpl = address(new SwapLpFeeRouter(routerProxy));
        UUPSUpgradeable(lpFeeRouter).upgradeToAndCall(lpImpl, "");
        RealmLaunchpad(launchpad).setTreasuryAddress(routerProxy);
        vm.stopBroadcast();

        RealmTreasuryRouter router = RealmTreasuryRouter(payable(routerProxy));
        require(router.TREASURY() == teamTreasury, "post: router treasury mismatch");
        require(router.VOTING() == voting, "post: router voting mismatch");
        require(router.owner() == broadcaster, "post: router owner mismatch");
        require(SwapLpFeeRouter(lpFeeRouter).TREASURY() == routerProxy, "post: LP router not repointed");
        require(RealmLaunchpad(launchpad).treasury() == routerProxy, "post: launchpad not repointed");

        console.log("=== Done. Paste into src/config/manifest.%s.sol ===", ChainConfig.name());
        console.log("  TREASURY_ROUTER      =", routerProxy);
        console.log("  TREASURY_ROUTER_IMPL =", routerImpl);
        console.log("  LP_FEE_ROUTER_IMPL   =", lpImpl);
        console.log("");
        console.log("Then set REALM_TREASURY = TREASURY_ROUTER in this chain's src/config/DeploymentAddresses.sol");
        console.log("library (token impls bake it as DIVIDEND_TREASURY; redeploy them to follow), and");
        console.log("`just export-deployments`.");
    }
}
