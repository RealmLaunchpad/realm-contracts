// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {RealmLaunchpad} from "src/RealmLaunchpad.sol";
import {RealmQuoter} from "src/RealmQuoter.sol";
import {RealmMasterFeeHandler} from "src/feeHandlers/RealmMasterFeeHandler.sol";
import {RealmGraduatorUniswapV2} from "src/graduators/RealmGraduatorUniswapV2.sol";
import {RealmGraduatorUniswapV4} from "src/graduators/RealmGraduatorUniswapV4.sol";
import {RealmUniV4LiquidityAdder} from "src/liquidity/RealmUniV4LiquidityAdder.sol";
import {ConstantProductBondingCurve} from "src/bondingCurves/ConstantProductBondingCurve.sol";
import {ConstantProductBondingCurveConfigurable} from "src/bondingCurves/ConstantProductBondingCurveConfigurable.sol";
import {RealmCreatorVault} from "src/vaults/RealmCreatorVault.sol";
import {RealmCreatorVaultFactory} from "src/vaults/RealmCreatorVaultFactory.sol";
import {RealmToken} from "src/tokens/RealmToken.sol";
import {RealmTaxableTokenUniV2} from "src/tokens/RealmTaxableTokenUniV2.sol";
import {RealmTaxableTokenUniV4} from "src/tokens/RealmTaxableTokenUniV4.sol";
import {RealmFactoryAbstract} from "src/factories/RealmFactoryAbstract.sol";
import {RealmFactoryUniV2Unified} from "src/factories/RealmFactoryUniV2Unified.sol";
import {RealmFactoryUniV4Unified} from "src/factories/RealmFactoryUniV4Unified.sol";

import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {CreatorVaultCurveConstants} from "src/config/CreatorVaultCurveConstants.sol";
import {UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants.sol";
import {ChainConfig} from "script/ChainConfig.sol";

import {DeploymentAddresses as TaxV2Build} from "src/tokens/RealmTaxableTokenUniV2.sol";
import {DeploymentAddresses as TaxV4Build} from "src/tokens/RealmTaxableTokenUniV4.sol";

/// @title Phase 1 — deploy the whole Realm stack on a fresh chain, in one broadcast
/// @notice Everything Realm owns except the phase-0 prerequisites and the `LivoSwapHook`:
///
///           core      `RealmMasterFeeHandler`, `RealmLaunchpad`, `RealmQuoter`,
///                     `RealmUniV4LiquidityAdder`
///           graduate  `RealmGraduatorUniswapV2`, and three `RealmGraduatorUniswapV4` (DEFAULT /
///                     THIN / THICK) all pointed at the inherited `SWAP_HOOK`
///           curves    22 bonding curves: the hardcoded `ConstantProductBondingCurve` (DEFAULT base)
///                     plus 21 `ConstantProductBondingCurveConfigurable` — six DEFAULT vault curves
///                     (5%..30%) and a base + six vault curves for each of THIN and THICK
///           vaults    `RealmCreatorVault` impl, `RealmCreatorVaultFactory` impl + UUPS proxy
///           tokens    `RealmToken`, `RealmTaxableTokenUniV2`, `RealmTaxableTokenUniV4` (clone masters;
///                     the taxable pair each deploy their own dividend-logic extension in their
///                     constructor, so those need no script)
///           factories `RealmFactoryUniV2Unified` + `RealmFactoryUniV4Unified`, impl + UUPS proxy each,
///                     then whitelisted on the launchpad
///
///         Nothing is read back from the manifest except `SWAP_HOOK` — every address is passed in
///         memory within the single run, so there is no paste-and-rebuild round trip between steps.
///         Paste the printed block into the manifest once, at the end.
///
///         The broadcaster becomes the launchpad owner (it whitelists the two factories here) and the
///         owner of both factory proxies and the vault factory proxy. Hand those over afterwards.
///
/// @dev    PRE-FLIGHT, in order — the script refuses to broadcast otherwise:
///           1. `just chain-sepolia` / `just chain-robinhood`, then `forge build`.
///           2. `DeployRealmPrereqs` must have run and its two addresses pasted into
///              `src/config/DeploymentAddresses.sol` (they are baked into the taxable token bytecode).
///           3. `SWAP_HOOK` must be set in the manifest for this chain.
///
///         Run: forge script DeployRealmStack --rpc-url <sepolia|robinhood-mainnet> \
///                  --account realm.dev --slow --broadcast --verify
contract DeployRealmStack is Script {
    /// @dev Graduation prices per tier, from `simulations/script/uniswapV4Settings.py`:
    ///      DEFAULT 12.25 ETH mcap, THIN 6.125 ETH, THICK 24.5 ETH.
    uint160 internal constant DEFAULT_GRAD_SQRT_PRICE_X96 = 715832709642994126662528799866880;
    uint160 internal constant THIN_GRAD_SQRT_PRICE_X96 = 1012340326367404053977557838594048;
    uint160 internal constant THICK_GRAD_SQRT_PRICE_X96 = 506170163183702026988778919297024;

    /// @dev Index 0 is each tier's no-vault base curve; 1..6 are the 5%..30% vault curves.
    uint256[7] internal VAULT_BPS = [uint256(0), 500, 1000, 1500, 2000, 2500, 3000];

    struct Core {
        address feeHandler;
        address launchpad;
        address quoter;
        address liquidityAdder;
        address graduatorV2;
        address graduatorV4;
        address graduatorV4Thin;
        address graduatorV4Thick;
    }

    struct Vaults {
        address vaultImpl;
        address factoryImpl;
        address factory;
    }

    struct Tokens {
        address token;
        address taxV2;
        address taxV4;
    }

    struct Factories {
        address v2Impl;
        address v2;
        address v4Impl;
        address v4;
    }

    function run() public {
        ChainConfig.Infra memory infra = ChainConfig.infra();
        address hook = ChainConfig.swapHook();
        _preflight();

        console.log("=== Deploy the Realm stack ===");
        console.log("Chain ID: ", block.chainid);
        console.log("Deployer: ", msg.sender);
        console.log("Treasury: ", infra.treasury);
        console.log("Swap hook:", hook);
        console.log("");

        vm.startBroadcast();

        Core memory core = _deployCore(infra, hook);
        address[7] memory def = _deployDefaultCurves();
        address[7] memory thin = _deployTierCurves(LiquidityTier.THIN);
        address[7] memory thick = _deployTierCurves(LiquidityTier.THICK);
        Vaults memory vaults = _deployVaults();
        Tokens memory tokens = _deployTokenImpls();
        Factories memory factories = _deployFactories(core, def, thin, thick, vaults.factory, tokens);

        RealmLaunchpad(core.launchpad).whitelistFactory(factories.v2);
        RealmLaunchpad(core.launchpad).whitelistFactory(factories.v4);

        vm.stopBroadcast();

        _report(core, def, thin, thick, vaults, tokens, factories);
    }

    /////////////////////////////// DEPLOY ///////////////////////////////

    function _deployCore(ChainConfig.Infra memory infra, address hook) internal returns (Core memory c) {
        c.feeHandler = address(new RealmMasterFeeHandler());
        c.launchpad = address(new RealmLaunchpad(infra.treasury, msg.sender));
        c.quoter = address(new RealmQuoter(c.launchpad));
        // Chain-shared singleton: every V4 graduator's secondary position and taxable tokens'
        // `processLiquidity` both route through it.
        c.liquidityAdder = address(new RealmUniV4LiquidityAdder(infra.univ4PositionManager, infra.univ4PoolManager));
        c.graduatorV2 =
            address(new RealmGraduatorUniswapV2(infra.univ2Router, c.launchpad, infra.univ2PairInitCodeHash));
        // One graduator per tier; the hook is fee-agnostic (it reads the LP fee off the token), so the
        // only per-tier difference is the graduation price and the primary range's upper tick.
        c.graduatorV4 =
            _deployGraduatorV4(infra, c, hook, DEFAULT_GRAD_SQRT_PRICE_X96, UniswapV4PoolConstants.TICK_UPPER);
        c.graduatorV4Thin =
            _deployGraduatorV4(infra, c, hook, THIN_GRAD_SQRT_PRICE_X96, UniswapV4PoolConstants.TICK_UPPER_THIN);
        c.graduatorV4Thick =
            _deployGraduatorV4(infra, c, hook, THICK_GRAD_SQRT_PRICE_X96, UniswapV4PoolConstants.TICK_UPPER);
    }

    function _deployGraduatorV4(
        ChainConfig.Infra memory infra,
        Core memory c,
        address hook,
        uint160 sqrtPriceGraduation,
        int24 tickUpper
    ) internal returns (address) {
        RealmGraduatorUniswapV4 g = new RealmGraduatorUniswapV4(
            c.launchpad,
            infra.univ4PoolManager,
            infra.univ4PositionManager,
            infra.permit2,
            hook,
            sqrtPriceGraduation,
            tickUpper,
            c.liquidityAdder
        );
        require(g.HOOK_ADDRESS() == hook, "graduator hook mismatch");
        return address(g);
    }

    /// @dev DEFAULT's no-vault curve is the hardcoded `ConstantProductBondingCurve` (manifest slot
    ///      `BONDING_CURVE`), so `CreatorVaultCurveConstants` has no `(DEFAULT, 0)` entry and index 0
    ///      is special-cased. 1..6 are the configurable `VAULT_CURVE_5..30`.
    function _deployDefaultCurves() internal returns (address[7] memory curves) {
        (uint256 threshold, uint256 maxExcess) = CreatorVaultCurveConstants.tierGraduation(LiquidityTier.DEFAULT);
        curves[0] = address(new ConstantProductBondingCurve());
        for (uint256 i = 1; i < 7; ++i) {
            (uint256 k, uint256 t0, uint256 e0) =
                CreatorVaultCurveConstants.paramsFor(LiquidityTier.DEFAULT, VAULT_BPS[i]);
            curves[i] = address(new ConstantProductBondingCurveConfigurable(k, t0, e0, threshold, maxExcess));
        }
    }

    function _deployTierCurves(LiquidityTier tier) internal returns (address[7] memory curves) {
        (uint256 threshold, uint256 maxExcess) = CreatorVaultCurveConstants.tierGraduation(tier);
        for (uint256 i = 0; i < 7; ++i) {
            (uint256 k, uint256 t0, uint256 e0) = CreatorVaultCurveConstants.paramsFor(tier, VAULT_BPS[i]);
            curves[i] = address(new ConstantProductBondingCurveConfigurable(k, t0, e0, threshold, maxExcess));
        }
    }

    function _deployVaults() internal returns (Vaults memory v) {
        v.vaultImpl = address(new RealmCreatorVault());
        v.factoryImpl = address(new RealmCreatorVaultFactory(v.vaultImpl));
        v.factory = address(new ERC1967Proxy(v.factoryImpl, abi.encodeCall(RealmCreatorVaultFactory.initialize, ())));
    }

    function _deployTokenImpls() internal returns (Tokens memory t) {
        t.token = address(new RealmToken());
        t.taxV2 = address(new RealmTaxableTokenUniV2());
        t.taxV4 = address(new RealmTaxableTokenUniV4());
    }

    function _deployFactories(
        Core memory c,
        address[7] memory def,
        address[7] memory thin,
        address[7] memory thick,
        address vaultFactory,
        Tokens memory t
    ) internal returns (Factories memory f) {
        IRealmFactory.LiquidityTierConfig memory tierCurves = IRealmFactory.LiquidityTierConfig({
            thin: IRealmFactory.TierCurves({base: thin[0], vaults: _vaultsOf(thin)}),
            thick: IRealmFactory.TierCurves({base: thick[0], vaults: _vaultsOf(thick)})
        });
        f.v2Impl = _deployFactoryV2Impl(c, def, vaultFactory, t, tierCurves);
        f.v2 = address(new ERC1967Proxy(f.v2Impl, abi.encodeCall(RealmFactoryAbstract.initialize, ())));
        f.v4Impl = _deployFactoryV4Impl(c, def, vaultFactory, t, tierCurves);
        f.v4 = address(new ERC1967Proxy(f.v4Impl, abi.encodeCall(RealmFactoryAbstract.initialize, ())));
    }

    function _deployFactoryV2Impl(
        Core memory c,
        address[7] memory def,
        address vaultFactory,
        Tokens memory t,
        IRealmFactory.LiquidityTierConfig memory tierCurves
    ) internal returns (address) {
        return address(
            new RealmFactoryUniV2Unified(
                c.launchpad,
                IRealmFactory.TokenImpls({base: t.token, tax: t.taxV2}),
                def[0],
                c.graduatorV2,
                c.feeHandler,
                vaultFactory,
                _vaultsOf(def),
                tierCurves
            )
        );
    }

    function _deployFactoryV4Impl(
        Core memory c,
        address[7] memory def,
        address vaultFactory,
        Tokens memory t,
        IRealmFactory.LiquidityTierConfig memory tierCurves
    ) internal returns (address) {
        RealmFactoryUniV4Unified.V4TierConfig memory v4Tier = RealmFactoryUniV4Unified.V4TierConfig({
            curves: tierCurves,
            graduators: RealmFactoryUniV4Unified.TierGraduators({thin: c.graduatorV4Thin, thick: c.graduatorV4Thick})
        });
        return address(
            new RealmFactoryUniV4Unified(
                c.launchpad,
                IRealmFactory.TokenImpls({base: t.token, tax: t.taxV4}),
                def[0],
                c.graduatorV4,
                c.feeHandler,
                vaultFactory,
                _vaultsOf(def),
                v4Tier
            )
        );
    }

    /// @dev Drops the base curve at index 0, leaving the six vault curves the factories expect.
    function _vaultsOf(address[7] memory curves) internal pure returns (address[6] memory v) {
        for (uint256 i = 0; i < 6; ++i) {
            v[i] = curves[i + 1];
        }
    }

    ////////////////////////////// PRE-FLIGHT //////////////////////////////

    /// @dev The taxable token impls are non-upgradeable clone masters that bake three compile-time
    ///      constants into their bytecode. Getting any of them wrong is unrecoverable for every clone
    ///      the factory ever mints, so all three are checked before a single tx is broadcast.
    function _preflight() internal view {
        require(TaxV2Build.BLOCKCHAIN_ID == block.chainid, "RealmTaxableTokenUniV2 built for another chain");
        require(TaxV4Build.BLOCKCHAIN_ID == block.chainid, "RealmTaxableTokenUniV4 built for another chain");
        require(
            TaxV2Build.REALM_KEEPERS_REGISTRY.code.length != 0,
            "REALM_KEEPERS_REGISTRY has no code: run DeployRealmPrereqs, paste it, rebuild"
        );
        require(
            TaxV2Build.DIVIDEND_SWAP_REGISTRY.code.length != 0,
            "DIVIDEND_SWAP_REGISTRY has no code: run DeployRealmPrereqs, paste the PROXY, rebuild"
        );
    }

    //////////////////////////////// REPORT ////////////////////////////////

    function _report(
        Core memory c,
        address[7] memory def,
        address[7] memory thin,
        address[7] memory thick,
        Vaults memory v,
        Tokens memory t,
        Factories memory f
    ) internal pure {
        console.log("=== Deployed. Paste these lines into src/config/manifest.<chain>.sol ===");
        console.log("");
        _slot("LAUNCHPAD", c.launchpad);
        _slot("BONDING_CURVE", def[0]);
        _slot("GRADUATOR_UNIV2", c.graduatorV2);
        _slot("GRADUATOR_UNIV4", c.graduatorV4);
        _slot("UNIV4_LIQUIDITY_ADDER", c.liquidityAdder);
        _slot("MASTER_FEE_HANDLER", c.feeHandler);
        _slot("QUOTER", c.quoter);
        _slot("TOKEN_IMPL", t.token);
        _slot("TAXABLE_TOKEN_V2_IMPL", t.taxV2);
        _slot("TAXABLE_TOKEN_V4_IMPL", t.taxV4);
        _slot("FACTORY_UNIV2_UNIFIED", f.v2);
        _slot("FACTORY_UNIV4_UNIFIED", f.v4);
        _slot("FACTORY_UNIV2_UNIFIED_IMPL", f.v2Impl);
        _slot("FACTORY_UNIV4_UNIFIED_IMPL", f.v4Impl);
        _slot("CREATOR_VAULT_IMPL", v.vaultImpl);
        _slot("CREATOR_VAULT_FACTORY", v.factory);
        _slot("CREATOR_VAULT_FACTORY_IMPL", v.factoryImpl);
        _slot("GRADUATOR_UNIV4_THIN", c.graduatorV4Thin);
        _slot("GRADUATOR_UNIV4_THICK", c.graduatorV4Thick);
        _slots("VAULT_CURVE_", def);
        _slots("THIN_", thin);
        _slots("THICK_", thick);
        console.log("");
        console.log("Both factory proxies are already whitelisted on the launchpad.");
        console.log("Next: paste the block above, `just export-deployments`, mirror the addresses in");
        console.log("      ../indexer config.yaml + config.{dev,prod}.yaml, and hand over ownerships.");
    }

    /// @dev Index 0 of a tier's curve array is its base curve, 1..6 the 5%..30% vault curves. DEFAULT
    ///      prints unprefixed (`BONDING_CURVE` / `VAULT_CURVE_*`, base emitted separately above);
    ///      THIN/THICK print as `<TIER>_CURVE_BASE` / `<TIER>_VAULT_CURVE_*`.
    function _slots(string memory prefix, address[7] memory curves) internal pure {
        bool isDefault = keccak256(bytes(prefix)) == keccak256("VAULT_CURVE_");
        if (!isDefault) _slot(string.concat(prefix, "CURVE_BASE"), curves[0]);
        string[6] memory pct = ["5", "10", "15", "20", "25", "30"];
        for (uint256 i = 0; i < 6; ++i) {
            string memory slot =
                isDefault ? string.concat("VAULT_CURVE_", pct[i]) : string.concat(prefix, "VAULT_CURVE_", pct[i]);
            _slot(slot, curves[i + 1]);
        }
    }

    function _slot(string memory slot, address a) internal pure {
        console.log(string.concat("    address internal constant ", slot, " = ", vm.toString(a), ";"));
    }
}
