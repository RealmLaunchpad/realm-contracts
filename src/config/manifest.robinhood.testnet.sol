// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Realm deployment manifest — Robinhood Chain Testnet
/// @notice Single source of truth for Realm's own deployed contracts on chain id 46630.
/// @dev External infrastructure (Uniswap V2/V4, Permit2, WETH) lives in
///      `src/config/DeploymentAddresses.sol`. Treasury also lives
///      there since it is consumed by core contracts at deploy time. Update this file
///      on every redeploy and run `just export-deployments` to refresh
///      `deployments.robinhood.testnet.md`.
library DeploymentsRobinhoodTestnet {
    uint256 internal constant BLOCKCHAIN_ID = 46630;

    // --- Core ---
    address internal constant LAUNCHPAD = 0x7FC9Df6114A845A8068dfeb1b0baF51B90d48740;
    address internal constant BONDING_CURVE = 0x33d09EB5A074782f7C79d002baE7959008b5574c;
    address internal constant GRADUATOR_UNIV2 = 0x0D1D9492C2FDBaAE34F790d21A575c73293bd24e;
    address internal constant GRADUATOR_UNIV4 = 0x4657b823dE45f267199E6B6485B7179ae154b807;

    /// @notice Shared, permissionless `RealmUniV4LiquidityAdder` singleton — one per chain, passed to every
    ///         V4 graduator and used by taxable tokens' `processLiquidity`. Deploy with
    ///         `DeployRealmStack`; `address(0)` until first deployed on this chain.
    address internal constant UNIV4_LIQUIDITY_ADDER = 0x97Ea0bD248de8745AfcE7F73A7fE68E18736a05e;
    address internal constant MASTER_FEE_HANDLER = 0xBFc87134883B77Ce80F7C1c7Efc17820c09b435C;

    /// @notice Swap hook: fee-agnostic, reads each token's `swapLpFeeBps` via
    ///         `getSwapFees` and forwards LP fees to `LP_FEE_ROUTER`. The V4 graduators point here.
    /// @dev Realm deploys its OWN hook rather than reusing the Livo one, whose `TREASURY` and
    ///      `FEE_ROUTER` immutables are pinned to Livo addresses and cannot be repointed. Deploy with
    ///      `DeployRealmSwapHook` (`RealmSwapHook` or `RealmHook`, see that script) and paste whichever
    ///      variant Uniswap whitelists. `address(0)` until then.
    address internal constant SWAP_HOOK = 0xCb31DF4846fd7aFaF4Ffdb074c733DE216F340Cc;

    /// @notice `RealmHookAnyPair`: the hook every ERC20-quoted Realm pool is bound to. A SECOND hook
    ///         beside `SWAP_HOOK`, which is whitelisted by Uniswap and keeps every native pool. Mined
    ///         with the same permission bits; deployed by `DeployRealmHookAnyPair`.
    address public constant SWAP_HOOK_ANY_PAIR = 0x0000000000000000000000000000000000000000;

    /// @notice `RealmDirectGraduatorUniV4`: the direct-launch venue's graduator. Non-upgradeable, holds
    ///         every launch's seed position NFTs forever.
    address public constant GRADUATOR_UNIV4_DIRECT = 0x0000000000000000000000000000000000000000;

    /// @notice `RealmFactoryUniV4Direct` proxy — the direct-launch venue's entry point.
    address public constant FACTORY_UNIV4_DIRECT = 0x0000000000000000000000000000000000000000;

    /// @notice Implementation behind `FACTORY_UNIV4_DIRECT`.
    address public constant FACTORY_UNIV4_DIRECT_IMPL = 0x0000000000000000000000000000000000000000;

    /// @notice `RealmAssetsWhitelist` proxy (UUPS): the quote currencies the direct venue will launch
    ///         against, each with the native rate derived from its price pool. `FACTORY_UNIV4_DIRECT`
    ///         holds it as an immutable, so replacing it means a new factory implementation.
    address public constant ASSETS_WHITELIST = 0x0000000000000000000000000000000000000000;

    /// @notice Implementation behind `ASSETS_WHITELIST`. Tracked for verification and audit trails only.
    address public constant ASSETS_WHITELIST_IMPL = 0x0000000000000000000000000000000000000000;

    /// @notice `RealmDividendLogicUniV4`: the V4 token's dividend extension. Passed to the token impl's
    ///         constructor and reached only by `delegatecall`; recorded here so it can be verified.
    address public constant DIVIDEND_LOGIC_V4 = 0x0000000000000000000000000000000000000000;

    /// @notice `RealmEarningsLogicUniV4`: the V4 token's buy-back / liquidity extension. Same shape.
    address public constant EARNINGS_LOGIC_V4 = 0x0000000000000000000000000000000000000000;
    /// @notice `SwapLpFeeRouter` proxy (UUPS) consumed by `SWAP_HOOK`; splits LP fees 30/70
    ///         treasury/creator.
    /// @dev The hook holds this as an immutable, so it must be deployed BEFORE the hook
    ///      (`DeployRealmPrereqs`). Router policy changes ship by `upgradeToAndCall`ing this proxy.
    address internal constant LP_FEE_ROUTER = 0xE4E30f8BFdA12af0f92991343c30F1b45A733aa0;
    /// @notice The `SwapLpFeeRouter` implementation behind `LP_FEE_ROUTER`. Update on every router
    ///         upgrade; tracked for verification and audit trails only.
    address internal constant LP_FEE_ROUTER_IMPL = 0x05FC54F41E240A7620d8e76A868E4e1EB064d0Cd;
    /// @notice `RealmTreasuryRouter` proxy (UUPS): the treasury address every push lands on once live —
    ///         `LAUNCHPAD.treasury()` and the `SwapLpFeeRouter` impl's `TREASURY` point here. Forwards 1/3
    ///         to `VOTING`, the rest to the team multisig. Deployed by `DeployRealmTreasuryRouter`, which also
    ///         does that repointing; `address(0)` until then.
    address internal constant TREASURY_ROUTER = 0xE28B56Fd2409bEa3AA0e9861F8327502e6aB562B;
    /// @notice Implementation behind `TREASURY_ROUTER`. Tracked for verification and audit trails only.
    address internal constant TREASURY_ROUTER_IMPL = 0x89d1ac70eF1D58C5F0a3aA0d461445A6A66F75D7;
    /// @notice The REALM token (a launchpad token like any other; the one `VOTING` burns). `address(0)`
    ///         until it is launched on this chain.
    address internal constant REALM_TOKEN = 0x6DE743Cc3CC7b283C4Dc80A35160fD07a937EeAa;
    /// @notice `RealmVoting` proxy (UUPS): REALM burn-to-vote rounds. Needs the REALM token, so it is
    ///         deployed after the first token; `TREASURY_ROUTER` bakes it in, so it comes BEFORE that.
    address internal constant VOTING = 0x18398f02fFB990B62A2371fD67f40cE24cDeCB38;
    /// @notice Implementation behind `VOTING`. Tracked for verification and audit trails only.
    address internal constant VOTING_IMPL = 0x51c98aD61B155399E18540aAaCcB7421b808f45b;
    address internal constant QUOTER = 0x99a41E696e39c45eAB006978D9Ad7F188039147a;

    // --- Token implementations (cloned by factories) ---
    address internal constant TOKEN_IMPL = 0xEB6cc7E55cd1DAbdD30bFfd9745c3fB93Be4b0D1;
    address internal constant TAXABLE_TOKEN_V4_IMPL = 0x25d70Dfab5447E80bE771a609AB5F92B3C894202;

    /// @notice V2 taxable token implementation (cloned by `RealmFactoryUniV2Unified` when tax is configured)
    address internal constant TAXABLE_TOKEN_V2_IMPL = 0x9Bb8dC03D767d7CA25424d183A1f18CdFE9344dd;

    // --- Factories (unified) ---
    /// @notice UUPS proxy addresses that integrators whitelist. These stay stable across upgrades.
    address internal constant FACTORY_UNIV2_UNIFIED = 0xe3159990B4DaE3Ae812F2591921988d0093056aB;
    address internal constant FACTORY_UNIV4_UNIFIED = 0x3B6bbE80f2e6138e7a612d11bA2A69d25e7Be320;

    /// @notice Implementation addresses currently set behind the proxies above. Updated on every
    ///         `UpgradeRealmFactories` run. Tracked for Etherscan verification and audit trails;
    ///         no contract or frontend consumes these directly.
    address internal constant FACTORY_UNIV2_UNIFIED_IMPL = 0xe73C45ec0a1c1389C842dF2E7CB59D53D73fEaf5;
    address internal constant FACTORY_UNIV4_UNIFIED_IMPL = 0xF143d1CA1cFcAb18A6B81609FFcE9B874D569Cc9;

    // --- Creator vaults ---
    /// @notice `RealmCreatorVault` implementation cloned by the vault factory. Update after deploying.
    address internal constant CREATOR_VAULT_IMPL = 0x24451106759727997e7b3455f9Ff4266d60402F7;
    /// @notice `RealmCreatorVaultFactory` UUPS proxy (stable across upgrades). Update after deploying.
    address internal constant CREATOR_VAULT_FACTORY = 0xDC6b4aec62B24aE8582d9393Bf0288C531033df5;
    /// @notice `RealmCreatorVaultFactory` implementation behind the proxy. Update after deploying.
    address internal constant CREATOR_VAULT_FACTORY_IMPL = 0xE2893aEaa4c88CF4197796bcb6C1930683D76981;

    /// @notice The six allocation-specific bonding curves (`ConstantProductBondingCurveConfigurable`),
    ///         one per locked allocation. Update after deploying with `DeployRealmStack`.
    address internal constant VAULT_CURVE_5 = 0x46627C8e1611b995177BFa21aA350e0b74747C42;
    address internal constant VAULT_CURVE_10 = 0xfc0C38BA004c67E14a45194c0ef6c1eA092D81EB;
    address internal constant VAULT_CURVE_15 = 0xc7EAA3af9112e1199f0Eab553F3339C0362a944c;
    address internal constant VAULT_CURVE_20 = 0x7c01945208D1FDaB23D0335f3cAaFe6A462646D8;
    address internal constant VAULT_CURVE_25 = 0xe55D16Ad006C3cf51cC2fa60D3bbFDD2F3f9b915;
    address internal constant VAULT_CURVE_30 = 0xec4AaE00a7Ee69C6864172347bDEadfb31494AC6;

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
    /// @notice THIN/THICK V4 graduators, one per tier (the fee-agnostic hook reads the swap fee from the
    ///         token). The DEFAULT tier reuses `GRADUATOR_UNIV4`. Update after deploying with
    ///         `DeployRealmStack` or `RedeployGraduators`. Both point at `SWAP_HOOK` above.
    address internal constant GRADUATOR_UNIV4_THIN = 0xD6b1F849D52e5bA577c9d153105C0c36B343A85B;
    address internal constant GRADUATOR_UNIV4_THICK = 0xa757400235BF395B200cd48850BD2369925cF9e9;

    /// @notice THIN-tier bonding curves (`ConstantProductBondingCurveConfigurable`): the no-vault
    ///         base curve plus six vault curves (5%..30%). Update after deploying with
    ///         `DeployRealmStack`. Venue-agnostic — shared by the V2 and V4 factories.
    address internal constant THIN_CURVE_BASE = 0xD8337a7B71F9eC48aBaBDFf7e9875E12e4f1bb4b;
    address internal constant THIN_VAULT_CURVE_5 = 0xC2dcc63DF56f4C192343703446a486BcA48F2798;
    address internal constant THIN_VAULT_CURVE_10 = 0xf5db4fB05749Dd9b7d2523A8D52Cafcb36fCE9e2;
    address internal constant THIN_VAULT_CURVE_15 = 0xAaC7544a9F56bb14C9A29b62AB4DbDfE376bEb00;
    address internal constant THIN_VAULT_CURVE_20 = 0xEc54ebbd8463341b1B318d97A15eA135DAf3c3da;
    address internal constant THIN_VAULT_CURVE_25 = 0x431cADEa3bbfb91bC7d065b6bfd234DccD760a3e;
    address internal constant THIN_VAULT_CURVE_30 = 0xDF18271063776573e444DB1DDB89C4E4A6403c65;

    /// @notice THICK-tier bonding curves. Same layout as the THIN tier above.
    address internal constant THICK_CURVE_BASE = 0x557c778574c278c9Ebd8EC3B4725955A648Abc81;
    address internal constant THICK_VAULT_CURVE_5 = 0x7738cB7BcdD535fBd8033c747d5b42AEb24F1448;
    address internal constant THICK_VAULT_CURVE_10 = 0x1baD03527861a8A629924A0F12E1DA315CB64FD3;
    address internal constant THICK_VAULT_CURVE_15 = 0xC894F5BB039c8FE4b3acE7e066c5EbB4A22e1AAE;
    address internal constant THICK_VAULT_CURVE_20 = 0x3DCBdd192e2Ca5CbFCC8b1BbDa33A02F34FB17B1;
    address internal constant THICK_VAULT_CURVE_25 = 0xd9a01D0d4C141296F83d48ebA80F2aE4380b5E6c;
    address internal constant THICK_VAULT_CURVE_30 = 0x437a0D31fE3a0329c614fef2558E9bE6FC72f525;

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

    // --- Accounts ---
    /// @notice The `realm.dev` deployer keystore: the broadcaster of every deploy script and the initial
    ///         owner of everything they deploy.
    /// @dev Rotated from the now-deprecated `0x1a209bB4d0bC40f169c06dC2808d7d512Aea62bb`, which is what the
    ///      `deprecated.realm.dev` keystore holds. Everything deployed on this chain is already owned by the new key.
    address internal constant REALM_DEV = 0x81f7D06a88223f5a2850411E72256AacC9E27035;
    address internal constant REALM_TOKEN_DEPLOYER = address(0);
    /// @notice The keeper lambda's EOA (see the Sepolia manifest); appointed on the keepers registry.
    address internal constant REALM_KEEPER = 0xE092CB5868e1Ca091Ea975069bf2Afc9CDD1732C;
}
