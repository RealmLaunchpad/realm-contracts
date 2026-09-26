// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {
    Ownable2StepUpgradeable
} from "lib/openzeppelin-contracts-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "lib/v4-core/src/types/PoolId.sol";
import {Currency} from "lib/v4-core/src/types/Currency.sol";
import {StateLibrary} from "lib/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "lib/v4-core/src/libraries/FullMath.sol";
import {IUniswapV2Factory} from "src/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "src/interfaces/IUniswapV2Pair.sol";

/// @dev The slice of Uniswap V3 this contract reads.
interface IUniswapV3PoolState {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function liquidity() external view returns (uint128);
    function slot0() external view returns (uint160 sqrtPriceX96, int24, uint16, uint16, uint16, uint8, bool);
}

interface IUniswapV3FactoryPools {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

/// @title RealmAssetsWhitelist
/// @notice The ERC20 assets the protocol has vetted, each with the Uniswap pool that prices it — V2, V3
///         or V4 — and its value in the chain's native currency. An asset is whitelisted while its
///         `unitsPerNativeX18` is non-zero.
///
/// @dev TWO TIERS, like every operational allowlist here, but stricter at the top: the owner is a cold
///      multisig that manages APPROVERS (and upgrades) and cannot whitelist anything itself. Approvers
///      are hot keys (the team reviewing listing requests by hand, an agent later) doing the frequent,
///      low-stakes work.
///
/// @dev PRICED BY ITS POOL. An approver lists an asset with the pool holding its main liquidity, against
///      native (WETH counts as native) or against a REFERENCE asset — one already listed directly
///      against native, such as a main stablecoin. V2 pairs and V3 pools must be the ones Uniswap's own
///      factory returns for their tokens, so a lookalike contract cannot be listed. The rate is read
///      from that pool (and the reference's rate) at listing time and stored, so the approver never
///      types a number and decimals cannot slip: they come from the tokens. Integrators read
///      `priceSource` to price the asset live.
///
/// @dev THE RATE IS A SNAPSHOT, deliberately. A live read at the consumer would let anyone push the pool
///      and unwind it around their own call for the price of two swap fees. Approvers refresh it by
///      listing the asset again; on a chain with a public mempool, through private orderflow, since a
///      sandwiched listing would snapshot a pushed price. Re-listing a reference does not reprice the
///      assets listed against it. `liveUnitsPerNativeX18` re-reads the same sources on demand, for a
///      consumer that accepts that risk (the direct factory's launch price, bounded by the snapshot).
///
/// @dev UPGRADEABLE (UUPS, owner-authorised) because its pricing rules are expected to grow, and the
///      direct factory bakes this address in: an upgrade keeps every listing and the factory untouched.
///      The Uniswap addresses are implementation immutables, set per chain by the deploy script; a zero
///      factory means that venue does not exist on the chain and its listings are refused.
contract RealmAssetsWhitelist is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @notice Where a price comes from. `NONE` delists.
    enum Venue {
        NONE,
        V2,
        V3,
        V4
    }

    /// @notice A listing's price pool: `pool` is the V2 pair or V3 pool, `key` the V4 pool. The unused
    ///         field is zero.
    struct PriceSource {
        Venue venue;
        address pool;
        PoolKey key;
    }

    /// @notice The Uniswap V4 pool manager every V4 source lives on.
    IPoolManager public immutable POOL_MANAGER;

    /// @notice The chain's wrapped native, which prices as native.
    address public immutable WETH;

    /// @notice Uniswap's V2 factory, or zero where V2 is not deployed.
    address public immutable UNIV2_FACTORY;

    /// @notice Uniswap's V3 factory, or zero where V3 is not deployed.
    address public immutable UNIV3_FACTORY;

    /// @notice Addresses allowed to whitelist assets. Managed by the owner.
    mapping(address account => bool) public isApprover;

    /// @notice Whole units of `asset` worth one whole unit of the chain's native currency, scaled by 1e18,
    ///         as of its last listing. Zero means not whitelisted. Whole units: 3,500 USDC per ETH is
    ///         `3500e18`, whatever the asset's decimals.
    mapping(address asset => uint256) public unitsPerNativeX18;

    /// @notice The asset `asset` was priced against: zero for native (or WETH), else the reference.
    mapping(address asset => address) public referenceOf;

    mapping(address asset => PriceSource) internal _priceSources;

    event ApproverSet(address indexed account, bool allowed);
    event WhitelistUpdated(address indexed asset, uint256 unitsPerNativeX18, PriceSource source);

    error NotApprover();
    /// @notice The source's venue is unavailable here, its pool is not Uniswap's, does not hold `asset`,
    ///         is not live with liquidity, or its other side is neither native (nor WETH) nor an asset
    ///         listed directly against native.
    error InvalidPriceSource();

    /// @dev Implementation immutables: the proxy reads them from the implementation's bytecode.
    constructor(address poolManager, address weth, address univ2Factory, address univ3Factory) {
        POOL_MANAGER = IPoolManager(poolManager);
        WETH = weth;
        UNIV2_FACTORY = univ2Factory;
        UNIV3_FACTORY = univ3Factory;
        _disableInitializers();
    }

    /// @param initialOwner cold multisig: manages approvers and upgrades, nothing else
    function initialize(address initialOwner) external initializer {
        __Ownable_init(initialOwner);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
    }

    /// @notice Allow or revoke an approver. Owner only.
    function setApprover(address account, bool allowed) external onlyOwner {
        isApprover[account] = allowed;
        emit ApproverSet(account, allowed);
    }

    /// @notice Whitelist `asset`, or refresh its rate, priced from `source`. A `NONE` source removes it.
    ///         Approvers only.
    function setWhitelisted(address asset, PriceSource calldata source) external {
        require(isApprover[msg.sender], NotApprover());
        uint256 rate;
        address ref;
        if (source.venue != Venue.NONE) (rate, ref) = _rateFrom(asset, source, false);
        unitsPerNativeX18[asset] = rate;
        referenceOf[asset] = ref;
        _priceSources[asset] = source;
        emit WhitelistUpdated(asset, rate, source);
    }

    /// @notice The pool `asset` was priced from, for integrators pricing it live.
    function priceSource(address asset) external view returns (PriceSource memory) {
        return _priceSources[asset];
    }

    /// @notice `unitsPerNativeX18` re-read NOW from the stored price source (and the reference's, for an
    ///         asset listed against one), through the same math as the listing snapshot. Zero when
    ///         `asset` is not whitelisted.
    /// @dev A spot read: anyone can move it within a transaction. The snapshot stays the listing gate;
    ///      consumers using this accept the manipulation risk (the direct factory bounds it by the
    ///      snapshot, see `RealmFactoryUniV4Direct._launchTick`).
    function liveUnitsPerNativeX18(address asset) public view returns (uint256 rate) {
        if (unitsPerNativeX18[asset] == 0) return 0;
        (rate,) = _rateFrom(asset, _priceSources[asset], true);
    }

    /// @dev `asset`'s whole units per whole native, scaled by 1e18, from `source`'s spot price, and the
    ///      reference it was priced against (zero for native). `live` prices the reference at its live
    ///      rate instead of its snapshot.
    function _rateFrom(address asset, PriceSource memory source, bool live)
        private
        view
        returns (uint256 rate, address ref)
    {
        (address t0, address t1, uint256 priceX128) = _spot(source);
        require(asset == t0 || asset == t1, InvalidPriceSource());
        ref = asset == t0 ? t1 : t0;
        if (ref == WETH) ref = address(0);

        // The other side's own rate and decimals: native is one per native at 18.
        (uint256 refRate, uint256 refDecimals) = (1e18, 18);
        if (ref != address(0)) {
            refRate = live ? liveUnitsPerNativeX18(ref) : unitsPerNativeX18[ref];
            // One hop from native at most: the reference must itself be priced against native.
            require(refRate != 0 && referenceOf[ref] == address(0), InvalidPriceSource());
            refDecimals = IERC20Metadata(ref).decimals();
        }

        // Raw `asset` per raw reference, Q128.
        uint256 rawPerRefX128 = asset == t1 ? priceX128 : FullMath.mulDiv(1 << 128, 1 << 128, priceX128);
        // Whole asset per whole native = raw ratio * 10^refDecimals / 10^assetDecimals * refRate.
        uint256 assetDecimals = IERC20Metadata(asset).decimals();
        rate = FullMath.mulDiv(rawPerRefX128, refRate * 10 ** refDecimals, (1 << 128) * 10 ** assetDecimals);
        require(rate != 0, InvalidPriceSource());
    }

    /// @dev The source pool's two tokens (zero for native) and its spot price as raw token1 per raw
    ///      token0 in Q128, after checking it is Uniswap's and live with liquidity.
    function _spot(PriceSource memory source) private view returns (address t0, address t1, uint256 priceX128) {
        uint160 sqrtPriceX96;
        if (source.venue == Venue.V4) {
            (t0, t1) = (Currency.unwrap(source.key.currency0), Currency.unwrap(source.key.currency1));
            PoolId id = source.key.toId();
            (sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(id);
            require(sqrtPriceX96 != 0 && POOL_MANAGER.getLiquidity(id) != 0, InvalidPriceSource());
        } else if (source.venue == Venue.V3) {
            IUniswapV3PoolState pool = IUniswapV3PoolState(source.pool);
            (t0, t1) = (pool.token0(), pool.token1());
            require(
                UNIV3_FACTORY != address(0)
                    && IUniswapV3FactoryPools(UNIV3_FACTORY).getPool(t0, t1, pool.fee()) == source.pool,
                InvalidPriceSource()
            );
            (sqrtPriceX96,,,,,,) = pool.slot0();
            require(sqrtPriceX96 != 0 && pool.liquidity() != 0, InvalidPriceSource());
        } else {
            IUniswapV2Pair pair = IUniswapV2Pair(source.pool);
            (t0, t1) = (pair.token0(), pair.token1());
            require(
                UNIV2_FACTORY != address(0) && IUniswapV2Factory(UNIV2_FACTORY).getPair(t0, t1) == source.pool,
                InvalidPriceSource()
            );
            (uint112 r0, uint112 r1,) = pair.getReserves();
            require(r0 != 0 && r1 != 0, InvalidPriceSource());
            return (t0, t1, FullMath.mulDiv(r1, 1 << 128, r0));
        }
        // Raw token1 per raw token0 = sqrtPrice^2 / 2^192; in Q128 that is sqrtPrice^2 / 2^64.
        priceX128 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
