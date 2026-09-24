// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "lib/forge-std/src/Script.sol";
import {console} from "lib/forge-std/src/console.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "lib/v4-periphery/src/utils/HookMiner.sol";
import {RealmHook} from "src/hooks/RealmHook.sol";
import {RealmHookAnyPair} from "src/hooks/RealmHookAnyPair.sol";
import {
    DeploymentAddressesRobinhoodMainnet,
    DeploymentAddressesRobinhoodTestnet
} from "src/config/DeploymentAddresses.sol";
import {DeploymentsRobinhoodMainnet} from "src/config/manifest.robinhood.mainnet.sol";
import {DeploymentsRobinhoodTestnet} from "src/config/manifest.robinhood.testnet.sol";

/// @title Hook deployment via CREATE2 + salt mining
/// @notice Deployment machinery for Realm's V4 swap hook. A Uniswap V4 hook advertises its callbacks in
///         the low 14 bits of its own address, so the address cannot be chosen freely: the deployer must
///         brute-force a CREATE2 salt whose resulting address carries exactly the permission bits the
///         hook's `getHookPermissions()` declares. `HookMiner.find` does that search, and the PoolManager
///         rejects the hook at pool initialization if the bits are wrong — hence the post-deploy asserts.
///
/// @dev `RealmHook` declares BEFORE_SWAP, AFTER_SWAP, BEFORE_SWAP_RETURNS_DELTA and
///      AFTER_SWAP_RETURNS_DELTA → mask `0xCC`. The base is abstract over the creation code and the
///      `new` call so a future hook variant only has to supply those two.
///
/// @dev Runs against Robinhood mainnet (4663) or Robinhood testnet (46630). Pool manager and treasury come from
///      `DeploymentAddresses*`; the LP fee router proxy comes from `Deployments*` and must already exist —
///      run `DeployRealmPrereqs` first.
///
/// @dev `ROUTER_ADDRESS` (optional) overrides the manifest's `LP_FEE_ROUTER`, so a bring-up that just
///      deployed the router does not need a paste-and-rebuild round trip between the two steps.
abstract contract DeployHookBase is Script {
    /// @notice Deterministic CREATE2 proxy used by `forge script` for `new X{salt:..}(..)` syntax.
    /// @dev Same address on every EVM chain. This is what HookMiner must use as the deployer, or the
    ///      mined address will not match what the broadcast actually produces.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice Human-readable name of the hook this script deploys, for the console output.
    function hookName() internal pure virtual returns (string memory);

    /// @notice Creation code of the hook to mine a salt for. Must match what `_deploy` builds, or the
    ///         mined address will not carry the permission bits.
    function creationCode() internal pure virtual returns (bytes memory);

    /// @notice Deploys the hook with the mined `salt`. Separate from `creationCode()` because
    ///         `new X{salt:..}` needs the concrete type, which an abstract base cannot name.
    function _deploy(bytes32 salt, address poolManager, address router, address treasury)
        internal
        virtual
        returns (address);

    function run() external {
        (address poolManager, address router, address treasury) = _resolveAddresses();
        require(router != address(0), "LP_FEE_ROUTER not set; run DeployRealmPrereqs first");
        require(treasury != address(0), "REALM_TREASURY not set");

        console.log("=== Deploy %s ===", hookName());
        console.log("Chain ID:    %d", block.chainid);
        console.log("PoolManager: %s", poolManager);
        console.log("LpFeeRouter: %s", router);
        console.log("Treasury:    %s", treasury);

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(IPoolManager(poolManager), router, treasury);

        console.log("Mining hook salt (this may take 30-60s)...");
        (address minedAddress, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, flags, creationCode(), constructorArgs);
        console.log("Mined address: %s", minedAddress);
        console.log("Salt:          %x", uint256(salt));

        vm.startBroadcast();
        address hook = _deploy(salt, poolManager, router, treasury);
        vm.stopBroadcast();

        // If either check fails the hook is unusable: the PoolManager re-validates the permission bits
        // on every pool initialization and would reject it.
        require(hook == minedAddress, "Deployed address mismatch");
        require((uint160(hook) & uint160(0x3FFF)) == flags, "Hook flags mismatch");

        console.log("=== Deployed ===");
        console.log("%s: %s", hookName(), hook);
        console.log("");
        console.log("Next: ask Uniswap to whitelist it, then paste the approved address into SWAP_HOOK");
        console.log("      in src/config/manifest.%s.sol", _manifestName());
        console.log("Then: just export-deployments");
    }

    /// @dev Manifest file suffix for the current chain, for the "paste it here" hint.
    function _manifestName() internal view returns (string memory) {
        if (block.chainid == DeploymentAddressesRobinhoodTestnet.BLOCKCHAIN_ID) return "robinhood.testnet";
        return "robinhood.mainnet";
    }

    function _resolveAddresses() internal view returns (address poolManager, address router, address treasury) {
        if (block.chainid == DeploymentAddressesRobinhoodMainnet.BLOCKCHAIN_ID) {
            poolManager = DeploymentAddressesRobinhoodMainnet.UNIV4_POOL_MANAGER;
            router = DeploymentsRobinhoodMainnet.LP_FEE_ROUTER;
            treasury = DeploymentAddressesRobinhoodMainnet.REALM_TREASURY;
        } else if (block.chainid == DeploymentAddressesRobinhoodTestnet.BLOCKCHAIN_ID) {
            poolManager = DeploymentAddressesRobinhoodTestnet.UNIV4_POOL_MANAGER;
            router = DeploymentsRobinhoodTestnet.LP_FEE_ROUTER;
            treasury = DeploymentAddressesRobinhoodTestnet.REALM_TREASURY;
        } else {
            revert("Unsupported chain ID");
        }

        // Manifest `LP_FEE_ROUTER` is still `address(0)` on a chain where the router was just deployed.
        // Let the caller pass it directly rather than paste-and-rebuild first.
        router = vm.envOr("ROUTER_ADDRESS", router);
    }
}

/// @notice Deploys `RealmHook` — the same hook plus a per-swap `RealmPoolState` log, which is what lets
///         the indexer stop subscribing to the singleton V4 `PoolManager.Swap`.
/// @dev The whitelisted variant, and the only hook Realm deploys; its address becomes the manifest's
///      `SWAP_HOOK`.
///
/// Usage (dry run):   forge script DeployRealmHook --rpc-url rh-testnet --account realm.dev
/// Usage (robinhood): ROUTER_ADDRESS=<router> forge script DeployRealmHook --rpc-url rh-mainnet \
///                        --account realm.dev --slow --broadcast --gas-estimate-multiplier 300
contract DeployRealmHook is DeployHookBase {
    function hookName() internal pure override returns (string memory) {
        return "RealmHook";
    }

    function creationCode() internal pure override returns (bytes memory) {
        return type(RealmHook).creationCode;
    }

    function _deploy(bytes32 salt, address poolManager, address router, address treasury)
        internal
        override
        returns (address)
    {
        return address(new RealmHook{salt: salt}(IPoolManager(poolManager), router, treasury));
    }
}

/// @notice Deploys `RealmHookAnyPair` — the hook every ERC20-quoted Realm pool is bound to, which
///         resolves which side of the pair is the token and collects its fee in the pool's own quote.
/// @dev A SECOND hook, not a replacement: `RealmHook` is whitelisted by Uniswap and keeps every
///      native-quoted pool. This one's address becomes the manifest's `SWAP_HOOK_ANY_PAIR` and is what
///      `RealmDirectGraduatorUniV4` binds an ERC20 pair to. It declares the same four callbacks, so it
///      mines against the same `0xCC` mask.
///
/// Usage (dry run):   forge script DeployRealmHookAnyPair --rpc-url rh-testnet --account realm.dev
/// Usage (deploy):    just deploy-anypair-hook-rh-testnet
contract DeployRealmHookAnyPair is DeployHookBase {
    function hookName() internal pure override returns (string memory) {
        return "RealmHookAnyPair";
    }

    function creationCode() internal pure override returns (bytes memory) {
        return type(RealmHookAnyPair).creationCode;
    }

    function _deploy(bytes32 salt, address poolManager, address router, address treasury)
        internal
        override
        returns (address)
    {
        return address(new RealmHookAnyPair{salt: salt}(IPoolManager(poolManager), router, treasury));
    }
}
