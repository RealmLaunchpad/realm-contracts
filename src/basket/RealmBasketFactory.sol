// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {RealmBasket} from "src/basket/RealmBasket.sol";
import {RealmBasketAssets} from "src/basket/RealmBasketAssets.sol";

/// @title RealmBasketFactory
/// @notice Anyone creates an ETF basket here, seeding it with USDG split by the weights they pick. The
///         creator owns the basket (and alone rebalances it). `isBasket` is what `RealmBasketHook` trusts.
/// @dev Deployed BY the hook, in its constructor, so each side knows the other without a setter.
contract RealmBasketFactory {
    using SafeERC20 for IERC20;

    /// @notice Where every basket's assets and routes are listed.
    RealmBasketAssets public immutable REGISTRY;

    /// @notice The `RealmBasketHook` that deployed this factory, trusted by every basket for `redeemOnCredit`.
    address public immutable HOOK;

    /// @notice Baskets this factory deployed.
    mapping(address basket => bool) public isBasket;

    event BasketCreated(
        address indexed basket,
        address indexed creator,
        string name,
        string symbol,
        address[] assets,
        uint16[] weightsBps,
        uint256 seedAssets,
        uint256 shares
    );

    constructor(RealmBasketAssets registry) {
        REGISTRY = registry;
        HOOK = msg.sender;
    }

    /// @notice Deploys a basket holding `assets`, owned by the caller, and seeds it with `seedAssets` USDG
    ///         pulled from the caller, split by `weightsBps` (summing to 10,000). The caller receives the shares.
    function createBasket(
        string calldata name,
        string calldata symbol,
        address[] calldata assets,
        uint16[] calldata weightsBps,
        uint256 seedAssets,
        uint256 minShares
    ) external returns (address basket) {
        RealmBasket b = new RealmBasket(name, symbol, msg.sender, REGISTRY, HOOK, assets);
        basket = address(b);
        isBasket[basket] = true;
        IERC20(REGISTRY.USDG()).safeTransferFrom(msg.sender, basket, seedAssets);
        uint256 shares = b.seed(seedAssets, weightsBps, msg.sender, minShares);
        emit BasketCreated(basket, msg.sender, name, symbol, assets, weightsBps, seedAssets, shares);
    }
}
