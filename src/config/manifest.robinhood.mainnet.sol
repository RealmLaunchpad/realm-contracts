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
    address internal constant LAUNCHPAD = 0x2F5Ee43983391c57e755761d9C614Ea859e0EEaA;
    address internal constant BONDING_CURVE = 0x07c3779dfF41516C1f754FD10C5984808c377078;
    address internal constant GRADUATOR_UNIV2 = 0x840289Acaf98c751790d21AE9D63A9eCA8333763;

    /// @notice Shared, permissionless `RealmUniV4LiquidityAdder` singleton — one per chain, passed to the
    ///         direct V4 graduator and used by taxable tokens' `processLiquidity`. Deploy with
    ///         `DeployRealmStack`; `address(0)` until first deployed on this chain.
    address internal constant UNIV4_LIQUIDITY_ADDER = 0xF682Af86cf1f8F591d8f1FDba21eDC2a7e0d64c2;
    address internal constant MASTER_FEE_HANDLER = 0x6a41978F2965e8B406d59AEaf9F5DBf895c7A088;

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
    address public constant GRADUATOR_UNIV4_DIRECT = 0x09e01A80b2c555233B90E3AD7Ebc8F63d1a671AB;
    /// @notice `RealmLpLocker` holding every seed band and bid wall of `GRADUATOR_UNIV4_DIRECT`'s tokens.
    ///         Deployed by that graduator's constructor (read it back as `LP_LOCKER()`); `address(0)` until
    ///         the graduator that deploys one is live on this chain.
    address public constant LP_LOCKER = 0x44bB5Da1e8eA3C8B1917261381D0e228dfED0F7F;

    /// @notice `RealmFactoryUniV4Direct` proxy — the direct-launch venue's entry point.
    address public constant FACTORY_UNIV4_DIRECT = 0x7d02298989f2cE2Af36F7dCcadbB9985E30BCD53;

    /// @notice Implementation behind `FACTORY_UNIV4_DIRECT`.
    address public constant FACTORY_UNIV4_DIRECT_IMPL = 0x6591168598af7631Bd817e50f2ed43747db97bD6;

    /// @notice `RealmAssetsWhitelist` proxy (UUPS): the quote currencies the direct venue will launch
    ///         against, each with the native rate derived from its price pool. `FACTORY_UNIV4_DIRECT`
    ///         holds it as an immutable, so replacing it means a new factory implementation.
    address public constant ASSETS_WHITELIST = 0x551B32cB9f7A6379Cec3907b5be1e0D3c1653AfE;

    /// @notice Implementation behind `ASSETS_WHITELIST`. Tracked for verification and audit trails only.
    address public constant ASSETS_WHITELIST_IMPL = 0x642C06E754D97E0bD796bd669D5E7dA56E430D23;

    /// @notice `SwapLpFeeRouter` proxy (UUPS) consumed by `SWAP_HOOK`; splits LP fees 30/70
    ///         treasury/creator.
    /// @dev The hook holds this as an immutable, so it must be deployed BEFORE the hook
    ///      (`DeployRealmPrereqs`). Router policy changes ship by `upgradeToAndCall`ing this proxy.
    /// @dev Re-exported: the value lives in `DeploymentAddresses.sol`, which the token impls bake in.
    address internal constant LP_FEE_ROUTER = DeploymentAddressesRobinhoodMainnet.LP_FEE_ROUTER;
    /// @notice The `SwapLpFeeRouter` implementation behind `LP_FEE_ROUTER`. Update on every router
    ///         upgrade; tracked for verification and audit trails only.
    address internal constant LP_FEE_ROUTER_IMPL = 0x0aF788a823C918b7D2C1C795f7108D6dc78e3153;
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
    address internal constant QUOTER = 0x678DE99643535BF5697a5e25AED8C76Cb3796fBD;
    /// @notice `RealmKeeperLens`: the stateless, view-only batch reader the dividend keeper drives its
    ///         per-token reads through. Consumed OFF chain only — no Realm contract references it — so it
    ///         is redeployed and repointed freely rather than upgraded. `address(0)` until deployed.
    address internal constant KEEPER_LENS = 0x6bE41662c3862447393aaF469c8608fb20790AEc;

    /// @notice `RealmSwapper` proxy: every protocol swap (dividend conversions, LP token-fee sells).
    /// @dev Re-exported: the value lives in `DeploymentAddresses.sol`, which the token impls bake in.
    address internal constant REALM_SWAPPER = DeploymentAddressesRobinhoodMainnet.REALM_SWAPPER;
    /// @notice Implementation behind `REALM_SWAPPER`. Update on every registry upgrade; tracked for
    ///         verification and audit trails only.
    address internal constant REALM_SWAPPER_IMPL = 0xcfb55b1E2A0ef787852De17F1011E85986C96587;

    // --- Token implementations (cloned by factories) ---
    address internal constant TOKEN_IMPL = 0x33452730dF17418Bf260B7Dc7993D99d29F37902;
    address internal constant TAXABLE_TOKEN_V4_IMPL = 0xB2aAa10f4772477af007b2b63F9bFCC0D37B9Aa2;

    /// @notice V2 taxable token implementation (cloned by `RealmFactoryUniV2Unified` when tax is configured)
    address internal constant TAXABLE_TOKEN_V2_IMPL = 0x3594bC13e9ff82e47C59887599FE9AE51Ba21072;

    // --- Factories (unified) ---
    /// @notice UUPS proxy addresses that integrators whitelist. These stay stable across upgrades.
    address internal constant FACTORY_UNIV2_UNIFIED = 0x0FEBCAd2654e754dAAb4BCebCB16E3Ed7d8B0B79;

    /// @notice Implementation addresses currently set behind the proxies above. Updated on every
    ///         `UpgradeRealmFactories` run. Tracked for Etherscan verification and audit trails;
    ///         no contract or frontend consumes these directly.
    address internal constant FACTORY_UNIV2_UNIFIED_IMPL = 0xe6ff3025E718153d72ddf396b5e345a9e078F467;

    // --- Creator vaults ---
    /// @notice `RealmCreatorVault` implementation cloned by the vault factory. Update after deploying.
    address internal constant CREATOR_VAULT_IMPL = 0x465ca30c56c16cCeCB6D45d5Fe69f8C6A1539DCB;
    /// @notice `RealmCreatorVaultFactory` UUPS proxy (stable across upgrades). Update after deploying.
    address internal constant CREATOR_VAULT_FACTORY = 0xE07792100C2Aa00E2B80807B4c0AfC0cfF3F4Fae;
    /// @notice `RealmCreatorVaultFactory` implementation behind the proxy. Update after deploying.
    address internal constant CREATOR_VAULT_FACTORY_IMPL = 0x5D94c565654c9EbA716f1DEa19F29D166e68C3ee;

    /// @notice The six allocation-specific bonding curves (`ConstantProductBondingCurveConfigurable`),
    ///         one per locked allocation. Update after deploying with `DeployRealmStack`.
    address internal constant VAULT_CURVE_5 = 0x2F994171887F64Dc78D18F28e547e26950F47214;
    address internal constant VAULT_CURVE_10 = 0x6E041705DA4FfF0D25278611A01FF9288cB689d1;
    address internal constant VAULT_CURVE_15 = 0xeC9494C3765dCdF67Da428887E6eD6903a20E7D3;
    address internal constant VAULT_CURVE_20 = 0x3dB40c91E81D086dE6D821575550a0EA7023BF79;
    address internal constant VAULT_CURVE_25 = 0xAf775E593C5CfA2Eb3256b6A6b95b94BacB1eFBa;
    address internal constant VAULT_CURVE_30 = 0x12e3D5897928AC52c98b889376037887278103F3;

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
    address internal constant THIN_CURVE_BASE = 0x0C6E7c885211E4f476cb3fE9192c8F3b4965DB86;
    address internal constant THIN_VAULT_CURVE_5 = 0xdF31B4Ccd5C8a9105254bD3c52c6729421BfCc10;
    address internal constant THIN_VAULT_CURVE_10 = 0xcEeb8cA9F97A46923c837Df3Df9a8B58cB46d8fA;
    address internal constant THIN_VAULT_CURVE_15 = 0x0c8a1fF5411c85A73A50768376d518ED8d30049B;
    address internal constant THIN_VAULT_CURVE_20 = 0x18C467d2e9C0A51bbD7D83923230A97FcA7E83FA;
    address internal constant THIN_VAULT_CURVE_25 = 0x734bA4EFaF05c862e914b0E647c7917962D27E83;
    address internal constant THIN_VAULT_CURVE_30 = 0x54E44F7C42f5164B64aD07C1bd4cA35aFCb3AA16;

    /// @notice THICK-tier bonding curves. Same layout as the THIN tier above.
    address internal constant THICK_CURVE_BASE = 0x53c0D1C0e854211E999FC87e15b65b51fac43FAE;
    address internal constant THICK_VAULT_CURVE_5 = 0x6463E7f308fC9DCfbB10a3BbB06a304918C67086;
    address internal constant THICK_VAULT_CURVE_10 = 0x52929C5f9573bde2ae707DA2Ba0c081D6eeb8b05;
    address internal constant THICK_VAULT_CURVE_15 = 0x9b35DFFa91dac7715183c45450E02EF332BC7aC2;
    address internal constant THICK_VAULT_CURVE_20 = 0xB7E315Af9401CDf90E34F37014f09108909eeB7D;
    address internal constant THICK_VAULT_CURVE_25 = 0x7e4d26f2e31c861Cc24CCEeF009203a7c2c39A5B;
    address internal constant THICK_VAULT_CURVE_30 = 0x24511Bf85068297056e4A7BD960c16062b991c49;

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
    address internal constant REALM_KEEPER = 0x622E3d8a1283d5ccbB4F36c6eFC2eccbdBcA4075;
}
