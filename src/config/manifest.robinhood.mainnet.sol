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
    address internal constant LAUNCHPAD = 0xEB046f43bd0AC18182dEa44e5B95b0Dc0d8dEeAa;
    address internal constant BONDING_CURVE = 0x8e954f9534e74c2A65819405E74BF2D7094d1816;
    address internal constant GRADUATOR_UNIV2 = 0xC31FE602A1f89A1fb484eE7cBD4EA775c5bA4B7C;

    /// @notice Shared, permissionless `RealmUniV4LiquidityAdder` singleton — one per chain, passed to the
    ///         direct V4 graduator and used by taxable tokens' `processLiquidity`. Deploy with
    ///         `DeployRealmStack`; `address(0)` until first deployed on this chain.
    address internal constant UNIV4_LIQUIDITY_ADDER = 0x9bCAbBf75B6CB66Eaa15AB0caA0BCb48A150385e;
    address internal constant MASTER_FEE_HANDLER = 0xe693579893A4E7066c2f69858694bcE9D4Fbf3D4;

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
    address public constant GRADUATOR_UNIV4_DIRECT = 0xD1AF35970A304d3529c16997C1f2e21CA341d621;
    /// @notice `RealmLpLocker` holding every seed band and bid wall of `GRADUATOR_UNIV4_DIRECT`'s tokens.
    ///         Deployed by that graduator's constructor (read it back as `LP_LOCKER()`); `address(0)` until
    ///         the graduator that deploys one is live on this chain.
    address public constant LP_LOCKER = 0x77493d5Efc88817A252a1a17Acd48951Af0EC016;

    /// @notice `RealmFactoryUniV4Direct` proxy — the direct-launch venue's entry point.
    address public constant FACTORY_UNIV4_DIRECT = 0xC763b1795DaBe2D2336EbA214d16969EBc5db27F;

    /// @notice Implementation behind `FACTORY_UNIV4_DIRECT`.
    address public constant FACTORY_UNIV4_DIRECT_IMPL = 0x51a0Dc18E965D8a93CabE37D227d2Dc05f40Efbd;

    /// @notice `RealmAssetsWhitelist` proxy (UUPS): the quote currencies the direct venue will launch
    ///         against, each with the native rate derived from its price pool. `FACTORY_UNIV4_DIRECT`
    ///         holds it as an immutable, so replacing it means a new factory implementation.
    address public constant ASSETS_WHITELIST = 0x1Fe8baA5254fD125386Da072cddd1c804BEe0e94;

    /// @notice Implementation behind `ASSETS_WHITELIST`. Tracked for verification and audit trails only.
    address public constant ASSETS_WHITELIST_IMPL = 0x233Fd9e6A79fB80c90f50c23Bc9aA57d0417F952;

    /// @notice `SwapLpFeeRouter` proxy (UUPS) consumed by `SWAP_HOOK`; splits LP fees 30/70
    ///         treasury/creator.
    /// @dev The hook holds this as an immutable, so it must be deployed BEFORE the hook
    ///      (`DeployRealmPrereqs`). Router policy changes ship by `upgradeToAndCall`ing this proxy.
    /// @dev Re-exported: the value lives in `DeploymentAddresses.sol`, which the token impls bake in.
    address internal constant LP_FEE_ROUTER = DeploymentAddressesRobinhoodMainnet.LP_FEE_ROUTER;
    /// @notice The `SwapLpFeeRouter` implementation behind `LP_FEE_ROUTER`. Update on every router
    ///         upgrade; tracked for verification and audit trails only.
    address internal constant LP_FEE_ROUTER_IMPL = 0x91fd2fFa173bC417Fc2Fd2FD5443f9f18c705C09;
    /// @notice `RealmTreasuryRouter` proxy (UUPS): the treasury address every push lands on once live —
    ///         `LAUNCHPAD.treasury()` and the `SwapLpFeeRouter` impl's `TREASURY` point here. Forwards 1/3
    ///         to `VOTING`, the rest to the team multisig. Deployed by `DeployRealmTreasuryStack`, which also
    ///         does that repointing; `address(0)` until then.
    address internal constant TREASURY_ROUTER = 0x8F597ad86F07F3d1CF3Eb90eB1089ed6BDCbb6E2;
    /// @notice Implementation behind `TREASURY_ROUTER`. Tracked for verification and audit trails only.
    address internal constant TREASURY_ROUTER_IMPL = 0xb52E9Ed0fE8d95B9561316b5Dca8a804D554e748;
    /// @notice The REALM token (a launchpad token like any other; the one `VOTING` burns). `address(0)`
    ///         until it is launched on this chain.
    address internal constant REALM_TOKEN = 0x4898891604a8d11798af0551766D7e100E5e1EDe;
    /// @notice `RealmVoting` proxy (UUPS): REALM burn-to-vote rounds. Needs the REALM token, so it is
    ///         deployed after the first token; `TREASURY_ROUTER` bakes it in, so it comes BEFORE that.
    address internal constant VOTING = 0x73E9F2B4Ea042FF7019773fc5B6A83649CA0456E;
    /// @notice Implementation behind `VOTING`. Tracked for verification and audit trails only.
    address internal constant VOTING_IMPL = 0xF5f3c635882DaA374d5927a442b25c323809Cc65;
    address internal constant QUOTER = 0xa9082bDfE16B19B2d28Fb55317d5ec6a274Fa8a0;
    /// @notice `RealmKeeperLens`: the stateless, view-only batch reader the dividend keeper drives its
    ///         per-token reads through. Consumed OFF chain only — no Realm contract references it — so it
    ///         is redeployed and repointed freely rather than upgraded. `address(0)` until deployed.
    address internal constant KEEPER_LENS = 0x99003757c6Cb83491234fA87C989ED35027122DB;

    /// @notice `RealmSwapper` proxy: every protocol swap (dividend conversions, LP token-fee sells).
    /// @dev Re-exported: the value lives in `DeploymentAddresses.sol`, which the token impls bake in.
    address internal constant REALM_SWAPPER = DeploymentAddressesRobinhoodMainnet.REALM_SWAPPER;
    /// @notice Implementation behind `REALM_SWAPPER`. Update on every registry upgrade; tracked for
    ///         verification and audit trails only.
    address internal constant REALM_SWAPPER_IMPL = 0x64065D09D3BedD141A1aedeDb36c286EB1512f09;

    // --- Token implementations (cloned by factories) ---
    address internal constant TOKEN_IMPL = 0xec3325Fe7B81c9aE6Aef607cC054b635B313ca5a;
    address internal constant TAXABLE_TOKEN_V4_IMPL = 0x92c7BFade4D90b5db982b32CB15C7D3f8EF741fa;

    /// @notice V2 taxable token implementation (cloned by `RealmFactoryUniV2Unified` when tax is configured)
    address internal constant TAXABLE_TOKEN_V2_IMPL = 0x333C3DE2816ab1c91bc9750f78a15f92CFC0C83E;

    // --- Factories (unified) ---
    /// @notice UUPS proxy addresses that integrators whitelist. These stay stable across upgrades.
    address internal constant FACTORY_UNIV2_UNIFIED = 0x8f83B3FbB0b296ed8e6f9781A5FD4f415ACE3916;

    /// @notice Implementation addresses currently set behind the proxies above. Updated on every
    ///         `UpgradeRealmFactories` run. Tracked for Etherscan verification and audit trails;
    ///         no contract or frontend consumes these directly.
    address internal constant FACTORY_UNIV2_UNIFIED_IMPL = 0xAe71Ee93d1176543400e444087A43df1e832b7BB;

    // --- Creator vaults ---
    /// @notice `RealmCreatorVault` implementation cloned by the vault factory. Update after deploying.
    address internal constant CREATOR_VAULT_IMPL = 0x670a1fFD8F02F10E39d48725193af08e725353A5;
    /// @notice `RealmCreatorVaultFactory` UUPS proxy (stable across upgrades). Update after deploying.
    address internal constant CREATOR_VAULT_FACTORY = 0x3B730eB37E6c947e22aC838584b72A4030595b05;
    /// @notice `RealmCreatorVaultFactory` implementation behind the proxy. Update after deploying.
    address internal constant CREATOR_VAULT_FACTORY_IMPL = 0x2b13Cc2b65D5E870405F91bC88B2b98bA5e7f4e7;

    /// @notice The six allocation-specific bonding curves (`ConstantProductBondingCurveConfigurable`),
    ///         one per locked allocation. Update after deploying with `DeployRealmStack`.
    address internal constant VAULT_CURVE_5 = 0x6F147d631d520094208355D89d92151Ccb368e2e;
    address internal constant VAULT_CURVE_10 = 0xaFB3aCc00434908F7002480adB36e1DBCB41F1E6;
    address internal constant VAULT_CURVE_15 = 0xD3EAf1C3C25f153fe2549531995F705C204c6bd3;
    address internal constant VAULT_CURVE_20 = 0x1cd96AFa17A95B94c8D777a67202d16D9552CFbE;
    address internal constant VAULT_CURVE_25 = 0x4415bA5b19B51e999d3532Cc3C0082b35999dA4c;
    address internal constant VAULT_CURVE_30 = 0x714063584630B12f3027d50c9635E14973330832;

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
    address internal constant THIN_CURVE_BASE = 0x71a5B1fF782205a020ADcFF0B57B8F519bf6DD03;
    address internal constant THIN_VAULT_CURVE_5 = 0x6ba6A1C465B0410761fFf4408034a16DAe1CEF2f;
    address internal constant THIN_VAULT_CURVE_10 = 0x1786ED5f7B053cB7c496Dc790fA4aAf0C95EaE07;
    address internal constant THIN_VAULT_CURVE_15 = 0x4672330e51E6E7d696FFbF6b52d1415F52D2A56b;
    address internal constant THIN_VAULT_CURVE_20 = 0x95b61f0Cd83F782d128997f62D5706CC62Aede21;
    address internal constant THIN_VAULT_CURVE_25 = 0x38587aC633F3C281e2AAAa9D375214FcB94042c9;
    address internal constant THIN_VAULT_CURVE_30 = 0x71bF73B12F0921Fc463922cc3f6B4c0aAF88fF0D;

    /// @notice THICK-tier bonding curves. Same layout as the THIN tier above.
    address internal constant THICK_CURVE_BASE = 0x578BA60A29289DD4216534cE195E5c49d62Cb2B2;
    address internal constant THICK_VAULT_CURVE_5 = 0x859D95792be39478342aCAFC9c6F442989fb46E0;
    address internal constant THICK_VAULT_CURVE_10 = 0x58418b551247897F63459A25a2DdF48E85ebE867;
    address internal constant THICK_VAULT_CURVE_15 = 0xf5D575668Bee7eE13caD2b7aF13Ba44646F43B28;
    address internal constant THICK_VAULT_CURVE_20 = 0xE03481F6F728663302a992e68Bd937dC25981F04;
    address internal constant THICK_VAULT_CURVE_25 = 0xb501471C214df92aefA0E1368D17bcFa8fD4AdC5;
    address internal constant THICK_VAULT_CURVE_30 = 0x2C17a088AC88fa1bAedeaDC059f6967469BB467d;

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
    address internal constant REALM_KEEPER = 0x9FC60bd60298eCe67ab98ff10CaC8Bd7E37eEc02;
}
