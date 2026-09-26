// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

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
    address internal constant LAUNCHPAD = 0x4052Fd02173608e8511622CB95B5C75CefD4eEaA;
    address internal constant BONDING_CURVE = 0xC894F5BB039c8FE4b3acE7e066c5EbB4A22e1AAE;
    address internal constant GRADUATOR_UNIV2 = 0x1baD03527861a8A629924A0F12E1DA315CB64FD3;

    /// @notice Shared, permissionless `RealmUniV4LiquidityAdder` singleton — one per chain, passed to the
    ///         direct V4 graduator and used by taxable tokens' `processLiquidity`. Deploy with
    ///         `DeployRealmStack`; `address(0)` until first deployed on this chain.
    address internal constant UNIV4_LIQUIDITY_ADDER = 0x7738cB7BcdD535fBd8033c747d5b42AEb24F1448;
    address internal constant MASTER_FEE_HANDLER = 0x431cADEa3bbfb91bC7d065b6bfd234DccD760a3e;

    /// @notice Swap hook: fee-agnostic, reads each token's `swapLpFeeBps` via
    ///         `getSwapFees` and forwards LP fees to `LP_FEE_ROUTER`. The direct V4 graduator points here for native pools.
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
    address public constant GRADUATOR_UNIV4_DIRECT = 0xE46F23DcfFa51513C42978E7EE136383632cD76F;

    /// @notice `RealmFactoryUniV4Direct` proxy — the direct-launch venue's entry point.
    address public constant FACTORY_UNIV4_DIRECT = 0x7c3777357da3f2FB8911ddA946afB1Fc74f0A613;

    /// @notice Implementation behind `FACTORY_UNIV4_DIRECT`.
    address public constant FACTORY_UNIV4_DIRECT_IMPL = 0x84083D67C0CC576726AB5270e01315d728476dC5;

    /// @notice `RealmAssetsWhitelist` proxy (UUPS): the quote currencies the direct venue will launch
    ///         against, each with the native rate derived from its price pool. `FACTORY_UNIV4_DIRECT`
    ///         holds it as an immutable, so replacing it means a new factory implementation.
    address public constant ASSETS_WHITELIST = 0x540d02FFD93D22d33Da196b426A465DCdE6BfAa2;

    /// @notice Implementation behind `ASSETS_WHITELIST`. Tracked for verification and audit trails only.
    address public constant ASSETS_WHITELIST_IMPL = 0x29470284A73077a1039f4FeC3534a3a588D2fd12;

    /// @notice `RealmDividendLogicUniV4`: the LIVE V4 token impl's dividend extension, reached only by
    ///         `delegatecall`. Removed from the source (folded into the token); kept as a deploy record.
    address public constant DIVIDEND_LOGIC_V4 = 0x3cec0f5719b1a2860eDA4016565a49B40A48Af3c;

    /// @notice `RealmEarningsLogicUniV4`: the V4 token's buy-back / liquidity extension. Same shape.
    address public constant EARNINGS_LOGIC_V4 = 0x9B1F2d5dB689A45e352D0d1d7b4eB0769998E0aa;
    /// @notice `SwapLpFeeRouter` proxy (UUPS) consumed by `SWAP_HOOK`; splits LP fees 30/70
    ///         treasury/creator.
    /// @dev The hook holds this as an immutable, so it must be deployed BEFORE the hook
    ///      (`DeployRealmPrereqs`). Router policy changes ship by `upgradeToAndCall`ing this proxy.
    address internal constant LP_FEE_ROUTER = 0x823ca5B8041217Df052D9e64AC6E7c16A62FA957;
    /// @notice The `SwapLpFeeRouter` implementation behind `LP_FEE_ROUTER`. Update on every router
    ///         upgrade; tracked for verification and audit trails only.
    address internal constant LP_FEE_ROUTER_IMPL = 0xA53a42561D85255C0dbDc73a27626FCb71bA48EA;
    /// @notice `RealmTreasuryRouter` proxy (UUPS): the treasury address every push lands on once live —
    ///         `LAUNCHPAD.treasury()` and the `SwapLpFeeRouter` impl's `TREASURY` point here. Forwards 1/3
    ///         to `VOTING`, the rest to the team multisig. Deployed by `DeployRealmTreasuryStack`, which also
    ///         does that repointing; `address(0)` until then.
    address internal constant TREASURY_ROUTER = address(0);
    /// @notice Implementation behind `TREASURY_ROUTER`. Tracked for verification and audit trails only.
    address internal constant TREASURY_ROUTER_IMPL = address(0);
    /// @notice The REALM token (a launchpad token like any other; the one `VOTING` burns). `address(0)`
    ///         until it is launched on this chain.
    address internal constant REALM_TOKEN = 0x5b1d3bF27e8Ea07c050BFf6401C72478A43CeeaA;
    /// @notice `RealmVoting` proxy (UUPS): REALM burn-to-vote rounds. Needs the REALM token, so it is
    ///         deployed after the first token; `TREASURY_ROUTER` bakes it in, so it comes BEFORE that.
    address internal constant VOTING = address(0);
    /// @notice Implementation behind `VOTING`. Tracked for verification and audit trails only.
    address internal constant VOTING_IMPL = address(0);
    address internal constant QUOTER = 0x557c778574c278c9Ebd8EC3B4725955A648Abc81;
    /// @notice `RealmKeeperLens`: the stateless, view-only batch reader the dividend keeper drives its
    ///         per-token reads through. Consumed OFF chain only — no Realm contract references it — so it
    ///         is redeployed and repointed freely rather than upgraded. `address(0)` until deployed.
    address internal constant KEEPER_LENS = address(0);

    /// @notice Implementation behind the `RealmDividendSwapRegistry` proxy, which lives in
    ///         `DeploymentAddresses.sol` (`DIVIDEND_SWAP_REGISTRY`). Update on every registry upgrade;
    ///         tracked for verification and audit trails only.
    address internal constant DIVIDEND_SWAP_REGISTRY_IMPL = address(0);

    // --- Token implementations (cloned by factories) ---
    address internal constant TOKEN_IMPL = 0x90c602831FeEec9537915793572323C6f4C8CbB9;
    address internal constant TAXABLE_TOKEN_V4_IMPL = 0x06D2df9F1524820b86ef6e064B2480CdB3FCB785;

    /// @notice V2 taxable token implementation (cloned by `RealmFactoryUniV2Unified` when tax is configured)
    address internal constant TAXABLE_TOKEN_V2_IMPL = 0xB9aB764680D74aC220DB8D6740ec56a26f24e575;

    // --- Factories (unified) ---
    /// @notice UUPS proxy addresses that integrators whitelist. These stay stable across upgrades.
    address internal constant FACTORY_UNIV2_UNIFIED = 0xCad0fA1851AdCfbB977caC19422fb525495cc8d3;

    /// @notice Implementation addresses currently set behind the proxies above. Updated on every
    ///         `UpgradeRealmFactories` run. Tracked for Etherscan verification and audit trails;
    ///         no contract or frontend consumes these directly.
    address internal constant FACTORY_UNIV2_UNIFIED_IMPL = 0x73BA11122a5B92d14dfdF71606f76A440c95337C;

    // --- Creator vaults ---
    /// @notice `RealmCreatorVault` implementation cloned by the vault factory. Update after deploying.
    address internal constant CREATOR_VAULT_IMPL = 0xF62E303E0b6AEDb9b55d4Ed8ce233440170bea7a;
    /// @notice `RealmCreatorVaultFactory` UUPS proxy (stable across upgrades). Update after deploying.
    address internal constant CREATOR_VAULT_FACTORY = 0x918c750C3d2Bea026454253d54a76b1888cE360d;
    /// @notice `RealmCreatorVaultFactory` implementation behind the proxy. Update after deploying.
    address internal constant CREATOR_VAULT_FACTORY_IMPL = 0x0c366124649250D0B625962A6Da67dFdC23cB763;

    /// @notice The six allocation-specific bonding curves (`ConstantProductBondingCurveConfigurable`),
    ///         one per locked allocation. Update after deploying with `DeployRealmStack`.
    address internal constant VAULT_CURVE_5 = 0x3DCBdd192e2Ca5CbFCC8b1BbDa33A02F34FB17B1;
    address internal constant VAULT_CURVE_10 = 0xd9a01D0d4C141296F83d48ebA80F2aE4380b5E6c;
    address internal constant VAULT_CURVE_15 = 0x437a0D31fE3a0329c614fef2558E9bE6FC72f525;
    address internal constant VAULT_CURVE_20 = 0x24451106759727997e7b3455f9Ff4266d60402F7;
    address internal constant VAULT_CURVE_25 = 0xE2893aEaa4c88CF4197796bcb6C1930683D76981;
    address internal constant VAULT_CURVE_30 = 0xDC6b4aec62B24aE8582d9393Bf0288C531033df5;

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
    address internal constant THIN_CURVE_BASE = 0x76631b1398e4f71027044780F2d781AFf41B407C;
    address internal constant THIN_VAULT_CURVE_5 = 0x2cD2Df598ABb096A85d5f1E5fA02A0b5Be85dfD2;
    address internal constant THIN_VAULT_CURVE_10 = 0xa594E5E25f7F2d4E71336cDB755f96811b5ee3F5;
    address internal constant THIN_VAULT_CURVE_15 = 0xEF010E0154574ecbA99299695Dd02F7E2712Fb53;
    address internal constant THIN_VAULT_CURVE_20 = 0xe3159990B4DaE3Ae812F2591921988d0093056aB;
    address internal constant THIN_VAULT_CURVE_25 = 0x4952dB62Cfb42959001bC2602fdaeF54806DCD1c;
    address internal constant THIN_VAULT_CURVE_30 = 0x3B6bbE80f2e6138e7a612d11bA2A69d25e7Be320;

    /// @notice THICK-tier bonding curves. Same layout as the THIN tier above.
    address internal constant THICK_CURVE_BASE = 0xA03e9dB206A10B7af8bB024919E7d2842343b0D4;
    address internal constant THICK_VAULT_CURVE_5 = 0x661B67d7C75Ee8E2a348449594B12eC3FeC4F025;
    address internal constant THICK_VAULT_CURVE_10 = 0x1a4Fe0502d3dBDc18263dcabdb94D45442bbDe04;
    address internal constant THICK_VAULT_CURVE_15 = 0xdbf83496B70693eB2e326009B893d9Bc9f722d06;
    address internal constant THICK_VAULT_CURVE_20 = 0xBF4451dAedeFC616599498BB1Af762CdD0aFe3a7;
    address internal constant THICK_VAULT_CURVE_25 = 0x76b39921AE929C5776E55B5f8fe501e03097BeA5;
    address internal constant THICK_VAULT_CURVE_30 = 0xfD8aCcF68257BA7A5D15752f66D267e4C8aeDcc2;

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
    /// @dev NOTHING IS WHITELISTED PER ASSET, and there is no route table to fill in. A payout asset is
    ///      permissionless: the token registers its own route at creation
    ///      (`RealmDividendSwapRegistry.registerRoute`, `DIVIDEND_SWAP_REGISTRY` in
    ///      `DeploymentAddresses.sol`) and the registry only proves the pools that route names are
    ///      initialized and hold in-range liquidity. So the ~190 xStock routes need no transaction here:
    ///      the only thing a V4 route reads from registry state is the quote-token allowlist, and mainnet
    ///      already has it — quote = WETH `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`, allowed, with
    ///      `defaultThreshold` 2e18 (that threshold only gates the empty V2 route anyway).
    /// @dev WHAT IS STILL MISSING on the mainnet registry, both admin-tier, both harmless until
    ///      dividends actually launch here:
    ///        1. `setAdmin(...)` — the registry OWNER (the DEPRECATED deployer key, not the current
    ///           `REALM_DEV`; it predates the rotation) is not an admin, and every operational lever
    ///           (`setBlacklisted`, `setAllowedQuoteToken`, the thresholds) is admin-only. Until then a
    ///           payout asset that turns hostile cannot be vetoed.
    ///        2. `setKeeperFunding(REALM_KEEPER)` — unset, so a conversion hands the keeper no gas money.
    ///      Only a V3 route's MIDDLE hops are allowlisted against `isAllowedQuoteToken` (USDG is not in
    ///      it today); every route the picker generates for an xStock is V4, whose hops are not checked
    ///      against that set, so this matters only if a V3 venue is ever used.

    // --- Accounts ---
    /// @notice The `realm.dev` deployer keystore: the broadcaster of every deploy script and the initial
    ///         owner of everything they deploy.
    /// @dev Rotated from the now-deprecated `0x1a209bB4d0bC40f169c06dC2808d7d512Aea62bb`, which is what the
    ///      `deprecated.realm.dev` keystore holds. That old key still owns the contracts deployed before the
    ///      rotation — `REALM_KEEPERS_REGISTRY` and `DIVIDEND_SWAP_REGISTRY` in `DeploymentAddresses.sol` —
    ///      so their `setAdmin` / `transferOwnership` must still be signed with it.
    address internal constant REALM_DEV = 0x81f7D06a88223f5a2850411E72256AacC9E27035;
    address internal constant REALM_TOKEN_DEPLOYER = address(0);
    /// @notice The keeper lambda's EOA. `address(0)` until configured here.
    address internal constant REALM_KEEPER = 0xE092CB5868e1Ca091Ea975069bf2Afc9CDD1732C;
}
