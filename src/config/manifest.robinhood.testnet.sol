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
    address internal constant LAUNCHPAD = 0x914e8A6fcA2af6E8Cf4434d1D50234fC89CdF2Ec;
    address internal constant BONDING_CURVE = 0xd0b4476f2044574CA498A5AdD5DFB26516E2526d;
    address internal constant GRADUATOR_UNIV2 = 0xE8168F37CdaAdB08818469De191eD2461EEcc229;
    address internal constant GRADUATOR_UNIV4 = 0xA99282F37825E996a15B9619A13575A266127Ea3;

    /// @notice Shared, permissionless `RealmUniV4LiquidityAdder` singleton — one per chain, passed to every
    ///         V4 graduator and used by taxable tokens' `processLiquidity`. Deploy with
    ///         `DeployRealmStack`; `address(0)` until first deployed on this chain.
    address internal constant UNIV4_LIQUIDITY_ADDER = 0x5606c6EDF892FEd317c60C95a1BCcDA5c1c5f551;
    address internal constant MASTER_FEE_HANDLER = 0xc2dD7eB98C39fA6BBC117E8D599422687D4f29E3;

    /// @notice Marketcap-tiered swap hook: fee-agnostic, reads each token's `swapLpFeeBps` via
    ///         `getSwapFees` and forwards LP fees to `LP_FEE_ROUTER`. The V4 graduators point here.
    /// @dev Realm deploys its OWN hook rather than reusing the Livo one, whose `TREASURY` and
    ///      `FEE_ROUTER` immutables are pinned to Livo addresses and cannot be repointed. Deploy with
    ///      `DeployRealmSwapHook` (`RealmSwapHook` or `RealmHook`, see that script) and paste whichever
    ///      variant Uniswap whitelists. `address(0)` until then.
    address internal constant SWAP_HOOK = 0x5C5Ae1E32c02259741ab912523594155EFae80Cc;
    /// @notice `SwapLpFeeRouter` proxy (UUPS) consumed by `SWAP_HOOK`; splits LP fees treasury/creator
    ///         by marketcap tier.
    /// @dev The hook holds this as an immutable, so it must be deployed BEFORE the hook
    ///      (`DeployRealmPrereqs`). Router policy changes ship by `upgradeToAndCall`ing this proxy.
    address internal constant LP_FEE_ROUTER = 0x823ca5B8041217Df052D9e64AC6E7c16A62FA957;
    /// @notice The `SwapLpFeeRouter` implementation behind `LP_FEE_ROUTER`. Update on every router
    ///         upgrade; tracked for verification and audit trails only.
    address internal constant LP_FEE_ROUTER_IMPL = 0xa2E3C9B3B33Cbad41ECCA283734c335490a09d4a;
    address internal constant QUOTER = 0x5f09e414a6f8A004D152dE6aeA5FD435c4188dEC;

    // --- Token implementations (cloned by factories) ---
    address internal constant TOKEN_IMPL = 0x284A47F94624037Cca0f7b0c13734F6C684B9F6C;
    address internal constant TAXABLE_TOKEN_V4_IMPL = 0x32076B54e0504CF8EFCE26170f56EEAF2204DBe8;

    /// @notice V2 taxable token implementation (cloned by `RealmFactoryUniV2Unified` when tax is configured)
    address internal constant TAXABLE_TOKEN_V2_IMPL = 0xa5498948245b1D3CDda08B9324e22c709CE9bDE7;

    // --- Factories (unified) ---
    /// @notice UUPS proxy addresses that integrators whitelist. These stay stable across upgrades.
    address internal constant FACTORY_UNIV2_UNIFIED = 0xfe9Db30e48b56eD34785643A6e9e01176Dd16386;
    address internal constant FACTORY_UNIV4_UNIFIED = 0x9686177008dda7D6d0AEEA5063530bF552e893Bd;

    /// @notice Implementation addresses currently set behind the proxies above. Updated on every
    ///         `UpgradeRealmFactories` run. Tracked for Etherscan verification and audit trails;
    ///         no contract or frontend consumes these directly.
    address internal constant FACTORY_UNIV2_UNIFIED_IMPL = 0xa492a0edb9eE7412F061e26EF8Ec4b0594C9101c;
    address internal constant FACTORY_UNIV4_UNIFIED_IMPL = 0xC2793d815BA81AaDC5ae5c8b6de5f14365f8743B;

    // --- Creator vaults ---
    /// @notice `RealmCreatorVault` implementation cloned by the vault factory. Update after deploying.
    address internal constant CREATOR_VAULT_IMPL = 0x6fd7765a8b08E45ff7F1816d3688784675ecd6A5;
    /// @notice `RealmCreatorVaultFactory` UUPS proxy (stable across upgrades). Update after deploying.
    address internal constant CREATOR_VAULT_FACTORY = 0xd346ECc082B5db7D7fb787aB7c14f4222e2dd042;
    /// @notice `RealmCreatorVaultFactory` implementation behind the proxy. Update after deploying.
    address internal constant CREATOR_VAULT_FACTORY_IMPL = 0x64dDAe54fb7c1f2b6E1a76645422D8cd26B23ceF;

    /// @notice The six allocation-specific bonding curves (`ConstantProductBondingCurveConfigurable`),
    ///         one per locked allocation. Update after deploying with `DeployRealmStack`.
    address internal constant VAULT_CURVE_5 = 0x63B78b60fbD518aa66944E60579372C421cf06d7;
    address internal constant VAULT_CURVE_10 = 0x88Ee77C8d151FcFC2CF410EEc19a878B8E260e70;
    address internal constant VAULT_CURVE_15 = 0x5De1A697f5463319b38f795CEf4F0d0E7b87608d;
    address internal constant VAULT_CURVE_20 = 0x03bC021fd09E75d1dbbB040742Fa85629F3e04b8;
    address internal constant VAULT_CURVE_25 = 0x6d78a676a7b6DDEA364F427eF2EB1CFfeC10cfF2;
    address internal constant VAULT_CURVE_30 = 0x90D9FdE054E6a6860cE760Fa7a40362a6b122f1F;

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
    ///         `DeployRealmStack`. Both point at `SWAP_HOOK` above.
    address internal constant GRADUATOR_UNIV4_THIN = 0x53b659806b6DDF83D4a14f607A8d28487b140cF3;
    address internal constant GRADUATOR_UNIV4_THICK = 0x6B29469d3E5D5861E6a5C449863a0566E163272C;

    /// @notice THIN-tier bonding curves (`ConstantProductBondingCurveConfigurable`): the no-vault
    ///         base curve plus six vault curves (5%..30%). Update after deploying with
    ///         `DeployRealmStack`. Venue-agnostic — shared by the V2 and V4 factories.
    address internal constant THIN_CURVE_BASE = 0x04d14C0dE84757E4539C7429983E5b5FBF30AbD9;
    address internal constant THIN_VAULT_CURVE_5 = 0xA8Df983578993Eea0C02C08BD84Aaaea07FdBc8d;
    address internal constant THIN_VAULT_CURVE_10 = 0x2DAB5D3a65F6deE7F72a60abb6E7ECbf03304783;
    address internal constant THIN_VAULT_CURVE_15 = 0x3D194bcD0B3b84ed0e1f657d1b48C7fE4243238c;
    address internal constant THIN_VAULT_CURVE_20 = 0x5aBBE013BE0FB3E34b1b01Fc1870137D132F40Cb;
    address internal constant THIN_VAULT_CURVE_25 = 0x834DE31760b75A6989b54b0dc23Fa076991EC328;
    address internal constant THIN_VAULT_CURVE_30 = 0x4cD7a42DF15C49867e42C1c8ae562b6B8358F3D5;

    /// @notice THICK-tier bonding curves. Same layout as the THIN tier above.
    address internal constant THICK_CURVE_BASE = 0x2ddb749849276FACe386f2Cf975a6f786468e022;
    address internal constant THICK_VAULT_CURVE_5 = 0x5aF1D8216a07C47Cc34E64E1f63e7C1Ec32690B9;
    address internal constant THICK_VAULT_CURVE_10 = 0xFcfEBf16e01A18Cc02a04791ACC00A113F56528D;
    address internal constant THICK_VAULT_CURVE_15 = 0xE3055ABdF44A3802421D20347C37F9de5e8C37AE;
    address internal constant THICK_VAULT_CURVE_20 = 0x45F77df37a0e987D7EF0d97f5D30ad56DF3aBC6A;
    address internal constant THICK_VAULT_CURVE_25 = 0x2446dC637A897bEDDad7Da2103C17b30d4F36ca4;
    address internal constant THICK_VAULT_CURVE_30 = 0x4c651Ca2099A5c87C56b65B4006841C6aefE31F8;

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
    address internal constant REALM_DEV = 0x1a209bB4d0bC40f169c06dC2808d7d512Aea62bb;
    address internal constant REALM_TOKEN_DEPLOYER = address(0);
    /// @notice The keeper lambda's EOA (see the Sepolia manifest). `address(0)` until configured here.
    address internal constant REALM_KEEPER = address(0);
}
