// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {RealmAssetsWhitelist} from "src/access/RealmAssetsWhitelist.sol";
import {RealmKeepersRegistry} from "src/access/RealmKeepersRegistry.sol";
import {RealmDividendSwapRegistry} from "src/dividends/RealmDividendSwapRegistry.sol";
import {ChainConfig} from "script/ChainConfig.sol";
import {BuildTarget} from "script/BuildTarget.sol";
import {DeploymentAddresses as KeeperGateBuild} from "src/tokens/KeeperGated.sol";
import {DeploymentAddresses as DividendBuild} from "src/tokens/DividendDistribution.sol";

/// @title Post-deploy wiring for the registries
/// @notice Every registry ships empty: the deploy scripts only set an owner. This appoints the admin
///         that holds every operational lever and the keeper that triggers `process*`:
///           1. `RealmKeepersRegistry.setAdmin(admin, true)`        — owner-only
///           2. `RealmKeepersRegistry.setKeeper(keeper, true)`      — admin-only, hence after (1)
///           3. `RealmDividendSwapRegistry.setAdmin(admin, true)`   — owner-only
///           4. `RealmDividendSwapRegistry.setKeeperFunding(keeper)` — admin-only, hence after (3)
///           5. `RealmAssetsWhitelist.setApprover(admin, true)`     — owner-only
///
/// @dev (5) is the same appointment in the direct venue's registry: its owner cannot list a quote asset,
///      only an approver can, so until this runs `WhitelistRobinhoodAssets` has nobody to broadcast as.
///      Skipped, not fatal, on a chain whose manifest has no `ASSETS_WHITELIST` yet.
///
/// @dev Idempotent: each call is skipped if the state is already what it should be, so this is also the
///      way to re-run after rotating the keeper (`REALM_KEEPER` in the manifest) with no bespoke steps.
///
/// @dev `admin` defaults to the broadcasting account — the registries' owner, which is who runs this —
///      and `REALMDEVADDRESS` overrides it. The registry addresses come from the RETARGETED BUILD rather
///      than a manifest read, so a tree pointed at the wrong chain fails on `assertBuiltFor` instead of
///      configuring the wrong registries. The quote-token allowlist needs no call: `initialize` allows
///      the chain's canonical quote token.
///
///      Run: just configure-registries-<chain>
contract ConfigureRegistries is Script {
    function run() external {
        BuildTarget.assertBuiltFor(block.chainid);

        RealmKeepersRegistry keepers = RealmKeepersRegistry(KeeperGateBuild.REALM_KEEPERS_REGISTRY);
        RealmDividendSwapRegistry dividends = RealmDividendSwapRegistry(payable(DividendBuild.DIVIDEND_SWAP_REGISTRY));
        address keeper = ChainConfig.realmKeeper();

        vm.startBroadcast();
        // `msg.sender` is forge's DEFAULT_SENDER unless `--sender` is passed; `readCallers` reports the
        // real `--account` broadcaster, and only inside an active broadcast.
        (, address broadcaster,) = vm.readCallers();
        address admin = vm.envOr("REALMDEVADDRESS", broadcaster);

        console.log("=== Configure registries ===");
        console.log("Chain ID:    ", block.chainid);
        console.log("Broadcaster: ", broadcaster);
        console.log("Admin:       ", admin);
        console.log("Keeper:      ", keeper);
        console.log("");

        // Steps 2 and 4 are admin-gated, so the broadcaster must itself be an admin. It is when it IS the
        // admin; otherwise it has to have been appointed already. A mismatch is nearly always a stale
        // `REALMDEVADDRESS` left over from a previous deployer key — refuse rather than guess which of two
        // conflicting addresses should hold every operational lever, and refuse before sending anything.
        require(
            admin == broadcaster || (keepers.isAdmin(broadcaster) && dividends.isAdmin(broadcaster)),
            "REALMDEVADDRESS names an address that is neither the broadcaster nor an existing admin (see the two logged above)"
        );

        // (5) is owner-gated, not admin-gated: only the whitelist's own owner can appoint an approver.
        // Checked up front so a chain where that is a different key fails before the four sends above.
        RealmAssetsWhitelist assets = RealmAssetsWhitelist(ChainConfig.assetsWhitelistOrZero());
        require(
            address(assets) == address(0) || assets.isApprover(admin) || assets.owner() == broadcaster,
            "broadcaster does not own ASSETS_WHITELIST: its owner has to appoint the approver"
        );

        _log("keepers.setAdmin", admin, keepers.isAdmin(admin));
        if (!keepers.isAdmin(admin)) keepers.setAdmin(admin, true);

        _log("keepers.setKeeper", keeper, keepers.isKeeper(keeper));
        if (!keepers.isKeeper(keeper)) keepers.setKeeper(keeper, true);

        _log("dividends.setAdmin", admin, dividends.isAdmin(admin));
        if (!dividends.isAdmin(admin)) dividends.setAdmin(admin, true);

        _log("dividends.setKeeperFunding", keeper, dividends.keeper() == keeper);
        if (dividends.keeper() != keeper) dividends.setKeeperFunding(keeper);

        if (address(assets) == address(0)) {
            console.log("  [skip]  assets.setApprover: no ASSETS_WHITELIST in this chain's manifest");
        } else {
            _log("assets.setApprover", admin, assets.isApprover(admin));
            if (!assets.isApprover(admin)) assets.setApprover(admin, true);
        }

        vm.stopBroadcast();
    }

    function _log(string memory what, address who, bool alreadySet) internal pure {
        console.log(alreadySet ? "  [skip] " : "  [send] ", what, who);
    }
}
