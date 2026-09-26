// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {RealmKeeperLens} from "src/RealmKeeperLens.sol";

/// @title Deploy `RealmKeeperLens`
/// @notice One broadcast, one contract, no arguments: the stateless read lens the dividend keeper
///         batches its per-token reads through.
///
/// @dev Deliberately has no "already deployed" guard, unlike the deploy-once scripts beside it. The
///      lens holds nothing, owns nothing and is referenced by nothing on chain — redeploying it and
///      repointing the keeper IS its upgrade path, so refusing to run would only be in the way.
///
/// @dev Chain-agnostic bytecode: the lens bakes no `DeploymentAddresses` constant, so unlike the token
///      implementations it does not need `just chain-*` run first and its artifact verifies identically
///      on every chain. The recipes retarget anyway, because the rest of the tree is built alongside it.
///
/// @dev Run: just deploy-keeper-lens-<rh|rh-testnet>
///      Dry-run first: the same `forge script` without --broadcast, plus --sender <realm.dev address>.
contract DeployRealmKeeperLens is Script {
    function run() external {
        console.log("=== Deploy RealmKeeperLens ===");
        console.log("Chain ID:        ", block.chainid);

        vm.startBroadcast();
        (, address broadcaster,) = vm.readCallers();
        console.log("Deployer:        ", broadcaster);
        RealmKeeperLens lens = new RealmKeeperLens();
        vm.stopBroadcast();

        // Cheapest possible proof the deployed bytecode answers: a batch of one address that is not a
        // token must come back as a zeroed row rather than reverting, which is the whole contract.
        address[] memory probe = new address[](1);
        probe[0] = broadcaster;
        require(!lens.keeperState(probe)[0].isDividendToken, "post: lens misread a non-token");
        require(lens.MAX_DIVIDEND_ASSETS() == 3, "post: asset cap drifted");

        console.log("");
        // Chain id rather than `ChainConfig.name()`: the lens is the one deploy that is chain-agnostic,
        // and a dry-run on the default local chain should not fail on a log line.
        console.log("=== Done. Paste KEEPER_LENS into this chain's src/config/manifest.*.sol ===");
        console.log("  KEEPER_LENS          =", address(lens));
        console.log("");
        console.log("Then `just export-deployments`, and set the keeper's `keeperLens` to this address");
        console.log("(indexer repo: the dividend-keeper secret, per infra/docs/dividend-keeper.md).");
    }
}
