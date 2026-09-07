// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {RealmKeepersRegistry} from "src/access/RealmKeepersRegistry.sol";
import {RealmDividendSwapRegistry} from "src/dividends/RealmDividendSwapRegistry.sol";
import {ChainConfig} from "script/ChainConfig.sol";
import {
    DeploymentAddressesEthereumSepolia,
    DeploymentAddressesRobinhoodMainnet
} from "src/config/DeploymentAddresses.sol";

/// @title The two keeper registries, owned by the broadcasting account
/// @notice Deploys `RealmKeepersRegistry` and the `RealmDividendSwapRegistry` proxy, both owned by the
///         account that broadcasts (`realm.dev`), and prints the two `DeploymentAddresses` constants to
///         paste. Standalone so the registries can be redeployed without touching the LP fee router or
///         the hooks (whose Uniswap whitelisting must survive); `DeployRealmPrereqs` builds on it.
/// @dev    Nothing already deployed references the registries: only the taxable token impls bake them
///         in, and those come later in `DeployRealmStack`. Paste, `forge build`, then deploy the stack.
///
///         Run: just chain-<sepolia|robinhood> && forge script DeployRealmRegistries \
///                  --rpc-url <sepolia|robinhood-mainnet> --account realm.dev --slow --broadcast --verify
contract DeployRealmRegistries is Script {
    function run() external virtual {
        vm.startBroadcast();
        (address keepers, address dividendProxy, address dividendImpl) = _deployRegistries();
        vm.stopBroadcast();

        _reportRegistries(keepers, dividendProxy, dividendImpl);
    }

    /// @dev Owner is the broadcaster, read from `readCallers` inside the broadcast: `msg.sender` would
    ///      be forge's DEFAULT_SENDER unless `--sender` is passed. Must run inside `startBroadcast`.
    function _deployRegistries() internal returns (address keepers, address dividendProxy, address dividendImpl) {
        (, address owner,) = vm.readCallers();
        console.log("Registries owner:", owner);

        keepers = address(new RealmKeepersRegistry(owner));
        dividendImpl = address(new RealmDividendSwapRegistry());
        dividendProxy = address(
            new ERC1967Proxy(
                dividendImpl, abi.encodeCall(RealmDividendSwapRegistry.initialize, (owner, _dividendDepthThreshold()))
            )
        );
    }

    function _reportRegistries(address keepers, address dividendProxy, address dividendImpl) internal pure {
        console.log("=== Paste into src/config/DeploymentAddresses.sol (this chain's library) ===");
        console.log("  REALM_KEEPERS_REGISTRY  =", keepers);
        console.log("  DIVIDEND_SWAP_REGISTRY  =", dividendProxy);
        console.log("  (RealmDividendSwapRegistry impl, not in the manifest:", dividendImpl, ")");
        console.log("Then `forge build` (bytecode changes).");
    }

    /// @dev Depth an asset's V2 pair must hold to be an eligible dividend payout asset, in native
    ///      18-dec. 10x the per-process cap, so the largest swap a token ever sends through the pool is
    ///      ~10% of its quote side. NOT a sandwich defence (the keeper gate is) — it only keeps honest
    ///      conversions out of dead pairs. Changed later with `setDefaultThreshold`.
    function _dividendDepthThreshold() internal view returns (uint256) {
        if (ChainConfig.isSepolia()) return 10 * DeploymentAddressesEthereumSepolia.MAX_EARNINGS_PER_PROCESS;
        return 10 * DeploymentAddressesRobinhoodMainnet.MAX_EARNINGS_PER_PROCESS;
    }
}
