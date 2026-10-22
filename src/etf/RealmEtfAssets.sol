// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {
    Ownable2StepUpgradeable
} from "lib/openzeppelin-contracts-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

/// @dev The slice of Uniswap V3 this registry and the ETFs read.
interface IEtfV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function slot0() external view returns (uint160 sqrtPriceX96, int24, uint16, uint16, uint16, uint8, bool);
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

interface IEtfV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

/// @dev The slice of Uniswap V2 this registry and the ETFs read.
interface IEtfV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IEtfV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address);
}

/// @title RealmEtfAssets
/// @notice The assets an ETF may hold, each with the ONE Uniswap pool it trades against USDG through:
///         a V2 pair, a V3 pool or a V4 pool. Stricter than `RealmAssetsWhitelist` (the pairs list): an asset is here
///         only once its USDG route is proven. The route also prices the asset (`usdgValueOf`), at spot.
///
/// @dev TWO TIERS: the owner (cold multisig) manages approvers and upgrades, approvers list assets.
///
/// @dev UPGRADEABLE (UUPS, owner-authorised) because every ETF bakes this address in: an upgrade fixes pricing,
///      validation or listing rules for all of them at once. It cannot teach an existing ETF a new venue (the
///      swap code is in the ETF). What a malicious upgrade can reach is bounded by the ETF: it can misprice and
///      misroute the swaps in flight (a deposit's USDG, a redemption's slice, a rebalance), never the holdings
///      at rest, since an ETF pays each swap at most its exact input (`RealmEtf.uniswapV3SwapCallback`).
///
/// @dev ROUTES ARE NEVER CLEARED, only replaced. An ETF swaps through the route on every deposit and
///      redemption, so clearing one would brick every ETF holding the asset. Delisting (`setListed(false)`)
///      only stops ETFs from buying INTO it by rebalance or creation; holders keep trading through it.
///      Replacing a route is how a drained or migrated pool is fixed, for every ETF at once.
///
/// @dev SUNSET is for a dead TOKEN (delisted, acquired, paused for good), which no route can fix: ETFs stop
///      buying, selling and valuing it, so their deposits and redemptions work again, but still hand it out in
///      `redeemInKind`. Owner only and one-way. A malicious owner can cut ETFs' NAV with it, but moves nothing.
contract RealmEtfAssets is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @notice Where an asset trades against USDG. `NONE`: no route.
    enum Venue {
        NONE,
        V3,
        V4,
        V2
    }

    /// @notice An asset's USDG pool: `pool` for V2 and V3, `key` for V4; the unused field is zero.
    struct Route {
        Venue venue;
        address pool;
        PoolKey key;
    }

    /// @notice Contract version.
    uint256 public constant VERSION = 1;

    /// @notice The Uniswap V4 pool manager every V4 route lives on.
    /// @dev This and the other immutables live in the implementation's bytecode. ETFs copy `POOL_MANAGER` and
    ///      `USDG` at creation, so an upgrade must keep both.
    IPoolManager public immutable POOL_MANAGER;

    /// @notice Uniswap's V3 factory; V3 routes must be pools it created.
    address public immutable UNIV3_FACTORY;

    /// @notice Uniswap's V2 factory; V2 routes must be pairs it created.
    address public immutable UNIV2_FACTORY;

    /// @notice The ETF deposit asset, the other side of every route.
    address public immutable USDG;

    /// @notice Addresses allowed to set routes and listings. Managed by the owner.
    mapping(address account => bool) public isApprover;

    /// @notice Whether ETFs may buy INTO `asset` (creation, rebalance).
    mapping(address asset => bool) public isListed;

    /// @notice Assets retired for every ETF (see the contract docstring). One-way.
    mapping(address asset => bool) public isSunset;

    mapping(address asset => Route) internal _routes;

    event ApproverSet(address indexed account, bool allowed);
    event RouteSet(address indexed asset, Route route);
    event ListedSet(address indexed asset, bool listed);
    event AssetSunset(address indexed asset);

    error NotApprover();
    /// @notice The route is not a Uniswap pool between `asset` and USDG, or `asset` is USDG or the native
    ///         currency (ETFs hold ERC20s only).
    error InvalidRoute();
    error NoRoute();

    constructor(address poolManager, address univ3Factory, address univ2Factory, address usdg) {
        POOL_MANAGER = IPoolManager(poolManager);
        UNIV3_FACTORY = univ3Factory;
        UNIV2_FACTORY = univ2Factory;
        USDG = usdg;
        _disableInitializers();
    }

    /// @param initialOwner cold multisig: manages approvers, sunsets assets and upgrades
    function initialize(address initialOwner) external initializer {
        __Ownable_init(initialOwner);
    }

    function setApprover(address account, bool allowed) external onlyOwner {
        isApprover[account] = allowed;
        emit ApproverSet(account, allowed);
    }

    /// @notice Sets (or replaces) `asset`'s USDG route and lists it. Approvers only.
    function setRoute(address asset, Route calldata route) external {
        require(isApprover[msg.sender], NotApprover());
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

    /// @notice Retires `asset` for every ETF, for good. Owner only.
    function sunset(address asset) external onlyOwner {
        isSunset[asset] = true;
        emit AssetSunset(asset);
    }

    /// @notice `asset`'s USDG route. Reverts when it has none.
    function routeOf(address asset) external view returns (Route memory route) {
        route = _routes[asset];
        require(route.venue != Venue.NONE, NoRoute());
    }

    /// @notice `amount` of `asset` in raw USDG at its route pool's SPOT price, before fees and impact.
    /// @dev Anyone can move it within a transaction: fit for estimates and for splitting a deposit (where a
    ///      wrong price costs only the depositor), never for anything a manipulator could profit from.
    function usdgValueOf(address asset, uint256 amount) external view returns (uint256) {
        Route memory route = _routes[asset];
        require(route.venue != Venue.NONE, NoRoute());
        if (route.venue == Venue.V2) {
            (uint112 r0, uint112 r1,) = IEtfV2Pair(route.pool).getReserves();
            return IEtfV2Pair(route.pool).token0() == asset ? Math.mulDiv(amount, r1, r0) : Math.mulDiv(amount, r0, r1);
        }
        uint160 sqrtPriceX96;
        bool assetIsToken0;
        if (route.venue == Venue.V3) {
            (sqrtPriceX96,,,,,,) = IEtfV3Pool(route.pool).slot0();
            assetIsToken0 = IEtfV3Pool(route.pool).token0() == asset;
        } else {
            (sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(route.key.toId());
            assetIsToken0 = Currency.unwrap(route.key.currency0) == asset;
        }
        // Raw token1 per raw token0, Q128.
        uint256 priceX128 = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
        return assetIsToken0 ? Math.mulDiv(amount, priceX128, 1 << 128) : Math.mulDiv(amount, 1 << 128, priceX128);
    }

    function _setListed(address asset, bool listed) private {
        isListed[asset] = listed;
        emit ListedSet(asset, listed);
    }

    function _validate(address asset, Route calldata route) private view {
        require(asset != USDG && asset != address(0), InvalidRoute());
        address t0;
        address t1;
        if (route.venue == Venue.V3) {
            IEtfV3Pool pool = IEtfV3Pool(route.pool);
            (t0, t1) = (pool.token0(), pool.token1());
            require(IEtfV3Factory(UNIV3_FACTORY).getPool(t0, t1, pool.fee()) == route.pool, InvalidRoute());
        } else if (route.venue == Venue.V4) {
            (t0, t1) = (Currency.unwrap(route.key.currency0), Currency.unwrap(route.key.currency1));
            (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(route.key.toId());
            require(sqrtPriceX96 != 0, InvalidRoute());
        } else if (route.venue == Venue.V2) {
            IEtfV2Pair pair = IEtfV2Pair(route.pool);
            (t0, t1) = (pair.token0(), pair.token1());
            require(IEtfV2Factory(UNIV2_FACTORY).getPair(t0, t1) == route.pool, InvalidRoute());
            // An unfunded pair has no price, and `usdgValueOf` divides by its reserves.
            (uint112 r0, uint112 r1,) = pair.getReserves();
            require(r0 != 0 && r1 != 0, InvalidRoute());
        } else {
            revert InvalidRoute();
        }
        require((t0 == asset && t1 == USDG) || (t0 == USDG && t1 == asset), InvalidRoute());
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
