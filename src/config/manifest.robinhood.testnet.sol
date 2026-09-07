// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Livo deployment manifest — Robinhood Chain Testnet
/// @notice Single source of truth for Livo's own deployed contracts on chain id 46630.
/// @dev External infrastructure (Uniswap V2/V4, Permit2, WETH) lives in
///      `src/config/DeploymentAddresses.sol`. Treasury also lives
///      there since it is consumed by core contracts at deploy time. Update this file
///      on every redeploy and run `just export-deployments` to refresh
///      `deployments.robinhood.testnet.md`.
library DeploymentsRobinhoodTestnet {
    uint256 internal constant BLOCKCHAIN_ID = 46630;

    // --- Core ---
    address internal constant LAUNCHPAD = 0x15aC2AADeEe84A674157e2ca108efba43fcD0D49;
    address internal constant BONDING_CURVE = 0xF3303E03aa58B1366652E883326675E67E20423f;
    address internal constant GRADUATOR_UNIV2 = 0x57aA990063b49cABf3EE9FeB49dca8DADc9511cD;
    address internal constant GRADUATOR_UNIV4 = 0x99Fe2360f8121b3CE92a67612AE13Af18B738533;

    /// @notice Shared, permissionless `LivoUniV4LiquidityAdder` singleton — one per chain, passed to every
    ///         V4 graduator and used by taxable tokens' `processLiquidity`. Deploy with
    ///         `DeployUniV4LiquidityAdder`; `address(0)` until first deployed on this chain.
    address internal constant UNIV4_LIQUIDITY_ADDER = address(0);
    address internal constant MASTER_FEE_HANDLER = 0xFF076a7110A404674Af27EC9749CB021699890EA;

    /// @notice Marketcap-tiered `LivoSwapHook`: fee-agnostic, reads each token's `swapLpFeeBps` via
    ///         `getSwapFees` and forwards LP fees to `LP_FEE_ROUTER`. Wired to the router + treasury below.
    /// @dev All three `GRADUATOR_UNIV4*` addresses below are wired to this hook (verified on-chain via
    ///      `HOOK_ADDRESS()`). The RETIRED fee-hardcoded hook (`0x64c5fAE1c446FEE704BF63e8b1e4A004168740Cc`)
    ///      is still live and serving the tokens already graduated on it, but nothing in this manifest
    ///      points at it any more. The retired 0.5% hook/graduator variants are recorded in the legacy git
    ///      history of `deployments.robinhood.testnet.md`.
    address internal constant SWAP_HOOK = 0xc6A488bE0F7e7622aa42370De70Ee8f7bB4040cc;
    /// @notice LP fee router proxy (UUPS) consumed by `LivoSwapHook`; splits LP fees treasury/creator by marketcap tier.
    address internal constant LP_FEE_ROUTER = 0x9A996216c0Cd3B1cDeDC4D2A38E0ca94eBeC3565;
    address internal constant LP_FEE_ROUTER_IMPL = 0x75A42715c6B8912631971c0737E523a662Ec7064;
    address internal constant QUOTER = 0xaA9c5758D8E5804dbbC4c931C6EAf1Be68DD30CD;

    // --- Token implementations (cloned by factories) ---
    address internal constant TOKEN_IMPL = 0xf68Ea9a3522647C58d7c77edE156cAA0930a7101;
    address internal constant TAXABLE_TOKEN_V4_IMPL = 0x2aAE5BAa1FFE5a93a0feE92cb1d73FDA80120728;

    /// @notice V2 taxable token implementation (cloned by `LivoFactoryUniV2Unified` when tax is configured)
    address internal constant TAXABLE_TOKEN_V2_IMPL = 0x1f4F57DdCda5f2697899eEBe763682279b7aE39a;

    // --- Factories (unified) ---
    /// @notice UUPS proxy addresses that integrators whitelist. These stay stable across upgrades.
    address internal constant FACTORY_UNIV2_UNIFIED = 0xc0dE7109626A458dE1E0Ff06106830beD96DE971;
    address internal constant FACTORY_UNIV4_UNIFIED = 0xfBa7137768E53f3B6a0d2333F41C44BaC7161FA0;

    /// @notice Implementation addresses currently set behind the proxies above. Updated on every
    ///         `UpgradeUnifiedFactories` run. Tracked for Etherscan verification and audit trails;
    ///         no contract or frontend consumes these directly.
    address internal constant FACTORY_UNIV2_UNIFIED_IMPL = 0xBB0EBb375e9dc06DE3eC0d6410606Cb3DAc6737b;
    address internal constant FACTORY_UNIV4_UNIFIED_IMPL = 0x23f1b9158071B651268c4A626808958E2DC63f02;

    // --- Creator vaults ---
    /// @notice `LivoCreatorVault` implementation cloned by the vault factory. Update after deploying.
    address internal constant CREATOR_VAULT_IMPL = 0xd1B50918Aa2e34b89A89B23C84d2377F1622d0f6;
    /// @notice `LivoCreatorVaultFactory` UUPS proxy (stable across upgrades). Update after deploying.
    address internal constant CREATOR_VAULT_FACTORY = 0x7BA7523E87a07514Ec059D233AefbDED0C21833B;
    /// @notice `LivoCreatorVaultFactory` implementation behind the proxy. Update after deploying.
    address internal constant CREATOR_VAULT_FACTORY_IMPL = 0x76f404dDcbc6E3ff466F983121CC2b0D8a63F4cb;

    /// @notice The six allocation-specific bonding curves (`ConstantProductBondingCurveConfigurable`),
    ///         one per locked allocation. Update after deploying with `DeployCreatorVaultSystem`.
    address internal constant VAULT_CURVE_5 = 0xb6956027c44D4a1fa9437DE6f5e68ff4EF6A935B;
    address internal constant VAULT_CURVE_10 = 0x749cf5c70baAA1BCC2ACCF467F98A08a93eFb498;
    address internal constant VAULT_CURVE_15 = 0x2D8769aEd66F441Eb3aBE270DACc92761CCE994B;
    address internal constant VAULT_CURVE_20 = 0x768c48398aD5E4019bDB50e011a6012414Ba5e5C;
    address internal constant VAULT_CURVE_25 = 0x8A625e68c0705dBfFD2A3222fd2694651bAf4535;
    address internal constant VAULT_CURVE_30 = 0x653241bD3F700678f6D60C0d3eD606FA76Dd605B;

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
    address internal constant GRADUATOR_UNIV4_THIN = 0x354C5053E9D6a900C06F9475735cdE188260ab63;
    address internal constant GRADUATOR_UNIV4_THICK = 0xE8582a05eaD18B0231D9295E98B176c6E0391062;

    /// @notice THIN-tier bonding curves (`ConstantProductBondingCurveConfigurable`): the no-vault
    ///         base curve plus six vault curves (5%..30%). Update after deploying with
    ///         `DeployTierLiquiditySystem`. Venue-agnostic — shared by the V2 and V4 factories.
    address internal constant THIN_CURVE_BASE = 0x82A07D5A619AAa1125114d6eD746870B0Cc40edD;
    address internal constant THIN_VAULT_CURVE_5 = 0x0211C3577F35b625653f0660982BfFBcF0916F03;
    address internal constant THIN_VAULT_CURVE_10 = 0xD2485f8b2BA952CB9df5BF86Fae0b01950b1f5b3;
    address internal constant THIN_VAULT_CURVE_15 = 0x4399E0a4c1132a247A67E9Ae12A1d0A2CBd5E4CC;
    address internal constant THIN_VAULT_CURVE_20 = 0xC6eef0e88C3206A23C7F960ABf3aE245ec89B171;
    address internal constant THIN_VAULT_CURVE_25 = 0x911eFD4DDA954BF0647E438E28E0308a47Cc7A06;
    address internal constant THIN_VAULT_CURVE_30 = 0x8d5B86c29E0B8dF4eFBf63f72967a426C08B72B6;

    /// @notice THICK-tier bonding curves. Same layout as the THIN tier above.
    address internal constant THICK_CURVE_BASE = 0xf134c47de4644F7b7F2Df6AeeC29FBb22d205e6A;
    address internal constant THICK_VAULT_CURVE_5 = 0x45e88211f59291e33eaf7503b58CFB37123a8bC6;
    address internal constant THICK_VAULT_CURVE_10 = 0xeCe320b1C2ED2B25d6f66bb54c2e85f28391C2Fd;
    address internal constant THICK_VAULT_CURVE_15 = 0x207D277F18776327b75c14A9E7C1E8280D429c9A;
    address internal constant THICK_VAULT_CURVE_20 = 0xA55FA059B9848490E1009EA6161e5c03c9fD69dB;
    address internal constant THICK_VAULT_CURVE_25 = 0x9D305cd3A9C39d8f4A7D45DE30F420B1eBD38E52;
    address internal constant THICK_VAULT_CURVE_30 = 0xd8861EBe9Ee353c4Dcaed86C7B90d354f064cc8D;

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
