// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Livo deployment manifest — Robinhood Chain Mainnet
/// @notice Single source of truth for Livo's own deployed contracts on chain id 4663.
/// @dev External infrastructure (Uniswap V2/V4, Permit2, WETH) lives in
///      `src/config/DeploymentAddresses.sol`. Treasury also lives
///      there since it is consumed by core contracts at deploy time. Update this file
///      on every redeploy and run `just export-deployments` to refresh
///      `deployments.robinhood.mainnet.md`.
library DeploymentsRobinhoodMainnet {
    uint256 internal constant BLOCKCHAIN_ID = 4663;

    // --- Core ---
    address internal constant LAUNCHPAD = 0xfD550c5dC070Ea575A06A40f2e18304D85211663;
    address internal constant BONDING_CURVE = 0x696180420F8215749d5D59bD6239eE0e66e97A64;
    address internal constant GRADUATOR_UNIV2 = 0x3828e402D901603eFcBd71F03Eba406B71f5e307;
    address internal constant GRADUATOR_UNIV4 = 0x071221210C33962eEd92081e93e73e9a06149E92;

    /// @notice Shared, permissionless `LivoUniV4LiquidityAdder` singleton — one per chain, passed to every
    ///         V4 graduator and used by taxable tokens' `processLiquidity`. Deploy with
    ///         `DeployUniV4LiquidityAdder`; `address(0)` until first deployed on this chain.
    address internal constant UNIV4_LIQUIDITY_ADDER = address(0);
    address internal constant MASTER_FEE_HANDLER = 0x7766e3a6A8C98a76308CFb4040E330c3308F7C73;

    /// @notice Marketcap-tiered `LivoSwapHook`: fee-agnostic, reads each token's `swapLpFeeBps` via
    ///         `getSwapFees` and forwards LP fees to `LP_FEE_ROUTER`. Wired to the router + treasury below.
    /// @dev All three `GRADUATOR_UNIV4*` addresses below are wired to this hook (verified on-chain via
    ///      `HOOK_ADDRESS()`). The RETIRED fee-hardcoded hook (`0xbFFe76CC9e506285032B2e5D1B74B579e39ac0CC`)
    ///      is still live and serving the tokens already graduated on it, but nothing in this manifest
    ///      points at it any more. The retired 0.5% hook/graduator variants are recorded in the legacy git
    ///      history of `deployments.robinhood.mainnet.md`.
    address internal constant SWAP_HOOK = 0xdB1902Bc975992828616b0224D9C5Ff907E9c0Cc;
    /// @notice LP fee router proxy (UUPS) consumed by `LivoSwapHook`; splits LP fees treasury/creator by marketcap tier.
    address internal constant LP_FEE_ROUTER = 0x3175bB69cfeE26FC90ea0A33E45BbDe466053f43;
    address internal constant LP_FEE_ROUTER_IMPL = 0x3C6773BC3e9dBC76834e3F38D05066BA72Abd410;
    address internal constant QUOTER = 0x5176076dD27C12b5fF60eFbf97D2C6a0697CE0DF;

    // --- Token implementations (cloned by factories) ---
    address internal constant TOKEN_IMPL = 0x92A71B6A578D2345946DeCeDbCA3874702a3fCa3;
    address internal constant TAXABLE_TOKEN_V4_IMPL = 0xCbcaB7c9d9Ce45CEFb17bBEbd419881b253d7371;

    /// @notice V2 taxable token implementation (cloned by `LivoFactoryUniV2Unified` when tax is configured)
    address internal constant TAXABLE_TOKEN_V2_IMPL = 0x2Bf62383a4A1349461bB744b4eC561338D8b4CF9;

    // --- Factories (unified) ---
    /// @notice UUPS proxy addresses that integrators whitelist. These stay stable across upgrades.
    address internal constant FACTORY_UNIV2_UNIFIED = 0x7843203be233b3Be7E5017A68a64FdBf32b45fFE;
    address internal constant FACTORY_UNIV4_UNIFIED = 0xb637800Dcd5c83913D828E961dBB964A9896f19d;

    /// @notice Implementation addresses currently set behind the proxies above. Updated on every
    ///         `UpgradeUnifiedFactories` run. Tracked for Etherscan verification and audit trails;
    ///         no contract or frontend consumes these directly.
    address internal constant FACTORY_UNIV2_UNIFIED_IMPL = 0x66534bDE4f69F69342F929479797F7118B7ca74F;
    address internal constant FACTORY_UNIV4_UNIFIED_IMPL = 0xF74aD241bDe9e2DAe7849D06ee4935731c1B5258;

    // --- Creator vaults ---
    /// @notice `LivoCreatorVault` implementation cloned by the vault factory. Update after deploying.
    address internal constant CREATOR_VAULT_IMPL = 0xE735d281d313AD09bd8bFF81F181715b6c6aD772;
    /// @notice `LivoCreatorVaultFactory` UUPS proxy (stable across upgrades). Update after deploying.
    address internal constant CREATOR_VAULT_FACTORY = 0xBa1a7Fe65E7aAb563630F5921080996030a80AA1;
    /// @notice `LivoCreatorVaultFactory` implementation behind the proxy. Update after deploying.
    address internal constant CREATOR_VAULT_FACTORY_IMPL = 0xf5E30BE2b72b0dEbCD85103AdaE399CbC3046Fcf;

    /// @notice The six allocation-specific bonding curves (`ConstantProductBondingCurveConfigurable`),
    ///         one per locked allocation. Update after deploying with `DeployCreatorVaultSystem`.
    address internal constant VAULT_CURVE_5 = 0x34Cac940b94e2Cb577CBB671c2272412E1436a68;
    address internal constant VAULT_CURVE_10 = 0xEF6fCB80e976733dCd9e4F0b2F3A9C49771a09Fb;
    address internal constant VAULT_CURVE_15 = 0x61D6362e1FF2e81059D8fFeAc2407950a65684a6;
    address internal constant VAULT_CURVE_20 = 0xe4772247D918E32a9908EDb4225c4a123C576e48;
    address internal constant VAULT_CURVE_25 = 0x87426937c4e28F69900C2f3453399CF5F06886D7;
    address internal constant VAULT_CURVE_30 = 0xF5c4fEaC340e65A95EF72499E0aFaD4d45812946;

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
    ///         `RedeployUniV4Graduators`. Both point at `SWAP_HOOK` above.
    address internal constant GRADUATOR_UNIV4_THIN = 0xa1D4E34AC9946Ab53B155E79d0A3023e52B27400;
    address internal constant GRADUATOR_UNIV4_THICK = 0x338728dA52Fb88679793E74D6E3f2177b64C1Dc4;

    /// @notice THIN-tier bonding curves (`ConstantProductBondingCurveConfigurable`): the no-vault
    ///         base curve plus six vault curves (5%..30%). Update after deploying with
    ///         `DeployTierLiquiditySystem`. Venue-agnostic — shared by the V2 and V4 factories.
    address internal constant THIN_CURVE_BASE = 0xf69FC76AEdAA95C1EE0f466760290cE77f94885D;
    address internal constant THIN_VAULT_CURVE_5 = 0x522fD5758e5185Cc95e2D0A8CB30f4a4B70c9107;
    address internal constant THIN_VAULT_CURVE_10 = 0x004f58F78DFbAC06439Da806C2E60d11B66E9731;
    address internal constant THIN_VAULT_CURVE_15 = 0x895c4914B0b11f285289493332Aa6A91D1B6A067;
    address internal constant THIN_VAULT_CURVE_20 = 0xe8a447E523138853d9B73f390a9cA603fa914a26;
    address internal constant THIN_VAULT_CURVE_25 = 0x28c0118F75c0658253036CEFbAf45EB2dF128642;
    address internal constant THIN_VAULT_CURVE_30 = 0xa076265b17B34eA6f8fF378d35E80C88b55aA9d2;

    /// @notice THICK-tier bonding curves. Same layout as the THIN tier above.
    address internal constant THICK_CURVE_BASE = 0xe42Be5CBEf30E6Ca3C5cBB0B9C631C619832ad89;
    address internal constant THICK_VAULT_CURVE_5 = 0x5f1df884684AD0a52fB5bd896147284907D321EC;
    address internal constant THICK_VAULT_CURVE_10 = 0xb33771a7Eb4fC9f54Adb39ec4519591477295974;
    address internal constant THICK_VAULT_CURVE_15 = 0x4BD5224FEec1c9c6194389bFEF8Db43144BE36f1;
    address internal constant THICK_VAULT_CURVE_20 = 0x8DF0D2791A55863d5a152f5Ab6f80b4aff243828;
    address internal constant THICK_VAULT_CURVE_25 = 0x8a80112BCdd79f7b2635DDB4775ca50b56A940B2;
    address internal constant THICK_VAULT_CURVE_30 = 0x77c51a398ff81cBDb14ed0FBc7816252fF78877F;

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
    address internal constant LIVO_DEV = 0xBa489180Ea6EEB25cA65f123a46F3115F388f181;
    address internal constant LIVO_TOKEN_DEPLOYER = address(0);
}
