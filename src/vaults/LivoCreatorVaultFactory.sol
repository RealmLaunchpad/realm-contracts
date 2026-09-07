// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import {ILivoCreatorVaultFactory} from "src/interfaces/ILivoCreatorVaultFactory.sol";
import {LivoCreatorVault} from "src/vaults/LivoCreatorVault.sol";

/// @title LivoCreatorVaultFactory
/// @notice UUPS-upgradeable factory that deploys minimal-proxy `LivoCreatorVault` clones. The vault
///         implementation is baked into this factory's bytecode as an immutable; upgrading the
///         factory (new impl + `upgradeTo`) is the mechanism to point FUTURE vaults at a new
///         implementation. Already-deployed clones keep their implementation forever.
/// @dev    `createVault` is permissionless by design: a vault deployed without funding is inert (it
///         only ever vests whatever tokens are transferred into it, and only its configured owner
///         can claim), so there is no spam/abuse surface that warrants a caller allowlist. In the
///         normal flow the Livo token factory calls `createVault` and then funds the vault in the
///         same transaction.
contract LivoCreatorVaultFactory is ILivoCreatorVaultFactory, Initializable, OwnableUpgradeable, UUPSUpgradeable {
    /// @notice The `LivoCreatorVault` implementation cloned for every new vault.
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

    /// @inheritdoc ILivoCreatorVaultFactory
    function createVault(address token, address owner, uint256 amount, uint256 cliffSeconds, uint256 vestingSeconds)
        external
        returns (address vault)
    {
        vault = Clones.clone(VAULT_IMPLEMENTATION);
        LivoCreatorVault(payable(vault)).initialize(token, owner, amount, cliffSeconds, vestingSeconds);
        emit CreatorVaultDeployed(vault, token, owner, amount, cliffSeconds, vestingSeconds);
    }

    /// @dev Reserved for future storage variables. Decrement when adding new storage to keep the
    ///      proxy's slot layout stable across upgrades.
    uint256[50] private __gap;
}
