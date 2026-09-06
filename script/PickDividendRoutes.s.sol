// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "lib/forge-std/src/Script.sol";
import {console} from "lib/forge-std/src/console.sol";

import {LivoDividendSwapRegistry} from "src/dividends/LivoDividendSwapRegistry.sol";
import {Hop} from "src/interfaces/ILivoDividendSwapRegistry.sol";
import {DividendRouteLib} from "src/libraries/DividendRouteLib.sol";

/// @notice Picks the Uniswap V4 route that actually buys the most of each payout asset, out of the
///         candidates `discover_xstock_routes.py` shortlisted, and writes them out in the wire format a
///         token creation takes. The output feeds the frontend's suggested-asset catalogue: a creator
///         who picks a listed asset ships its route with it and never has to search for pools.
///
/// @dev WRITES NOTHING ON-CHAIN. Routes belong to the token that converts through them and are
///      registered by that token, at its own creation, via `registerRoute`. There is no admin route
///      table any more and no asset-level approval — Livo does not review payout assets. This script is
///      therefore a measurement, not an operation: it broadcasts nothing and needs no keys.
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
/// @dev IT IS ALSO THE CATALOGUE'S HEALTH CHECK. Re-run it and an asset whose pools have moved reports
///      a different winner, or none at all. A route in the shipped catalogue that can no longer buy its
///      asset is worse than no entry: it hands a creator a permanent, unfixable configuration.
///
/// Usage:  forge script PickDividendRoutes --rpc-url robinhood-mainnet
///
/// Env:
///   DIVIDEND_SWAP_REGISTRY  the registry proxy on this chain
///   ROUTES_JSON             (optional) path to the discovery output
///   ROUTES_OUT              (optional) where to write the picked routes
contract PickDividendRoutes is Script {
    /// @dev Native spent by the probe swap. Small enough that any pool worth routing through can
    ///      absorb it, large enough that a pool holding dust fails rather than passes.
    uint256 internal constant PROBE_AMOUNT = 0.001 ether;

    string internal constant DEFAULT_ROUTES_JSON = "script/operations/dividend-routes/routes.robinhood.mainnet.json";
    string internal constant DEFAULT_ROUTES_OUT = "script/operations/dividend-routes/catalogue.robinhood.mainnet.json";

    function run() external {
        LivoDividendSwapRegistry registry = LivoDividendSwapRegistry(vm.envAddress("DIVIDEND_SWAP_REGISTRY"));
        string memory json = vm.readFile(vm.envOr("ROUTES_JSON", DEFAULT_ROUTES_JSON));

        address[] memory assets = vm.parseJsonAddressArray(json, ".assets");
        // Pre-encoded `Hop[][]` rather than a JSON object per hop: `parseJson` decodes struct fields in
        // alphabetical order, which silently mismatches `Hop`'s declaration order.
        bytes[] memory encoded = vm.parseJsonBytesArray(json, ".candidates");
        string[] memory symbols = vm.parseJsonStringArray(json, ".readable[*].symbol");
        require(assets.length == encoded.length, "assets/candidates length mismatch");
        require(assets.length == symbols.length, "assets/symbols length mismatch");

        console.log("=== Pick dividend routes ===");
        console.log("Chain ID: %d", block.chainid);
        console.log("Registry: %s", address(registry));
        console.log("Assets:   %d", assets.length);

        bytes[] memory chosen = _probe(registry, assets, encoded);

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
    function _probe(LivoDividendSwapRegistry registry, address[] memory assets, bytes[] memory encoded)
        internal
        returns (bytes[] memory chosen)
    {
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
            if (best == 0) console.log("  %s : no candidate route could buy it - skipped", assets[i]);
        }

        vm.revertToState(snapshot);
    }

    /// @dev How much of `asset` one probe-sized buy delivers through `route`, or 0 if it cannot.
    /// @dev Rolled back before returning, so every candidate for an asset is measured against the same
    ///      pool state — otherwise the first probe would move the price the second one is judged on. The
    ///      rollback is also what lets this script register the same (token, asset) pair repeatedly:
    ///      `registerRoute` is write-once, and `address(this)` stands in as the token every time.
    /// @dev `minOut` of 1: the probe asks whether the pools exist and hold anything, and compares
    ///      candidates against each other. Pricing a real floor is the keeper's job, per conversion.
    function _bought(LivoDividendSwapRegistry registry, address asset, bytes memory route)
        internal
        returns (uint256 out)
    {
        uint256 snapshot = vm.snapshotState();

        try registry.registerRoute(asset, route) {
            vm.deal(address(this), PROBE_AMOUNT);
            try registry.swapNativeToAsset{value: PROBE_AMOUNT}(asset, 1, address(this)) returns (uint256 bought) {
                out = bought;
            } catch {
                out = 0;
            }
        } catch {
            // The route did not even validate — a dead pool, a malformed hop. Same answer as a swap that
            // bought nothing, and the caller only compares magnitudes.
            out = 0;
        }

        vm.revertToState(snapshot);
    }

    receive() external payable {}
}
