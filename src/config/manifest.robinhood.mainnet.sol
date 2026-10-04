// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DeploymentAddressesRobinhoodMainnet} from "src/config/DeploymentAddresses.sol";

/// @title Realm deployment manifest — Robinhood Chain Mainnet
/// @notice Single source of truth for Realm's own deployed contracts on chain id 4663.
/// @dev External infrastructure (Uniswap V2/V4, Permit2, WETH) lives in
///      `src/config/DeploymentAddresses.sol`. Treasury also lives
///      there since it is consumed by core contracts at deploy time. Update this file
///      on every redeploy and run `just export-deployments` to refresh
///      `deployments.robinhood.mainnet.md`.
library DeploymentsRobinhoodMainnet {
    uint256 internal constant BLOCKCHAIN_ID = 4663;

    // --- Core ---
    address internal constant LAUNCHPAD = address(0);
    address internal constant BONDING_CURVE = address(0);
    address internal constant GRADUATOR_UNIV2 = address(0);

    /// @notice Shared, permissionless `RealmUniV4LiquidityAdder` singleton — one per chain, passed to the
    ///         direct V4 graduator and used by taxable tokens' `processLiquidity`. Deploy with
    ///         `DeployRealmStack`; `address(0)` until first deployed on this chain.
    address internal constant UNIV4_LIQUIDITY_ADDER = address(0);
    address internal constant MASTER_FEE_HANDLER = address(0);

    /// @notice Swap hook: fee-agnostic, reads each token's fees via `getSwapFees` (taxes only on current
    ///         tokens; the LP fee is the pool's native tier) and forwards any LP fee to `LP_FEE_ROUTER`. The direct V4 graduator points here for native pools.
    /// @dev Realm deploys its OWN hook rather than reusing the Livo one, whose `TREASURY` and
    ///      `FEE_ROUTER` immutables are pinned to Livo addresses and cannot be repointed. Deploy with
    ///      `DeployRealmSwapHook` (`RealmSwapHook` or `RealmHook`, see that script) and paste whichever
    ///      variant Uniswap whitelists. `address(0)` until then.
    address internal constant SWAP_HOOK = 0xAE4c0Cf7C3Feb79e0c244EdBC6A3f8a3290940cC;

    /// @notice `RealmHookAnyPair`: the hook every ERC20-quoted Realm pool is bound to. A SECOND hook
    ///         beside `SWAP_HOOK`, which is whitelisted by Uniswap and keeps every native pool. Mined
    ///         with the same permission bits; deployed by `DeployRealmHookAnyPair`.
    address public constant SWAP_HOOK_ANY_PAIR = 0x24d9308561c322a603370A0c3BeAD39E05DA00CC;

    /// @notice `RealmDirectGraduatorUniV4`: the direct-launch venue's graduator. Non-upgradeable, holds
    ///         every launch's seed position NFTs forever.
    address public constant GRADUATOR_UNIV4_DIRECT = address(0);
    /// @notice `RealmLpLocker` holding every seed band and bid wall of `GRADUATOR_UNIV4_DIRECT`'s tokens.
    ///         Deployed by that graduator's constructor (read it back as `LP_LOCKER()`); `address(0)` until
    ///         the graduator that deploys one is live on this chain.
    address public constant LP_LOCKER = address(0);

    /// @notice `RealmFactoryUniV4Direct` proxy — the direct-launch venue's entry point.
    address public constant FACTORY_UNIV4_DIRECT = address(0);

    /// @notice Implementation behind `FACTORY_UNIV4_DIRECT`.
    address public constant FACTORY_UNIV4_DIRECT_IMPL = address(0);

    /// @notice `RealmAssetsWhitelist` proxy (UUPS): the quote currencies the direct venue will launch
    ///         against, each with the native rate derived from its price pool. `FACTORY_UNIV4_DIRECT`
    ///         holds it as an immutable, so replacing it means a new factory implementation.
    address public constant ASSETS_WHITELIST = address(0);

    /// @notice Implementation behind `ASSETS_WHITELIST`. Tracked for verification and audit trails only.
    address public constant ASSETS_WHITELIST_IMPL = address(0);

    /// @notice `SwapLpFeeRouter` proxy (UUPS) consumed by `SWAP_HOOK`; splits LP fees 30/70
    ///         treasury/creator.
    /// @dev The hook holds this as an immutable, so it must be deployed BEFORE the hook
    ///      (`DeployRealmPrereqs`). Router policy changes ship by `upgradeToAndCall`ing this proxy.
    /// @dev Re-exported: the value lives in `DeploymentAddresses.sol`, which the token impls bake in.
    address internal constant LP_FEE_ROUTER = DeploymentAddressesRobinhoodMainnet.LP_FEE_ROUTER;
    /// @notice The `SwapLpFeeRouter` implementation behind `LP_FEE_ROUTER`. Update on every router
    ///         upgrade; tracked for verification and audit trails only.
    address internal constant LP_FEE_ROUTER_IMPL = 0xAc2444639cEc9b5ED31937982F34f62280F9B273;
    /// @notice `RealmTreasuryRouter` proxy (UUPS): the treasury address every push lands on once live —
    ///         `LAUNCHPAD.treasury()` and the `SwapLpFeeRouter` impl's `TREASURY` point here. Forwards 1/3
    ///         to `VOTING`, the rest to the team multisig. Deployed by `DeployRealmTreasuryStack`, which also
    ///         does that repointing; `address(0)` until then.
    address internal constant TREASURY_ROUTER = address(0);
    /// @notice Implementation behind `TREASURY_ROUTER`. Tracked for verification and audit trails only.
    address internal constant TREASURY_ROUTER_IMPL = address(0);
    /// @notice The REALM token (a launchpad token like any other; the one `VOTING` burns). `address(0)`
    ///         until it is launched on this chain.
    address internal constant REALM_TOKEN = address(0);
    /// @notice `RealmVoting` proxy (UUPS): REALM burn-to-vote rounds. Needs the REALM token, so it is
    ///         deployed after the first token; `TREASURY_ROUTER` bakes it in, so it comes BEFORE that.
    address internal constant VOTING = address(0);
    /// @notice Implementation behind `VOTING`. Tracked for verification and audit trails only.
    address internal constant VOTING_IMPL = address(0);
    address internal constant QUOTER = address(0);
    /// @notice `RealmKeeperLens`: the stateless, view-only batch reader the dividend keeper drives its
    ///         per-token reads through. Consumed OFF chain only — no Realm contract references it — so it
    ///         is redeployed and repointed freely rather than upgraded. `address(0)` until deployed.
    address internal constant KEEPER_LENS = address(0);

    /// @notice `RealmSwapper` proxy: every protocol swap (dividend conversions, LP token-fee sells).
    /// @dev Re-exported: the value lives in `DeploymentAddresses.sol`, which the token impls bake in.
    address internal constant REALM_SWAPPER = DeploymentAddressesRobinhoodMainnet.REALM_SWAPPER;
    /// @notice Implementation behind `REALM_SWAPPER`. Update on every registry upgrade; tracked for
    ///         verification and audit trails only.
    address internal constant REALM_SWAPPER_IMPL = address(0);

    // --- Token implementations (cloned by factories) ---
    address internal constant TOKEN_IMPL = address(0);
    address internal constant TAXABLE_TOKEN_V4_IMPL = address(0);

    /// @notice V2 taxable token implementation (cloned by `RealmFactoryUniV2Unified` when tax is configured)
    address internal constant TAXABLE_TOKEN_V2_IMPL = address(0);

    // --- Factories (unified) ---
    /// @notice UUPS proxy addresses that integrators whitelist. These stay stable across upgrades.
    address internal constant FACTORY_UNIV2_UNIFIED = address(0);

    /// @notice Implementation addresses currently set behind the proxies above. Updated on every
    ///         `UpgradeRealmFactories` run. Tracked for Etherscan verification and audit trails;
    ///         no contract or frontend consumes these directly.
    address internal constant FACTORY_UNIV2_UNIFIED_IMPL = address(0);

    // --- Creator vaults ---
    /// @notice `RealmCreatorVault` implementation cloned by the vault factory. Update after deploying.
    address internal constant CREATOR_VAULT_IMPL = address(0);
    /// @notice `RealmCreatorVaultFactory` UUPS proxy (stable across upgrades). Update after deploying.
    address internal constant CREATOR_VAULT_FACTORY = address(0);
    /// @notice `RealmCreatorVaultFactory` implementation behind the proxy. Update after deploying.
    address internal constant CREATOR_VAULT_FACTORY_IMPL = address(0);

    /// @notice The six allocation-specific bonding curves (`ConstantProductBondingCurveConfigurable`),
    ///         one per locked allocation. Update after deploying with `DeployRealmStack`.
    address internal constant VAULT_CURVE_5 = address(0);
    address internal constant VAULT_CURVE_10 = address(0);
    address internal constant VAULT_CURVE_15 = address(0);
    address internal constant VAULT_CURVE_20 = address(0);
    address internal constant VAULT_CURVE_25 = address(0);
    address internal constant VAULT_CURVE_30 = address(0);

    /// @notice The six vault curves as the `address[6]` the unified-factory constructors expect.
    function vaultBondingCurves() internal pure returns (address[6] memory c) {
        c[0] = VAULT_CURVE_5;
        c[1] = VAULT_CURVE_10;
        c[2] = VAULT_CURVE_15;
        c[3] = VAULT_CURVE_20;
        c[4] = VAULT_CURVE_25;
        c[5] = VAULT_CURVE_30;
    }

    // --- Liquidity tiers (THIN + THICK) ---
    /// @notice THIN-tier bonding curves (`ConstantProductBondingCurveConfigurable`): the no-vault
    ///         base curve plus six vault curves (5%..30%). Update after deploying with
    ///         `DeployRealmStack`. Used by the V2 factory.
    address internal constant THIN_CURVE_BASE = address(0);
    address internal constant THIN_VAULT_CURVE_5 = address(0);
    address internal constant THIN_VAULT_CURVE_10 = address(0);
    address internal constant THIN_VAULT_CURVE_15 = address(0);
    address internal constant THIN_VAULT_CURVE_20 = address(0);
    address internal constant THIN_VAULT_CURVE_25 = address(0);
    address internal constant THIN_VAULT_CURVE_30 = address(0);

    /// @notice THICK-tier bonding curves. Same layout as the THIN tier above.
    address internal constant THICK_CURVE_BASE = address(0);
    address internal constant THICK_VAULT_CURVE_5 = address(0);
    address internal constant THICK_VAULT_CURVE_10 = address(0);
    address internal constant THICK_VAULT_CURVE_15 = address(0);
    address internal constant THICK_VAULT_CURVE_20 = address(0);
    address internal constant THICK_VAULT_CURVE_25 = address(0);
    address internal constant THICK_VAULT_CURVE_30 = address(0);

    /// @notice The six THIN-tier vault curves as the `address[6]` the factory tier config expects.
    function thinVaultCurves() internal pure returns (address[6] memory c) {
        c[0] = THIN_VAULT_CURVE_5;
        c[1] = THIN_VAULT_CURVE_10;
        c[2] = THIN_VAULT_CURVE_15;
        c[3] = THIN_VAULT_CURVE_20;
        c[4] = THIN_VAULT_CURVE_25;
        c[5] = THIN_VAULT_CURVE_30;
    }

    /// @notice The six THICK-tier vault curves as the `address[6]` the factory tier config expects.
    function thickVaultCurves() internal pure returns (address[6] memory c) {
        c[0] = THICK_VAULT_CURVE_5;
        c[1] = THICK_VAULT_CURVE_10;
        c[2] = THICK_VAULT_CURVE_15;
        c[3] = THICK_VAULT_CURVE_20;
        c[4] = THICK_VAULT_CURVE_25;
        c[5] = THICK_VAULT_CURVE_30;
    }

    // --- Dividends ---
    /// @dev ROUTES ARE PER TOKEN, ON THE REGISTRY (`REALM_SWAPPER` in `DeploymentAddresses.sol`):
    ///      the creator passes them at creation, and an admin can repoint them per token or for every
    ///      token paying an asset (`RealmSwapper.setRoute(ALL_TOKENS, …)`). Any ERC20 can
    ///      be a payout asset; one without a route does not convert until it gets one. Set an override
    ///      only after `test_catalogue_everyRouteConvertsAtMaxSize`-style fork proof that it absorbs a
    ///      full conversion. Also needed before dividends launch: `setAdmin(...)` and
    ///      `setKeeperFunding(REALM_KEEPER)`.

    // --- Accounts ---
    /// @notice The keeper lambda's EOA. `address(0)` until configured here.
    address internal constant REALM_KEEPER = 0xE092CB5868e1Ca091Ea975069bf2Afc9CDD1732C;
}
