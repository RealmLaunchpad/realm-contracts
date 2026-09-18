// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "lib/v4-core/src/types/PoolId.sol";
import {Currency} from "lib/v4-core/src/types/Currency.sol";
import {StateLibrary} from "lib/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "lib/v4-core/src/libraries/FullMath.sol";

/// @title RealmAssetsWhitelist
/// @notice The ERC20 assets the protocol has vetted, each with the Uniswap V4 pool that prices it and its
///         value in the chain's native currency. An asset is whitelisted while its `unitsPerNativeX18` is
///         non-zero.
///
/// @dev TWO TIERS, like every operational allowlist here, but stricter at the top: the owner is a cold
///      multisig that manages APPROVERS and cannot whitelist anything itself. Approvers are hot keys
///      (an agent reviewing listing requests) doing the frequent, low-stakes work.
///
/// @dev PRICED BY ITS POOL. An approver lists an asset with the one V4 pool holding its main liquidity,
///      against native or against a REFERENCE asset — one already listed directly against native, such
///      as a main stablecoin. The rate is read from that pool (and the reference's rate) at listing time
///      and stored, so the approver never types a number, and so decimals cannot slip: they come from
///      the tokens. Integrators read `pricePool` to price the asset live.
///
/// @dev THE RATE IS A SNAPSHOT, deliberately. A live read at the consumer would let anyone push the pool
///      and unwind it around their own call for the price of two swap fees. Approvers refresh it by
///      listing the asset again; on a chain with a public mempool, through private orderflow, since a
///      sandwiched listing would snapshot a pushed price.
///
/// @dev NOT UPGRADEABLE: two mappings, a role and two setters.
contract RealmAssetsWhitelist is Ownable2Step {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @notice The Uniswap V4 pool manager every `pricePool` lives on.
    IPoolManager public immutable POOL_MANAGER;

    /// @notice Addresses allowed to whitelist assets. Managed by the owner.
    mapping(address account => bool) public isApprover;

    /// @notice Whole units of `asset` worth one whole unit of the chain's native currency, scaled by 1e18,
    ///         as of its last listing. Zero means not whitelisted. Whole units: 3,500 USDC per ETH is
    ///         `3500e18`, whatever the asset's decimals.
    mapping(address asset => uint256) public unitsPerNativeX18;

    /// @notice The V4 pool `asset` was priced from: against native, or against a reference asset that is
    ///         itself priced against native.
    mapping(address asset => PoolKey) public pricePool;

    event ApproverSet(address indexed account, bool allowed);
    event WhitelistUpdated(address indexed asset, uint256 unitsPerNativeX18, PoolKey pricePool);

    error NotApprover();
    /// @notice The pool does not hold `asset`, is not live with in-range liquidity, or its other side is
    ///         neither native nor an asset listed directly against native.
    error InvalidPricePool();

    /// @param initialOwner cold multisig: manages approvers, nothing else
    constructor(address initialOwner, address poolManager) Ownable(initialOwner) {
        POOL_MANAGER = IPoolManager(poolManager);
    }

    /// @notice Allow or revoke an approver. Owner only.
    function setApprover(address account, bool allowed) external onlyOwner {
        isApprover[account] = allowed;
        emit ApproverSet(account, allowed);
    }

    /// @notice Whitelist `asset`, or refresh its rate, priced from `key`. An all-zero `key` removes it.
    ///         Approvers only.
    function setWhitelisted(address asset, PoolKey calldata key) external {
        require(isApprover[msg.sender], NotApprover());
        // Native always sorts first, so a real pool never has native as `currency1`.
        uint256 rate = Currency.unwrap(key.currency1) == address(0) ? 0 : _rateFrom(asset, key);
        unitsPerNativeX18[asset] = rate;
        pricePool[asset] = key;
        emit WhitelistUpdated(asset, rate, key);
    }

    /// @dev `asset`'s whole units per whole native, scaled by 1e18, from `key`'s spot price.
    function _rateFrom(address asset, PoolKey calldata key) private view returns (uint256 rate) {
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        require(asset == c0 || asset == c1, InvalidPricePool());
        address other = asset == c0 ? c1 : c0;

        // The other side's own rate and decimals: native is one per native at 18.
        (uint256 otherRate, uint256 otherDecimals) = (1e18, 18);
        if (other != address(0)) {
            otherRate = unitsPerNativeX18[other];
            // One hop from native at most: the reference must itself be priced against native.
            require(otherRate != 0 && Currency.unwrap(pricePool[other].currency0) == address(0), InvalidPricePool());
            otherDecimals = IERC20Metadata(other).decimals();
        }

        PoolId id = key.toId();
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(id);
        require(sqrtPriceX96 != 0 && POOL_MANAGER.getLiquidity(id) != 0, InvalidPricePool());

        // Raw currency1 per raw currency0 in Q128, then raw `asset` per raw `other`.
        uint256 priceX128 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
        uint256 rawPerOtherX128 = asset == c1 ? priceX128 : FullMath.mulDiv(1 << 128, 1 << 128, priceX128);

        // Whole asset per whole native = raw ratio * 10^otherDecimals / 10^assetDecimals * otherRate.
        uint256 assetDecimals = IERC20Metadata(asset).decimals();
        rate = FullMath.mulDiv(rawPerOtherX128, otherRate * 10 ** otherDecimals, (1 << 128) * 10 ** assetDecimals);
        require(rate != 0, InvalidPricePool());
    }
}
