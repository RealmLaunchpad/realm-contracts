// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {RealmFactoryUniV2Unified} from "src/factories/RealmFactoryUniV2Unified.sol";
import {RealmFactoryUniV4Unified} from "src/factories/RealmFactoryUniV4Unified.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import {DeploymentsEthereumMainnet} from "src/config/manifest.ethereum.mainnet.sol";
import {DeploymentsEthereumSepolia} from "src/config/manifest.ethereum.sepolia.sol";

/// @title Flip the unified factory proxies onto their pre-deployed v2 implementations — the launchpad v1->v2 cutover
/// @notice Phase 2 of the launchpad-v2 rollout, and the SINGLE atomic switch of token creation from
///         v1 to v2. Deploys NOTHING: it reads the already-deployed `FACTORY_UNIV2_UNIFIED_IMPL` /
///         `FACTORY_UNIV4_UNIFIED_IMPL` from the per-chain manifest (`src/config/manifest.{mainnet,
///         sepolia}.sol`) — produced by `DeployLaunchpadV2Stack` — and calls
///         `upgradeToAndCall(impl, "")` on each existing factory proxy.
///
///         Until this runs, the factory proxies keep registering tokens on the OLD launchpad. The
///         instant both `upgradeToAndCall`s land, every new token flows to the v2 launchpad. There
///         is no intermediate state and no fresh implementation deployed here, so the run is small,
///         fast, and trivially reviewable — by design.
///
///         The proxy addresses (and therefore the launchpad's `whitelistedFactories` mapping) do
///         NOT change. No init data is passed — there are no new storage variables to populate.
///
///         The broadcaster MUST be the proxy owner (the EOA that ran the original proxy deploy,
///         since `initialize()` set the owner to `msg.sender` of the proxy-deployment tx). If the
///         broadcaster isn't the owner, `_authorizeUpgrade` reverts with
///         `OwnableUnauthorizedAccount(broadcaster)` — no state changes.
///
///         Pre-flight, this asserts each target impl's immutable `LAUNCHPAD()` already points at the
///         manifest launchpad, so a stale impl (e.g. one wired to the old launchpad) aborts the run
///         before any proxy is touched. Post-broadcast it re-reads each proxy to confirm the flip
///         took effect against the simulated end state.
///
///         Storage layout safety: the new implementations must keep `RealmFactoryAbstract`'s storage
///         layout. Today that's "empty + 50-slot gap", so any change that adds storage must shrink
///         the gap and never reorder. Review the diff before broadcasting.
///
/// @dev    Run with (no `--verify`: this script deploys nothing):
///         forge script UpgradeUnifiedFactories --rpc-url <mainnet|sepolia> --account livo.dev --slow --broadcast
contract UpgradeUnifiedFactories is Script {
    /// @dev Addresses sourced from the per-chain manifest. `factoryV2Proxy` / `factoryV4Proxy` are
    ///      the existing UUPS proxies; `factoryV2Impl` / `factoryV4Impl` are the pre-deployed v2
    ///      implementations to flip onto; `launchpad` is the v2 launchpad the impls must already be
    ///      wired to (pre-flight guard).
    struct Deps {
        address factoryV2Proxy;
        address factoryV4Proxy;
        address factoryV2Impl;
        address factoryV4Impl;
        address launchpad;
    }

    function _getDeps() internal view returns (Deps memory d) {
        if (block.chainid == DeploymentsEthereumMainnet.BLOCKCHAIN_ID) {
            d = Deps({
                factoryV2Proxy: DeploymentsEthereumMainnet.FACTORY_UNIV2_UNIFIED,
                factoryV4Proxy: DeploymentsEthereumMainnet.FACTORY_UNIV4_UNIFIED,
                factoryV2Impl: DeploymentsEthereumMainnet.FACTORY_UNIV2_UNIFIED_IMPL,
                factoryV4Impl: DeploymentsEthereumMainnet.FACTORY_UNIV4_UNIFIED_IMPL,
                launchpad: DeploymentsEthereumMainnet.LAUNCHPAD
            });
        } else if (block.chainid == DeploymentsEthereumSepolia.BLOCKCHAIN_ID) {
            d = Deps({
                factoryV2Proxy: DeploymentsEthereumSepolia.FACTORY_UNIV2_UNIFIED,
                factoryV4Proxy: DeploymentsEthereumSepolia.FACTORY_UNIV4_UNIFIED,
                factoryV2Impl: DeploymentsEthereumSepolia.FACTORY_UNIV2_UNIFIED_IMPL,
                factoryV4Impl: DeploymentsEthereumSepolia.FACTORY_UNIV4_UNIFIED_IMPL,
                launchpad: DeploymentsEthereumSepolia.LAUNCHPAD
            });
        } else {
            revert("Unsupported chain");
        }

        // Belt-and-braces: catch a stale or zero address in the manifest before broadcasting.
        require(d.factoryV2Proxy != address(0), "manifest: FACTORY_UNIV2_UNIFIED missing");
        require(d.factoryV4Proxy != address(0), "manifest: FACTORY_UNIV4_UNIFIED missing");
        require(d.factoryV2Impl != address(0), "manifest: FACTORY_UNIV2_UNIFIED_IMPL missing");
        require(d.factoryV4Impl != address(0), "manifest: FACTORY_UNIV4_UNIFIED_IMPL missing");
        require(d.launchpad != address(0), "manifest: LAUNCHPAD missing");
    }

    function run() public {
        Deps memory d = _getDeps();

        // Sanity: confirm proxies are responsive and initialized. `owner()` reverts on uninitialized
        // proxies (returns 0 from storage), so an explicit nonzero check catches a wrong manifest
        // address pointing at a non-Realm contract.
        address ownerV2 = RealmFactoryUniV2Unified(d.factoryV2Proxy).owner();
        address ownerV4 = RealmFactoryUniV4Unified(d.factoryV4Proxy).owner();
        require(ownerV2 != address(0), "V2 proxy not initialized");
        require(ownerV4 != address(0), "V4 proxy not initialized");
        require(ownerV2 == ownerV4, "V2/V4 proxies have diverged owners - verify the manifest");

        // Pre-flight: the target impls (read straight from their bytecode immutables, no proxy
        // involved) must already be wired to the v2 launchpad. A stale impl pointing elsewhere aborts
        // the run before any proxy is flipped — this is the v1->v2 switch, so wrong wiring is fatal.
        require(
            address(RealmFactoryUniV2Unified(d.factoryV2Impl).LAUNCHPAD()) == d.launchpad,
            "V2 impl not wired to manifest launchpad"
        );
        require(
            address(RealmFactoryUniV4Unified(d.factoryV4Impl).LAUNCHPAD()) == d.launchpad,
            "V4 impl not wired to manifest launchpad"
        );

        console.log("=== Realm Unified Factories Flip (v1 -> v2 cutover) ===");
        console.log("Chain ID:                ", block.chainid);
        console.log("Broadcaster:             ", msg.sender);
        console.log("Required owner (V2/V4):  ", ownerV2);
        console.log("V2 proxy:                ", d.factoryV2Proxy);
        console.log("V4 proxy:                ", d.factoryV4Proxy);
        console.log("V2 impl (target):        ", d.factoryV2Impl);
        console.log("V4 impl (target):        ", d.factoryV4Impl);
        console.log("v2 launchpad:            ", d.launchpad);
        console.log("");

        vm.startBroadcast();

        UUPSUpgradeable(d.factoryV2Proxy).upgradeToAndCall(d.factoryV2Impl, "");
        console.log("| V2 proxy flipped to |", d.factoryV2Impl);

        UUPSUpgradeable(d.factoryV4Proxy).upgradeToAndCall(d.factoryV4Impl, "");
        console.log("| V4 proxy flipped to |", d.factoryV4Impl);

        vm.stopBroadcast();

        // Post-broadcast: both proxies now delegate to the v2 impls, so they report the v2 launchpad.
        require(address(RealmFactoryUniV2Unified(d.factoryV2Proxy).LAUNCHPAD()) == d.launchpad, "V2 flip failed");
        require(address(RealmFactoryUniV4Unified(d.factoryV4Proxy).LAUNCHPAD()) == d.launchpad, "V4 flip failed");

        console.log("");
        console.log("=== Cutover Complete: token creation now flows to the v2 launchpad ===");
        console.log("Proxy addresses are UNCHANGED - no launchpad whitelisting or integrator action needed.");
    }
}
