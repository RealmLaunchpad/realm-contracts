// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Factory that deploys minimal-proxy creator-vault clones. The vault implementation is
///         baked into the (UUPS-upgradeable) factory; upgrading the factory swaps the implementation
///         used by FUTURE vaults. Existing clones keep their implementation forever.
interface IRealmCreatorVaultFactory {
    /// @notice Emitted for every vault deployed.
    event CreatorVaultDeployed(
        address indexed vault,
        address indexed token,
        address indexed owner,
        uint256 amount,
        uint256 cliffSeconds,
        uint256 vestingSeconds
    );

    /// @notice Deploys and initializes a creator-vault clone. The caller is responsible for funding
    ///         the returned vault with exactly `amount` of `token` afterwards.
    /// @param token The token whose graduation gates the vault and whose units it vests
    /// @param owner The beneficiary allowed to claim vested tokens
    /// @param amount The total token allocation that will be locked in the vault
    /// @param cliffSeconds Cliff duration after token creation, before anything vests
    /// @param vestingSeconds Linear vesting duration after the cliff
    /// @return vault The freshly-deployed vault clone address
    function createVault(address token, address owner, uint256 amount, uint256 cliffSeconds, uint256 vestingSeconds)
        external
        returns (address vault);

    /// @notice The vault implementation currently cloned for new vaults.
    function VAULT_IMPLEMENTATION() external view returns (address);
}
