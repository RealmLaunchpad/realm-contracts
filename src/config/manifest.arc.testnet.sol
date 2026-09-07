// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Livo deployment manifest — ARC Chain Testnet
/// @notice Single source of truth for Livo's own deployed contracts on chain id 5042002.
/// @dev External infrastructure (Uniswap V2/V4, Permit2, the USDC-ERC20 quote alias) lives in
///      `src/config/DeploymentAddresses.sol` (`DeploymentAddressesArcTestnet`) — Uniswap V2+V4 are
///      Livo-self-deployed there; the Uniswap StateView/V4Quoter/PositionDescriptor go into the
///      frontend/indexer configs, not here. Treasury also lives in DeploymentAddresses (consumed by
///      core contracts at deploy time). Update any address below on redeploy and run
///      `just export-deployments`.
library DeploymentsArcTestnet {
    uint256 internal constant BLOCKCHAIN_ID = 5042002;

    // --- Core ---
    address internal constant LAUNCHPAD = 0x586BE26ab3304C119817B8E18467A952C8C0Ecc5;
    address internal constant BONDING_CURVE = 0x139bce34e7a5A5E4F139d1A3a9aEAFFD46656e6F;
    address internal constant GRADUATOR_UNIV2 = 0x5235362Db85d8378E6f72150d2756E80860dB25b;
    address internal constant GRADUATOR_UNIV4 = 0x43F8BC6d25BE185711680987019d20543e6B53F6;
    address internal constant MASTER_FEE_HANDLER = 0x3175bB69cfeE26FC90ea0A33E45BbDe466053f43;

    /// @notice Shared, permissionless `LivoUniV4LiquidityAdder` singleton — one per chain, passed to every
    ///         V4 graduator and used by taxable tokens' `processLiquidity`. Deploy with
    ///         `DeployUniV4LiquidityAdder`; `address(0)` until first deployed on this chain.
    address internal constant UNIV4_LIQUIDITY_ADDER = address(0);

    address internal constant SWAP_HOOK = 0x432A7d3841F6dFe79F2CB34fb5F1225ba42F00CC;
    address internal constant LP_FEE_ROUTER = 0x522fD5758e5185Cc95e2D0A8CB30f4a4B70c9107;
    address internal constant LP_FEE_ROUTER_IMPL = 0xf69FC76AEdAA95C1EE0f466760290cE77f94885D;
    address internal constant QUOTER = 0xa53878A7C2B79465CB6a93deA5DF70a837EadEa4;

    // --- Token implementations (cloned by factories) ---
    address internal constant TOKEN_IMPL = 0x8024f24dF3fe8B45dAa0D9D94F59AA7e98DA1B7f;
    address internal constant TAXABLE_TOKEN_V4_IMPL = 0x2281BE8DbFD38F8B1603AB2c1D6E36afC0851FB8;
    address internal constant TAXABLE_TOKEN_V2_IMPL = 0x3ddc687a57674F5AD6e3b25f8c41cf41E70c0402;

    // --- Factories (unified) ---
    address internal constant FACTORY_UNIV2_UNIFIED = 0x0776824884d9E10b526ce735f4b110722c2AdB56;
    address internal constant FACTORY_UNIV4_UNIFIED = 0x5E8b516d97C4D9D22e070342cc39EF7De84ab412;
    address internal constant FACTORY_UNIV2_UNIFIED_IMPL = 0x3faCE9330730fB6f2a9Bb5994cDC882F21ee0A23;
    address internal constant FACTORY_UNIV4_UNIFIED_IMPL = 0xc18030d76573784fff4E6365309E1acD967506ff;

    // --- Creator vaults ---
    address internal constant CREATOR_VAULT_IMPL = 0x752A3798893D8987D99A27D2B27F2dfAC6EB9E39;
    address internal constant CREATOR_VAULT_FACTORY = 0x2714A9E811CC5FBd73fa1b9467FDBe641204D020;
    address internal constant CREATOR_VAULT_FACTORY_IMPL = 0xAB9950BfC212e7a60448a8833f5cD876b10d87D6;

    /// @notice The six DEFAULT-tier allocation-specific bonding curves (5%..30% locked).
    address internal constant VAULT_CURVE_5 = 0x071221210C33962eEd92081e93e73e9a06149E92;
    address internal constant VAULT_CURVE_10 = 0xa1D4E34AC9946Ab53B155E79d0A3023e52B27400;
    address internal constant VAULT_CURVE_15 = 0x338728dA52Fb88679793E74D6E3f2177b64C1Dc4;
    address internal constant VAULT_CURVE_20 = 0x32B4F048d15178FA1958BA6eC3ac8007d516E5e9;
    address internal constant VAULT_CURVE_25 = 0x50e30bfE4CFB0b6aC6369eE54D7510B2473573fF;
    address internal constant VAULT_CURVE_30 = 0x2f1C9cf234E17ca0Df9A8071c83D8794B3be2058;

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
    address internal constant GRADUATOR_UNIV4_THIN = 0x758Af7bCde2875a6Aa06337125EA81335a860AC5;
    address internal constant GRADUATOR_UNIV4_THICK = 0x588951ecc682cBbe3BC4fa60F807e2Fa165255B2;

    /// @notice THIN-tier bonding curves: no-vault base + six vault curves (5%..30%).
    address internal constant THIN_CURVE_BASE = 0x209504c3fB153a2e37690c30441eC67e909FE490;
    address internal constant THIN_VAULT_CURVE_5 = 0x17d5e0776dafa4CAE8e6e1eBbf7278e1c4AF647f;
    address internal constant THIN_VAULT_CURVE_10 = 0x928f2f571BF9f18464fdeC8D36e6A075C3460862;
    address internal constant THIN_VAULT_CURVE_15 = 0x968295b7611eb750C2aaaAEB7733e54fEbae347F;
    address internal constant THIN_VAULT_CURVE_20 = 0x92A71B6A578D2345946DeCeDbCA3874702a3fCa3;
    address internal constant THIN_VAULT_CURVE_25 = 0x2Bf62383a4A1349461bB744b4eC561338D8b4CF9;
    address internal constant THIN_VAULT_CURVE_30 = 0xCbcaB7c9d9Ce45CEFb17bBEbd419881b253d7371;

    /// @notice THICK-tier bonding curves. Same layout as the THIN tier above.
    address internal constant THICK_CURVE_BASE = 0x66534bDE4f69F69342F929479797F7118B7ca74F;
    address internal constant THICK_VAULT_CURVE_5 = 0xF74aD241bDe9e2DAe7849D06ee4935731c1B5258;
    address internal constant THICK_VAULT_CURVE_10 = 0xeC46b101f042bbf0A677de0dfFe4dbD6cD2A0888;
    address internal constant THICK_VAULT_CURVE_15 = 0x08feCd4F6340EdEb8F34a8e117fa248eD4A722d6;
    address internal constant THICK_VAULT_CURVE_20 = 0x422fe43Ac0a9c7566b7B6A89e4bbF990c22807e7;
    address internal constant THICK_VAULT_CURVE_25 = 0xc89Fd26039DaA40BeE2e8D6a2c661AF8D52cb45d;
    address internal constant THICK_VAULT_CURVE_30 = 0xb17Ac827De11b1b69c37D3A9cA8d53C1E2718b0F;

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
