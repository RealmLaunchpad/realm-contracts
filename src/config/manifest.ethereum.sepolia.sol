// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Realm deployment manifest — Sepolia
/// @notice Single source of truth for Realm's own deployed contracts on chain id 11155111.
/// @dev External infrastructure (Uniswap V2/V4, Permit2, WETH) lives in
///      `src/config/DeploymentAddresses.sol`. Treasury (sepolia: dev EOA) also lives
///      there since it is consumed by core contracts at deploy time. Update this file
///      on every redeploy and run `just export-deployments` to refresh
///      `deployments.ethereum.sepolia.md`.
library DeploymentsEthereumSepolia {
    uint256 internal constant BLOCKCHAIN_ID = 11155111;

    // --- Core ---
    address internal constant LAUNCHPAD = 0x5f09e414a6f8A004D152dE6aeA5FD435c4188dEC;
    address internal constant BONDING_CURVE = 0x63B78b60fbD518aa66944E60579372C421cf06d7;
    address internal constant GRADUATOR_UNIV2 = 0xA99282F37825E996a15B9619A13575A266127Ea3;
    address internal constant GRADUATOR_UNIV4 = 0x53b659806b6DDF83D4a14f607A8d28487b140cF3;

    /// @notice Shared, permissionless `RealmUniV4LiquidityAdder` singleton — one per chain, passed to every
    ///         V4 graduator and used by taxable tokens' `processLiquidity`. Deploy with
    ///         `DeployRealmStack`; `address(0)` until first deployed on this chain.
    address internal constant UNIV4_LIQUIDITY_ADDER = 0xE8168F37CdaAdB08818469De191eD2461EEcc229;
    address internal constant MASTER_FEE_HANDLER = 0x914e8A6fcA2af6E8Cf4434d1D50234fC89CdF2Ec;

    /// @notice Swap hook: fee-agnostic, reads each token's `swapLpFeeBps` via
    ///         `getSwapFees` and forwards LP fees to `LP_FEE_ROUTER`. The V4 graduators point here.
    /// @dev Realm deploys its OWN hook rather than reusing the Livo one, whose `TREASURY` and
    ///      `FEE_ROUTER` immutables are pinned to Livo addresses and cannot be repointed. Deploy with
    ///      `DeployRealmSwapHook` (`RealmSwapHook` or `RealmHook`, see that script) and paste whichever
    ///      variant Uniswap whitelists. `address(0)` until then.
    address internal constant SWAP_HOOK = 0xE3246e5Ae48bA84e345D88b3e7473ae8DBB540cC;

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
    address internal constant LP_FEE_ROUTER = 0x823ca5B8041217Df052D9e64AC6E7c16A62FA957;
    /// @notice The `SwapLpFeeRouter` implementation behind `LP_FEE_ROUTER`. Update on every router
    ///         upgrade; tracked for verification and audit trails only.
    address internal constant LP_FEE_ROUTER_IMPL = 0xa2E3C9B3B33Cbad41ECCA283734c335490a09d4a;
    /// @notice `RealmTreasuryRouter` proxy (UUPS): the treasury address every push lands on once live —
    ///         `LAUNCHPAD.treasury()` and the `SwapLpFeeRouter` impl's `TREASURY` point here. Forwards 1/3
    ///         to `VOTING`, the rest to the team multisig. Deployed by `DeployRealmTreasuryRouter`, which also
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
    address internal constant QUOTER = 0x5606c6EDF892FEd317c60C95a1BCcDA5c1c5f551;

    // --- Token implementations (cloned by factories) ---
    address internal constant TOKEN_IMPL = 0xa5498948245b1D3CDda08B9324e22c709CE9bDE7;
    address internal constant TAXABLE_TOKEN_V4_IMPL = 0x0a4d26B99a124Bb08bc335764b6C2A1ee4C3E85c;

    /// @notice V2 taxable token implementation (cloned by `RealmFactoryUniV2Unified` when tax is configured)
    address internal constant TAXABLE_TOKEN_V2_IMPL = 0xdf63307C4Da6bD3Ed84C0682A3788F35845446c0;

    // --- Factories (unified) ---
    /// @notice UUPS proxy addresses that integrators whitelist. These stay stable across upgrades.
    address internal constant FACTORY_UNIV2_UNIFIED = 0xC2793d815BA81AaDC5ae5c8b6de5f14365f8743B;
    address internal constant FACTORY_UNIV4_UNIFIED = 0xAb8e2Ab6516712DA4E0f5B1fa3AB964Bf8b3e8Cf;

    /// @notice Implementation addresses currently set behind the proxies above. Updated on every
    ///         `UpgradeRealmFactories` run. Tracked for Etherscan verification and audit trails;
    ///         no contract or frontend consumes these directly.
    address internal constant FACTORY_UNIV2_UNIFIED_IMPL = 0xbcb1cA6a9B8DDFdaB3E4676FaF0115B408199774;
    address internal constant FACTORY_UNIV4_UNIFIED_IMPL = 0x61fa8c5a21378719C993F116Eb3f5984E280C408;

    // --- Creator vaults ---
    /// @notice `RealmCreatorVault` implementation cloned by the vault factory. Update after deploying.
    address internal constant CREATOR_VAULT_IMPL = 0x64dDAe54fb7c1f2b6E1a76645422D8cd26B23ceF;
    /// @notice `RealmCreatorVaultFactory` UUPS proxy (stable across upgrades). Update after deploying.
    address internal constant CREATOR_VAULT_FACTORY = 0x284A47F94624037Cca0f7b0c13734F6C684B9F6C;
    /// @notice `RealmCreatorVaultFactory` implementation behind the proxy. Update after deploying.
    address internal constant CREATOR_VAULT_FACTORY_IMPL = 0xd346ECc082B5db7D7fb787aB7c14f4222e2dd042;

    /// @notice The six allocation-specific bonding curves (`ConstantProductBondingCurveConfigurable`),
    ///         one per locked allocation. Update after deploying with `DeployRealmStack`.
    address internal constant VAULT_CURVE_5 = 0x88Ee77C8d151FcFC2CF410EEc19a878B8E260e70;
    address internal constant VAULT_CURVE_10 = 0x5De1A697f5463319b38f795CEf4F0d0E7b87608d;
    address internal constant VAULT_CURVE_15 = 0x03bC021fd09E75d1dbbB040742Fa85629F3e04b8;
    address internal constant VAULT_CURVE_20 = 0x6d78a676a7b6DDEA364F427eF2EB1CFfeC10cfF2;
    address internal constant VAULT_CURVE_25 = 0x90D9FdE054E6a6860cE760Fa7a40362a6b122f1F;
    address internal constant VAULT_CURVE_30 = 0x04d14C0dE84757E4539C7429983E5b5FBF30AbD9;

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
    address internal constant GRADUATOR_UNIV4_THIN = 0x6B29469d3E5D5861E6a5C449863a0566E163272C;
    address internal constant GRADUATOR_UNIV4_THICK = 0xd0b4476f2044574CA498A5AdD5DFB26516E2526d;

    /// @notice THIN-tier bonding curves (`ConstantProductBondingCurveConfigurable`): the no-vault
    ///         base curve plus six vault curves (5%..30%). Update after deploying with
    ///         `DeployRealmStack`. Venue-agnostic — shared by the V2 and V4 factories.
    address internal constant THIN_CURVE_BASE = 0xA8Df983578993Eea0C02C08BD84Aaaea07FdBc8d;
    address internal constant THIN_VAULT_CURVE_5 = 0x2DAB5D3a65F6deE7F72a60abb6E7ECbf03304783;
    address internal constant THIN_VAULT_CURVE_10 = 0x3D194bcD0B3b84ed0e1f657d1b48C7fE4243238c;
    address internal constant THIN_VAULT_CURVE_15 = 0x5aBBE013BE0FB3E34b1b01Fc1870137D132F40Cb;
    address internal constant THIN_VAULT_CURVE_20 = 0x834DE31760b75A6989b54b0dc23Fa076991EC328;
    address internal constant THIN_VAULT_CURVE_25 = 0x4cD7a42DF15C49867e42C1c8ae562b6B8358F3D5;
    address internal constant THIN_VAULT_CURVE_30 = 0x2ddb749849276FACe386f2Cf975a6f786468e022;

    /// @notice THICK-tier bonding curves. Same layout as the THIN tier above.
    address internal constant THICK_CURVE_BASE = 0x5aF1D8216a07C47Cc34E64E1f63e7C1Ec32690B9;
    address internal constant THICK_VAULT_CURVE_5 = 0xFcfEBf16e01A18Cc02a04791ACC00A113F56528D;
    address internal constant THICK_VAULT_CURVE_10 = 0xE3055ABdF44A3802421D20347C37F9de5e8C37AE;
    address internal constant THICK_VAULT_CURVE_15 = 0x45F77df37a0e987D7EF0d97f5D30ad56DF3aBC6A;
    address internal constant THICK_VAULT_CURVE_20 = 0x2446dC637A897bEDDad7Da2103C17b30d4F36ca4;
    address internal constant THICK_VAULT_CURVE_25 = 0x4c651Ca2099A5c87C56b65B4006841C6aefE31F8;
    address internal constant THICK_VAULT_CURVE_30 = 0x6fd7765a8b08E45ff7F1816d3688784675ecd6A5;

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
    ///      `deprecated.realm.dev` keystore holds. That old key still owns the contracts deployed before the
    ///      rotation — `REALM_KEEPERS_REGISTRY` and `DIVIDEND_SWAP_REGISTRY` in `DeploymentAddresses.sol` —
    ///      so their `setAdmin` / `transferOwnership` must still be signed with it.
    address internal constant REALM_DEV = 0x81f7D06a88223f5a2850411E72256AacC9E27035;
    address internal constant REALM_TOKEN_DEPLOYER = 0x566CB296539672bB2419F403d292544E9Abf7815;
    /// @notice The keeper lambda's EOA: `isKeeper` on `REALM_KEEPERS_REGISTRY` and the `keeper` that
    ///         `DIVIDEND_SWAP_REGISTRY` refunds gas to. Set via `setKeeper` / `setKeeperFunding`.
    address internal constant REALM_KEEPER = 0xE092CB5868e1Ca091Ea975069bf2Afc9CDD1732C;
}
