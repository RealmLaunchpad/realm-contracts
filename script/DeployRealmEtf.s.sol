// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "lib/v4-periphery/src/utils/HookMiner.sol";

import {RealmEtfAssets} from "src/etf/RealmEtfAssets.sol";
import {RealmEtfFactory} from "src/etf/RealmEtfFactory.sol";
import {RealmEtfHook} from "src/etf/RealmEtfHook.sol";
import {RealmAssetsWhitelist} from "src/access/RealmAssetsWhitelist.sol";
import {ChainConfig} from "script/ChainConfig.sol";

/// @dev Mines a salt for `RealmEtfHook` (its permission bits live in its address), deploys it for `factory`
///      and sets it there. Call inside a broadcast whose sender owns `factory`.
abstract contract EtfHookDeployer is Script {
    /// @dev Deterministic CREATE2 proxy forge routes `new X{salt:..}` through; HookMiner must mine against it.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint160 internal constant HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;

    function _deployHook(RealmEtfFactory factory) internal returns (address hook) {
        IPoolManager manager = IPoolManager(ChainConfig.infra().univ4PoolManager);
        (address mined, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, HOOK_FLAGS, type(RealmEtfHook).creationCode, abi.encode(manager, factory));
        hook = address(new RealmEtfHook{salt: salt}(manager, factory));
        require(hook == mined, "hook address mismatch");
        factory.setHook(hook);
    }

    /// @dev Makes `factory` an approver of its `ASSETS_WHITELIST`, which `createEtf` needs to list each new
    ///      ETF. Call inside a broadcast whose sender owns the whitelist; reverts otherwise.
    function _approveFactory(RealmEtfFactory factory, address sender) internal {
        RealmAssetsWhitelist whitelist = factory.ASSETS_WHITELIST();
        if (whitelist.isApprover(address(factory))) return;
        require(
            sender == whitelist.owner(),
            "ETF_FACTORY is no ASSETS_WHITELIST approver: its owner must setApprover(ETF_FACTORY, true) first"
        );
        whitelist.setApprover(address(factory), true);
    }
}

/// @title Deploy the ETF stack
/// @notice `RealmEtfAssets` and `RealmEtfFactory` (each impl + UUPS proxy) and `RealmEtfHook`, with the factory pointed
///         at the hook and made an `ASSETS_WHITELIST` approver (the broadcaster must own the whitelist). The
///         broadcaster owns the registry and the factory and is NOT a registry approver: appoint one
///         (`setApprover`) before listing assets, then hand both contracts to the multisig.
/// @dev    Run: just deploy-etf-<rh|rh-testnet>. Dry-run: the same `forge script` without --broadcast.
contract DeployRealmEtf is EtfHookDeployer {
    function run() external {
        address poolManager = ChainConfig.infra().univ4PoolManager;
        (address univ2Factory, address univ3Factory) = ChainConfig.univ2And3Factories();

        vm.startBroadcast();
        // Inside the broadcast: only there does `readCallers` report the real `--account` broadcaster.
        (, address owner,) = vm.readCallers();
        address registryImpl = address(new RealmEtfAssets(poolManager, univ3Factory, univ2Factory, ChainConfig.usdg()));
        RealmEtfAssets registry =
            RealmEtfAssets(address(new ERC1967Proxy(registryImpl, abi.encodeCall(RealmEtfAssets.initialize, (owner)))));
        address impl = address(new RealmEtfFactory(registry, RealmAssetsWhitelist(ChainConfig.assetsWhitelist())));
        RealmEtfFactory factory =
            RealmEtfFactory(address(new ERC1967Proxy(impl, abi.encodeCall(RealmEtfFactory.initialize, (owner)))));
        address hook = _deployHook(factory);
        _approveFactory(factory, owner);
        vm.stopBroadcast();

        console.log("=== Deployed. Paste into src/config/manifest.%s.sol ===", ChainConfig.name());
        console.log("  ETF_ASSETS =", address(registry));
        console.log("  ETF_ASSETS_IMPL =", registryImpl);
        console.log("  ETF_FACTORY =", address(factory));
        console.log("  ETF_FACTORY_IMPL =", impl);
        console.log("  ETF_HOOK =", hook);
        console.log("Then: just export-deployments");
    }
}

/// @title Redeploy the ETF hook
/// @notice Deploys a new `RealmEtfHook` for the manifest's `ETF_FACTORY` and sets it there. The hook is not
///         upgradeable: ETFs created before keep trading on their old hook, only new ones get this one.
/// @dev    Run: just deploy-etf-hook-<rh|rh-testnet>. The broadcaster must own the factory.
contract DeployRealmEtfHook is EtfHookDeployer {
    function run() external {
        RealmEtfFactory factory = RealmEtfFactory(ChainConfig.etfFactory());

        vm.startBroadcast();
        address hook = _deployHook(factory);
        vm.stopBroadcast();

        console.log("=== Deployed. Paste into src/config/manifest.%s.sol ===", ChainConfig.name());
        console.log("  ETF_HOOK =", hook);
        console.log("Then: just export-deployments");
    }
}

/// @title Upgrade the ETF factory
/// @notice Deploys a new `RealmEtfFactory` implementation, on the live proxy's registry and the manifest's
///         `ASSETS_WHITELIST`, makes the factory a whitelist approver if it is not one yet, and upgrades
///         `ETF_FACTORY` to it. Ships new `RealmEtf` code to ETFs created afterwards; existing ETFs, the hook
///         and its pools are untouched.
/// @dev    Run: just upgrade-etf-factory-<rh|rh-testnet>. The broadcaster must own the factory, and the
///         whitelist unless the factory is already its approver.
contract UpgradeRealmEtfFactory is EtfHookDeployer {
    function run() external {
        RealmEtfFactory factory = RealmEtfFactory(ChainConfig.etfFactory());
        RealmEtfAssets registry = factory.REGISTRY();
        RealmAssetsWhitelist whitelist = RealmAssetsWhitelist(ChainConfig.assetsWhitelist());
        address hook = factory.hook();

        vm.startBroadcast();
        (, address sender,) = vm.readCallers();
        address impl = address(new RealmEtfFactory(registry, whitelist));
        UUPSUpgradeable(address(factory)).upgradeToAndCall(impl, "");
        // Same broadcast: from the upgrade on, `createEtf` reverts while the factory is no approver.
        _approveFactory(factory, sender);
        vm.stopBroadcast();

        require(
            factory.REGISTRY() == registry && factory.hook() == hook && factory.ASSETS_WHITELIST() == whitelist,
            "post-upgrade: wiring moved"
        );
        console.log("=== Upgraded. Paste into src/config/manifest.%s.sol ===", ChainConfig.name());
        console.log("  ETF_FACTORY_IMPL =", impl);
        console.log("Then: just export-deployments");
    }
}

/// @title Upgrade the ETF asset registry
/// @notice Deploys a new `RealmEtfAssets` implementation, on the live proxy's pool manager, factories and USDG,
///         and upgrades `ETF_ASSETS` to it. Reaches every ETF at once: routes, listings and approvers stay.
/// @dev    Run: just upgrade-etf-assets-<rh|rh-testnet>. The broadcaster must own the registry.
contract UpgradeRealmEtfAssets is Script {
    function run() external {
        RealmEtfAssets registry = RealmEtfAssets(ChainConfig.etfAssets());
        IPoolManager poolManager = registry.POOL_MANAGER();
        address usdg = registry.USDG();

        vm.startBroadcast();
        address impl =
            address(new RealmEtfAssets(address(poolManager), registry.UNIV3_FACTORY(), registry.UNIV2_FACTORY(), usdg));
        UUPSUpgradeable(address(registry)).upgradeToAndCall(impl, "");
        vm.stopBroadcast();

        // ETFs copied both at creation.
        require(registry.POOL_MANAGER() == poolManager && registry.USDG() == usdg, "post-upgrade: wiring moved");
        console.log("=== Upgraded. Paste into src/config/manifest.%s.sol ===", ChainConfig.name());
        console.log("  ETF_ASSETS_IMPL =", impl);
        console.log("Then: just export-deployments");
    }
}
