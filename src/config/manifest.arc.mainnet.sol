// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Livo deployment manifest — ARC Chain Mainnet (chain id 5042)
/// @notice Single source of truth for Livo's own deployed contracts on ARC mainnet.
/// @dev ARC mainnet is live and Uniswap is officially deployed there. External infrastructure
///      (Uniswap V2/V3/V4, Permit2, the USDC-ERC20 quote alias) lives in
///      `src/config/DeploymentAddresses.sol` (`DeploymentAddressesArcMainnet`); treasury also lives
///      there. No Livo contract is deployed yet — every address below is `address(0)`; fill each on
///      deploy and run `just export-deployments`.
library DeploymentsArcMainnet {
    uint256 internal constant BLOCKCHAIN_ID = 5042;

    // --- Core ---
    address internal constant LAUNCHPAD = address(0);
    address internal constant BONDING_CURVE = address(0);
    address internal constant GRADUATOR_UNIV2 = address(0);
    address internal constant GRADUATOR_UNIV4 = address(0);
    address internal constant MASTER_FEE_HANDLER = address(0);

    /// @notice Shared, permissionless `LivoUniV4LiquidityAdder` singleton — one per chain, passed to every
    ///         V4 graduator and used by taxable tokens' `processLiquidity`. Deploy with
    ///         `DeployUniV4LiquidityAdder`; `address(0)` until first deployed on this chain.
    address internal constant UNIV4_LIQUIDITY_ADDER = address(0);

    address internal constant SWAP_HOOK = address(0);
    address internal constant LP_FEE_ROUTER = address(0);
    address internal constant LP_FEE_ROUTER_IMPL = address(0);
    address internal constant QUOTER = address(0);

    // --- Token implementations (cloned by factories) ---
    address internal constant TOKEN_IMPL = address(0);
    address internal constant TAXABLE_TOKEN_V4_IMPL = address(0);
    address internal constant TAXABLE_TOKEN_V2_IMPL = address(0);

    // --- Factories (unified) ---
    address internal constant FACTORY_UNIV2_UNIFIED = address(0);
    address internal constant FACTORY_UNIV4_UNIFIED = address(0);
    address internal constant FACTORY_UNIV2_UNIFIED_IMPL = address(0);
    address internal constant FACTORY_UNIV4_UNIFIED_IMPL = address(0);

    // --- Creator vaults ---
    address internal constant CREATOR_VAULT_IMPL = address(0);
    address internal constant CREATOR_VAULT_FACTORY = address(0);
    address internal constant CREATOR_VAULT_FACTORY_IMPL = address(0);

    /// @notice The six DEFAULT-tier allocation-specific bonding curves (5%..30% locked). Fill on deploy.
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
    address internal constant GRADUATOR_UNIV4_THIN = address(0);
    address internal constant GRADUATOR_UNIV4_THICK = address(0);

    /// @notice THIN-tier bonding curves: no-vault base + six vault curves (5%..30%). Fill on deploy.
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

    // --- Accounts ---
    address internal constant LIVO_DEV = 0xBa489180Ea6EEB25cA65f123a46F3115F388f181;
    address internal constant LIVO_TOKEN_DEPLOYER = address(0);
}
