// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {RealmVoting} from "src/voting/RealmVoting.sol";
import {ChainConfig} from "script/ChainConfig.sol";

/// @title Deploy `RealmVoting` for an existing REALM token
/// @notice Deploys the impl + UUPS proxy; round 1 opens in the deploy block. Round length defaults to
///         3 days (`VOTING_ROUND_DURATION`, seconds, overrides). Where the chain names a buyback wallet it
///         is appointed admin; the owner (broadcaster) can always act as one. The token must be a clone
///         of a `RealmToken` master that has `burnFrom` — a master that predates it needs
///         `RedeployTokenImpls` first, and a new REALM token after that.
///
/// @dev    Deploy-once: refuses while the manifest already has `VOTING`. `RealmTreasuryRouter` bakes the
///         proxy in, so this runs BEFORE `DeployRealmTreasuryRouter`.
///
/// @dev    Run: just deploy-voting-<sepolia|rh|rh-testnet> <REALM token>
///         Dry-run first: the same `forge script` without --broadcast, plus --sender <realm.dev address>.
contract DeployRealmVoting is Script {
    function run() external {
        address realm = vm.envAddress("REALM_TOKEN");
        uint256 duration = vm.envOr("VOTING_ROUND_DURATION", uint256(3 days));
        address admin = ChainConfig.voteBuybackWallet();
        require(realm.code.length != 0, "REALM_TOKEN has no code");
        require(ChainConfig.voting() == address(0), "manifest: VOTING already set");
        // A master without burnFrom would make every vote revert; probe the selector before spending gas.
        (bool ok,) = realm.staticcall(abi.encodeWithSignature("totalSupply()"));
        require(ok, "REALM_TOKEN is not an ERC20");

        console.log("=== Deploy RealmVoting ===");
        console.log("Chain ID:       ", block.chainid);
        console.log("REALM token:    ", realm);
        console.log("Round duration: ", duration);
        console.log("Admin:          ", admin);
        console.log("");

        vm.startBroadcast();
        (, address broadcaster,) = vm.readCallers();
        console.log("Deployer/owner: ", broadcaster);
        address impl = address(new RealmVoting(realm));
        RealmVoting voting =
            RealmVoting(payable(address(new ERC1967Proxy(impl, abi.encodeCall(RealmVoting.initialize, (duration))))));
        if (admin != address(0)) voting.setAdmin(admin, true);
        vm.stopBroadcast();

        require(address(voting.REALM()) == realm, "post: REALM mismatch");
        require(voting.owner() == broadcaster, "post: owner mismatch");
        require(voting.roundDuration() == duration, "post: duration mismatch");
        (uint256 id,,) = voting.currentRound();
        require(id == 1, "post: round 1 not open");

        console.log("=== Done. Paste into src/config/manifest.%s.sol ===", ChainConfig.name());
        console.log("  VOTING      =", address(voting));
        console.log("  VOTING_IMPL =", impl);
        console.log("");
        console.log("Then: just export-deployments, and just deploy-treasury-router-<chain>");
    }
}
