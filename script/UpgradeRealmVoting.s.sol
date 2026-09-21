// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Utils} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol";

import {RealmVoting} from "src/voting/RealmVoting.sol";
import {ChainConfig} from "script/ChainConfig.sol";

/// @title Repoint the live `RealmVoting` at the manifest's REALM token
/// @notice Deploys a fresh `RealmVoting` implementation from the current build and points the manifest's
///         `VOTING` proxy at it. The token it burns is an implementation immutable, so relaunching REALM
///         leaves the live voting contract burning the old one until this runs.
///
/// @dev    THE PROXY NEVER MOVES, which is the point: `RealmTreasuryRouter` bakes `VOTING` in as an
///         immutable and an indexer subscribes to it statically, so neither needs touching. Replacing the
///         proxy instead would mean `UpgradeRealmTreasuryRouter` and an indexer config change.
///
/// @dev    ROUND STATE SURVIVES THE UPGRADE. `roundDuration`, the schedule anchor, `lastSyncedRound` and
///         every per-round tally live in proxy storage, so the round counter carries on and any votes
///         already cast stay on the books — denominated in burns of the OLD token. Check
///         `currentRound()` and the round's tallies before running this on a chain where voting has seen
///         real use; a fresh proxy is the clean-slate option.
///
/// @dev    This is the counterpart to `DeployRealmVoting`, which is deploy-once and refuses while
///         `VOTING` is set: first-time wiring goes there, every later change comes here.
///
/// @dev    Run: just upgrade-voting-<sepolia|rh|rh-testnet>
///         Dry-run first: the same `forge script` without --broadcast, plus --sender <realm.dev address>
///         so the owner check passes in simulation.
contract UpgradeRealmVoting is Script {
    function run() external {
        address proxy = ChainConfig.voting();
        address realm = ChainConfig.realmToken();
        require(proxy != address(0), "manifest: VOTING missing (run DeployRealmVoting first)");
        require(realm != address(0), "manifest: REALM_TOKEN missing");
        require(realm.code.length != 0, "REALM_TOKEN has no code");
        // A master without burnFrom would make every vote revert; probe before spending gas.
        (bool ok,) = realm.staticcall(abi.encodeWithSignature("totalSupply()"));
        require(ok, "REALM_TOKEN is not an ERC20");

        address oldImpl = address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
        RealmVoting voting = RealmVoting(payable(proxy));
        address owner = voting.owner();
        address oldRealm = address(voting.REALM());

        console.log("=== Upgrade RealmVoting ===");
        console.log("Chain ID:      ", block.chainid);
        console.log("Deployer:      ", msg.sender);
        console.log("Proxy:         ", proxy);
        console.log("Old impl:      ", oldImpl);
        console.log("Old REALM:     ", oldRealm);
        console.log("New REALM:     ", realm);
        (uint256 round,,) = voting.currentRound();
        console.log("Current round: ", round);
        console.log("");

        vm.startBroadcast();
        address newImpl = address(new RealmVoting(realm));
        UUPSUpgradeable(proxy).upgradeToAndCall(newImpl, "");
        vm.stopBroadcast();

        require(address(voting.REALM()) == realm, "post-upgrade: REALM mismatch");
        require(voting.owner() == owner, "post-upgrade: owner moved");

        console.log("=== Upgraded. Paste into src/config/manifest.%s.sol ===", ChainConfig.name());
        console.log("  VOTING_IMPL =", newImpl);
        console.log("");
        console.log("Then: just export-deployments");
    }
}
