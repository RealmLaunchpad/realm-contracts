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
    address internal constant LAUNCHPAD = 0x8e0CdCF7842B0C383a36b2c569f84203F406eeAA;
    address internal constant BONDING_CURVE = 0x3A8923444AEBF1Da9950E7478386cf89E9c32074;
    address internal constant GRADUATOR_UNIV2 = 0x849dcEAe7aE00fAcC46802D4cfa41D299EacfEAf;

    /// @notice Shared, permissionless `RealmUniV4LiquidityAdder` singleton — one per chain, passed to the
    ///         direct V4 graduator and used by taxable tokens' `processLiquidity`. Deploy with
    ///         `DeployRealmStack`; `address(0)` until first deployed on this chain.
    address internal constant UNIV4_LIQUIDITY_ADDER = 0x20129911e18C775BBBC7388cfBe8D88F0371E96E;
    address internal constant MASTER_FEE_HANDLER = 0xA0cbcF47Eb58D56f480047465C8f52aa984Fdd88;

    /// @notice Swap hook: fee-agnostic, reads each token's `swapLpFeeBps` via
    ///         `getSwapFees` and forwards LP fees to `LP_FEE_ROUTER`. The direct V4 graduator points here for native pools.
    /// @dev Realm deploys its OWN hook rather than reusing the Livo one, whose `TREASURY` and
    ///      `FEE_ROUTER` immutables are pinned to Livo addresses and cannot be repointed. Deploy with
    ///      `DeployRealmSwapHook` (`RealmSwapHook` or `RealmHook`, see that script) and paste whichever
    ///      variant Uniswap whitelists. `address(0)` until then.
    address internal constant SWAP_HOOK = 0xCb31DF4846fd7aFaF4Ffdb074c733DE216F340Cc;

    /// @notice `RealmHookAnyPair`: the hook every ERC20-quoted Realm pool is bound to. A SECOND hook
    ///         beside `SWAP_HOOK`, which is whitelisted by Uniswap and keeps every native pool. Mined
    ///         with the same permission bits; deployed by `DeployRealmHookAnyPair`.
    address public constant SWAP_HOOK_ANY_PAIR = 0x87f077ebBE1D9d35D5E4522bf0a4e30adaaF40cc;

    /// @notice `RealmDirectGraduatorUniV4`: the direct-launch venue's graduator. Non-upgradeable, holds
    ///         every launch's seed position NFTs forever.
    address public constant GRADUATOR_UNIV4_DIRECT = 0xDaC64d8cB1182291a8586A39C6634d7BcD6a06fa;

    /// @notice `RealmFactoryUniV4Direct` proxy — the direct-launch venue's entry point.
    address public constant FACTORY_UNIV4_DIRECT = 0x3307857e113E9fF6D53Cf5478F9320407232574E;

    /// @notice Implementation behind `FACTORY_UNIV4_DIRECT`.
    address public constant FACTORY_UNIV4_DIRECT_IMPL = 0xCc19CEf72D915fe6A340486DF48eE990d0A226fc;

    /// @notice `RealmAssetsWhitelist` proxy (UUPS): the quote currencies the direct venue will launch
    ///         against, each with the native rate derived from its price pool. `FACTORY_UNIV4_DIRECT`
    ///         holds it as an immutable, so replacing it means a new factory implementation.
    address public constant ASSETS_WHITELIST = 0x0f3629Bd715C17373d7E401eB3f0ed94B46991d5;

    /// @notice Implementation behind `ASSETS_WHITELIST`. Tracked for verification and audit trails only.
    address public constant ASSETS_WHITELIST_IMPL = 0x6FAdbD11CF2dcD46305dC195A12cdF671ba96BE3;

    /// @notice `RealmDividendLogicUniV4`: the LIVE V4 token impl's dividend extension, reached only by
    ///         `delegatecall`. Removed from the source (folded into the token); kept as a deploy record.
    address public constant DIVIDEND_LOGIC_V4 = 0x6E45BfD35f4681b709079Dd886b3437fAd5996ff;

    /// @notice `RealmEarningsLogicUniV4`: the V4 token's buy-back / liquidity extension. Same shape.
    address public constant EARNINGS_LOGIC_V4 = 0x1BC0878C4225DDB72075b4683cE28497cc703B6f;
    /// @notice `SwapLpFeeRouter` proxy (UUPS) consumed by `SWAP_HOOK`; splits LP fees 30/70
    ///         treasury/creator.
    /// @dev The hook holds this as an immutable, so it must be deployed BEFORE the hook
    ///      (`DeployRealmPrereqs`). Router policy changes ship by `upgradeToAndCall`ing this proxy.
    address internal constant LP_FEE_ROUTER = 0xE4E30f8BFdA12af0f92991343c30F1b45A733aa0;
    /// @notice The `SwapLpFeeRouter` implementation behind `LP_FEE_ROUTER`. Update on every router
    ///         upgrade; tracked for verification and audit trails only.
    address internal constant LP_FEE_ROUTER_IMPL = 0xf3cFa580922c9266199818bFf756cC6E5C1bF826;
    /// @notice `RealmTreasuryRouter` proxy (UUPS): the treasury address every push lands on once live —
    ///         `LAUNCHPAD.treasury()` and the `SwapLpFeeRouter` impl's `TREASURY` point here. Forwards 1/3
    ///         to `VOTING`, the rest to the team multisig. Deployed by `DeployRealmTreasuryRouter`, which also
    ///         does that repointing; `address(0)` until then.
    address internal constant TREASURY_ROUTER = 0xE28B56Fd2409bEa3AA0e9861F8327502e6aB562B;
    /// @notice Implementation behind `TREASURY_ROUTER`. Tracked for verification and audit trails only.
    address internal constant TREASURY_ROUTER_IMPL = 0x2bBD05a8B7ac1D0Fe07C33397ff9D48e51F74Bcb;
    /// @notice The REALM token (a launchpad token like any other; the one `VOTING` burns). `address(0)`
    ///         until it is launched on this chain.
    address internal constant REALM_TOKEN = 0xedcA28e57E99379B3B4dc2c6C0BF0812a13cEEaA;
    /// @notice `RealmVoting` proxy (UUPS): REALM burn-to-vote rounds. Needs the REALM token, so it is
    ///         deployed after the first token; `TREASURY_ROUTER` bakes it in, so it comes BEFORE that.
    address internal constant VOTING = 0xd1fDE1598C7617fc6D987f1C93717aEE17735Fa5;
    /// @notice Implementation behind `VOTING`. Tracked for verification and audit trails only.
    address internal constant VOTING_IMPL = 0x110A9EB4A1B1913a705652Da1BA185D3398e1f8F;
    address internal constant QUOTER = 0xDD6C23cc9fD2113eDD11139d9BC695dD02d51883;
    /// @notice `RealmKeeperLens`: the stateless, view-only batch reader the dividend keeper drives its
    ///         per-token reads through. Consumed OFF chain only — no Realm contract references it — so it
    ///         is redeployed and repointed freely rather than upgraded. `address(0)` until deployed.
    address internal constant KEEPER_LENS = 0x3101f0F56708ef2b57559849a6A31218d1a17260;

    /// @notice Implementation behind the `RealmDividendSwapRegistry` proxy, which lives in
    ///         `DeploymentAddresses.sol` (`DIVIDEND_SWAP_REGISTRY`). Update on every registry upgrade;
    ///         tracked for verification and audit trails only.
    address internal constant DIVIDEND_SWAP_REGISTRY_IMPL = 0x7d01a4Ff4d61D0A91Dc92FF62B542298104C6121;

    // --- Token implementations (cloned by factories) ---
    address internal constant TOKEN_IMPL = 0x5cE49423A9034925a4D667838fC5719FeD9319e7;
    address internal constant TAXABLE_TOKEN_V4_IMPL = 0xA2869A3E1B66846B4FC57127Dd9eDE016e7C4A6F;

    /// @notice V2 taxable token implementation (cloned by `RealmFactoryUniV2Unified` when tax is configured)
    address internal constant TAXABLE_TOKEN_V2_IMPL = 0x265d839C1A3fe56661fc1ef1789D39E66799fa3b;

    // --- Factories (unified) ---
    /// @notice UUPS proxy addresses that integrators whitelist. These stay stable across upgrades.
    address internal constant FACTORY_UNIV2_UNIFIED = 0xbC2Ce024f4425B4928De257f3F3f8813f6a80122;

    /// @notice Implementation addresses currently set behind the proxies above. Updated on every
    ///         `UpgradeRealmFactories` run. Tracked for Etherscan verification and audit trails;
    ///         no contract or frontend consumes these directly.
    address internal constant FACTORY_UNIV2_UNIFIED_IMPL = 0x5ECC654222630C8B9Ba7ab5D6CEeDEaBAA6aa324;

    // --- Creator vaults ---
    /// @notice `RealmCreatorVault` implementation cloned by the vault factory. Update after deploying.
    address internal constant CREATOR_VAULT_IMPL = 0x4A2C4A74bFa4Db8039372E4caaFBfBd05C79304B;
    /// @notice `RealmCreatorVaultFactory` UUPS proxy (stable across upgrades). Update after deploying.
    address internal constant CREATOR_VAULT_FACTORY = 0x7a0073E5bF9fCB85Cbfe8b8340987055aEc7E5EA;
    /// @notice `RealmCreatorVaultFactory` implementation behind the proxy. Update after deploying.
    address internal constant CREATOR_VAULT_FACTORY_IMPL = 0x2af5d6a4dEC999446DC900e681Fe3E0Cb8f1DFc1;

    /// @notice The six allocation-specific bonding curves (`ConstantProductBondingCurveConfigurable`),
    ///         one per locked allocation. Update after deploying with `DeployRealmStack`.
    address internal constant VAULT_CURVE_5 = 0xfb2ca43D65BDF19529F65da1e9136db99205A4db;
    address internal constant VAULT_CURVE_10 = 0x1193ce7193535c5F88cf89278446D79D74d0ecc4;
    address internal constant VAULT_CURVE_15 = 0xD15720a23646B7aa0E2904f661B4683e46188B15;
    address internal constant VAULT_CURVE_20 = 0x06F24f0548960d1eF37005775f6f2566656CCfBF;
    address internal constant VAULT_CURVE_25 = 0x29d8a60461de79762bA1A2A8D679187AAc87f763;
    address internal constant VAULT_CURVE_30 = 0x91a61251f008D32f20b5c31893e464DEC71f8D68;

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
    address internal constant THIN_CURVE_BASE = 0xFa67a0fFdD8251081D6e9C6e78E8E09FbF5B8F2f;
    address internal constant THIN_VAULT_CURVE_5 = 0x543E241b7162cFf3d3Ca327B7ad980B61496F566;
    address internal constant THIN_VAULT_CURVE_10 = 0xfA532A47d6928F5AE76e7668C9FC49f8623fA7F8;
    address internal constant THIN_VAULT_CURVE_15 = 0xc1C85D4Bd0F15d75ADc7EEBbf85783318BD7a58c;
    address internal constant THIN_VAULT_CURVE_20 = 0x50AAB50eeD9791D0C4c623e1BaCA7aA3128fD171;
    address internal constant THIN_VAULT_CURVE_25 = 0xe717FF95Ee16C0F386398Ed2d48587A73221AAfE;
    address internal constant THIN_VAULT_CURVE_30 = 0x6bBd189dB47c6Ed2b95eD49119BB25C93e7702b9;

    /// @notice THICK-tier bonding curves. Same layout as the THIN tier above.
    address internal constant THICK_CURVE_BASE = 0x678b0211E93bC124E07E02AadCF36C32A8ec5898;
    address internal constant THICK_VAULT_CURVE_5 = 0x844A550258DC6CbE605A874e1E1F32202ecf2Ae7;
    address internal constant THICK_VAULT_CURVE_10 = 0x6db725e7774b6EEDA05eCD537eCfEfBD64B3b346;
    address internal constant THICK_VAULT_CURVE_15 = 0x15f158Ff08d1DCa065bDD5d2cE4082305CC25428;
    address internal constant THICK_VAULT_CURVE_20 = 0x0F9c018d31cEdd446d6fA55393dd74CA8fBa918E;
    address internal constant THICK_VAULT_CURVE_25 = 0x61aD1cd458D88B4CE9BE376b22eC0c06A0f13F49;
    address internal constant THICK_VAULT_CURVE_30 = 0x46d99056415AF11eBEd2a2C4Afaea4adf1Ed5133;

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
    /// @notice The keeper lambda's EOA; appointed on the keepers registry.
    address internal constant REALM_KEEPER = 0xE092CB5868e1Ca091Ea975069bf2Afc9CDD1732C;
}
