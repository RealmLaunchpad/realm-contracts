// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Factory that deploys minimal-proxy vesting-vault clones. The vault implementation is
///         baked into the (UUPS-upgradeable) factory; upgrading the factory swaps the implementation
///         used by FUTURE vaults. Existing clones keep their implementation forever.
///         Permissionless: the Realm token factory uses it for creator-locked supply at launch, and
///         any holder can use it later to lock their own tokens.
interface IRealmCreatorVaultFactory {
    /// @notice Emitted for every vault deployed. The vault holds exactly `amount` when this fires.
    event CreatorVaultDeployed(
        address indexed vault,
        address indexed token,
        address indexed owner,
        uint256 amount,
        uint256 cliffSeconds,
        uint256 vestingSeconds
    );

    /// @notice Deploys and initializes a vault clone, then pulls `amount` of `token` from the caller
    ///         into it. The caller must have approved this factory for `amount` beforehand.
    /// @param token The token whose graduation gates the vault and whose units it vests
    /// @param owner The beneficiary allowed to claim vested tokens
    /// @param amount The total token allocation locked in the vault
    /// @param cliffSeconds Cliff duration after vault creation, before anything vests
    /// @param vestingSeconds Linear vesting duration after the cliff
    /// @return vault The freshly-deployed vault clone address
    function createVault(address token, address owner, uint256 amount, uint256 cliffSeconds, uint256 vestingSeconds)
        external
        returns (address vault);

    /// @notice The vault implementation currently cloned for new vaults.
    function VAULT_IMPLEMENTATION() external view returns (address);
}
