// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import {IRealmCreatorVaultFactory} from "src/interfaces/IRealmCreatorVaultFactory.sol";
import {RealmCreatorVault} from "src/vaults/RealmCreatorVault.sol";

/// @title RealmCreatorVaultFactory
/// @notice UUPS-upgradeable factory that deploys minimal-proxy `RealmCreatorVault` clones. The vault
///         implementation is baked into this factory's bytecode as an immutable; upgrading the
///         factory (new impl + `upgradeTo`) is the mechanism to point FUTURE vaults at a new
///         implementation. Already-deployed clones keep their implementation forever.
/// @dev    `createVault` is permissionless by design and funds the vault itself, pulling `amount`
///         from the caller. That makes every `CreatorVaultDeployed` a funded vault by construction,
///         so off-chain consumers (the indexer) can trust the event's `amount` without a caller
///         allowlist. The Realm token factory uses it at launch for creator-locked supply; any
///         holder can use it later to lock their own tokens.
contract RealmCreatorVaultFactory is IRealmCreatorVaultFactory, Initializable, OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice The `RealmCreatorVault` implementation cloned for every new vault.
    address public immutable VAULT_IMPLEMENTATION;

    /// @notice Sets the vault implementation on the factory implementation and locks the impl's
    ///         storage so only proxies can be initialized.
    constructor(address vaultImplementation) {
        VAULT_IMPLEMENTATION = vaultImplementation;
        _disableInitializers();
    }

    /// @notice One-shot proxy initializer. Sets `msg.sender` as the initial owner.
    function initialize() external initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
    }

    /// @dev UUPS upgrade gate: only the owner can swap the implementation.
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @inheritdoc IRealmCreatorVaultFactory
    function createVault(address token, address owner, uint256 amount, uint256 cliffSeconds, uint256 vestingSeconds)
        external
        returns (address vault)
    {
        vault = Clones.clone(VAULT_IMPLEMENTATION);
        RealmCreatorVault(payable(vault)).initialize(token, owner, amount, cliffSeconds, vestingSeconds);
        // Fund before emitting so the event never describes an empty vault.
        IERC20(token).safeTransferFrom(msg.sender, vault, amount);
        emit CreatorVaultDeployed(vault, token, owner, amount, cliffSeconds, vestingSeconds);
    }

    /// @dev Reserved for future storage variables. Decrement when adding new storage to keep the
    ///      proxy's slot layout stable across upgrades.
    uint256[50] private __gap;
}
