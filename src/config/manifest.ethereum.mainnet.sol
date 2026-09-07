// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Livo deployment manifest — Ethereum Mainnet
/// @notice Single source of truth for Livo's own deployed contracts on chain id 1.
/// @dev External infrastructure (Uniswap V2/V4, Permit2, WETH) lives in
///      `src/config/DeploymentAddresses.sol`. Treasury also lives there since it is
///      consumed by core contracts at deploy time. Update this file on every redeploy
///      and run `just export-deployments` to refresh `deployments.ethereum.mainnet.md`.
library DeploymentsEthereumMainnet {
    uint256 internal constant BLOCKCHAIN_ID = 1;

    // --- Core ---
    address internal constant LAUNCHPAD = 0xaA74Aa89590E3B50BE178eA970E490c173b61110;
    address internal constant BONDING_CURVE = 0xc8aDB35992054948333486621D1891D298f050Ad;
    address internal constant GRADUATOR_UNIV2 = 0x042ed119F78b734407C6368A01D799C503df2E63;
    address internal constant GRADUATOR_UNIV4 = 0x1bB406cD19175FD707Bae63aA1410F7621fAc71D;
    address internal constant MASTER_FEE_HANDLER = 0x6F0f4F70a403B9191D6adf2C10750Ab8436345cC;

    /// @notice Shared, permissionless `LivoUniV4LiquidityAdder` singleton — one per chain, passed to every
    ///         V4 graduator and used by taxable tokens' `processLiquidity`. Deploy with
    ///         `DeployUniV4LiquidityAdder`; `address(0)` until first deployed on this chain.
    address internal constant UNIV4_LIQUIDITY_ADDER = address(0);

    address internal constant SWAP_HOOK = 0x10392843021A1aF0abE3B1A21F14673DC05340cc;
    /// @notice LP fee router proxy (UUPS) consumed by `LivoSwapHook`; splits LP fees treasury/creator by marketcap tier.
    address internal constant LP_FEE_ROUTER = 0xe229557449f65e20368c40B3fb7471CB50dcB3eA;
    address internal constant LP_FEE_ROUTER_IMPL = 0xbbA67f3f1D2D1C17328eD9B02251b1b7Dc762E6C;
    address internal constant QUOTER = 0xBd208C238Dd7895a7b94833063C2397F10E056f1;

    // --- Token implementations (cloned by factories) ---
    address internal constant TOKEN_IMPL = 0xf8CAD09f010f4ADFFCa63D049860469D5f3c6eAA;
    address internal constant TAXABLE_TOKEN_V4_IMPL = 0xfe09d129C227682849cF80d6a016A1022401289D;

    /// @notice V2 taxable token implementation (cloned by `LivoFactoryUniV2Unified` when tax is configured)
    address internal constant TAXABLE_TOKEN_V2_IMPL = 0x12a1FD4677F5985F4624FD44Ce44d9adE2833839;

    // --- Factories (unified) ---
    /// @notice UUPS proxy addresses that integrators whitelist. These stay stable across upgrades.
    address internal constant FACTORY_UNIV2_UNIFIED = 0x78Af7E41ab894fc2aCd1b1c918e3CC6d710054b9;
    address internal constant FACTORY_UNIV4_UNIFIED = 0x9A996216c0Cd3B1cDeDC4D2A38E0ca94eBeC3565;

    /// @notice Implementation addresses currently set behind the proxies above. Updated on every
    ///         `UpgradeUnifiedFactories` run. Tracked for Etherscan verification and audit trails;
    ///         no contract or frontend consumes these directly.
    address internal constant FACTORY_UNIV2_UNIFIED_IMPL = 0x24cd5AB9f3cebF9f332DD1A326EFB4EeB71441EE;
    address internal constant FACTORY_UNIV4_UNIFIED_IMPL = 0x61644515be886c211A4A0dAf8588165305d85be7;

    // --- Creator vaults ---
    /// @notice `LivoCreatorVault` implementation cloned by the vault factory. Update after deploying.
    address internal constant CREATOR_VAULT_IMPL = 0xcad4C889e0897BF3fdeE367F402F728342651603;
    /// @notice `LivoCreatorVaultFactory` UUPS proxy (stable across upgrades). Update after deploying.
    address internal constant CREATOR_VAULT_FACTORY = 0xA06f07bf255cB63c694339F172f9459f3BF015E7;
    /// @notice `LivoCreatorVaultFactory` implementation behind the proxy. Update after deploying.
    address internal constant CREATOR_VAULT_FACTORY_IMPL = 0x4b387716EbA7498Eb757467A876FAA98733A329e;

    /// @notice The six allocation-specific bonding curves (`ConstantProductBondingCurveConfigurable`),
    ///         one per locked allocation. Update after deploying with `DeployCreatorVaultSystem`.
    address internal constant VAULT_CURVE_5 = 0xf5Ac0aDd4135851fb01c8529C9D99d450692aF52;
    address internal constant VAULT_CURVE_10 = 0x5d228507e31C56250fF17BbcD41eF697883F4871;
    address internal constant VAULT_CURVE_15 = 0x10f33C53FAa0C84f4F6B8fBe909cdD647d20c611;
    address internal constant VAULT_CURVE_20 = 0x00d2a5C35BC21CdB1c9E7650505f8a26E86dB592;
    address internal constant VAULT_CURVE_25 = 0xcc78F1D12AdA3F83f5A90840b937D6ed30acE6D2;
    address internal constant VAULT_CURVE_30 = 0x79f75FB3C316f873cFEC5D35a6Be7d6825A140D5;

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
    address internal constant GRADUATOR_UNIV4_THIN = 0xe1F056fF67843E7cFB0DcF2e7dc4aF36bB34D57D;
    address internal constant GRADUATOR_UNIV4_THICK = 0xe9C9401Bc17143aAD13376b755812e0E515aE97E;

    /// @notice THIN-tier bonding curves (`ConstantProductBondingCurveConfigurable`): the no-vault
    ///         base curve plus six vault curves (5%..30%). Update after deploying with
    ///         `DeployTierLiquiditySystem`. Venue-agnostic — shared by the V2 and V4 factories.
    address internal constant THIN_CURVE_BASE = 0x1baDd69dCa006B79A95713B4e912e34cf98fe76B;
    address internal constant THIN_VAULT_CURVE_5 = 0x36Ae651E216d92b99A03ff6525951df3EC2B5DEa;
    address internal constant THIN_VAULT_CURVE_10 = 0xa3408533082e529D0Dbf740A2999E3c5f5d8dfc7;
    address internal constant THIN_VAULT_CURVE_15 = 0xd04eCB501E9a872B1C38DF94481153E23fB98690;
    address internal constant THIN_VAULT_CURVE_20 = 0x71a782D35E2dd30e4b51a52c6A8Fca98Cd98e466;
    address internal constant THIN_VAULT_CURVE_25 = 0x2429bbABb9be4E8cCE9949D7f907726b5a5472A4;
    address internal constant THIN_VAULT_CURVE_30 = 0x19655401bfa0B51b98b8E389FFf5001B0A46D3f3;

    /// @notice THICK-tier bonding curves. Same layout as the THIN tier above.
    address internal constant THICK_CURVE_BASE = 0x2d6a34b7feed5dF25a73C0F0a410103aa219abb4;
    address internal constant THICK_VAULT_CURVE_5 = 0x89f1d0568Ced031D4b8f456e08ba6E9157Ab1CA0;
    address internal constant THICK_VAULT_CURVE_10 = 0x1EfEcAB686643AF69F53d1cfB7119bb93b328EE6;
    address internal constant THICK_VAULT_CURVE_15 = 0x3cba1283Bf5E74C1D8E62F12ab3b6c5df3d59036;
    address internal constant THICK_VAULT_CURVE_20 = 0xc8CFEFe3038c72E47323D126960ADc42Cf3AB866;
    address internal constant THICK_VAULT_CURVE_25 = 0xDaA320b3347149E6297918587d6E8E3814d5b4C7;
    address internal constant THICK_VAULT_CURVE_30 = 0x5779E3b9A77891BdE32B735b850a748bd33AE72c;

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
