// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "lib/forge-std/src/Script.sol";
import {console} from "lib/forge-std/src/console.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {RealmLpFeeRouter} from "src/feeRouters/RealmLpFeeRouter.sol";
import {
    DeploymentAddressesEthereumSepolia,
    DeploymentAddressesRobinhoodMainnet
} from "src/config/DeploymentAddresses.sol";

/// @notice Deploys the `RealmLpFeeRouter` implementation + UUPS proxy with the initial tier policy.
/// @dev Tier thresholds are denominated in ETH wei and were chosen assuming ETH ≈ $3000 to mirror
///      the USD marketcap brackets that drive the split (100K / 500K / 1M / 2M / 3M / 5M USD).
///      To update the policy later (or rotate the treasury), deploy a new implementation with
///      different constructor args and call `upgradeTo` on the proxy — the implementation is
///      otherwise stateless.
///
/// Usage (dry run):  forge script DeployRealmLpFeeRouter --rpc-url sepolia --account livo.dev
/// Usage (deploy):   forge script DeployRealmLpFeeRouter --rpc-url sepolia --account livo.dev --slow --broadcast --verify
contract DeployRealmLpFeeRouter is Script {
    function run() external {
        address treasury = _resolveTreasury();

        console.log("=== Deploy RealmLpFeeRouter ===");
        console.log("Chain ID: %d", block.chainid);
        console.log("Treasury: %s", treasury);

        RealmLpFeeRouter.Config memory cfg = _defaultConfig();

        vm.startBroadcast();
        address impl = address(new RealmLpFeeRouter(treasury, cfg));
        address proxy = address(new ERC1967Proxy(impl, abi.encodeCall(RealmLpFeeRouter.initialize, ())));
        vm.stopBroadcast();

        console.log("=== Deployed ===");
        console.log("RealmLpFeeRouter (impl):  %s", impl);
        console.log("RealmLpFeeRouter (proxy): %s", proxy);
        console.log("");
        console.log(
            "Next: paste these into LP_FEE_ROUTER + LP_FEE_ROUTER_IMPL in src/config/manifest.%s.sol", _manifestName()
        );
        console.log("Then: just export-deployments");
    }

    /// @dev Manifest file suffix for the current chain, for the "paste it here" hint.
    function _manifestName() internal view returns (string memory) {
        if (block.chainid == DeploymentAddressesEthereumSepolia.BLOCKCHAIN_ID) return "ethereum.sepolia";
        return "robinhood.mainnet";
    }

    /// @dev Production tier policy. The treasury/creator split per tier is chain-invariant; only the
    ///      native-denominated marketcap brackets are ETH-denominated on both supported chains.
    ///        Tier 0 (post-graduation): 40% treasury / 60% creator
    ///        Tier 1: 35% / 65%
    ///        Tier 2: 30% / 70%
    ///        Tier 3: 25% / 75%
    ///        Tier 4: 20% / 80%
    ///        Tier 5: 15% / 85%
    ///        Tier 6: 10% / 90%
    function _defaultConfig() internal pure returns (RealmLpFeeRouter.Config memory cfg) {
        // Native ETH brackets, in ETH. The USD marketcap each one represents moves with the ETH
        // price, so they are due a repricing pass — deliberately left as deployed for now.
        cfg.thresholds = [
            uint256(30 ether),
            uint256(150 ether),
            uint256(300 ether),
            uint256(600 ether),
            uint256(900 ether),
            uint256(1500 ether)
        ];
        cfg.treasuryBps = [uint16(4000), 3500, 3000, 2500, 2000, 1500, 1000];
    }

    function _resolveTreasury() internal view returns (address treasury) {
        if (block.chainid == DeploymentAddressesEthereumSepolia.BLOCKCHAIN_ID) {
            treasury = DeploymentAddressesEthereumSepolia.REALM_TREASURY;
        } else if (block.chainid == DeploymentAddressesRobinhoodMainnet.BLOCKCHAIN_ID) {
            treasury = DeploymentAddressesRobinhoodMainnet.REALM_TREASURY;
        } else {
            revert("Unsupported chain ID");
        }
        require(treasury != address(0), "REALM_TREASURY missing");
    }
}
