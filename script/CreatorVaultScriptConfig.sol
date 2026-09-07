// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DeploymentsEthereumSepolia} from "src/config/manifest.ethereum.sepolia.sol";
import {DeploymentsRobinhoodMainnet} from "src/config/manifest.robinhood.mainnet.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {RealmFactoryUniV4Unified} from "src/factories/RealmFactoryUniV4Unified.sol";

/// @title CreatorVaultScriptConfig
/// @notice Script-only helper that resolves the two creator-vault constructor args the unified
///         factories now take — the `RealmCreatorVaultFactory` and the six allocation-specific
///         bonding curves — from the per-chain manifest. Lives under `script/` (not `src/`) so the
///         per-chain `block.chainid` split stays out of production/deployable code: this is a
///         deploy-time-only `internal` library, inlined into the scripts that use it.
/// @dev    Populated by `DeployCreatorVaultSystem` → manifest update. Until then these are
///         `address(0)`; the factory constructor doesn't validate them (vault args are only read
///         when a token actually locks supply in vaults), so an early upgrade won't revert — but
///         you MUST deploy the vault system and refresh the manifest before tokens use vaults.
library CreatorVaultScriptConfig {
    /// @notice The `RealmCreatorVaultFactory` proxy for the active chain.
    function factoryFor() internal view returns (address) {
        if (block.chainid == DeploymentsEthereumSepolia.BLOCKCHAIN_ID) {
            return DeploymentsEthereumSepolia.CREATOR_VAULT_FACTORY;
        }
        if (block.chainid == DeploymentsRobinhoodMainnet.BLOCKCHAIN_ID) {
            return DeploymentsRobinhoodMainnet.CREATOR_VAULT_FACTORY;
        }
        revert("CreatorVaultScriptConfig: unsupported chain");
    }

    /// @notice The six allocation-specific bonding curves [5%..30%] for the active chain.
    function curvesFor() internal view returns (address[6] memory) {
        if (block.chainid == DeploymentsEthereumSepolia.BLOCKCHAIN_ID) {
            return DeploymentsEthereumSepolia.vaultBondingCurves();
        }
        if (block.chainid == DeploymentsRobinhoodMainnet.BLOCKCHAIN_ID) {
            return DeploymentsRobinhoodMainnet.vaultBondingCurves();
        }
        revert("CreatorVaultScriptConfig: unsupported chain");
    }

    /// @notice THIN + THICK tier curve sets (no-vault base + six vault curves each) for the active chain.
    /// @dev Reads the manifest tier slots populated by `DeployTierLiquiditySystem`. Until that script
    ///      has run and the manifest is refreshed these resolve to `address(0)` — the factory
    ///      constructor doesn't validate them and they're only read when a token actually selects the
    ///      THIN/THICK tier, so an early factory deploy/upgrade won't revert. You MUST deploy the tier
    ///      system and refresh the manifest before THIN/THICK tokens can be created.
    function tierConfigFor() internal view returns (IRealmFactory.LiquidityTierConfig memory tierConfig) {
        if (block.chainid == DeploymentsEthereumSepolia.BLOCKCHAIN_ID) {
            tierConfig.thin = IRealmFactory.TierCurves({
                base: DeploymentsEthereumSepolia.THIN_CURVE_BASE, vaults: DeploymentsEthereumSepolia.thinVaultCurves()
            });
            tierConfig.thick = IRealmFactory.TierCurves({
                base: DeploymentsEthereumSepolia.THICK_CURVE_BASE, vaults: DeploymentsEthereumSepolia.thickVaultCurves()
            });
            return tierConfig;
        }
        if (block.chainid == DeploymentsRobinhoodMainnet.BLOCKCHAIN_ID) {
            tierConfig.thin = IRealmFactory.TierCurves({
                base: DeploymentsRobinhoodMainnet.THIN_CURVE_BASE, vaults: DeploymentsRobinhoodMainnet.thinVaultCurves()
            });
            tierConfig.thick = IRealmFactory.TierCurves({
                base: DeploymentsRobinhoodMainnet.THICK_CURVE_BASE,
                vaults: DeploymentsRobinhoodMainnet.thickVaultCurves()
            });
            return tierConfig;
        }
        revert("CreatorVaultScriptConfig: unsupported chain");
    }

    /// @notice The full V4 tier config (curves + per-tier graduators) for the active chain. See `tierConfigFor`.
    function v4TierConfigFor() internal view returns (RealmFactoryUniV4Unified.V4TierConfig memory v4Tier) {
        v4Tier.curves = tierConfigFor();
        if (block.chainid == DeploymentsEthereumSepolia.BLOCKCHAIN_ID) {
            v4Tier.graduators = RealmFactoryUniV4Unified.TierGraduators({
                thin: DeploymentsEthereumSepolia.GRADUATOR_UNIV4_THIN,
                thick: DeploymentsEthereumSepolia.GRADUATOR_UNIV4_THICK
            });
            return v4Tier;
        }
        if (block.chainid == DeploymentsRobinhoodMainnet.BLOCKCHAIN_ID) {
            v4Tier.graduators = RealmFactoryUniV4Unified.TierGraduators({
                thin: DeploymentsRobinhoodMainnet.GRADUATOR_UNIV4_THIN,
                thick: DeploymentsRobinhoodMainnet.GRADUATOR_UNIV4_THICK
            });
            return v4Tier;
        }
        revert("CreatorVaultScriptConfig: unsupported chain");
    }
}
