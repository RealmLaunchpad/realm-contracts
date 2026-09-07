// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Livo deployment manifest — Sepolia
/// @notice Single source of truth for Livo's own deployed contracts on chain id 11155111.
/// @dev External infrastructure (Uniswap V2/V4, Permit2, WETH) lives in
///      `src/config/DeploymentAddresses.sol`. Treasury (sepolia: dev EOA) also lives
///      there since it is consumed by core contracts at deploy time. Update this file
///      on every redeploy and run `just export-deployments` to refresh
///      `deployments.ethereum.sepolia.md`.
library DeploymentsEthereumSepolia {
    uint256 internal constant BLOCKCHAIN_ID = 11155111;

    // --- Core ---
    address internal constant LAUNCHPAD = 0x0f82BE05B136266203FcAD79A951bDbBB4f31110;
    address internal constant BONDING_CURVE = 0x523C474aB6C177B3A4eF9aeF226998eC3f35ae27;
    address internal constant GRADUATOR_UNIV2 = 0xdf2A4F12Af6Cce0588678FdA7ce69D5Edc7d0897;
    address internal constant GRADUATOR_UNIV4 = 0xa88eAEA0218F0c0E9cbeec17c3CF449379374Cc7;

    /// @notice Shared, permissionless `LivoUniV4LiquidityAdder` singleton — one per chain, passed to every
    ///         V4 graduator and used by taxable tokens' `processLiquidity`. Deploy with
    ///         `DeployUniV4LiquidityAdder`; `address(0)` until first deployed on this chain.
    address internal constant UNIV4_LIQUIDITY_ADDER = address(0);
    address internal constant MASTER_FEE_HANDLER = 0xcA5A02C3ADcEb4f37c2Bf6c6261EaD11166fb26f;

    address internal constant SWAP_HOOK = 0x681F2EEf3F43CfC6Eea7BFdAa801135E04ff00cC;
    /// @notice LP fee router proxy (UUPS) consumed by `LivoSwapHook`; splits LP fees treasury/creator by marketcap tier.
    address internal constant LP_FEE_ROUTER = 0x0cEC114e1b8712EBd9d67a773381410F0F78985A;
    address internal constant LP_FEE_ROUTER_IMPL = 0x215a7Cf7Cb881f52CA5350032ae56d27018A5889;
    address internal constant QUOTER = 0x17b8f037a261344714A64643Bde0Bd7C5745b3BE;

    // --- Token implementations (cloned by factories) ---
    address internal constant TOKEN_IMPL = 0x171d6448db236Ca3e185e0c9536f0B4D26C1cc24;
    address internal constant TAXABLE_TOKEN_V4_IMPL = 0xCCAf520224f6334dE8911B20E78B6Fa1df6D75cb;

    /// @notice V2 taxable token implementation (cloned by `LivoFactoryUniV2Unified` when tax is configured)
    address internal constant TAXABLE_TOKEN_V2_IMPL = 0x89b299A94B6d8Cb1B9F539a1B9B7a2CDd027DFE4;

    // --- Factories (unified) ---
    /// @notice UUPS proxy addresses that integrators whitelist. These stay stable across upgrades.
    address internal constant FACTORY_UNIV2_UNIFIED = 0x87Dd69F8d294fA9cd704fccd38d36d6197F80868;
    address internal constant FACTORY_UNIV4_UNIFIED = 0x2a992f6f5F7c049A165a13069BE3DbDEaa5C391b;

    /// @notice Implementation addresses currently set behind the proxies above. Updated on every
    ///         `UpgradeUnifiedFactories` run. Tracked for Etherscan verification and audit trails;
    ///         no contract or frontend consumes these directly.
    address internal constant FACTORY_UNIV2_UNIFIED_IMPL = 0xe2d96367A020B2a04465959B62d985E16bc11764;
    address internal constant FACTORY_UNIV4_UNIFIED_IMPL = 0x12bEbC0FAeE410F502674e00eaF27ada66b1172F;

    // --- Creator vaults ---
    /// @notice `LivoCreatorVault` implementation cloned by the vault factory. Update after deploying.
    address internal constant CREATOR_VAULT_IMPL = 0xe5aF8d840963060302cf5021630d6dBF41a9e07b;
    /// @notice `LivoCreatorVaultFactory` UUPS proxy (stable across upgrades). Update after deploying.
    address internal constant CREATOR_VAULT_FACTORY = 0x804ad45394FCF755350d924f712EC463E5E3147D;
    /// @notice `LivoCreatorVaultFactory` implementation behind the proxy. Update after deploying.
    address internal constant CREATOR_VAULT_FACTORY_IMPL = 0xcbeBF86091de0E2c5d18D6c4E3d44e44855C2C47;

    /// @notice The six allocation-specific bonding curves (`ConstantProductBondingCurveConfigurable`),
    ///         one per locked allocation. Update after deploying with `DeployCreatorVaultSystem`.
    address internal constant VAULT_CURVE_5 = 0x52E9f8C868dC93FC8f96Bd011919e792081fb994;
    address internal constant VAULT_CURVE_10 = 0xCfC997822F83fb5e097169D3ece200dC341CD4b2;
    address internal constant VAULT_CURVE_15 = 0x45494272d20566D6455551dd5B394aADF27B280E;
    address internal constant VAULT_CURVE_20 = 0x2a20a84be4843DB150cac3E540a0a233e2aB2F43;
    address internal constant VAULT_CURVE_25 = 0x47E194606A3c43751A3DE9680D163688114d0eB9;
    address internal constant VAULT_CURVE_30 = 0x0776c476F519cDB8c75d9b3bCd1165003812e028;

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
    address internal constant GRADUATOR_UNIV4_THIN = 0xcfcD21eb40212779F29f3C8e063F3Fc0595635A4;
    address internal constant GRADUATOR_UNIV4_THICK = 0xfE99fE47FA6f0860FD7a09fa5245a429EE75D330;

    /// @notice THIN-tier bonding curves (`ConstantProductBondingCurveConfigurable`): the no-vault
    ///         base curve plus six vault curves (5%..30%). Update after deploying with
    ///         `DeployTierLiquiditySystem`. Venue-agnostic — shared by the V2 and V4 factories.
    address internal constant THIN_CURVE_BASE = 0xe8f6083315eEC90e61D06e50163f8ce187DDb55b;
    address internal constant THIN_VAULT_CURVE_5 = 0xE7eb1d5d0E9EA8B0C9BD31D165B53Db16860ed07;
    address internal constant THIN_VAULT_CURVE_10 = 0xBB6a4e318cd5D8BA74405E52A1257589186b52bb;
    address internal constant THIN_VAULT_CURVE_15 = 0x46A66a1b305e10901D811306F5450bb51B67ab28;
    address internal constant THIN_VAULT_CURVE_20 = 0x9b179058A1a6Fa021f7172d05663Be394EbD9DA6;
    address internal constant THIN_VAULT_CURVE_25 = 0x3204f943FCf33E306F6F28E5F433Aa7851474cF2;
    address internal constant THIN_VAULT_CURVE_30 = 0xDe542942392BA7CB5c6e83f5d4467A9cfd4Ae1aF;

    /// @notice THICK-tier bonding curves. Same layout as the THIN tier above.
    address internal constant THICK_CURVE_BASE = 0x171D6cDCc4c695d1D32A687A395385B7439965d9;
    address internal constant THICK_VAULT_CURVE_5 = 0xC1F0f507a050B58edF32e073f6F6A862E59C9082;
    address internal constant THICK_VAULT_CURVE_10 = 0x8eD41e5357C71E87cd8cf942394600bA1AF9C2bE;
    address internal constant THICK_VAULT_CURVE_15 = 0x06E90E159fdA3b639CD5f9c09CCABefFE9cadc11;
    address internal constant THICK_VAULT_CURVE_20 = 0x33863bCAc9c43de66C7fB00F4E43bf6F6c42E9e3;
    address internal constant THICK_VAULT_CURVE_25 = 0xc5103e505c05AaAFf0ee4e8Fc927eD9371352727;
    address internal constant THICK_VAULT_CURVE_30 = 0x9E28f3902fBC209D88d34B729dA3BcfE5877412F;

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
    address internal constant LIVO_TOKEN_DEPLOYER = 0x566CB296539672bB2419F403d292544E9Abf7815;
}
