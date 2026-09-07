// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {RealmKeepersRegistry} from "src/access/RealmKeepersRegistry.sol";
import {RealmDividendSwapRegistry} from "src/dividends/RealmDividendSwapRegistry.sol";
import {SwapLpFeeRouter} from "src/feeRouters/SwapLpFeeRouter.sol";
import {ChainConfig} from "script/ChainConfig.sol";
import {
    DeploymentAddressesEthereumSepolia,
    DeploymentAddressesRobinhoodMainnet
} from "src/config/DeploymentAddresses.sol";

/// @title Phase 0 — the contracts whose addresses are COMPILE-TIME constants elsewhere
/// @notice Deploys the three contracts that must exist before anything else is compiled, because their
///         addresses are baked into other contracts' bytecode rather than passed at runtime:
///           1. `RealmKeepersRegistry`         -> `DeploymentAddresses.REALM_KEEPERS_REGISTRY`
///           2. `RealmDividendSwapRegistry`    -> `DeploymentAddresses.DIVIDEND_SWAP_REGISTRY` (PROXY)
///           3. `SwapLpFeeRouter` impl + UUPS proxy -> `LP_FEE_ROUTER_IMPL` / `LP_FEE_ROUTER`
///
///         (1) and (2) are read by the taxable token implementations, which are non-upgradeable clone
///         masters: an impl compiled against the placeholder fails closed FOREVER — every
///         `processDividends` / `processBurn` / `processLiquidity` reverts, and third-asset dividend
///         tokens cannot be created. So: run this, paste, rebuild, and only then run `DeployRealmStack`.
///
///         (3) is not a compile-time constant but must exist before the hook: `RealmSwapHook.FEE_ROUTER`
///         is an immutable, so the router proxy has to be deployed and its address passed at hook
///         construction. Realm deploys its own proxy (it no longer inherits Livo's, which is owned by
///         the old `livo.dev` key and pinned to the Livo treasury). Later router policy changes ship by
///         `upgradeToAndCall`ing this proxy, whose owner is the `realm.dev` deployer.
///
/// @dev    Run: just chain-<sepolia|robinhood> && forge script DeployRealmPrereqs \
///                  --rpc-url <sepolia|robinhood-mainnet> --account realm.dev --slow --broadcast --verify
contract DeployRealmPrereqs is Script {
    function run() external {
        address treasury = ChainConfig.infra().treasury;
        uint256 threshold = _dividendDepthThreshold();

        console.log("=== Phase 0: Realm prerequisites ===");
        console.log("Chain ID: ", block.chainid);
        console.log("Deployer: ", msg.sender);
        console.log("Owner:    ", treasury);
        console.log("");

        vm.startBroadcast();

        // Owner is the treasury (cold key): it appoints admins and does nothing operational itself.
        address keepers = address(new RealmKeepersRegistry(treasury));

        address dividendImpl = address(new RealmDividendSwapRegistry());
        address dividendProxy = address(
            new ERC1967Proxy(dividendImpl, abi.encodeCall(RealmDividendSwapRegistry.initialize, (treasury, threshold)))
        );

        // The hook takes this proxy as an immutable, so it must exist before `DeployRealmSwapHook`.
        // `initialize()` runs inside the proxy constructor so ownership cannot be front-run.
        address routerImpl = address(new SwapLpFeeRouter(treasury, _lpFeeRouterConfig()));
        address routerProxy = address(new ERC1967Proxy(routerImpl, abi.encodeCall(SwapLpFeeRouter.initialize, ())));

        vm.stopBroadcast();

        console.log("=== Paste into src/config/DeploymentAddresses.sol (this chain's library) ===");
        console.log("  REALM_KEEPERS_REGISTRY  =", keepers);
        console.log("  DIVIDEND_SWAP_REGISTRY  =", dividendProxy);
        console.log("");
        console.log("=== Paste into src/config/manifest.%s.sol ===", ChainConfig.name());
        console.log("  LP_FEE_ROUTER           =", routerProxy);
        console.log("  LP_FEE_ROUTER_IMPL      =", routerImpl);
        console.log("  (RealmDividendSwapRegistry impl, not in the manifest:", dividendImpl, ")");
        console.log("");
        console.log("Next:");
        console.log("  1. Paste the two DeploymentAddresses constants, then `forge build` (bytecode changes).");
        console.log("  2. Paste LP_FEE_ROUTER into the manifest, then `just export-deployments`.");
        console.log("  3. forge script DeployRealmSwapHook ...  (needs LP_FEE_ROUTER)");
        console.log("  4. forge script DeployRealmStack ...");
        console.log("  5. Appoint admins/keepers: setAdmin + setKeeper, from the treasury account.");
    }

    /// @dev Depth an asset's V2 pair must hold to be an eligible dividend payout asset, in native
    ///      18-dec. 10x the per-process cap, so the largest swap a token ever sends through the pool is
    ///      ~10% of its quote side. NOT a sandwich defence (the keeper gate is) — it only keeps honest
    ///      conversions out of dead pairs. Changed later with `setDefaultThreshold`.
    function _dividendDepthThreshold() internal view returns (uint256) {
        if (ChainConfig.isSepolia()) return 10 * DeploymentAddressesEthereumSepolia.MAX_EARNINGS_PER_PROCESS;
        return 10 * DeploymentAddressesRobinhoodMainnet.MAX_EARNINGS_PER_PROCESS;
    }

    /// @dev LP fee split by marketcap tier: 40/60 treasury/creator at graduation, sliding to 10/90 above
    ///      1500 ETH of marketcap. Thresholds are native-denominated, so their USD meaning drifts with
    ///      the ETH price — repriced by deploying a new implementation and `upgradeTo`ing the proxy.
    function _lpFeeRouterConfig() internal pure returns (SwapLpFeeRouter.Config memory cfg) {
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
}
