// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Utils} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol";

import {RealmDirectGraduatorUniV4} from "src/graduators/RealmDirectGraduatorUniV4.sol";
import {RealmFactoryUniV4Direct} from "src/factories/RealmFactoryUniV4Direct.sol";
import {RealmFactoryAbstract} from "src/factories/RealmFactoryAbstract.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {ChainConfig} from "script/ChainConfig.sol";

/// @title Repoint the live direct-launch venue at the current manifest
/// @notice Deploys a fresh `RealmDirectGraduatorUniV4` and a fresh `RealmFactoryUniV4Direct`
///         implementation from the current build, and points the manifest's `FACTORY_UNIV4_DIRECT`
///         proxy at the new implementation. The graduator holds both swap hooks and the liquidity adder
///         as immutables, and the factory holds the graduator as one, so redeploying `RealmHookAnyPair`
///         leaves the live venue seeding pools against a dead hook until this runs.
///
/// @dev    REUSES THE LIVE `ASSETS_WHITELIST`, unlike `DeployDirectVenue`, which mints a new one. That is
///         the whole reason this script exists: a fresh whitelist starts empty, so every quote the venue
///         accepts would have to be re-listed, and the whitelist address is one an indexer subscribes to
///         statically. Same for the factory proxy, which never moves here.
///
/// @dev    `RealmHook` — the native-quoted hook Uniswap whitelisted — is read from the manifest and
///         never redeployed; native pools are unaffected by any of this.
///
/// @dev    ALREADY-LAUNCHED TOKENS STAY ON THE OLD VENUE. A pool's `PoolKey` bakes its hook address, so
///         tokens seeded by the previous graduator keep trading against the previous hook, which keeps
///         working. They are orphaned from the new factory, not broken; settle their pending hook fees
///         on the OLD hook before it stops being watched.
///
/// @dev    This is the counterpart to `DeployDirectVenue`, which is first-time wiring and deploys the
///         proxy and the whitelist; every later change comes here.
///
/// @dev    Run: just upgrade-direct-venue-<rh|rh-testnet>
///         Dry-run first: the same `forge script` without --broadcast, plus --sender <realm.dev address>
///         so the owner check passes in simulation.
contract UpgradeDirectVenue is Script {
    function run() external {
        ChainConfig.Manifest memory m = ChainConfig.manifest();
        ChainConfig.Infra memory infra = ChainConfig.infra();
        address proxy = ChainConfig.directFactory();
        address hook = ChainConfig.swapHook();
        address anyPairHook = ChainConfig.swapHookAnyPair();
        address whitelist = ChainConfig.assetsWhitelist();
        address wrappedNative = ChainConfig.wrappedNative();
        address creatorVaultFactory = ChainConfig.creatorVaultFactory();

        require(proxy != address(0), "manifest: FACTORY_UNIV4_DIRECT missing (run DeployDirectVenue first)");
        require(m.liquidityAdder != address(0), "manifest: UNIV4_LIQUIDITY_ADDER missing");
        require(m.masterFeeHandler != address(0), "manifest: MASTER_FEE_HANDLER missing");
        require(m.tokenImpl != address(0), "manifest: TOKEN_IMPL missing");
        require(m.taxTokenV4Impl != address(0), "manifest: TAXABLE_TOKEN_V4_IMPL missing");
        address oldImpl = address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));

        console.log("=== Upgrade the direct-launch venue ===");
        console.log("Chain ID:           ", block.chainid);
        console.log("Deployer:           ", msg.sender);
        console.log("Factory proxy:      ", proxy);
        console.log("Old factory impl:   ", oldImpl);
        console.log("SWAP_HOOK:          ", hook);
        console.log("SWAP_HOOK_ANY_PAIR: ", anyPairHook);
        console.log("ASSETS_WHITELIST:   ", whitelist, "(reused, not redeployed)");
        console.log("LIQUIDITY_ADDER:    ", m.liquidityAdder);
        console.log("");

        vm.startBroadcast();
        // The factory takes the graduator as a constructor immutable, so the graduator comes first.
        RealmDirectGraduatorUniV4 graduator =
            new RealmDirectGraduatorUniV4(infra.univ4PoolManager, hook, anyPairHook, m.liquidityAdder);
        address newImpl = address(
            new RealmFactoryUniV4Direct(
                IRealmFactory.TokenImpls({base: m.tokenImpl, tax: m.taxTokenV4Impl}),
                address(graduator),
                m.masterFeeHandler,
                creatorVaultFactory,
                wrappedNative,
                whitelist
            )
        );
        UUPSUpgradeable(proxy).upgradeToAndCall(newImpl, abi.encodeCall(RealmFactoryAbstract.announceGraduator, ()));
        vm.stopBroadcast();

        RealmFactoryUniV4Direct factory = RealmFactoryUniV4Direct(payable(proxy));
        require(address(factory.GRADUATOR()) == address(graduator), "post-upgrade: graduator mismatch");
        require(address(factory.ASSETS_WHITELIST()) == whitelist, "post-upgrade: whitelist moved");
        require(graduator.ANY_PAIR_HOOK() == anyPairHook, "post-upgrade: any-pair hook mismatch");
        require(graduator.HOOK_ADDRESS() == hook, "post-upgrade: native hook mismatch");

        console.log("=== Upgraded. Paste into src/config/manifest.%s.sol ===", ChainConfig.name());
        console.log("  GRADUATOR_UNIV4_DIRECT    =", address(graduator));
        console.log("  FACTORY_UNIV4_DIRECT_IMPL =", newImpl);
        console.log("");
        console.log("Then: just export-deployments");
    }
}
