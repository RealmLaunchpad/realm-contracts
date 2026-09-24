// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {
    DeploymentAddressesRobinhoodMainnet,
    DeploymentAddressesRobinhoodTestnet
} from "src/config/DeploymentAddresses.sol";
import {DeploymentsRobinhoodMainnet} from "src/config/manifest.robinhood.mainnet.sol";
import {DeploymentsRobinhoodTestnet} from "src/config/manifest.robinhood.testnet.sol";

/// @title ChainConfig
/// @notice Deploy-time-only resolver for the two supported chains (Robinhood mainnet and
///         testnet). Keeps every `block.chainid` branch out of `src/`: external infra comes
///         from `DeploymentAddresses`, Realm's own deployed addresses from `manifest.<chain>.sol`.
library ChainConfig {
    string internal constant UNSUPPORTED = "ChainConfig: unsupported chain (Robinhood mainnet/testnet only)";

    /// @notice External infrastructure + the protocol treasury for the active chain.
    struct Infra {
        address treasury;
        address univ2Router;
        bytes32 univ2PairInitCodeHash;
        address univ4PoolManager;
        address univ4PositionManager;
        address permit2;
        address univ4UniversalRouter;
        address keepersRegistry;
    }

    /// @notice The manifest slots the factory constructors consume. Only populated once the stack is
    ///         deployed and the manifest pasted; used by `UpgradeRealmFactories`, not by a fresh deploy.
    struct Manifest {
        address launchpad;
        address bondingCurve;
        address graduatorV2;
        address graduatorV4Direct;
        address liquidityAdder;
        address masterFeeHandler;
        address tokenImpl;
        address taxTokenV2Impl;
        address taxTokenV4Impl;
        address factoryV2Proxy;
        address factoryV4DirectProxy;
    }

    function isRobinhood() internal view returns (bool) {
        return block.chainid == DeploymentAddressesRobinhoodMainnet.BLOCKCHAIN_ID;
    }

    function isRobinhoodTestnet() internal view returns (bool) {
        return block.chainid == DeploymentAddressesRobinhoodTestnet.BLOCKCHAIN_ID;
    }

    /// @notice Manifest file suffix for the active chain, for the "paste it here" hints.
    function name() internal view returns (string memory) {
        if (isRobinhood()) return "robinhood.mainnet";
        if (isRobinhoodTestnet()) return "robinhood.testnet";
        revert(UNSUPPORTED);
    }

    function infra() internal view returns (Infra memory i) {
        if (isRobinhood()) {
            i = Infra({
                treasury: DeploymentAddressesRobinhoodMainnet.REALM_TREASURY,
                univ2Router: DeploymentAddressesRobinhoodMainnet.UNIV2_ROUTER,
                univ2PairInitCodeHash: DeploymentAddressesRobinhoodMainnet.UNIV2_PAIR_INIT_CODE_HASH,
                univ4PoolManager: DeploymentAddressesRobinhoodMainnet.UNIV4_POOL_MANAGER,
                univ4PositionManager: DeploymentAddressesRobinhoodMainnet.UNIV4_POSITION_MANAGER,
                permit2: DeploymentAddressesRobinhoodMainnet.PERMIT2,
                univ4UniversalRouter: DeploymentAddressesRobinhoodMainnet.UNIV4_UNIVERSAL_ROUTER,
                keepersRegistry: DeploymentAddressesRobinhoodMainnet.REALM_KEEPERS_REGISTRY
            });
        } else if (isRobinhoodTestnet()) {
            i = Infra({
                treasury: DeploymentAddressesRobinhoodTestnet.REALM_TREASURY,
                univ2Router: DeploymentAddressesRobinhoodTestnet.UNIV2_ROUTER,
                univ2PairInitCodeHash: DeploymentAddressesRobinhoodTestnet.UNIV2_PAIR_INIT_CODE_HASH,
                univ4PoolManager: DeploymentAddressesRobinhoodTestnet.UNIV4_POOL_MANAGER,
                univ4PositionManager: DeploymentAddressesRobinhoodTestnet.UNIV4_POSITION_MANAGER,
                permit2: DeploymentAddressesRobinhoodTestnet.PERMIT2,
                univ4UniversalRouter: DeploymentAddressesRobinhoodTestnet.UNIV4_UNIVERSAL_ROUTER,
                keepersRegistry: DeploymentAddressesRobinhoodTestnet.REALM_KEEPERS_REGISTRY
            });
        } else {
            revert(UNSUPPORTED);
        }
        require(i.treasury != address(0), "REALM_TREASURY missing");
    }

    /// @notice The V4 swap hook for the active chain (`RealmSwapHook` or `RealmHook` — whichever Uniswap
    ///         whitelisted). Deployed separately by `DeployRealmSwapHook`, since its address must be
    ///         mined for the permission flags, so this is a manifest read.
    /// @notice `RealmHookAnyPair`, the hook every ERC20-quoted pool is bound to. A SECOND hook beside
    ///         `swapHook()`, which Uniswap whitelisted and which keeps every native pool.
    function swapHookAnyPair() internal view returns (address hook) {
        if (isRobinhood()) hook = DeploymentsRobinhoodMainnet.SWAP_HOOK_ANY_PAIR;
        else if (isRobinhoodTestnet()) hook = DeploymentsRobinhoodTestnet.SWAP_HOOK_ANY_PAIR;
        else revert(UNSUPPORTED);
        require(hook != address(0), "manifest: SWAP_HOOK_ANY_PAIR missing; run DeployRealmHookAnyPair first");
    }

    /// @notice `RealmAssetsWhitelist` for the active chain: the quote currencies the direct venue
    ///         accepts. Deployed with the venue (`DeployRealmStack` / `DeployDirectVenue`), which is why
    ///         this is a manifest read rather than a constant.
    function assetsWhitelist() internal view returns (address whitelist) {
        whitelist = assetsWhitelistOrZero();
        require(whitelist != address(0), "manifest: ASSETS_WHITELIST missing; deploy the direct venue first");
    }

    /// @notice As `assetsWhitelist()`, but zero instead of a revert on a chain where the direct venue is
    ///         not deployed yet. For callers that configure it if it exists and move on if it does not.
    function assetsWhitelistOrZero() internal view returns (address) {
        if (isRobinhood()) return DeploymentsRobinhoodMainnet.ASSETS_WHITELIST;
        if (isRobinhoodTestnet()) return DeploymentsRobinhoodTestnet.ASSETS_WHITELIST;
        revert(UNSUPPORTED);
    }

    /// @notice The chain's wrapped native token, which the direct venue refuses as a pair quote.
    function wrappedNative() internal view returns (address) {
        if (isRobinhood()) return DeploymentAddressesRobinhoodMainnet.WETH;
        if (isRobinhoodTestnet()) return DeploymentAddressesRobinhoodTestnet.WETH;
        revert(UNSUPPORTED);
    }

    /// @notice The chain's Uniswap V2 and V3 factories, which `RealmAssetsWhitelist` validates price
    ///         pools against. Zero where the venue is not deployed.
    function univ2And3Factories() internal view returns (address v2, address v3) {
        if (isRobinhood()) {
            return
                (DeploymentAddressesRobinhoodMainnet.UNIV2_FACTORY, DeploymentAddressesRobinhoodMainnet.UNIV3_FACTORY);
        }
        if (isRobinhoodTestnet()) {
            return
                (DeploymentAddressesRobinhoodTestnet.UNIV2_FACTORY, DeploymentAddressesRobinhoodTestnet.UNIV3_FACTORY);
        }
        revert(UNSUPPORTED);
    }

    function swapHook() internal view returns (address hook) {
        if (isRobinhood()) hook = DeploymentsRobinhoodMainnet.SWAP_HOOK;
        else if (isRobinhoodTestnet()) hook = DeploymentsRobinhoodTestnet.SWAP_HOOK;
        else revert(UNSUPPORTED);
        require(hook != address(0), "manifest: SWAP_HOOK missing");
    }

    /// @notice The LP fee router proxy `SWAP_HOOK` forwards LP fees to. Deployed by `DeployRealmPrereqs`
    ///         BEFORE the hook, which holds it as an immutable; router policy ships by upgrading this
    ///         proxy's implementation.
    function lpFeeRouter() internal view returns (address router) {
        if (isRobinhood()) router = DeploymentsRobinhoodMainnet.LP_FEE_ROUTER;
        else if (isRobinhoodTestnet()) router = DeploymentsRobinhoodTestnet.LP_FEE_ROUTER;
        else revert(UNSUPPORTED);
        require(router != address(0), "manifest: LP_FEE_ROUTER missing");
    }

    /// @notice The multisig that receives the 2/3 leg of `RealmTreasuryRouter`. Only Robinhood mainnet
    ///         has a dedicated one; the dev chains use their dev treasury.
    function teamTreasury() internal view returns (address t) {
        if (isRobinhood()) t = DeploymentAddressesRobinhoodMainnet.TEAM_TREASURY;
        else if (isRobinhoodTestnet()) t = DeploymentAddressesRobinhoodTestnet.TEAM_TREASURY;
        else revert(UNSUPPORTED);
        require(t != address(0), "team treasury missing");
    }

    /// @notice The ops wallet appointed as `RealmVoting` admin (pulls each round's native and buys the
    ///         winner). Only Robinhood mainnet names one; elsewhere the owner acts as admin.
    function voteBuybackWallet() internal view returns (address) {
        if (isRobinhood()) return DeploymentAddressesRobinhoodMainnet.VOTE_BUYBACK_WALLET;
        if (isRobinhoodTestnet()) return address(0);
        revert(UNSUPPORTED);
    }

    /// @notice `RealmTreasuryRouter` proxy from the manifest; `address(0)` until deployed.
    function treasuryRouter() internal view returns (address) {
        if (isRobinhood()) return DeploymentsRobinhoodMainnet.TREASURY_ROUTER;
        if (isRobinhoodTestnet()) return DeploymentsRobinhoodTestnet.TREASURY_ROUTER;
        revert(UNSUPPORTED);
    }

    /// @notice `RealmFactoryUniV4Direct` proxy from the manifest: the direct-launch venue's entry point.
    ///         Deployed with the venue (`DeployRealmStack` / `DeployDirectVenue`), which is why this is a
    ///         manifest read. `address(0)` on a chain where the venue is not live.
    function directFactory() internal view returns (address) {
        if (isRobinhood()) return DeploymentsRobinhoodMainnet.FACTORY_UNIV4_DIRECT;
        if (isRobinhoodTestnet()) return DeploymentsRobinhoodTestnet.FACTORY_UNIV4_DIRECT;
        revert(UNSUPPORTED);
    }

    /// @notice `RealmVoting` proxy from the manifest; `address(0)` until deployed.
    function voting() internal view returns (address) {
        if (isRobinhood()) return DeploymentsRobinhoodMainnet.VOTING;
        if (isRobinhoodTestnet()) return DeploymentsRobinhoodTestnet.VOTING;
        revert(UNSUPPORTED);
    }

    /// @notice The REALM token from the manifest — a launchpad token like any other, and the one
    ///         `RealmVoting` burns. `address(0)` until it is launched on this chain.
    function realmToken() internal view returns (address) {
        if (isRobinhood()) return DeploymentsRobinhoodMainnet.REALM_TOKEN;
        if (isRobinhoodTestnet()) return DeploymentsRobinhoodTestnet.REALM_TOKEN;
        revert(UNSUPPORTED);
    }

    /// @notice The keeper lambda's EOA from the manifest: appointed on `RealmKeepersRegistry` and set as
    ///         the `RealmDividendSwapRegistry`'s keeper-funding wallet by `ConfigureRegistries`.
    function realmKeeper() internal view returns (address keeper) {
        if (isRobinhood()) keeper = DeploymentsRobinhoodMainnet.REALM_KEEPER;
        else if (isRobinhoodTestnet()) keeper = DeploymentsRobinhoodTestnet.REALM_KEEPER;
        else revert(UNSUPPORTED);
        require(keeper != address(0), "manifest: REALM_KEEPER missing");
    }

    function manifest() internal view returns (Manifest memory m) {
        if (isRobinhood()) {
            m = Manifest({
                launchpad: DeploymentsRobinhoodMainnet.LAUNCHPAD,
                bondingCurve: DeploymentsRobinhoodMainnet.BONDING_CURVE,
                graduatorV2: DeploymentsRobinhoodMainnet.GRADUATOR_UNIV2,
                graduatorV4Direct: DeploymentsRobinhoodMainnet.GRADUATOR_UNIV4_DIRECT,
                liquidityAdder: DeploymentsRobinhoodMainnet.UNIV4_LIQUIDITY_ADDER,
                masterFeeHandler: DeploymentsRobinhoodMainnet.MASTER_FEE_HANDLER,
                tokenImpl: DeploymentsRobinhoodMainnet.TOKEN_IMPL,
                taxTokenV2Impl: DeploymentsRobinhoodMainnet.TAXABLE_TOKEN_V2_IMPL,
                taxTokenV4Impl: DeploymentsRobinhoodMainnet.TAXABLE_TOKEN_V4_IMPL,
                factoryV2Proxy: DeploymentsRobinhoodMainnet.FACTORY_UNIV2_UNIFIED,
                factoryV4DirectProxy: DeploymentsRobinhoodMainnet.FACTORY_UNIV4_DIRECT
            });
        } else if (isRobinhoodTestnet()) {
            m = Manifest({
                launchpad: DeploymentsRobinhoodTestnet.LAUNCHPAD,
                bondingCurve: DeploymentsRobinhoodTestnet.BONDING_CURVE,
                graduatorV2: DeploymentsRobinhoodTestnet.GRADUATOR_UNIV2,
                graduatorV4Direct: DeploymentsRobinhoodTestnet.GRADUATOR_UNIV4_DIRECT,
                liquidityAdder: DeploymentsRobinhoodTestnet.UNIV4_LIQUIDITY_ADDER,
                masterFeeHandler: DeploymentsRobinhoodTestnet.MASTER_FEE_HANDLER,
                tokenImpl: DeploymentsRobinhoodTestnet.TOKEN_IMPL,
                taxTokenV2Impl: DeploymentsRobinhoodTestnet.TAXABLE_TOKEN_V2_IMPL,
                taxTokenV4Impl: DeploymentsRobinhoodTestnet.TAXABLE_TOKEN_V4_IMPL,
                factoryV2Proxy: DeploymentsRobinhoodTestnet.FACTORY_UNIV2_UNIFIED,
                factoryV4DirectProxy: DeploymentsRobinhoodTestnet.FACTORY_UNIV4_DIRECT
            });
        } else {
            revert(UNSUPPORTED);
        }
    }

    /// @notice `RealmCreatorVaultFactory` proxy from the manifest.
    function creatorVaultFactory() internal view returns (address) {
        if (isRobinhood()) return DeploymentsRobinhoodMainnet.CREATOR_VAULT_FACTORY;
        if (isRobinhoodTestnet()) return DeploymentsRobinhoodTestnet.CREATOR_VAULT_FACTORY;
        revert(UNSUPPORTED);
    }

    /// @notice The six DEFAULT-tier vault curves [5%..30%] from the manifest.
    function defaultVaultCurves() internal view returns (address[6] memory) {
        if (isRobinhood()) return DeploymentsRobinhoodMainnet.vaultBondingCurves();
        if (isRobinhoodTestnet()) return DeploymentsRobinhoodTestnet.vaultBondingCurves();
        revert(UNSUPPORTED);
    }

    /// @notice THIN + THICK curve sets (no-vault base + six vault curves each) from the manifest.
    function tierCurves() internal view returns (IRealmFactory.LiquidityTierConfig memory c) {
        if (isRobinhood()) {
            c.thin = IRealmFactory.TierCurves({
                base: DeploymentsRobinhoodMainnet.THIN_CURVE_BASE, vaults: DeploymentsRobinhoodMainnet.thinVaultCurves()
            });
            c.thick = IRealmFactory.TierCurves({
                base: DeploymentsRobinhoodMainnet.THICK_CURVE_BASE,
                vaults: DeploymentsRobinhoodMainnet.thickVaultCurves()
            });
        } else if (isRobinhoodTestnet()) {
            c.thin = IRealmFactory.TierCurves({
                base: DeploymentsRobinhoodTestnet.THIN_CURVE_BASE, vaults: DeploymentsRobinhoodTestnet.thinVaultCurves()
            });
            c.thick = IRealmFactory.TierCurves({
                base: DeploymentsRobinhoodTestnet.THICK_CURVE_BASE,
                vaults: DeploymentsRobinhoodTestnet.thickVaultCurves()
            });
        } else {
            revert(UNSUPPORTED);
        }
    }
}
