// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {RealmVoting} from "src/voting/RealmVoting.sol";
import {ChainConfig} from "script/ChainConfig.sol";

/// @title Deploy `RealmVoting` for the chain's REALM token
/// @notice Deploys the impl + UUPS proxy; round 1 opens in the deploy block. Round length defaults to
///         3 days (`VOTING_ROUND_DURATION`, seconds, overrides). Where the chain names a buyback wallet it
///         is appointed admin; the owner (broadcaster) can always act as one. The token must be a clone
///         of a `RealmToken` master that has `burnFrom` — a master that predates it needs
///         `RedeployTokenImpls` first, and a new REALM token after that.
///
/// @dev    Deploy-once: refuses while the manifest already has `VOTING`. `RealmTreasuryRouter` bakes the
///         proxy in, and inherits this script to deploy it in its own broadcast when `VOTING` is still
///         zero — so running this standalone is only for the case where the two are deployed apart (a
///         launchpad already owned by the multisig, say, which the router leg needs and this one does not).
///
/// @dev    Run: just deploy-voting-<rh|rh-testnet>
///         Dry-run first: the same `forge script` without --broadcast, plus --sender <realm.dev address>.
contract DeployRealmVoting is Script {
    function run() external virtual {
        require(ChainConfig.voting() == address(0), "manifest: VOTING already set");

        vm.startBroadcast();
        (address voting, address impl) = _deployVoting();
        vm.stopBroadcast();

        _reportVoting(voting, impl);
        console.log("");
        console.log("Then: just export-deployments, and just deploy-treasury-router-<chain>");
    }

    /// @dev The REALM token, from the manifest like every other Realm-owned address. `REALM_TOKEN`
    ///      overrides it for a bring-up where the token was just launched and the paste has not happened
    ///      yet — the same escape hatch `ROUTER_ADDRESS` gives `DeployRealmHook`.
    function _realmToken() internal view returns (address realm) {
        realm = vm.envOr("REALM_TOKEN", ChainConfig.realmToken());
        require(realm != address(0), "manifest: REALM_TOKEN missing (or pass REALM_TOKEN=<address>)");
        require(realm.code.length != 0, "REALM_TOKEN has no code");
        // A master without burnFrom would make every vote revert; probe the selector before spending gas.
        (bool ok,) = realm.staticcall(abi.encodeWithSignature("totalSupply()"));
        require(ok, "REALM_TOKEN is not an ERC20");
    }

    /// @dev Impl + UUPS proxy + the admin appointment, with every post-condition asserted. Must run
    ///      inside an active broadcast: `DeployRealmTreasuryRouter` calls it from within its own, so the
    ///      voting proxy it bakes in as an immutable needs no paste-and-rebuild round trip first.
    function _deployVoting() internal returns (address proxy, address impl) {
        address realm = _realmToken();
        uint256 duration = vm.envOr("VOTING_ROUND_DURATION", uint256(3 days));
        address admin = ChainConfig.voteBuybackWallet();
        // `msg.sender` is forge's DEFAULT_SENDER unless `--sender` is passed; `readCallers` reports the
        // real `--account` broadcaster, and only inside an active broadcast.
        (, address broadcaster,) = vm.readCallers();

        console.log("=== Deploy RealmVoting ===");
        console.log("Chain ID:       ", block.chainid);
        console.log("Deployer/owner: ", broadcaster);
        console.log("REALM token:    ", realm);
        console.log("Round duration: ", duration);
        console.log("Admin:          ", admin);
        console.log("");

        impl = address(new RealmVoting(realm));
        RealmVoting voting =
            RealmVoting(payable(address(new ERC1967Proxy(impl, abi.encodeCall(RealmVoting.initialize, (duration))))));
        if (admin != address(0)) voting.setAdmin(admin, true);

        require(address(voting.REALM()) == realm, "post: REALM mismatch");
        require(voting.owner() == broadcaster, "post: owner mismatch");
        require(voting.roundDuration() == duration, "post: duration mismatch");
        (uint256 id,,) = voting.currentRound();
        require(id == 1, "post: round 1 not open");

        proxy = address(voting);
    }

    function _reportVoting(address voting, address impl) internal view {
        console.log("=== Paste into src/config/manifest.%s.sol ===", ChainConfig.name());
        console.log("  VOTING      =", voting);
        console.log("  VOTING_IMPL =", impl);
    }
}
