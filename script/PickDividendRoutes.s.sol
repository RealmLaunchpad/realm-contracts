// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "lib/forge-std/src/Script.sol";
import {console} from "lib/forge-std/src/console.sol";

import {RealmDividendSwapRegistry} from "src/dividends/RealmDividendSwapRegistry.sol";
import {Hop} from "src/interfaces/IRealmDividendSwapRegistry.sol";
import {DividendRouteLib} from "src/libraries/DividendRouteLib.sol";
import {DeploymentAddressesRobinhoodMainnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";

/// @notice Picks the Uniswap V2, V3 or V4 route that actually buys the most of each payout asset AT A
///         FULL CONVERSION (`MAX_EARNINGS_PER_PROCESS`), out of the candidates `discover_xstock_routes.py`
///         shortlisted, and writes them out in the wire format `RealmDividendSwapRegistry.setRoute`
///         takes. An asset no candidate can buy at that size is left out.
///
/// @dev WRITES NOTHING ON-CHAIN. It is the proof an admin lists a route on: broadcasts nothing and needs
///      no keys. Listing is a separate `setRoute` per asset.
///
/// @dev THE PROBE PICKS THE ROUTE, the discovery script only shortlists. `discover_xstock_routes.py`
///      cannot rank an ETH-quoted pool against a USDG-quoted one — `liquidity` is denominated in each
///      pool's own currencies — and cannot see that a fat 5% pool loses to a thin 0.05% one. So it hands
///      over CANDIDATES, and this script buys the asset through each of them against forked state and
///      keeps whichever delivers most.
///
/// @dev That probing is the whole reason this is a forge script rather than a Python quoter. A route
///      naming the wrong pool does not fail loudly — it fails at some future `processDividends`, on a
///      clone nobody can patch, for a creator who picked that asset in good faith. The probe is a real
///      swap through the real registry against real state, which is the only check that cannot disagree
///      with the contract it is validating.
///
/// @dev IT IS ALSO THE ROUTES' HEALTH CHECK. Re-run it and an asset whose pools have moved reports a
///      different winner, or none at all: repoint (or clear) that asset's route on the registry.
///
/// Usage:  forge script PickDividendRoutes --rpc-url rh-mainnet
///
/// Env:
///   DIVIDEND_SWAP_REGISTRY  the registry proxy on this chain
///   ROUTES_JSON             (optional) path to the discovery output
///   ROUTES_OUT              (optional) where to write the picked routes
contract PickDividendRoutes is Script {
    /// @dev Native spent by the probe swap: the largest conversion a token ever makes, so a route that
    ///      passes can take any conversion a keeper sends it.
    uint256 internal constant PROBE_AMOUNT = DeploymentAddresses.MAX_EARNINGS_PER_PROCESS;

    /// @dev Stands in as the token that converts through each route. A fixed pranked address, not
    ///      `address(this)`: forge refuses a script contract's own address.
    address internal constant PROBER = address(uint160(uint256(keccak256("PickDividendRoutes.prober"))));

    string internal constant DEFAULT_ROUTES_JSON = "script/operations/dividend-routes/routes.robinhood.mainnet.json";
    string internal constant DEFAULT_ROUTES_OUT = "script/operations/dividend-routes/catalogue.robinhood.mainnet.json";

    function run() external {
        RealmDividendSwapRegistry registry = RealmDividendSwapRegistry(payable(vm.envAddress("DIVIDEND_SWAP_REGISTRY")));
        string memory json = vm.readFile(vm.envOr("ROUTES_JSON", DEFAULT_ROUTES_JSON));

        address[] memory assets = vm.parseJsonAddressArray(json, ".assets");
        // Pre-encoded `Hop[][]` rather than a JSON object per hop: `parseJson` decodes struct fields in
        // alphabetical order, which silently mismatches `Hop`'s declaration order.
        bytes[] memory encoded = vm.parseJsonBytesArray(json, ".candidates");
        // Per asset, `abi.encode(bytes[])` of ready V3 routes. Absent in discovery output that predates V3.
        bytes[] memory v3 = vm.keyExistsJson(json, ".v3Candidates")
            ? vm.parseJsonBytesArray(json, ".v3Candidates")
            : new bytes[](assets.length);
        string[] memory symbols = vm.parseJsonStringArray(json, ".symbols");
        require(assets.length == encoded.length, "assets/candidates length mismatch");
        require(assets.length == symbols.length, "assets/symbols length mismatch");
        require(assets.length == v3.length, "assets/v3Candidates length mismatch");

        console.log("=== Pick dividend routes ===");
        console.log("Chain ID: %d", block.chainid);
        console.log("Registry: %s", address(registry));
        console.log("Assets:   %d", assets.length);

        bytes[] memory chosen = _probe(registry, assets, encoded, v3);

        string memory out;
        uint256 picked;
        for (uint256 i; i < assets.length; ++i) {
            if (chosen[i].length == 0) continue;
            // Keyed by address, not by symbol: two assets can share a ticker and only one of them is the
            // one this route buys. The symbol rides along as a label for the catalogue.
            out = vm.serializeBytes("catalogue", vm.toString(assets[i]), chosen[i]);
            console.log("  %s %s", symbols[i], vm.toString(assets[i]));
            console.logBytes(chosen[i]);
            ++picked;
        }

        vm.writeJson(out, vm.envOr("ROUTES_OUT", DEFAULT_ROUTES_OUT));
        console.log("=== Done: %d routed, %d unroutable ===", picked, assets.length - picked);
    }

    /// @dev Buys a little of every asset through every candidate route, all inside the simulation EVM,
    ///      then rolls the whole thing back. Nothing here is broadcast; the return value is the wire
    ///      format of the route that bought the most of each asset, empty for an asset no candidate
    ///      could buy at all.
    function _probe(
        RealmDividendSwapRegistry registry,
        address[] memory assets,
        bytes[] memory encoded,
        bytes[] memory v3
    ) internal returns (bytes[] memory chosen) {
        chosen = new bytes[](assets.length);
        uint256 snapshot = vm.snapshotState();

        for (uint256 i; i < assets.length; ++i) {
            Hop[][] memory candidates = abi.decode(encoded[i], (Hop[][]));
            uint256 best;
            for (uint256 j; j < candidates.length; ++j) {
                bytes memory route = DividendRouteLib.encodeV4(candidates[j]);
                uint256 amountOut = _bought(registry, assets[i], route);
                if (amountOut > best) {
                    best = amountOut;
                    chosen[i] = route;
                }
            }
            uint256 v2Out = _bought(registry, assets[i], DividendRouteLib.encodeV2());
            if (v2Out > best) {
                best = v2Out;
                chosen[i] = DividendRouteLib.encodeV2();
            }
            bytes[] memory v3Routes = v3[i].length == 0 ? new bytes[](0) : abi.decode(v3[i], (bytes[]));
            for (uint256 j; j < v3Routes.length; ++j) {
                uint256 amountOut = _bought(registry, assets[i], v3Routes[j]);
                if (amountOut > best) {
                    best = amountOut;
                    chosen[i] = v3Routes[j];
                }
            }
            if (best == 0) console.log("  %s : no candidate route could buy it - skipped", assets[i]);
        }

        vm.revertToState(snapshot);
    }

    /// @dev How much of `asset` one probe-sized buy delivers through `route`, or 0 if it cannot.
    /// @dev Rolled back before returning, so every candidate for an asset is measured against the same
    ///      pool state — otherwise the first probe would move the price the second one is judged on.
    /// @dev `minOut` of 1: the probe asks whether the route can take a full conversion at all, and
    ///      compares candidates against each other. Pricing a real floor is the keeper's job.
    function _bought(RealmDividendSwapRegistry registry, address asset, bytes memory route)
        internal
        returns (uint256 out)
    {
        uint256 snapshot = vm.snapshotState();

        vm.prank(registry.owner());
        try registry.setRoute(asset, route) {
            vm.deal(PROBER, PROBE_AMOUNT);
            vm.prank(PROBER);
            try registry.swapNativeToAsset{value: PROBE_AMOUNT}(asset, 1, PROBER) returns (uint256 bought) {
                out = bought;
            } catch {}
        } catch {}

        vm.revertToState(snapshot);
    }

    receive() external payable {}
}
