// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "lib/forge-std/src/Script.sol";
import {console} from "lib/forge-std/src/console.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {RealmDividendSwapRegistry} from "src/dividends/RealmDividendSwapRegistry.sol";
import {
    DeploymentAddressesEthereumMainnet,
    DeploymentAddressesEthereumSepolia,
    DeploymentAddressesRobinhoodMainnet,
    DeploymentAddressesRobinhoodTestnet,
    DeploymentAddressesArcMainnet,
    DeploymentAddressesArcTestnet
} from "src/config/DeploymentAddresses.sol";

/// @notice Deploys the `RealmDividendSwapRegistry` implementation + UUPS proxy.
///
/// @dev ⚠️ DEPLOY ORDER. This must land BEFORE the taxable token implementations on a given chain:
///      they bake the proxy address into their bytecode as `DeploymentAddresses.DIVIDEND_SWAP_REGISTRY`,
///      which today still holds a placeholder. The sequence is: run this, paste the PROXY address into
///      that chain's `DIVIDEND_SWAP_REGISTRY` constant, then deploy the token implementations. A token
///      implementation compiled against the placeholder fails closed — third-asset dividend
///      configurations revert at creation, while native and self-token payouts keep working.
///
/// @dev The owner is the treasury multisig: it manages admins and upgrades, nothing else. Appoint the
///      operational admins afterwards with `setAdmin`, so the day-to-day blacklist and threshold work
///      does not need the cold key.
///
/// Usage (dry run):  forge script DeployRealmDividendSwapRegistry --rpc-url sepolia --account livo.dev
/// Usage (deploy):   forge script DeployRealmDividendSwapRegistry --rpc-url sepolia --account livo.dev --slow --broadcast --verify
contract DeployRealmDividendSwapRegistry is Script {
    function run() external {
        address owner = _resolveOwner();
        uint256 threshold = _defaultThreshold();

        console.log("=== Deploy RealmDividendSwapRegistry ===");
        console.log("Chain ID:  %d", block.chainid);
        console.log("Owner:     %s", owner);
        console.log("Threshold: %d (native 18-dec)", threshold);

        vm.startBroadcast();
        address impl = address(new RealmDividendSwapRegistry());
        address proxy =
            address(new ERC1967Proxy(impl, abi.encodeCall(RealmDividendSwapRegistry.initialize, (owner, threshold))));
        vm.stopBroadcast();

        console.log("=== Deployed ===");
        console.log("RealmDividendSwapRegistry (impl):  %s", impl);
        console.log("RealmDividendSwapRegistry (proxy): %s", proxy);
        console.log("");
        console.log("Next: paste the PROXY into DIVIDEND_SWAP_REGISTRY in src/config/DeploymentAddresses.sol");
        console.log("      (library DeploymentAddresses%s), then redeploy the taxable token impls.", _libraryName());
    }

    /// @dev The depth an asset's V2 pair must hold to be an eligible payout asset, in native 18-dec.
    ///      Sized off the per-freeze cap: at 10x, the largest swap a token will ever send through the
    ///      pool is ~10% of its quote side. Changed later with `setDefaultThreshold`, which applies to
    ///      tokens that already exist.
    /// @dev ⚠️ NOT A SANDWICH DEFENCE, at this or any value. The depth measured is the pair's QUOTE side,
    ///      which is the exact side an attacker's front-run buy inflates — a decayed pool is lifted back
    ///      over the bar by the manipulation itself. What this threshold buys is that HONEST conversions
    ///      do not route through a dead pair. The sandwich is stopped by the keeper gate on
    ///      `processDividends` (see `RealmKeepersRegistry`), not here.
    function _defaultThreshold() internal view returns (uint256) {
        if (block.chainid == DeploymentAddressesEthereumMainnet.BLOCKCHAIN_ID) {
            return 10 * DeploymentAddressesEthereumMainnet.MAX_EARNINGS_PER_PROCESS;
        } else if (block.chainid == DeploymentAddressesEthereumSepolia.BLOCKCHAIN_ID) {
            return 10 * DeploymentAddressesEthereumSepolia.MAX_EARNINGS_PER_PROCESS;
        } else if (block.chainid == DeploymentAddressesRobinhoodMainnet.BLOCKCHAIN_ID) {
            return 10 * DeploymentAddressesRobinhoodMainnet.MAX_EARNINGS_PER_PROCESS;
        } else if (block.chainid == DeploymentAddressesRobinhoodTestnet.BLOCKCHAIN_ID) {
            return 10 * DeploymentAddressesRobinhoodTestnet.MAX_EARNINGS_PER_PROCESS;
        } else if (block.chainid == DeploymentAddressesArcMainnet.BLOCKCHAIN_ID) {
            return 10 * DeploymentAddressesArcMainnet.MAX_EARNINGS_PER_PROCESS;
        } else if (block.chainid == DeploymentAddressesArcTestnet.BLOCKCHAIN_ID) {
            return 10 * DeploymentAddressesArcTestnet.MAX_EARNINGS_PER_PROCESS;
        }
        revert("Unsupported chain ID");
    }

    function _resolveOwner() internal view returns (address owner) {
        if (block.chainid == DeploymentAddressesEthereumMainnet.BLOCKCHAIN_ID) {
            owner = DeploymentAddressesEthereumMainnet.REALM_TREASURY;
        } else if (block.chainid == DeploymentAddressesEthereumSepolia.BLOCKCHAIN_ID) {
            owner = DeploymentAddressesEthereumSepolia.REALM_TREASURY;
        } else if (block.chainid == DeploymentAddressesRobinhoodMainnet.BLOCKCHAIN_ID) {
            owner = DeploymentAddressesRobinhoodMainnet.REALM_TREASURY;
        } else if (block.chainid == DeploymentAddressesRobinhoodTestnet.BLOCKCHAIN_ID) {
            owner = DeploymentAddressesRobinhoodTestnet.REALM_TREASURY;
        } else if (block.chainid == DeploymentAddressesArcMainnet.BLOCKCHAIN_ID) {
            owner = DeploymentAddressesArcMainnet.REALM_TREASURY;
        } else if (block.chainid == DeploymentAddressesArcTestnet.BLOCKCHAIN_ID) {
            owner = DeploymentAddressesArcTestnet.REALM_TREASURY;
        } else {
            revert("Unsupported chain ID");
        }
        require(owner != address(0), "REALM_TREASURY missing");
    }

    /// @dev Library suffix for the current chain, for the "paste it here" hint.
    function _libraryName() internal view returns (string memory) {
        if (block.chainid == DeploymentAddressesEthereumMainnet.BLOCKCHAIN_ID) return "EthereumMainnet";
        if (block.chainid == DeploymentAddressesEthereumSepolia.BLOCKCHAIN_ID) return "EthereumSepolia";
        if (block.chainid == DeploymentAddressesRobinhoodMainnet.BLOCKCHAIN_ID) return "RobinhoodMainnet";
        if (block.chainid == DeploymentAddressesArcMainnet.BLOCKCHAIN_ID) return "ArcMainnet";
        if (block.chainid == DeploymentAddressesArcTestnet.BLOCKCHAIN_ID) return "ArcTestnet";
        return "RobinhoodTestnet";
    }
}
