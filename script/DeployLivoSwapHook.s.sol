// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "lib/forge-std/src/Script.sol";
import {console} from "lib/forge-std/src/console.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "lib/v4-periphery/src/utils/HookMiner.sol";
import {LivoSwapHook} from "src/hooks/LivoSwapHook.sol";
import {
    DeploymentAddressesEthereumSepolia,
    DeploymentAddressesRobinhoodMainnet
} from "src/config/DeploymentAddresses.sol";
import {DeploymentsEthereumSepolia} from "src/config/manifest.ethereum.sepolia.sol";
import {DeploymentsRobinhoodMainnet} from "src/config/manifest.robinhood.mainnet.sol";

/// @notice Deploys `LivoSwapHook` via CREATE2 after mining a salt that encodes the four
///         required Uniswap V4 permission flags into the address.
/// @dev Runs against Mainnet (1), Sepolia (11155111) or Robinhood (4663 / 46630). Pool manager and
///      treasury come from `DeploymentAddresses*`; the LP fee router comes from `Deployments*`. Required
///      flags mirror `LivoSwapHook.getHookPermissions()`: BEFORE_SWAP, AFTER_SWAP, BEFORE_SWAP_RETURNS_DELTA,
///      AFTER_SWAP_RETURNS_DELTA → mask 0xCC.
///
/// @dev `ROUTER_ADDRESS` (optional) overrides the manifest's `LP_FEE_ROUTER`. Needed on chains where the
///      router has just been deployed but the manifest constant is still `address(0)` (both Robinhood
///      chains), so a one-off bring-up doesn't need a paste-and-rebuild round trip between the two steps.
///
/// Usage (dry run):  forge script DeployLivoSwapHook --rpc-url sepolia --account livo.dev
/// Usage (deploy):   forge script DeployLivoSwapHook --rpc-url sepolia --account livo.dev --slow --broadcast --verify
/// Usage (robinhood): ROUTER_ADDRESS=<router> forge script DeployLivoSwapHook --rpc-url robinhood-mainnet \
///                        --account livo.dev --slow --broadcast --gas-estimate-multiplier 300
contract DeployLivoSwapHook is Script {
    /// @notice Deterministic CREATE2 proxy used by `forge script` for `new X{salt:..}(..)` syntax.
    /// @dev Same address on every EVM chain. This is what HookMiner must use as the deployer.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        (address poolManager, address router, address treasury) = _resolveAddresses();
        require(router != address(0), "LP_FEE_ROUTER not set; deploy RealmLpFeeRouter first");
        require(treasury != address(0), "REALM_TREASURY not set");

        console.log("=== Deploy LivoSwapHook ===");
        console.log("Chain ID:    %d", block.chainid);
        console.log("PoolManager: %s", poolManager);
        console.log("LpFeeRouter: %s", router);
        console.log("Treasury:    %s", treasury);

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        bytes memory constructorArgs = abi.encode(IPoolManager(poolManager), router, treasury);
        bytes memory creationCode = type(LivoSwapHook).creationCode;

        console.log("Mining hook salt (this may take 30-60s)...");
        (address minedAddress, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, flags, creationCode, constructorArgs);
        console.log("Mined address: %s", minedAddress);
        console.log("Salt:          %x", uint256(salt));

        vm.startBroadcast();
        LivoSwapHook hook = new LivoSwapHook{salt: salt}(IPoolManager(poolManager), router, treasury);
        vm.stopBroadcast();

        require(address(hook) == minedAddress, "Deployed address mismatch");
        require((uint160(address(hook)) & uint160(0x3FFF)) == flags, "Hook flags mismatch");

        console.log("=== Deployed ===");
        console.log("LivoSwapHook: %s", address(hook));
        console.log("");
        console.log("Next: paste this address into SWAP_HOOK in src/config/manifest.%s.sol", _manifestName());
        console.log("Then: just export-deployments");
    }

    /// @dev Manifest file suffix for the current chain, for the "paste it here" hint.
    function _manifestName() internal view returns (string memory) {
        if (block.chainid == DeploymentAddressesEthereumSepolia.BLOCKCHAIN_ID) return "ethereum.sepolia";
        return "robinhood.mainnet";
    }

    function _resolveAddresses() internal view returns (address poolManager, address router, address treasury) {
        if (block.chainid == DeploymentAddressesEthereumSepolia.BLOCKCHAIN_ID) {
            poolManager = DeploymentAddressesEthereumSepolia.UNIV4_POOL_MANAGER;
            router = DeploymentsEthereumSepolia.LP_FEE_ROUTER;
            treasury = DeploymentAddressesEthereumSepolia.REALM_TREASURY;
        } else if (block.chainid == DeploymentAddressesRobinhoodMainnet.BLOCKCHAIN_ID) {
            poolManager = DeploymentAddressesRobinhoodMainnet.UNIV4_POOL_MANAGER;
            router = DeploymentsRobinhoodMainnet.LP_FEE_ROUTER;
            treasury = DeploymentAddressesRobinhoodMainnet.REALM_TREASURY;
        } else {
            revert("Unsupported chain ID");
        }

        // Manifest `LP_FEE_ROUTER` is still `address(0)` on chains where the router was just deployed
        // (both Robinhood chains). Let the caller pass it directly rather than paste-and-rebuild first.
        router = vm.envOr("ROUTER_ADDRESS", router);
    }
}
