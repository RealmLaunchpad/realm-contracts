// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";

import {RealmEtf} from "src/etf/RealmEtf.sol";
import {RealmEtfAssets} from "src/etf/RealmEtfAssets.sol";

/// @title RealmEtfFactory
/// @notice Anyone creates an ETF here, seeding it with USDG split by the weights they pick. The
///         creator owns the ETF (and alone rebalances it). `isEtf` is what `RealmEtfHook` trusts.
/// @dev Each ETF records `hook` at creation and trusts only that one for `redeemOnCredit`, so repointing the
///      hook (owner) affects ETFs created afterwards; earlier ones stay on the hook they were created with.
contract RealmEtfFactory is Ownable2Step {
    using SafeERC20 for IERC20;

    /// @notice Where every ETF's assets and routes are listed.
    RealmEtfAssets public immutable REGISTRY;

    /// @notice The `RealmEtfHook` new ETFs are created with. Zero: they get no pool.
    address public hook;

    /// @notice Etfs this factory deployed.
    mapping(address etf => bool) public isEtf;

    event EtfCreated(
        address indexed etf,
        address indexed creator,
        string name,
        string symbol,
        address[] assets,
        uint16[] weightsBps,
        uint256 seedAssets,
        uint256 shares
    );
    event HookSet(address indexed hook);

    constructor(address initialOwner, RealmEtfAssets registry) Ownable(initialOwner) {
        REGISTRY = registry;
    }

    /// @notice Sets the hook new ETFs are created with. Owner only.
    function setHook(address hook_) external onlyOwner {
        hook = hook_;
        emit HookSet(hook_);
    }

    /// @notice Deploys an ETF holding `assets`, owned by the caller, and seeds it with `seedAssets` USDG
    ///         pulled from the caller, split by `weightsBps` (summing to 10,000). The caller receives the shares.
    function createEtf(
        string calldata name,
        string calldata symbol,
        address[] calldata assets,
        uint16[] calldata weightsBps,
        uint256 seedAssets,
        uint256 minShares
    ) external returns (address etf) {
        RealmEtf b = new RealmEtf(name, symbol, msg.sender, REGISTRY, hook, assets);
        etf = address(b);
        isEtf[etf] = true;
        IERC20(REGISTRY.USDG()).safeTransferFrom(msg.sender, etf, seedAssets);
        uint256 shares = b.seed(seedAssets, weightsBps, msg.sender, minShares);
        emit EtfCreated(etf, msg.sender, name, symbol, assets, weightsBps, seedAssets, shares);
    }
}
