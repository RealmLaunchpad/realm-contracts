// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {RealmFactoryUniV4Unified} from "src/factories/RealmFactoryUniV4Unified.sol";
import {
    DeploymentAddressesEthereumSepolia,
    DeploymentAddressesRobinhoodMainnet
} from "src/config/DeploymentAddresses.sol";
import {DeploymentsEthereumSepolia} from "src/config/manifest.ethereum.sepolia.sol";
import {DeploymentsRobinhoodMainnet} from "src/config/manifest.robinhood.mainnet.sol";

/// @title ChainConfig
/// @notice Deploy-time-only resolver for the two supported chains (Sepolia, Robinhood mainnet). Keeps
///         every `block.chainid` branch out of `src/`: external infra comes from `DeploymentAddresses`,
///         Realm's own deployed addresses from `manifest.<chain>.sol`.
library ChainConfig {
    /// @notice External infrastructure + the protocol treasury for the active chain.
    struct Infra {
        address treasury;
        address univ2Router;
        bytes32 univ2PairInitCodeHash;
        address univ4PoolManager;
        address univ4PositionManager;
        address permit2;
    }

    /// @notice The manifest slots the factory constructors consume. Only populated once the stack is
    ///         deployed and the manifest pasted; used by `UpgradeRealmFactories`, not by a fresh deploy.
    struct Manifest {
        address launchpad;
        address bondingCurve;
        address graduatorV2;
        address graduatorV4;
        address masterFeeHandler;
        address tokenImpl;
        address taxTokenV2Impl;
        address taxTokenV4Impl;
        address factoryV2Proxy;
        address factoryV4Proxy;
    }

    function isSepolia() internal view returns (bool) {
        return block.chainid == DeploymentAddressesEthereumSepolia.BLOCKCHAIN_ID;
    }

    function isRobinhood() internal view returns (bool) {
        return block.chainid == DeploymentAddressesRobinhoodMainnet.BLOCKCHAIN_ID;
    }

    /// @notice Manifest file suffix for the active chain, for the "paste it here" hints.
    function name() internal view returns (string memory) {
        if (isSepolia()) return "ethereum.sepolia";
        if (isRobinhood()) return "robinhood.mainnet";
        revert("ChainConfig: unsupported chain (Sepolia and Robinhood mainnet only)");
    }

    function infra() internal view returns (Infra memory i) {
        if (isSepolia()) {
            i = Infra({
                treasury: DeploymentAddressesEthereumSepolia.REALM_TREASURY,
                univ2Router: DeploymentAddressesEthereumSepolia.UNIV2_ROUTER,
                univ2PairInitCodeHash: DeploymentAddressesEthereumSepolia.UNIV2_PAIR_INIT_CODE_HASH,
                univ4PoolManager: DeploymentAddressesEthereumSepolia.UNIV4_POOL_MANAGER,
                univ4PositionManager: DeploymentAddressesEthereumSepolia.UNIV4_POSITION_MANAGER,
                permit2: DeploymentAddressesEthereumSepolia.PERMIT2
            });
        } else if (isRobinhood()) {
            i = Infra({
                treasury: DeploymentAddressesRobinhoodMainnet.REALM_TREASURY,
                univ2Router: DeploymentAddressesRobinhoodMainnet.UNIV2_ROUTER,
                univ2PairInitCodeHash: DeploymentAddressesRobinhoodMainnet.UNIV2_PAIR_INIT_CODE_HASH,
                univ4PoolManager: DeploymentAddressesRobinhoodMainnet.UNIV4_POOL_MANAGER,
                univ4PositionManager: DeploymentAddressesRobinhoodMainnet.UNIV4_POSITION_MANAGER,
                permit2: DeploymentAddressesRobinhoodMainnet.PERMIT2
            });
        } else {
            revert("ChainConfig: unsupported chain (Sepolia and Robinhood mainnet only)");
        }
        require(i.treasury != address(0), "REALM_TREASURY missing");
    }

    /// @notice The `LivoSwapHook` for the active chain. Inherited from the Livo deployment (Uniswap has
    ///         whitelisted it), so it is a manifest read, not something a fresh deploy produces.
    function swapHook() internal view returns (address hook) {
        if (isSepolia()) hook = DeploymentsEthereumSepolia.SWAP_HOOK;
        else if (isRobinhood()) hook = DeploymentsRobinhoodMainnet.SWAP_HOOK;
        else revert("ChainConfig: unsupported chain (Sepolia and Robinhood mainnet only)");
        require(hook != address(0), "manifest: SWAP_HOOK missing");
    }

    /// @notice The LP fee router proxy `SWAP_HOOK` forwards LP fees to. Inherited alongside the hook —
    ///         the hook holds it as an immutable, so it cannot be repointed; Realm's router policy ships
    ///         by upgrading this proxy's implementation.
    function lpFeeRouter() internal view returns (address router) {
        if (isSepolia()) router = DeploymentsEthereumSepolia.LP_FEE_ROUTER;
        else if (isRobinhood()) router = DeploymentsRobinhoodMainnet.LP_FEE_ROUTER;
        else revert("ChainConfig: unsupported chain (Sepolia and Robinhood mainnet only)");
        require(router != address(0), "manifest: LP_FEE_ROUTER missing");
    }

    function manifest() internal view returns (Manifest memory m) {
        if (isSepolia()) {
            m = Manifest({
                launchpad: DeploymentsEthereumSepolia.LAUNCHPAD,
                bondingCurve: DeploymentsEthereumSepolia.BONDING_CURVE,
                graduatorV2: DeploymentsEthereumSepolia.GRADUATOR_UNIV2,
                graduatorV4: DeploymentsEthereumSepolia.GRADUATOR_UNIV4,
                masterFeeHandler: DeploymentsEthereumSepolia.MASTER_FEE_HANDLER,
                tokenImpl: DeploymentsEthereumSepolia.TOKEN_IMPL,
                taxTokenV2Impl: DeploymentsEthereumSepolia.TAXABLE_TOKEN_V2_IMPL,
                taxTokenV4Impl: DeploymentsEthereumSepolia.TAXABLE_TOKEN_V4_IMPL,
                factoryV2Proxy: DeploymentsEthereumSepolia.FACTORY_UNIV2_UNIFIED,
                factoryV4Proxy: DeploymentsEthereumSepolia.FACTORY_UNIV4_UNIFIED
            });
        } else if (isRobinhood()) {
            m = Manifest({
                launchpad: DeploymentsRobinhoodMainnet.LAUNCHPAD,
                bondingCurve: DeploymentsRobinhoodMainnet.BONDING_CURVE,
                graduatorV2: DeploymentsRobinhoodMainnet.GRADUATOR_UNIV2,
                graduatorV4: DeploymentsRobinhoodMainnet.GRADUATOR_UNIV4,
                masterFeeHandler: DeploymentsRobinhoodMainnet.MASTER_FEE_HANDLER,
                tokenImpl: DeploymentsRobinhoodMainnet.TOKEN_IMPL,
                taxTokenV2Impl: DeploymentsRobinhoodMainnet.TAXABLE_TOKEN_V2_IMPL,
                taxTokenV4Impl: DeploymentsRobinhoodMainnet.TAXABLE_TOKEN_V4_IMPL,
                factoryV2Proxy: DeploymentsRobinhoodMainnet.FACTORY_UNIV2_UNIFIED,
                factoryV4Proxy: DeploymentsRobinhoodMainnet.FACTORY_UNIV4_UNIFIED
            });
        } else {
            revert("ChainConfig: unsupported chain (Sepolia and Robinhood mainnet only)");
        }
    }

    /// @notice `RealmCreatorVaultFactory` proxy from the manifest.
    function creatorVaultFactory() internal view returns (address) {
        if (isSepolia()) return DeploymentsEthereumSepolia.CREATOR_VAULT_FACTORY;
        if (isRobinhood()) return DeploymentsRobinhoodMainnet.CREATOR_VAULT_FACTORY;
        revert("ChainConfig: unsupported chain (Sepolia and Robinhood mainnet only)");
    }

    /// @notice The six DEFAULT-tier vault curves [5%..30%] from the manifest.
    function defaultVaultCurves() internal view returns (address[6] memory) {
        if (isSepolia()) return DeploymentsEthereumSepolia.vaultBondingCurves();
        if (isRobinhood()) return DeploymentsRobinhoodMainnet.vaultBondingCurves();
        revert("ChainConfig: unsupported chain (Sepolia and Robinhood mainnet only)");
    }

    /// @notice THIN + THICK curve sets (no-vault base + six vault curves each) from the manifest.
    function tierCurves() internal view returns (IRealmFactory.LiquidityTierConfig memory c) {
        if (isSepolia()) {
            c.thin = IRealmFactory.TierCurves({
                base: DeploymentsEthereumSepolia.THIN_CURVE_BASE, vaults: DeploymentsEthereumSepolia.thinVaultCurves()
            });
            c.thick = IRealmFactory.TierCurves({
                base: DeploymentsEthereumSepolia.THICK_CURVE_BASE, vaults: DeploymentsEthereumSepolia.thickVaultCurves()
            });
        } else if (isRobinhood()) {
            c.thin = IRealmFactory.TierCurves({
                base: DeploymentsRobinhoodMainnet.THIN_CURVE_BASE, vaults: DeploymentsRobinhoodMainnet.thinVaultCurves()
            });
            c.thick = IRealmFactory.TierCurves({
                base: DeploymentsRobinhoodMainnet.THICK_CURVE_BASE,
                vaults: DeploymentsRobinhoodMainnet.thickVaultCurves()
            });
        } else {
            revert("ChainConfig: unsupported chain (Sepolia and Robinhood mainnet only)");
        }
    }

    /// @notice THIN/THICK curves + their per-tier V4 graduators from the manifest.
    function v4TierConfig() internal view returns (RealmFactoryUniV4Unified.V4TierConfig memory v4) {
        v4.curves = tierCurves();
        if (isSepolia()) {
            v4.graduators = RealmFactoryUniV4Unified.TierGraduators({
                thin: DeploymentsEthereumSepolia.GRADUATOR_UNIV4_THIN,
                thick: DeploymentsEthereumSepolia.GRADUATOR_UNIV4_THICK
            });
        } else if (isRobinhood()) {
            v4.graduators = RealmFactoryUniV4Unified.TierGraduators({
                thin: DeploymentsRobinhoodMainnet.GRADUATOR_UNIV4_THIN,
                thick: DeploymentsRobinhoodMainnet.GRADUATOR_UNIV4_THICK
            });
        } else {
            revert("ChainConfig: unsupported chain (Sepolia and Robinhood mainnet only)");
        }
    }
}
