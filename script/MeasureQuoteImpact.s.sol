// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "lib/forge-std/src/Script.sol";
import {console} from "lib/forge-std/src/console.sol";

import {RealmDividendSwapRegistry} from "src/dividends/RealmDividendSwapRegistry.sol";
import {Hop} from "src/interfaces/IRealmDividendSwapRegistry.sol";
import {DividendRouteLib} from "src/libraries/DividendRouteLib.sol";
import {DeploymentAddressesRobinhoodMainnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";

interface IV3Pool {
    function fee() external view returns (uint24);
}

/// @notice Price impact of a native buy of each `ASSETS` entry through the pool the mainnet listings file
///         names for it, simulated on forked state. BROADCASTS NOTHING.
/// @dev Impact = 1 - (per-native out at SIZE) / (per-native out at 0.001 ETH); fees cancel out. Buys go through
///      the dividend swap registry, which already routes native -> [USDG ->] asset on V2/V3/V4.
/// Usage:  ASSETS=0x..,0x.. forge script MeasureQuoteImpact --rpc-url rh-mainnet
contract MeasureQuoteImpact is Script {
    string internal constant LISTINGS = "script/operations/assets-whitelist/listings.robinhood.mainnet.json";
    address internal constant PROBER = address(uint160(uint256(keccak256("MeasureQuoteImpact.prober"))));
    uint256 internal constant SMALL = 0.001 ether;

    RealmDividendSwapRegistry internal registry =
        RealmDividendSwapRegistry(payable(DeploymentAddresses.DIVIDEND_SWAP_REGISTRY));

    function run() external {
        string memory json = vm.readFile(LISTINGS);
        address[] memory listed = vm.parseJsonAddressArray(json, ".assets");
        address[] memory wanted = vm.envAddress("ASSETS", ",");

        // No keeper cut: its flat fee would skew the small reference buy.
        vm.prank(registry.owner());
        try registry.setKeeperFunding(address(0)) {} catch {}

        console.log("asset | impact bps at 0.1 / 1 / 3 ETH");
        for (uint256 w; w < wanted.length; ++w) {
            uint256 i = _indexOf(listed, wanted[w]);
            bytes memory route = _route(json, i, listed[i]);
            uint256 base = _bought(listed[i], route, SMALL);
            console.log(
                "%s %s %s", vm.parseJsonString(json, string.concat(".symbols[", vm.toString(i), "]")), listed[i], ""
            );
            console.log(
                "   %s / %s / %s",
                _impact(base, _bought(listed[i], route, 0.1 ether), 0.1 ether),
                _impact(base, _bought(listed[i], route, 1 ether), 1 ether),
                _impact(base, _bought(listed[i], route, 3 ether), 3 ether)
            );
        }
    }

    /// @dev The listing's price source as a registry route. A USDG-quoted V4 pool gets USDG's own listed pool
    ///      (entry 0) as its first hop. V3 listings are native-quoted here, so a single WETH hop.
    function _route(string memory json, uint256 i, address asset) internal view returns (bytes memory) {
        uint256 venue = _uint(json, "venues", i);
        if (venue == 1) return DividendRouteLib.encodeV2();
        if (venue == 2) {
            address pool = vm.parseJsonAddress(json, string.concat(".pools[", vm.toString(i), "]"));
            return DividendRouteLib.encodeV3(abi.encodePacked(DeploymentAddresses.WETH, IV3Pool(pool).fee(), asset));
        }
        bool native = vm.parseJsonAddress(json, string.concat(".currency0[", vm.toString(i), "]")) == address(0);
        Hop[] memory hops = new Hop[](native ? 1 : 2);
        if (!native) hops[0] = _hop(json, 0, vm.parseJsonAddress(json, ".assets[0]"));
        hops[hops.length - 1] = _hop(json, i, asset);
        return DividendRouteLib.encodeV4(hops);
    }

    function _hop(string memory json, uint256 i, address currency) internal pure returns (Hop memory) {
        return Hop({
            currency: currency,
            fee: uint24(_uint(json, "fees", i)),
            tickSpacing: int24(int256(_uint(json, "tickSpacings", i))),
            hooks: vm.parseJsonAddress(json, string.concat(".hooks[", vm.toString(i), "]"))
        });
    }

    function _bought(address asset, bytes memory route, uint256 amount) internal returns (uint256 out) {
        uint256 snapshot = vm.snapshotState();
        vm.prank(registry.owner());
        registry.setRoute(PROBER, asset, route);
        vm.deal(PROBER, amount);
        vm.prank(PROBER);
        try registry.swapNativeToAsset{value: amount}(asset, 1, PROBER) returns (uint256 bought) {
            out = bought;
        } catch {}
        vm.revertToState(snapshot);
    }

    /// @dev "revert" when the buy fails outright.
    function _impact(uint256 base, uint256 out, uint256 amount) internal pure returns (string memory) {
        if (base == 0 || out == 0) return "revert";
        uint256 ratio = out * SMALL * 10_000 / (base * amount);
        return vm.toString(ratio >= 10_000 ? 0 : 10_000 - ratio);
    }

    function _uint(string memory json, string memory key, uint256 i) internal pure returns (uint256) {
        return vm.parseJsonUint(json, string.concat(".", key, "[", vm.toString(i), "]"));
    }

    function _indexOf(address[] memory list, address a) internal pure returns (uint256) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == a) return i;
        }
        revert("asset not in the listings file");
    }
}
