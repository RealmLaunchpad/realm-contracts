// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DeploymentAddressesRobinhoodTestnet} from "src/config/DeploymentAddresses.sol";

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
    address internal constant LAUNCHPAD = 0xA74B2A973e2De76fFb80D440cC633220786Eeeaa;
    address internal constant BONDING_CURVE = 0xdDE5e6E499AB075660C816bf51a0Fe020e1D26F0;
    address internal constant GRADUATOR_UNIV2 = 0xe911474eda6CF973D5995DAE40d72b3f19b354c2;

    /// @notice Shared, permissionless `RealmUniV4LiquidityAdder` singleton — one per chain, passed to the
    ///         direct V4 graduator and used by taxable tokens' `processLiquidity`. Deploy with
    ///         `DeployRealmStack`; `address(0)` until first deployed on this chain.
    address internal constant UNIV4_LIQUIDITY_ADDER = 0x88C96AED2B2Ce7D1aC1d854970EB0B50f50a71Be;
    address internal constant MASTER_FEE_HANDLER = 0x41E9BF779B042C9BcEaa55E6729b16A59019660A;

    /// @notice Swap hook: fee-agnostic, reads each token's fees via `getSwapFees` (taxes only on current
    ///         tokens; the LP fee is the pool's native tier) and forwards any LP fee to `LP_FEE_ROUTER`. The direct V4 graduator points here for native pools.
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
    address public constant GRADUATOR_UNIV4_DIRECT = 0xa3e87b0236B9Fa1cbd10c6d9fDE8b72b627CfE4a;
    /// @notice `RealmLpLocker` holding every seed band and bid wall of `GRADUATOR_UNIV4_DIRECT`'s tokens.
    ///         Deployed by that graduator's constructor (read it back as `LP_LOCKER()`); `address(0)` until
    ///         the graduator that deploys one is live on this chain.
    address public constant LP_LOCKER = 0x92D3135C992e4288829a4C848c1Bdd1f901C215F;

    /// @notice `RealmFactoryUniV4Direct` proxy — the direct-launch venue's entry point.
    address public constant FACTORY_UNIV4_DIRECT = 0xF0399F67e359c08A18816E466364797b7fBc4df4;

    /// @notice Implementation behind `FACTORY_UNIV4_DIRECT`.
    address public constant FACTORY_UNIV4_DIRECT_IMPL = 0xff0F11E1B4A338C301B116d20b62D7d8bC566892;

    /// @notice `RealmAssetsWhitelist` proxy (UUPS): the quote currencies the direct venue will launch
    ///         against, each with the native rate derived from its price pool. `FACTORY_UNIV4_DIRECT`
    ///         holds it as an immutable, so replacing it means a new factory implementation.
    address public constant ASSETS_WHITELIST = 0xf15562e731c05Fb9DD9c7BE0a2FD8C03b778c261;

    /// @notice Implementation behind `ASSETS_WHITELIST`. Tracked for verification and audit trails only.
    address public constant ASSETS_WHITELIST_IMPL = 0xC5006Ba2E152DA37E8Ad44927775B4e5B0447f5f;

    /// @notice `RealmDividendLogicUniV4`: the LIVE V4 token impl's dividend extension, reached only by
    ///         `delegatecall`. Removed from the source (folded into the token); kept as a deploy record.
    address public constant DIVIDEND_LOGIC_V4 = 0x6E45BfD35f4681b709079Dd886b3437fAd5996ff;

    /// @notice `RealmEarningsLogicUniV4`: the V4 token's buy-back / liquidity extension. Same shape.
    address public constant EARNINGS_LOGIC_V4 = 0x1BC0878C4225DDB72075b4683cE28497cc703B6f;
    /// @notice `SwapLpFeeRouter` proxy (UUPS) consumed by `SWAP_HOOK`; splits LP fees 30/70
    ///         treasury/creator.
    /// @dev The hook holds this as an immutable, so it must be deployed BEFORE the hook
    ///      (`DeployRealmPrereqs`). Router policy changes ship by `upgradeToAndCall`ing this proxy.
    /// @dev Re-exported: the value lives in `DeploymentAddresses.sol`, which the token impls bake in.
    address internal constant LP_FEE_ROUTER = DeploymentAddressesRobinhoodTestnet.LP_FEE_ROUTER;
    /// @notice The `SwapLpFeeRouter` implementation behind `LP_FEE_ROUTER`. Update on every router
    ///         upgrade; tracked for verification and audit trails only.
    address internal constant LP_FEE_ROUTER_IMPL = 0xD575E0a07438929966C018762367448b67691589;
    /// @notice `RealmTreasuryRouter` proxy (UUPS): the treasury address every push lands on once live —
    ///         `LAUNCHPAD.treasury()` and the `SwapLpFeeRouter` impl's `TREASURY` point here. Forwards 1/3
    ///         to `VOTING`, the rest to the team multisig. Deployed by `DeployRealmTreasuryStack`, which also
    ///         does that repointing; `address(0)` until then.
    address internal constant TREASURY_ROUTER = 0x49cCD62E9A4F713761F3E121a053dd9CBf67860F;
    /// @notice Implementation behind `TREASURY_ROUTER`. Tracked for verification and audit trails only.
    address internal constant TREASURY_ROUTER_IMPL = 0x82CEC809404EaE07Ee2A5CFa32bdAC222c5b77Df;
    /// @notice The REALM token (a launchpad token like any other; the one `VOTING` burns). `address(0)`
    ///         until it is launched on this chain.
    address internal constant REALM_TOKEN = 0x0F4536A356C649129806f91010e3d91266eEEEAA;
    /// @notice `RealmVoting` proxy (UUPS): REALM burn-to-vote rounds. Needs the REALM token, so it is
    ///         deployed after the first token; `TREASURY_ROUTER` bakes it in, so it comes BEFORE that.
    address internal constant VOTING = 0x5026DC7fF53e95147362421Aac2Cf4c15f37Edc7;
    /// @notice Implementation behind `VOTING`. Tracked for verification and audit trails only.
    address internal constant VOTING_IMPL = 0x97aE707A21eb832c563c10013d2dCA4B82F63801;
    address internal constant QUOTER = 0x84083D67C0CC576726AB5270e01315d728476dC5;
    /// @notice `RealmKeeperLens`: the stateless, view-only batch reader the dividend keeper drives its
    ///         per-token reads through. Consumed OFF chain only — no Realm contract references it — so it
    ///         is redeployed and repointed freely rather than upgraded. `address(0)` until deployed.
    address internal constant KEEPER_LENS = 0xCC128819B2E46bb042847aECA56AF1BE4BA0E38a;

    /// @notice `RealmSwapper` proxy: every protocol swap (dividend conversions, LP token-fee sells).
    /// @dev Re-exported: the value lives in `DeploymentAddresses.sol`, which the token impls bake in.
    address internal constant REALM_SWAPPER = DeploymentAddressesRobinhoodTestnet.REALM_SWAPPER;
    /// @notice Implementation behind `REALM_SWAPPER`. Update on every registry upgrade; tracked for
    ///         verification and audit trails only.
    address internal constant REALM_SWAPPER_IMPL = 0xa47C008C2abcee6cD6F796a7Dd18d162F28Bb927;

    // --- Token implementations (cloned by factories) ---
    address internal constant TOKEN_IMPL = 0x97bc923b0e7Cb85CF844d148bB3887E03850C2e7;
    address internal constant TAXABLE_TOKEN_V4_IMPL = 0xdf703921E857Eb724313Bf98E5e0b60160F0f22b;

    /// @notice V2 taxable token implementation (cloned by `RealmFactoryUniV2Unified` when tax is configured)
    address internal constant TAXABLE_TOKEN_V2_IMPL = 0x0be5C4834cfa8022e0dAFE53e172EEfCFBe24e12;

    // --- Factories (unified) ---
    /// @notice UUPS proxy addresses that integrators whitelist. These stay stable across upgrades.
    address internal constant FACTORY_UNIV2_UNIFIED = 0x90Ec28b1F31E576Bb368F873fEf209cFa6880c05;

    /// @notice Implementation addresses currently set behind the proxies above. Updated on every
    ///         `UpgradeRealmFactories` run. Tracked for Etherscan verification and audit trails;
    ///         no contract or frontend consumes these directly.
    address internal constant FACTORY_UNIV2_UNIFIED_IMPL = 0x0fCd28d5eA4BAe04271DD1B23b45a4Bd3D283Bc1;

    // --- Creator vaults ---
    /// @notice `RealmCreatorVault` implementation cloned by the vault factory. Update after deploying.
    address internal constant CREATOR_VAULT_IMPL = 0x00b87AAEd1D51675Fd1AF7731Da5fCe0eA008deF;
    /// @notice `RealmCreatorVaultFactory` UUPS proxy (stable across upgrades). Update after deploying.
    address internal constant CREATOR_VAULT_FACTORY = 0x0EEd34B7Da6cA5cF293DFcef1e2280697274026b;
    /// @notice `RealmCreatorVaultFactory` implementation behind the proxy. Update after deploying.
    address internal constant CREATOR_VAULT_FACTORY_IMPL = 0x84A4B551bD76219Ef064d9f43A178fEe5781574a;

    /// @notice The six allocation-specific bonding curves (`ConstantProductBondingCurveConfigurable`),
    ///         one per locked allocation. Update after deploying with `DeployRealmStack`.
    address internal constant VAULT_CURVE_5 = 0x73e970f30f6B7AC07F179B03B5B844A7b52afbEc;
    address internal constant VAULT_CURVE_10 = 0x23d1A64231cE5508e12D32462237069e9B7F17e5;
    address internal constant VAULT_CURVE_15 = 0x9756b155415A69eEAF5829C1DC52cE6e8874B98E;
    address internal constant VAULT_CURVE_20 = 0x93C33E33ECA0Dd2923D26B76D58Ea33BAFb296EE;
    address internal constant VAULT_CURVE_25 = 0xbFEE1c0ec81f4C17c2BFb476d956E810Da585397;
    address internal constant VAULT_CURVE_30 = 0xCDbB6278C04d5DB97972897F810138bDc80b89E2;

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
    address internal constant THIN_CURVE_BASE = 0x1624b6EC2A3E82928E04325E71589674056F7A5F;
    address internal constant THIN_VAULT_CURVE_5 = 0x038c3a0301b3878066532d0C030d977De6D5071f;
    address internal constant THIN_VAULT_CURVE_10 = 0xf8579ff9D8767B5101Ed104d9262Cf0b3d87A0f9;
    address internal constant THIN_VAULT_CURVE_15 = 0xd53D21Df208402ec5e0cf8C1BF383F1C11ADeC15;
    address internal constant THIN_VAULT_CURVE_20 = 0x635108A06F884a54d87A3db15fbefCB39b4cdD02;
    address internal constant THIN_VAULT_CURVE_25 = 0xcBE1A4c412Ac9C8eb427bcF6CcDb19d4bD2731a8;
    address internal constant THIN_VAULT_CURVE_30 = 0xbe165ed5051e153F6d68dC1371611044393Cd028;

    /// @notice THICK-tier bonding curves. Same layout as the THIN tier above.
    address internal constant THICK_CURVE_BASE = 0x6d4708696e62e30188C2357798Fe42F58906017F;
    address internal constant THICK_VAULT_CURVE_5 = 0x1AcBF1C247Ee71ECd6c33E7Af7F5eEc6EF1DA585;
    address internal constant THICK_VAULT_CURVE_10 = 0x0AE35e0474C289c45d135772c326f161Bfb20eaf;
    address internal constant THICK_VAULT_CURVE_15 = 0xB6Cb316D3385876fB730dDaBE68F0aaf38fc0dC4;
    address internal constant THICK_VAULT_CURVE_20 = 0x96BDCcf4Fcaf715bD1477c052572059C3D6F630e;
    address internal constant THICK_VAULT_CURVE_25 = 0xbc354a731940bDceBC0FAD24E609b3fa3c6A437e;
    address internal constant THICK_VAULT_CURVE_30 = 0xD184B23515792d3723906630026EEaaE3295B5F0;

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
    /// @notice The keeper lambda's EOA; appointed on the keepers registry.
    address internal constant REALM_KEEPER = 0xE092CB5868e1Ca091Ea975069bf2Afc9CDD1732C;
}
