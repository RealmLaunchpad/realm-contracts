// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable, Ownable2Step} from "lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/// @notice The slice of `RealmAssetsWhitelist` baskets read: snapshot and live rates, whole units per native, x1e18.
interface IBasketRates {
    function unitsPerNativeX18(address asset) external view returns (uint256);
    function liveUnitsPerNativeX18(address asset) external view returns (uint256);
}

/// @dev The slice of Uniswap V3 this registry and the baskets read.
interface IBasketV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

interface IBasketV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

/// @title RealmBasketAssets
/// @notice The assets an ETF basket may hold, each with the ONE Uniswap pool it trades against USDG through:
///         a V3 pool or a V4 pool. Stricter than `RealmAssetsWhitelist` (the pairs list): an asset is here
///         only once its USDG route is proven, and it must also be priced there, because baskets value
///         their holdings and bound rebalances with those rates.
///
/// @dev TWO TIERS: the owner manages approvers, approvers list assets.
///
/// @dev ROUTES ARE NEVER CLEARED, only replaced. A basket swaps through the route on every deposit and
///      redemption, so clearing one would brick every basket holding the asset. Delisting (`setListed(false)`)
///      only stops baskets from buying INTO it by rebalance or creation; holders keep trading through it.
///      Replacing a route is how a drained or migrated pool is fixed, for every basket at once.
contract RealmBasketAssets is Ownable2Step {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @notice Where an asset trades against USDG. `NONE`: no route.
    enum Venue {
        NONE,
        V3,
        V4
    }

    /// @notice An asset's USDG pool: `pool` for V3, `key` for V4; the unused field is zero.
    struct Route {
        Venue venue;
        address pool;
        PoolKey key;
    }

    /// @notice The Uniswap V4 pool manager every V4 route lives on.
    IPoolManager public immutable POOL_MANAGER;

    /// @notice Uniswap's V3 factory; V3 routes must be pools it created.
    address public immutable UNIV3_FACTORY;

    /// @notice The basket deposit asset, the other side of every route.
    address public immutable USDG;

    /// @notice The pairs whitelist, whose rates price basket holdings.
    IBasketRates public immutable ASSETS_WHITELIST;

    /// @notice Addresses allowed to set routes and listings. Managed by the owner.
    mapping(address account => bool) public isApprover;

    /// @notice Whether baskets may buy INTO `asset` (creation, rebalance).
    mapping(address asset => bool) public isListed;

    mapping(address asset => Route) internal _routes;

    event ApproverSet(address indexed account, bool allowed);
    event RouteSet(address indexed asset, Route route);
    event ListedSet(address indexed asset, bool listed);

    error NotApprover();
    /// @notice The route is not a Uniswap pool between `asset` and USDG, or `asset` is USDG.
    error InvalidRoute();
    /// @notice `asset` has no rate in `ASSETS_WHITELIST`.
    error NotPriced();
    error NoRoute();

    constructor(address initialOwner, address poolManager, address univ3Factory, address usdg, address assetsWhitelist)
        Ownable(initialOwner)
    {
        POOL_MANAGER = IPoolManager(poolManager);
        UNIV3_FACTORY = univ3Factory;
        USDG = usdg;
        ASSETS_WHITELIST = IBasketRates(assetsWhitelist);
    }

    function setApprover(address account, bool allowed) external onlyOwner {
        isApprover[account] = allowed;
        emit ApproverSet(account, allowed);
    }

    /// @notice Sets (or replaces) `asset`'s USDG route and lists it. Approvers only.
    function setRoute(address asset, Route calldata route) external {
        require(isApprover[msg.sender], NotApprover());
        require(ASSETS_WHITELIST.unitsPerNativeX18(asset) != 0, NotPriced());
        _validate(asset, route);
        _routes[asset] = route;
        emit RouteSet(asset, route);
        _setListed(asset, true);
    }

    /// @notice Lists or delists `asset` without touching its route. Approvers only.
    function setListed(address asset, bool listed) external {
        require(isApprover[msg.sender], NotApprover());
        require(_routes[asset].venue != Venue.NONE, NoRoute());
        _setListed(asset, listed);
    }

    /// @notice `asset`'s USDG route. Reverts when it has none.
    function routeOf(address asset) external view returns (Route memory route) {
        route = _routes[asset];
        require(route.venue != Venue.NONE, NoRoute());
    }

    function _setListed(address asset, bool listed) private {
        isListed[asset] = listed;
        emit ListedSet(asset, listed);
    }

    function _validate(address asset, Route calldata route) private view {
        require(asset != USDG, InvalidRoute());
        address t0;
        address t1;
        if (route.venue == Venue.V3) {
            IBasketV3Pool pool = IBasketV3Pool(route.pool);
            (t0, t1) = (pool.token0(), pool.token1());
            require(IBasketV3Factory(UNIV3_FACTORY).getPool(t0, t1, pool.fee()) == route.pool, InvalidRoute());
        } else if (route.venue == Venue.V4) {
            (t0, t1) = (Currency.unwrap(route.key.currency0), Currency.unwrap(route.key.currency1));
            (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(route.key.toId());
            require(sqrtPriceX96 != 0, InvalidRoute());
        } else {
            revert InvalidRoute();
        }
        require((t0 == asset && t1 == USDG) || (t0 == USDG && t1 == asset), InvalidRoute());
    }
}
