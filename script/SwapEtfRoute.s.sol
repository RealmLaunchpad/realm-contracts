// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "lib/forge-std/src/Script.sol";
import {console} from "lib/forge-std/src/console.sol";
import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {RealmEtf} from "src/etf/RealmEtf.sol";
import {RealmEtfAssets} from "src/etf/RealmEtfAssets.sol";
import {ChainConfig} from "script/ChainConfig.sol";

/// @notice Test helper: buys (or sells) an ETF asset with USDG through its route pool in `RealmEtfAssets`, the
///         pool every ETF's NAV prices it from, and logs the asset's USDG price before and after. With ETF set,
///         also logs that ETF's NAV per share: buying the asset raises it, selling lowers it.
/// @dev V4 routes only (every testnet route is one). Swaps with a throwaway `PoolSwapTest`, which pulls the
///      input from the broadcaster: it must hold AMOUNT of USDG (buy) or of the asset (sell).
///
/// Usage: just swap-etf-route-rh-testnet <asset> [amount] [sell] [etf] [account]
///
/// Env:
///   ASSET   an asset with a route in `RealmEtfAssets`.
///   AMOUNT  exact input, raw units of USDG (buy) or the asset (sell). Default 1000e18.
///   SELL    true sells the asset for USDG. Default false.
///   ETF     (optional) an ETF whose NAV per share is logged.
contract SwapEtfRoute is Script {
    function run() external {
        address asset = vm.envAddress("ASSET");
        uint256 amount = vm.envOr("AMOUNT", uint256(1000e18));
        bool sell = vm.envOr("SELL", false);
        RealmEtf etf = RealmEtf(vm.envOr("ETF", address(0)));

        RealmEtfAssets registry = RealmEtfAssets(ChainConfig.etfAssets());
        RealmEtfAssets.Route memory route = registry.routeOf(asset);
        require(route.venue == RealmEtfAssets.Venue.V4, "V4 routes only");

        uint256 oneAsset = 10 ** IERC20Metadata(asset).decimals();
        uint256 priceBefore = registry.usdgValueOf(asset, oneAsset);
        uint256 navBefore = _nav(etf);

        _swap(registry, route, sell ? asset : registry.USDG(), amount);

        console.log("%s %s %s", sell ? "Sold" : "Bought", IERC20Metadata(asset).symbol(), asset);
        console.log("   USDG per asset (raw) %d -> %d", priceBefore, registry.usdgValueOf(asset, oneAsset));
        if (address(etf) != address(0)) console.log("   NAV per share (raw)  %d -> %d", navBefore, _nav(etf));
    }

    function _nav(RealmEtf etf) internal view returns (uint256) {
        return address(etf) == address(0) ? 0 : etf.convertToAssets(10 ** etf.decimals());
    }

    function _swap(RealmEtfAssets registry, RealmEtfAssets.Route memory route, address tokenIn, uint256 amount)
        internal
    {
        bool zeroForOne = Currency.unwrap(route.key.currency0) == tokenIn;
        vm.startBroadcast();
        PoolSwapTest router = new PoolSwapTest(registry.POOL_MANAGER());
        IERC20Metadata(tokenIn).approve(address(router), amount);
        router.swap(
            route.key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopBroadcast();
    }
}
