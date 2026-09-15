// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

interface IRealmAnyPairsV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface IRealmAnyPairsV3Pool {
    function liquidity() external view returns (uint128);
}

/// @title RealmAnyPairsRouteLib
/// @notice Reward-basket routes, chosen at conversion time rather than at tracker construction. Each conversion
/// takes its route from one of two sources:
///   * DISCOVERED ({best}) -- the deepest pool between the input and the leg asset right now, across V3's four
///     standard fee tiers and hookless V4 pools at common fee / tick-spacing pairs ({_bestV4}).
///   * SUPPLIED ({supplied}) -- a V3 path or full V4 `PoolKey` passed in by the claimer's front end; the only way
///     to reach a V4 pool behind a custom hook, since those cannot be enumerated on chain.
///
/// @dev WHY EITHER SOURCE IS SAFE. The conversion is self-service: a holder claims in their own transaction, with their
/// own `minOut` per leg, and the trackers refuse to run a claim inside a V4 unlock. Whoever plants or deepens a pool to
/// win a discovery -- or a front end that supplies a poor route -- can only produce a fill the holder's floor accepts.
/// Supplied routes are additionally validated before anything is paid: they must connect the input to that leg's asset
/// through a live pool, and may not route through the tracker's own feeder (the Realm AnyPairs tax hook).
library RealmAnyPairsRouteLib {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint8 internal constant VENUE_NONE = 0;
    uint8 internal constant VENUE_V3 = 1;
    uint8 internal constant VENUE_V4 = 2;

    error PartialFill();
    error BadRoute();

    struct Route {
        uint8 venue;
        uint24 fee;
        /// @dev V4 only.
        int24 tickSpacing;
        /// @dev What the chosen pool is paid in: the tracker's input token, or address(0) for a native-ETH V4 pool.
        address tokenIn;
        /// @dev V4 only. Always zero for a discovered route; whatever the caller named for a supplied one.
        address hooks;
        /// @dev In-range liquidity, for discovered routes (the ranking key). Zero for a supplied route.
        uint128 liquidity;
    }

    // ───────────────────────────── discovered ─────────────────────────────

    /// @notice The deepest route from `tokenIn` to `asset` right now. `venue == VENUE_NONE` when there is none.
    /// @param v3Factory Zero skips V3 (a tracker without a V3 router cannot use a V3 pool).
    /// @param poolManager Zero skips V4.
    /// @param probeNative Also consider V4 pools paired with NATIVE ETH instead of `tokenIn` (the ETH basket, whose
    /// `tokenIn` is WETH).
    function best(address v3Factory, address poolManager, address tokenIn, bool probeNative, address asset)
        internal
        view
        returns (Route memory r)
    {
        if (asset == tokenIn) return r;
        if (v3Factory != address(0)) {
            uint24[4] memory fees = [uint24(100), uint24(500), uint24(3000), uint24(10000)];
            for (uint256 i; i < fees.length; ++i) {
                address pool = IRealmAnyPairsV3Factory(v3Factory).getPool(tokenIn, asset, fees[i]);
                if (pool == address(0) || pool.code.length == 0) continue;
                uint128 liq;
                try IRealmAnyPairsV3Pool(pool).liquidity() returns (uint128 l) {
                    liq = l;
                } catch {
                    continue;
                }
                if (liq > r.liquidity) r = Route(VENUE_V3, fees[i], 0, tokenIn, address(0), liq);
            }
        }
        if (poolManager != address(0)) {
            r = _bestV4(IPoolManager(poolManager), tokenIn, asset, r);
            if (probeNative) r = _bestV4(IPoolManager(poolManager), address(0), asset, r);
        }
    }

    /// @dev The hookless V4 fee / tick-spacing pairs probed: the market tiers in use on Robinhood Chain plus Uniswap's
    /// standard (500,10) and (3000,60). Extreme-fee launch pools are deliberately not probed.
    function _bestV4(IPoolManager pm, address tokenIn, address asset, Route memory r)
        private
        view
        returns (Route memory)
    {
        uint24[7] memory fees =
            [uint24(100), uint24(500), uint24(500), uint24(2500), uint24(3000), uint24(10000), uint24(30000)];
        int24[7] memory spacings = [int24(1), int24(1), int24(10), int24(25), int24(60), int24(200), int24(200)];
        for (uint256 i; i < fees.length; ++i) {
            PoolId id = poolKey(tokenIn, asset, fees[i], spacings[i], address(0)).toId();
            (uint160 sqrtP,,,) = pm.getSlot0(id);
            if (sqrtP == 0) continue;
            uint128 liq = pm.getLiquidity(id);
            if (liq > r.liquidity) r = Route(VENUE_V4, fees[i], spacings[i], tokenIn, address(0), liq);
        }
        return r;
    }

    // ───────────────────────────── supplied ─────────────────────────────

    /// @notice A route SUPPLIED BY THE CALLER for one leg, validated, or {BadRoute}.
    /// @param route Either the 43-byte single-hop V3 path `abi.encodePacked(tokenIn, fee, asset)`, whose pool must exist
    /// on `v3Factory`; or an ABI-encoded V4 `PoolKey` (160 bytes) whose currencies are exactly `{tokenIn, asset}` -- or,
    /// when `allowNativeIn`, `{native ETH, asset}` -- which must be initialized on `poolManager`, and whose hook may be
    /// anything except `forbiddenHook`.
    /// @dev Validation only proves the route is a real, live pool between the right two tokens. It does not vouch for the
    /// price or for the hook's behaviour; the claimer's `minOut` is what bounds the fill, exactly as for a discovered
    /// route.
    function supplied(
        bytes memory route,
        address v3Factory,
        address poolManager,
        address tokenIn,
        bool allowNativeIn,
        address asset,
        address forbiddenHook
    ) internal view returns (Route memory r) {
        if (route.length == 43) {
            if (v3Factory == address(0)) revert BadRoute();
            (address a, uint24 fee, address b) = _decodeV3(route);
            if (a != tokenIn || b != asset) revert BadRoute();
            address pool = IRealmAnyPairsV3Factory(v3Factory).getPool(tokenIn, asset, fee);
            if (pool == address(0) || pool.code.length == 0) revert BadRoute();
            return Route(VENUE_V3, fee, 0, tokenIn, address(0), 0);
        }
        if (route.length == 160) {
            if (poolManager == address(0)) revert BadRoute();
            PoolKey memory k = abi.decode(route, (PoolKey));
            address c0 = Currency.unwrap(k.currency0);
            address c1 = Currency.unwrap(k.currency1);
            address paidIn;
            if ((c0 == tokenIn && c1 == asset) || (c0 == asset && c1 == tokenIn)) paidIn = tokenIn;
            else if (allowNativeIn && c0 == address(0) && c1 == asset) paidIn = address(0);
            else revert BadRoute();
            if (forbiddenHook != address(0) && address(k.hooks) == forbiddenHook) revert BadRoute();
            // An unsorted or never-initialized key reads a zero price here, so this also rejects malformed keys.
            (uint160 sqrtP,,,) = IPoolManager(poolManager).getSlot0(k.toId());
            if (sqrtP == 0) revert BadRoute();
            return Route(VENUE_V4, k.fee, k.tickSpacing, paidIn, address(k.hooks), 0);
        }
        revert BadRoute();
    }

    function _decodeV3(bytes memory path) private pure returns (address a, uint24 fee, address b) {
        assembly ("memory-safe") {
            a := shr(96, mload(add(path, 32)))
            fee := shr(232, mload(add(path, 52)))
            b := shr(96, mload(add(path, 55)))
        }
    }

    // ───────────────────────────── shared ─────────────────────────────

    /// @notice A V4 pool key for a pair, currencies sorted (native ETH is address(0), always currency0).
    function poolKey(address a, address b, uint24 fee, int24 tickSpacing, address hooks)
        internal
        pure
        returns (PoolKey memory)
    {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), fee, tickSpacing, IHooks(hooks));
    }

    /// @notice The single-hop V3 `exactInput` path for a V3 route.
    function v3Path(Route memory r, address asset) internal pure returns (bytes memory) {
        return abi.encodePacked(r.tokenIn, r.fee, asset);
    }

    /// @notice A route as the trackers' `basketLeg` views report it -- and in the same encoding a front end SUPPLIES one:
    /// the V3 path (43 bytes), the ABI-encoded V4 `PoolKey` (160 bytes), or empty when there is none.
    function encode(Route memory r, address asset) internal pure returns (bytes memory) {
        if (r.venue == VENUE_V3) return v3Path(r, asset);
        if (r.venue == VENUE_V4) return abi.encode(poolKey(r.tokenIn, asset, r.fee, r.tickSpacing, r.hooks));
        return "";
    }

    /// @notice INSIDE AN UNLOCK: swap exactly `amountIn` of `tokenIn` on `key`, requiring a COMPLETE fill, and return
    /// the output. A partial fill would leave the input only partly spent; it reverts instead.
    function swapExactIn(IPoolManager pm, PoolKey memory key, address tokenIn, uint256 amountIn)
        internal
        returns (uint256 out)
    {
        bool zeroForOne = Currency.unwrap(key.currency0) == tokenIn;
        BalanceDelta d = pm.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 inDelta = zeroForOne ? d.amount0() : d.amount1();
        int128 outDelta = zeroForOne ? d.amount1() : d.amount0();
        if (inDelta >= 0 || outDelta <= 0 || uint256(uint128(-inDelta)) != amountIn) revert PartialFill();
        out = uint256(uint128(outDelta));
    }

    /// @notice INSIDE AN UNLOCK: pay the PoolManager `amountIn` of `tokenIn` (native ETH from the caller's balance when
    /// `tokenIn` is address(0)) and send `out` of `asset` to `to`.
    function settleAndTake(IPoolManager pm, address tokenIn, uint256 amountIn, address asset, address to, uint256 out)
        internal
    {
        if (tokenIn == address(0)) {
            pm.settle{value: amountIn}();
        } else {
            pm.sync(Currency.wrap(tokenIn));
            IERC20(tokenIn).safeTransfer(address(pm), amountIn);
            pm.settle();
        }
        pm.take(Currency.wrap(asset), to, out);
    }
}
