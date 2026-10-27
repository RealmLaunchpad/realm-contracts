// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {
    Ownable2StepUpgradeable
} from "lib/openzeppelin-contracts-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {RealmEtf} from "src/etf/RealmEtf.sol";
import {RealmEtfAssets} from "src/etf/RealmEtfAssets.sol";
import {RealmAssetsWhitelist} from "src/access/RealmAssetsWhitelist.sol";
// `RealmAssetsWhitelist` is built on `lib/v4-core`, whose structs are distinct types from `@uniswap`'s.
import {PoolKey as WhitelistPoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {Currency as WhitelistCurrency} from "lib/v4-core/src/types/Currency.sol";
import {IHooks as WhitelistIHooks} from "lib/v4-core/src/interfaces/IHooks.sol";

/// @title RealmEtfFactory
/// @notice Anyone creates an ETF here, seeding it with USDG split by the weights they pick. The
///         creator owns the ETF (and alone proposes its rebalances). `isEtf` is what `RealmEtfHook` trusts.
///         With a hook set, every new ETF is also listed in `ASSETS_WHITELIST` as a direct-venue quote at its
///         NAV (`Venue.VAULT`): its liquidity is its components', already vetted in `REGISTRY`.
/// @dev Each ETF records `hook` at creation and trusts only that one for `redeemOnCredit`, so repointing the
///      hook (owner) affects ETFs created afterwards; earlier ones stay on the hook they were created with.
/// @dev UPGRADEABLE (UUPS, owner-authorised) because the hook bakes this address in: an upgrade ships new
///      creation logic (a new `RealmEtf` version) while every hook, pool and `isEtf` entry stays valid. ETFs
///      themselves are plain contracts, so an upgrade never touches an existing one.
contract RealmEtfFactory is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice Contract version.
    uint256 public constant VERSION = 2;

    /// @notice Where every ETF's assets and routes are listed.
    /// @dev Implementation immutable: the proxy reads it from the implementation's bytecode.
    RealmEtfAssets public immutable REGISTRY;

    /// @notice Where every new ETF is listed as a launch quote. This factory must be one of its approvers.
    /// @dev Implementation immutable: the proxy reads it from the implementation's bytecode.
    RealmAssetsWhitelist public immutable ASSETS_WHITELIST;

    /// @notice The `RealmEtfHook` new ETFs are created with. Zero: they get no pool.
    address public hook;

    /// @notice Etfs this factory deployed.
    mapping(address etf => bool) public isEtf;

    /// @notice Least USDG (6 decimals) `createEtf` accepts as seed.
    uint256 public minSeedAssets;

    event EtfCreated(
        address indexed etf,
        address indexed creator,
        string name,
        string symbol,
        RealmEtf.Mode mode,
        address[] assets,
        uint16[] weightsBps,
        uint256 seedAssets,
        uint256 shares
    );
    event HookSet(address indexed hook);
    event MinSeedAssetsSet(uint256 minSeedAssets);

    error SeedTooSmall();

    constructor(RealmEtfAssets registry, RealmAssetsWhitelist assetsWhitelist) {
        REGISTRY = registry;
        ASSETS_WHITELIST = assetsWhitelist;
        _disableInitializers();
    }

    /// @param initialOwner cold multisig: sets the hook and upgrades
    function initialize(address initialOwner) external initializer {
        __Ownable_init(initialOwner);
        minSeedAssets = 1_000e6;
    }

    /// @notice Sets the hook new ETFs are created with. Owner only.
    function setHook(address hook_) external onlyOwner {
        hook = hook_;
        emit HookSet(hook_);
    }

    /// @notice Sets the least USDG `createEtf` accepts as seed. Owner only.
    function setMinSeedAssets(uint256 minSeedAssets_) external onlyOwner {
        minSeedAssets = minSeedAssets_;
        emit MinSeedAssetsSet(minSeedAssets_);
    }

    /// @notice Deploys an ETF holding `assets`, owned by the caller, and seeds it with `seedAssets` USDG
    ///         pulled from the caller, split by `weightsBps` (summing to 10,000). The caller receives the shares.
    ///         `mode` (immutable) bounds the creator's rebalances. Reverts below `minSeedAssets`, or if any
    ///         asset's seed buy gets less than its `minAmountsOut` entry (same order as `assets`). With a hook
    ///         set, lists the ETF in `ASSETS_WHITELIST`, and reverts if it cannot: USDG not listed against
    ///         native, or this factory not an approver.
    function createEtf(
        string memory name,
        string memory symbol,
        RealmEtf.Mode mode,
        address[] calldata assets,
        uint16[] calldata weightsBps,
        uint256 seedAssets,
        uint256[] calldata minAmountsOut
    ) external returns (address etf) {
        if (seedAssets < minSeedAssets) revert SeedTooSmall();
        RealmEtf b = new RealmEtf(name, symbol, msg.sender, REGISTRY, hook, mode, assets);
        etf = address(b);
        isEtf[etf] = true;
        IERC20(REGISTRY.USDG()).safeTransferFrom(msg.sender, etf, seedAssets);
        uint256 shares = b.seed(seedAssets, weightsBps, msg.sender, minAmountsOut);
        if (hook != address(0)) _initializePool(etf, seedAssets, b.totalSupply());
        emit EtfCreated(etf, msg.sender, name, symbol, mode, assets, weightsBps, seedAssets, shares);
        if (hook != address(0)) _listAsQuote(etf);
    }

    /// @dev Lists `etf` as a launch quote at its NAV through USDG, its pool (the one `_initializePool` opened)
    ///      only routing dev-buy zaps. After `EtfCreated`, so indexers see the ETF before its listing.
    function _listAsQuote(address etf) internal {
        address usdgToken = REGISTRY.USDG();
        (address c0, address c1) = etf < usdgToken ? (etf, usdgToken) : (usdgToken, etf);
        ASSETS_WHITELIST.setWhitelisted(
            etf,
            RealmAssetsWhitelist.PriceSource({
                venue: RealmAssetsWhitelist.Venue.VAULT,
                pool: etf,
                key: WhitelistPoolKey(
                    WhitelistCurrency.wrap(c0), WhitelistCurrency.wrap(c1), 0, 1, WhitelistIHooks(hook)
                )
            })
        );
    }

    /// @dev Opens the ETF's shares/USDG pool at the seed price (`usdg` for `shares`), so the hook's first JIT
    ///      price move is short. Atomic with creation: the hook accepts no pool before `isEtf` is set.
    function _initializePool(address etf, uint256 usdg, uint256 shares) internal {
        address usdgToken = REGISTRY.USDG();
        bool etfIs0 = etf < usdgToken;
        (address c0, address c1) = etfIs0 ? (etf, usdgToken) : (usdgToken, etf);
        uint160 sqrtPriceX96 =
            uint160(Math.sqrt(etfIs0 ? Math.mulDiv(usdg, 1 << 192, shares) : Math.mulDiv(shares, 1 << 192, usdg)));
        REGISTRY.POOL_MANAGER()
            .initialize(PoolKey(Currency.wrap(c0), Currency.wrap(c1), 0, 1, IHooks(hook)), sqrtPriceX96);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
