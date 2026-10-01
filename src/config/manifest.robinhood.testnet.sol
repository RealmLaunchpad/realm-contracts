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
    address internal constant LAUNCHPAD = 0xC847726FA54b6d0E41043f0Aa20Bc6caBFA3eEAA;
    address internal constant BONDING_CURVE = 0xFfcc1DD49d72C614aeB957B6E667287aB1600b3B;
    address internal constant GRADUATOR_UNIV2 = 0x0df553Cc64bfDe391a7dd6e00b13928b93Abc996;

    /// @notice Shared, permissionless `RealmUniV4LiquidityAdder` singleton — one per chain, passed to the
    ///         direct V4 graduator and used by taxable tokens' `processLiquidity`. Deploy with
    ///         `DeployRealmStack`; `address(0)` until first deployed on this chain.
    address internal constant UNIV4_LIQUIDITY_ADDER = 0xD852F5FCC5511d71CcAA0820b3FcCD7D2Cf28a6d;
    address internal constant MASTER_FEE_HANDLER = 0x566eab62A5f768f17D4261eb123766C8F3A3B741;

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
    address public constant GRADUATOR_UNIV4_DIRECT = 0xDB19b9412d351536C907891E10601F2e85Ee3E1a;
    /// @notice `RealmLpLocker` holding every seed band and bid wall of `GRADUATOR_UNIV4_DIRECT`'s tokens.
    ///         Deployed by that graduator's constructor (read it back as `LP_LOCKER()`); `address(0)` until
    ///         the graduator that deploys one is live on this chain.
    address public constant LP_LOCKER = 0x8a6a403A4193FB6f31FF729CC986F1fEd70a1c44;

    /// @notice `RealmFactoryUniV4Direct` proxy — the direct-launch venue's entry point.
    address public constant FACTORY_UNIV4_DIRECT = 0xAB24A7B6b7CA47B64C4EC3BCCDd53FB91b5EBeC2;

    /// @notice Implementation behind `FACTORY_UNIV4_DIRECT`.
    address public constant FACTORY_UNIV4_DIRECT_IMPL = 0xAD67c9cab2aaDa04952c83a2ddd800Ae4219B5aE;

    /// @notice `RealmAssetsWhitelist` proxy (UUPS): the quote currencies the direct venue will launch
    ///         against, each with the native rate derived from its price pool. `FACTORY_UNIV4_DIRECT`
    ///         holds it as an immutable, so replacing it means a new factory implementation.
    address public constant ASSETS_WHITELIST = 0x9C777eB8A40Dd70612148Daa39B4a6B1358aa00D;

    /// @notice Implementation behind `ASSETS_WHITELIST`. Tracked for verification and audit trails only.
    address public constant ASSETS_WHITELIST_IMPL = 0x6c85A8Fc071862f5383BFe6392D6B8A87D7D994C;

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
    address internal constant LP_FEE_ROUTER_IMPL = 0xb2C47D2ED28C7286bcCe53E04F095aB07b37d0b1;
    /// @notice `RealmTreasuryRouter` proxy (UUPS): the treasury address every push lands on once live —
    ///         `LAUNCHPAD.treasury()` and the `SwapLpFeeRouter` impl's `TREASURY` point here. Forwards 1/3
    ///         to `VOTING`, the rest to the team multisig. Deployed by `DeployRealmTreasuryStack`, which also
    ///         does that repointing; `address(0)` until then.
    address internal constant TREASURY_ROUTER = 0x2BE1D41df10E674f9E07195cAA0B16Cb1acB88C8;
    /// @notice Implementation behind `TREASURY_ROUTER`. Tracked for verification and audit trails only.
    address internal constant TREASURY_ROUTER_IMPL = 0x47a9734c06e5C684be757177CD974AbFFDE40c2d;
    /// @notice The REALM token (a launchpad token like any other; the one `VOTING` burns). `address(0)`
    ///         until it is launched on this chain.
    address internal constant REALM_TOKEN = 0xAf5bc7F655618c3148dE9C4b36faF3D9cE75eeAa;
    /// @notice `RealmVoting` proxy (UUPS): REALM burn-to-vote rounds. Needs the REALM token, so it is
    ///         deployed after the first token; `TREASURY_ROUTER` bakes it in, so it comes BEFORE that.
    address internal constant VOTING = 0x899657a6CCe27e1a865c051201344713e9b92fDD;
    /// @notice Implementation behind `VOTING`. Tracked for verification and audit trails only.
    address internal constant VOTING_IMPL = 0xC0b56623Bf3D49CaD97ff051f1f270e320C549F4;
    address internal constant QUOTER = 0x07f157b125395E1e3Ad85aB03a54EA1f1a6cB5B9;
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
    address internal constant TOKEN_IMPL = 0xa6B76b57B3F2d494007e05Ef94Dd0AAB96BC8436;
    address internal constant TAXABLE_TOKEN_V4_IMPL = 0xc2E3453FF2687cC10e1F5915577E4366257cc7F3;

    /// @notice V2 taxable token implementation (cloned by `RealmFactoryUniV2Unified` when tax is configured)
    address internal constant TAXABLE_TOKEN_V2_IMPL = 0xE4BdED43EBA13A0184DD233bAb149129eE204b6A;

    // --- Factories (unified) ---
    /// @notice UUPS proxy addresses that integrators whitelist. These stay stable across upgrades.
    address internal constant FACTORY_UNIV2_UNIFIED = 0x5D67E6480D3aeFD2B062369c86Ccb2637358c72c;

    /// @notice Implementation addresses currently set behind the proxies above. Updated on every
    ///         `UpgradeRealmFactories` run. Tracked for Etherscan verification and audit trails;
    ///         no contract or frontend consumes these directly.
    address internal constant FACTORY_UNIV2_UNIFIED_IMPL = 0xC3013795Ea9A38Cc7100fF1D43CAf328E7111b21;

    // --- Creator vaults ---
    /// @notice `RealmCreatorVault` implementation cloned by the vault factory. Update after deploying.
    address internal constant CREATOR_VAULT_IMPL = 0x398cceaa2A75b0f106925D6a2b0d3BF0b05FD78e;
    /// @notice `RealmCreatorVaultFactory` UUPS proxy (stable across upgrades). Update after deploying.
    address internal constant CREATOR_VAULT_FACTORY = 0xB627A77aa44A2D61294560bcd478a10cf6BeD5d5;
    /// @notice `RealmCreatorVaultFactory` implementation behind the proxy. Update after deploying.
    address internal constant CREATOR_VAULT_FACTORY_IMPL = 0x5D04A729BE86190a398d9aE45dC0308F5Abf0a0f;

    /// @notice The six allocation-specific bonding curves (`ConstantProductBondingCurveConfigurable`),
    ///         one per locked allocation. Update after deploying with `DeployRealmStack`.
    address internal constant VAULT_CURVE_5 = 0xFE695eE546Dd8eAB86B71788609Fe9c3Cc29A03A;
    address internal constant VAULT_CURVE_10 = 0x6620FD86496eb9B472D2C916e59C9D27EeF9D1a4;
    address internal constant VAULT_CURVE_15 = 0x613f03Bb1f2190f158cEd2ACcB174401C69ec643;
    address internal constant VAULT_CURVE_20 = 0xac5E380C3f941df93C74c9633D38F2e22147AD21;
    address internal constant VAULT_CURVE_25 = 0xed968fb1c91D97267dCF917c20213961DfFE02d4;
    address internal constant VAULT_CURVE_30 = 0x37DBB64f824Ef1a6d11bc68e1a28F4d4C5926099;

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
    address internal constant THIN_CURVE_BASE = 0x1b6DAfec68c0567398938Bcb19ce6a4C16F8c750;
    address internal constant THIN_VAULT_CURVE_5 = 0x3CFBd9056452b1E15079a7E52D15a7AF05F77B80;
    address internal constant THIN_VAULT_CURVE_10 = 0xcEB13de91dA7187949067b1A6A98329EAfEd117f;
    address internal constant THIN_VAULT_CURVE_15 = 0x1bC99A11895C126a3AF8c16D1791b04C3A58b511;
    address internal constant THIN_VAULT_CURVE_20 = 0x10Cd08caaf85F612E87e2F8030539e381A7c43AA;
    address internal constant THIN_VAULT_CURVE_25 = 0x52549d3F5896F35f7D338761f6C93470D0E3e2c4;
    address internal constant THIN_VAULT_CURVE_30 = 0xc01CD7FBC6b017aA3806d54D9C822D2Ea20F870e;

    /// @notice THICK-tier bonding curves. Same layout as the THIN tier above.
    address internal constant THICK_CURVE_BASE = 0xB27BBd70b2a4F2B3315a01AF274Ec9fb57665472;
    address internal constant THICK_VAULT_CURVE_5 = 0xa394a45889aA8ee8f97d3223d6C2dd0383BAA8F9;
    address internal constant THICK_VAULT_CURVE_10 = 0xF93B457f1dAE3216E20456A293a840dc33BEeb3F;
    address internal constant THICK_VAULT_CURVE_15 = 0xbA68B81Ce0E12bD665Eab7fd4507b40CCFADEDC6;
    address internal constant THICK_VAULT_CURVE_20 = 0x19472724D32a32fe069e3085eA3323500b5CA71D;
    address internal constant THICK_VAULT_CURVE_25 = 0xF17A18307bBCdfb76B5C29f01867627c994F44B5;
    address internal constant THICK_VAULT_CURVE_30 = 0x2F14f43424B6d4d9d1C0E346AdBC20A324cd51cC;

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
