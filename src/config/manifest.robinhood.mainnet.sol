// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

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
    address internal constant LAUNCHPAD = address(0);
    address internal constant BONDING_CURVE = address(0);
    address internal constant GRADUATOR_UNIV2 = address(0);
    address internal constant GRADUATOR_UNIV4 = address(0);

    /// @notice Shared, permissionless `RealmUniV4LiquidityAdder` singleton — one per chain, passed to every
    ///         V4 graduator and used by taxable tokens' `processLiquidity`. Deploy with
    ///         `DeployRealmStack`; `address(0)` until first deployed on this chain.
    address internal constant UNIV4_LIQUIDITY_ADDER = address(0);
    address internal constant MASTER_FEE_HANDLER = address(0);

    /// @notice Marketcap-tiered swap hook: fee-agnostic, reads each token's `swapLpFeeBps` via
    ///         `getSwapFees` and forwards LP fees to `LP_FEE_ROUTER`. The V4 graduators point here.
    /// @dev Realm deploys its OWN hook rather than reusing the Livo one, whose `TREASURY` and
    ///      `FEE_ROUTER` immutables are pinned to Livo addresses and cannot be repointed. Deploy with
    ///      `DeployRealmSwapHook` (`RealmSwapHook` or `RealmHook`, see that script) and paste whichever
    ///      variant Uniswap whitelists. `address(0)` until then.
    address internal constant SWAP_HOOK = 0xAE4c0Cf7C3Feb79e0c244EdBC6A3f8a3290940cC;
    /// @notice `SwapLpFeeRouter` proxy (UUPS) consumed by `SWAP_HOOK`; splits LP fees treasury/creator
    ///         by marketcap tier.
    /// @dev The hook holds this as an immutable, so it must be deployed BEFORE the hook
    ///      (`DeployRealmPrereqs`). Router policy changes ship by `upgradeToAndCall`ing this proxy.
    address internal constant LP_FEE_ROUTER = 0x823ca5B8041217Df052D9e64AC6E7c16A62FA957;
    /// @notice The `SwapLpFeeRouter` implementation behind `LP_FEE_ROUTER`. Update on every router
    ///         upgrade; tracked for verification and audit trails only.
    address internal constant LP_FEE_ROUTER_IMPL = 0xa2E3C9B3B33Cbad41ECCA283734c335490a09d4a;
    address internal constant QUOTER = address(0);

    // --- Token implementations (cloned by factories) ---
    address internal constant TOKEN_IMPL = address(0);
    address internal constant TAXABLE_TOKEN_V4_IMPL = address(0);

    /// @notice V2 taxable token implementation (cloned by `RealmFactoryUniV2Unified` when tax is configured)
    address internal constant TAXABLE_TOKEN_V2_IMPL = address(0);

    // --- Factories (unified) ---
    /// @notice UUPS proxy addresses that integrators whitelist. These stay stable across upgrades.
    address internal constant FACTORY_UNIV2_UNIFIED = address(0);
    address internal constant FACTORY_UNIV4_UNIFIED = address(0);

    /// @notice Implementation addresses currently set behind the proxies above. Updated on every
    ///         `UpgradeRealmFactories` run. Tracked for Etherscan verification and audit trails;
    ///         no contract or frontend consumes these directly.
    address internal constant FACTORY_UNIV2_UNIFIED_IMPL = address(0);
    address internal constant FACTORY_UNIV4_UNIFIED_IMPL = address(0);

    // --- Creator vaults ---
    /// @notice `RealmCreatorVault` implementation cloned by the vault factory. Update after deploying.
    address internal constant CREATOR_VAULT_IMPL = address(0);
    /// @notice `RealmCreatorVaultFactory` UUPS proxy (stable across upgrades). Update after deploying.
    address internal constant CREATOR_VAULT_FACTORY = address(0);
    /// @notice `RealmCreatorVaultFactory` implementation behind the proxy. Update after deploying.
    address internal constant CREATOR_VAULT_FACTORY_IMPL = address(0);

    /// @notice The six allocation-specific bonding curves (`ConstantProductBondingCurveConfigurable`),
    ///         one per locked allocation. Update after deploying with `DeployRealmStack`.
    address internal constant VAULT_CURVE_5 = address(0);
    address internal constant VAULT_CURVE_10 = address(0);
    address internal constant VAULT_CURVE_15 = address(0);
    address internal constant VAULT_CURVE_20 = address(0);
    address internal constant VAULT_CURVE_25 = address(0);
    address internal constant VAULT_CURVE_30 = address(0);

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
    address internal constant GRADUATOR_UNIV4_THIN = address(0);
    address internal constant GRADUATOR_UNIV4_THICK = address(0);

    /// @notice THIN-tier bonding curves (`ConstantProductBondingCurveConfigurable`): the no-vault
    ///         base curve plus six vault curves (5%..30%). Update after deploying with
    ///         `DeployRealmStack`. Venue-agnostic — shared by the V2 and V4 factories.
    address internal constant THIN_CURVE_BASE = address(0);
    address internal constant THIN_VAULT_CURVE_5 = address(0);
    address internal constant THIN_VAULT_CURVE_10 = address(0);
    address internal constant THIN_VAULT_CURVE_15 = address(0);
    address internal constant THIN_VAULT_CURVE_20 = address(0);
    address internal constant THIN_VAULT_CURVE_25 = address(0);
    address internal constant THIN_VAULT_CURVE_30 = address(0);

    /// @notice THICK-tier bonding curves. Same layout as the THIN tier above.
    address internal constant THICK_CURVE_BASE = address(0);
    address internal constant THICK_VAULT_CURVE_5 = address(0);
    address internal constant THICK_VAULT_CURVE_10 = address(0);
    address internal constant THICK_VAULT_CURVE_15 = address(0);
    address internal constant THICK_VAULT_CURVE_20 = address(0);
    address internal constant THICK_VAULT_CURVE_25 = address(0);
    address internal constant THICK_VAULT_CURVE_30 = address(0);

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
    /// @dev NOTHING IS WHITELISTED PER ASSET, and there is no route table to fill in. A payout asset is
    ///      permissionless: the token registers its own route at creation
    ///      (`RealmDividendSwapRegistry.registerRoute`, `DIVIDEND_SWAP_REGISTRY` in
    ///      `DeploymentAddresses.sol`) and the registry only proves the pools that route names are
    ///      initialized and hold in-range liquidity. So the ~190 xStock routes need no transaction here:
    ///      the only thing a V4 route reads from registry state is the quote-token allowlist, and mainnet
    ///      already has it — quote = WETH `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`, allowed, with
    ///      `defaultThreshold` 2e18 (that threshold only gates the empty V2 route anyway).
    /// @dev WHAT IS STILL MISSING on the mainnet registry, both admin-tier, both harmless until
    ///      dividends actually launch here:
    ///        1. `setAdmin(REALM_DEV, true)` — `REALM_DEV` is the OWNER but is not an admin, and every
    ///           operational lever (`setBlacklisted`, `setAllowedQuoteToken`, the thresholds) is
    ///           admin-only. Until then a payout asset that turns hostile cannot be vetoed.
    ///        2. `setKeeperFunding(REALM_KEEPER)` — unset, so a conversion hands the keeper no gas money.
    ///      Only a V3 route's MIDDLE hops are allowlisted against `isAllowedQuoteToken` (USDG is not in
    ///      it today); every route the picker generates for an xStock is V4, whose hops are not checked
    ///      against that set, so this matters only if a V3 venue is ever used.

    // --- Accounts ---
    address internal constant REALM_DEV = 0x1a209bB4d0bC40f169c06dC2808d7d512Aea62bb;
    address internal constant REALM_TOKEN_DEPLOYER = address(0);
    /// @notice The keeper lambda's EOA (see the Sepolia manifest). `address(0)` until configured here.
    address internal constant REALM_KEEPER = address(0);
}
