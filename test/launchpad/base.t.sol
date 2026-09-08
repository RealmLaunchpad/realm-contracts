// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RealmDividendSwapRegistry} from "src/dividends/RealmDividendSwapRegistry.sol";
import {installDividendSwapRegistry} from "test/helpers/DividendRegistryHelpers.sol";
import {installKeepersRegistry} from "test/helpers/KeepersRegistryHelpers.sol";
import {RealmKeepersRegistry} from "src/access/RealmKeepersRegistry.sol";
import "forge-std/Test.sol";
import {RealmLaunchpad} from "src/RealmLaunchpad.sol";
import {RealmToken} from "src/tokens/RealmToken.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {TaxConfigInit, TaxConfigs} from "src/interfaces/IRealmTaxableToken.sol";
import {RealmFactoryAbstract} from "src/factories/RealmFactoryAbstract.sol";
import {RealmFactoryUniV2Unified} from "src/factories/RealmFactoryUniV2Unified.sol";
import {RealmFactoryUniV4Unified} from "src/factories/RealmFactoryUniV4Unified.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RealmTaxableTokenUniV2} from "src/tokens/RealmTaxableTokenUniV2.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {ConstantProductBondingCurve} from "src/bondingCurves/ConstantProductBondingCurve.sol";
import {ConstantProductBondingCurveConfigurable} from "src/bondingCurves/ConstantProductBondingCurveConfigurable.sol";
import {CreatorVaultCurveConstants} from "src/config/CreatorVaultCurveConstants.sol";
import {RealmCreatorVault} from "src/vaults/RealmCreatorVault.sol";
import {RealmCreatorVaultFactory} from "src/vaults/RealmCreatorVaultFactory.sol";
import {RealmGraduatorUniswapV2} from "src/graduators/RealmGraduatorUniswapV2.sol";
import {RealmGraduatorUniswapV4} from "src/graduators/RealmGraduatorUniswapV4.sol";
import {RealmUniV4LiquidityAdder} from "src/liquidity/RealmUniV4LiquidityAdder.sol";
import {UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {DeploymentAddressesEthereumMainnet} from "src/config/DeploymentAddresses.sol";
import {IRealmGraduator} from "src/interfaces/IRealmGraduator.sol";
import {TokenConfig, TokenState} from "src/types/tokenData.sol";
import {IUniswapV2Router02} from "src/interfaces/IUniswapV2Router02.sol";
import {IUniswapV2Factory} from "src/interfaces/IUniswapV2Factory.sol";
import {IWETH} from "src/interfaces/IWETH.sol";
import {RealmSwapHook} from "src/hooks/RealmSwapHook.sol";
import {SwapLpFeeRouter} from "src/feeRouters/SwapLpFeeRouter.sol";
import {RealmTaxableTokenUniV4} from "src/tokens/RealmTaxableTokenUniV4.sol";
import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import {RealmMasterFeeHandler} from "src/feeHandlers/RealmMasterFeeHandler.sol";

contract LaunchpadBaseTests is Test {
    /// @notice Eligibility gate + swap venue for third-asset dividends, installed at the constant
    ///         address every taxable token implementation compiles against.
    RealmDividendSwapRegistry internal dividendSwapRegistry;
    RealmKeepersRegistry internal keepersRegistry;

    RealmLaunchpad public launchpad;

    RealmToken public realmToken;
    RealmTaxableTokenUniV4 public realmTaxToken;
    RealmTaxableTokenUniV2 public realmTaxTokenV2;
    // Anti-sniper is now a gated feature of the base/tax impls (no separate sniper impls). These
    // `*Sniper` names are kept as ALIASES pointing at the merged impls so existing call sites (impl
    // assertions, salt prediction) keep compiling and stay correct.
    RealmTaxableTokenUniV2 public realmTaxTokenV2Sniper;

    IRealmToken public implementation;

    ConstantProductBondingCurve public bondingCurve;

    /// @notice Creator-vault infrastructure (deployed in `setUp`), shared with vault tests.
    RealmCreatorVaultFactory public creatorVaultFactory;
    address[6] public vaultCurves; // [5%, 10%, 15%, 20%, 25%, 30%] DEFAULT-tier vault curves

    /// @notice THIN/THICK tier V4 graduators (single hook in tests). Deployed in `setUp`.
    RealmGraduatorUniswapV4 public graduatorV4Thin;
    RealmGraduatorUniswapV4 public graduatorV4Thick;

    /// @notice THIN/THICK tier curves (no-vault base + 6 vault curves each), built in `setUp`.
    ///         Stored so subclasses (e.g. factory-upgrade tests) can rebuild a factory with them.
    IRealmFactory.TierCurves internal thinCurves;
    IRealmFactory.TierCurves internal thickCurves;

    IRealmGraduator public graduator;

    // Two unified factories. Legacy aliases below point to these instances so existing call sites
    // that read `factoryV2`, `factoryV4`, `factoryTax`, `factoryV2Sniper`, `factorySniper`, and
    // `factoryTaxSniper` keep working. The unified factories dispatch implementations based on
    // `TaxConfigInit`/`AntiSniperConfigs` sentinels.
    RealmFactoryUniV2Unified public factoryV2Unified;
    RealmFactoryUniV4Unified public factoryV4Unified;

    // Legacy aliases (read-only). The pre-consolidation factories (`RealmFactoryUniV2`,
    // `RealmFactoryUniV4`, `RealmFactoryTaxToken`, `RealmFactoryUniV2SniperProtected`,
    // `RealmFactoryUniV4SniperProtected`, `RealmFactoryTaxTokenSniperProtected`) no longer exist;
    // these names now refer to the unified factories so the test surface remains stable.
    RealmFactoryUniV2Unified public factoryV2;
    RealmFactoryUniV2Unified public factoryV2Sniper;
    RealmFactoryUniV4Unified public factoryV4;
    RealmFactoryUniV4Unified public factoryTax;
    RealmFactoryUniV4Unified public factorySniper;
    RealmFactoryUniV4Unified public factoryTaxSniper;

    RealmToken public realmTokenSniper; // alias of `realmToken` (anti-sniper is a gated feature)
    RealmTaxableTokenUniV4 public realmTaxTokenSniper; // alias of `realmTaxToken`
    RealmMasterFeeHandler public feeHandler;

    address public treasury = makeAddr("treasury");
    address public creator = makeAddr("creator");
    address public buyer = makeAddr("buyer");
    address public seller = makeAddr("seller");

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    address public admin = makeAddr("admin");

    address public testToken;

    uint256 public constant INITIAL_ETH_BALANCE = 100 ether;
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 public constant CREATOR_GRADUATION_COMPENSATION = 0.125 ether;
    uint256 public constant TRIGGERER_GRADUATION_COMPENSATION = 0.005 ether;
    uint256 constant GRADUATION_FEE = 0.25 ether;
    uint16 public constant BASE_BUY_FEE_BPS = 100;
    uint16 public constant BASE_SELL_FEE_BPS = 100;

    uint256 constant GRADUATION_THRESHOLD = 3.75 ether;
    uint256 constant MAX_THRESHOLD_EXCESS = 0.05 ether;

    // we don't test deadlines mostly
    uint256 constant DEADLINE = type(uint256).max;
    address constant DEAD_ADDRESS = DeploymentAddressesEthereumMainnet.DEAD_ADDRESS;

    // Hook address with correct Uniswap V4 permission bits; deployCodeTo() overrides whatever is at this address
    address constant TEST_HOOK_ADDRESS = 0x2ca2764a626de36331E20b08aEd13E5C7A0240cC;

    // for fork tests
    uint256 constant BLOCKNUMBER = 23327777;

    /// @dev The chain a suite forks and the external infrastructure the stack is wired to. Ethereum
    ///      mainnet unless a suite overrides `_forkInfra()`. The token implementations bake their chain's
    ///      addresses in and refuse a mismatched `block.chainid`, so an override needs the matching
    ///      `just chain-<name>` retarget first.
    struct ForkInfra {
        string rpcUrlEnv;
        uint256 blockNumber;
        address poolManager;
        address positionManager;
        address permit2;
        address universalRouter;
        address uniV2Router;
        address uniV2Factory;
        bytes32 uniV2PairInitCodeHash;
        address weth;
    }

    function _forkInfra() internal view virtual returns (ForkInfra memory) {
        return ForkInfra({
            rpcUrlEnv: "MAINNET_RPC_URL",
            blockNumber: BLOCKNUMBER,
            poolManager: DeploymentAddressesEthereumMainnet.UNIV4_POOL_MANAGER,
            positionManager: DeploymentAddressesEthereumMainnet.UNIV4_POSITION_MANAGER,
            permit2: DeploymentAddressesEthereumMainnet.PERMIT2,
            universalRouter: DeploymentAddressesEthereumMainnet.UNIV4_UNIVERSAL_ROUTER,
            uniV2Router: DeploymentAddressesEthereumMainnet.UNIV2_ROUTER,
            uniV2Factory: DeploymentAddressesEthereumMainnet.UNIV2_FACTORY,
            uniV2PairInitCodeHash: DeploymentAddressesEthereumMainnet.UNIV2_PAIR_INIT_CODE_HASH,
            weth: DeploymentAddressesEthereumMainnet.WETH
        });
    }

    // Filled from `_forkInfra()` in `setUp`.
    address internal poolManagerAddress;
    address internal positionManagerAddress;
    address internal permit2Address;
    address internal universalRouter;
    address internal UNISWAP_V2_ROUTER;
    IUniswapV2Factory internal UNISWAP_FACTORY;
    IWETH internal WETH;

    // This is the effective price when buying at graduation (from bonding curve slope)
    uint256 constant GRADUATION_PRICE = 12373924040; // ETH/token (eth per token, expressed in wei)
    // This is the pool setpoint price derived from SQRT_PRICEX96_GRADUATION
    uint256 constant POOL_SETPOINT_PRICE = 12249999999; // ETH/token (eth per token, expressed in wei)

    RealmGraduatorUniswapV2 public graduatorV2;
    RealmGraduatorUniswapV4 public graduatorV4;
    RealmSwapHook public taxHook;
    SwapLpFeeRouter public lpFeeRouter;

    // Default LP-fee-router tier thresholds used in tests (ETH wei). Tier 0 covers `[0, T1)`.
    uint256 public constant LP_TIER_THRESHOLD_1 = 30 ether;
    uint256 public constant LP_TIER_THRESHOLD_2 = 150 ether;
    uint256 public constant LP_TIER_THRESHOLD_3 = 300 ether;
    uint256 public constant LP_TIER_THRESHOLD_4 = 600 ether;
    uint256 public constant LP_TIER_THRESHOLD_5 = 900 ether;
    uint256 public constant LP_TIER_THRESHOLD_6 = 1500 ether;

    // Treasury share per tier (BPS). Creator share is the complement to 10_000.
    uint16 public constant LP_TIER0_TREASURY_BPS = 4000; // post-grad: 40/60
    uint16 public constant LP_TIER1_TREASURY_BPS = 3500;
    uint16 public constant LP_TIER2_TREASURY_BPS = 3000;
    uint16 public constant LP_TIER3_TREASURY_BPS = 2500;
    uint16 public constant LP_TIER4_TREASURY_BPS = 2000;
    uint16 public constant LP_TIER5_TREASURY_BPS = 1500;
    uint16 public constant LP_TIER6_TREASURY_BPS = 1000;

    uint256 public constant LP_FEE_BPS_DEFAULT = 100; // 1%

    /// @dev Expected treasury share of the LP fee at tier 0 (marketcap below the first threshold), for a
    ///      gross ETH swap amount. Most graduation tests trade tiny amounts, so they stay in tier 0.
    function _lpTreasuryShareTier0(uint256 grossEth) internal pure returns (uint256) {
        uint256 totalLpFee = (grossEth * LP_FEE_BPS_DEFAULT) / 10_000;
        return (totalLpFee * LP_TIER0_TREASURY_BPS) / 10_000;
    }

    /// @dev Expected creator share of the LP fee at tier 0 (complement of `_lpTreasuryShareTier0`).
    function _lpCreatorShareTier0(uint256 grossEth) internal pure returns (uint256) {
        uint256 totalLpFee = (grossEth * LP_FEE_BPS_DEFAULT) / 10_000;
        return totalLpFee - (totalLpFee * LP_TIER0_TREASURY_BPS) / 10_000;
    }

    /// @dev Default `SwapLpFeeRouter.Config` used by the test fixtures. Mirrors the tier policy the
    ///      production deployment is expected to start with.
    function _defaultLpRouterCfg() internal pure returns (SwapLpFeeRouter.Config memory) {
        uint256[6] memory thresholds = [
            LP_TIER_THRESHOLD_1,
            LP_TIER_THRESHOLD_2,
            LP_TIER_THRESHOLD_3,
            LP_TIER_THRESHOLD_4,
            LP_TIER_THRESHOLD_5,
            LP_TIER_THRESHOLD_6
        ];
        uint16[7] memory treasuryBps = [
            LP_TIER0_TREASURY_BPS,
            LP_TIER1_TREASURY_BPS,
            LP_TIER2_TREASURY_BPS,
            LP_TIER3_TREASURY_BPS,
            LP_TIER4_TREASURY_BPS,
            LP_TIER5_TREASURY_BPS,
            LP_TIER6_TREASURY_BPS
        ];
        return SwapLpFeeRouter.Config({thresholds: thresholds, treasuryBps: treasuryBps});
    }

    uint256 internal _saltCounter;

    /// @dev The factory namespaces the CREATE2 salt by the deployer (`keccak256(msg.sender, salt)`),
    ///      so address prediction / vanity mining must use the same derivation. `creator` is the
    ///      default deployer used by the createToken helpers below.
    function _namespacedSalt(address deployer, bytes32 salt) internal pure returns (bytes32 result) {
        // Equivalent to keccak256(abi.encodePacked(deployer, salt)), but computed in scratch space so
        // that mining loops (which call this ~65k times per salt) don't leak memory. `abi.encodePacked`
        // advances the free-memory pointer every call and Solidity never frees it, so the naive version
        // grows memory into the megabytes across a loop → quadratic memory-expansion gas → MemoryOOG.
        assembly {
            mstore(0x00, shl(96, deployer)) // deployer in bytes [0x00, 0x14)
            mstore(0x14, salt) // salt in bytes [0x14, 0x34)
            result := keccak256(0x00, 0x34) // hash the 52-byte packed encoding
        }
    }

    /// @dev Predicts the token address the factory would deploy for `deployer` with `salt`, matching
    ///      the on-chain namespaced-salt derivation.
    function _predictToken(address factory, address impl, address deployer, bytes32 salt)
        internal
        pure
        returns (address)
    {
        return Clones.predictDeterministicAddress(impl, _namespacedSalt(deployer, salt), factory);
    }

    /// @dev Mines the next salt whose namespaced address has the `0x1110` vanity suffix, for the
    ///      default `creator` deployer. Use the 3-arg overload when deploying as a different account.
    function _nextValidSalt(address factory, address impl) internal returns (bytes32 salt) {
        return _nextValidSalt(factory, impl, creator);
    }

    function _nextValidSalt(address factory, address impl, address deployer) internal returns (bytes32 salt) {
        for (uint256 i = _saltCounter;; i++) {
            salt = bytes32(i);
            if (uint16(uint160(_predictToken(factory, impl, deployer, salt))) == 0x1110) {
                _saltCounter = i + 1;
                return salt;
            }
        }
    }

    /// @dev Build a single-entry FeeShare[] with `account` getting 100% of fees (claimable, no direct).
    function _fs(address account) internal pure returns (IRealmFactory.FeeShare[] memory arr) {
        arr = new IRealmFactory.FeeShare[](1);
        arr[0] = IRealmFactory.FeeShare({account: account, shares: 10_000, directFeesEnabled: false});
    }

    /// @dev Build a single-entry FeeShare[] with `account` opted into direct fee forwarding.
    function _fsDirect(address account) internal pure returns (IRealmFactory.FeeShare[] memory arr) {
        arr = new IRealmFactory.FeeShare[](1);
        arr[0] = IRealmFactory.FeeShare({account: account, shares: 10_000, directFeesEnabled: true});
    }

    /// @dev Build an empty FeeShare[] (only valid for UniV2 factory).
    function _noFs() internal pure returns (IRealmFactory.FeeShare[] memory arr) {
        return new IRealmFactory.FeeShare[](0);
    }

    /// @dev Build an empty SupplyShare[] (valid when msg.value == 0).
    function _noSs() internal pure returns (IRealmFactory.SupplyShare[] memory arr) {
        return new IRealmFactory.SupplyShare[](0);
    }

    /// @dev Build a single-entry SupplyShare[] with `account` receiving 100% of the bought supply.
    function _ss(address account) internal pure returns (IRealmFactory.SupplyShare[] memory arr) {
        arr = new IRealmFactory.SupplyShare[](1);
        arr[0] = IRealmFactory.SupplyShare({account: account, shares: 10_000});
    }

    /// @dev Build a `TaxConfigInit` struct for passing to any tax-factory's `createToken`. Defaults to
    ///      `startTaxFromLaunch: true` (creation-anchored), preserving every existing test's behavior.
    function _taxCfg(uint16 buyTaxBps, uint16 sellTaxBps, uint32 taxDurationSeconds)
        internal
        pure
        returns (TaxConfigInit memory)
    {
        return _taxCfg(buyTaxBps, sellTaxBps, taxDurationSeconds, true);
    }

    /// @dev `_taxCfg` overload that picks the tax-window anchor explicitly. No decay configured.
    function _taxCfg(uint16 buyTaxBps, uint16 sellTaxBps, uint32 taxDurationSeconds, bool startTaxFromLaunch)
        internal
        pure
        returns (TaxConfigInit memory)
    {
        return TaxConfigInit({
            buyTaxBps: buyTaxBps,
            sellTaxBps: sellTaxBps,
            taxDurationSeconds: taxDurationSeconds,
            startTaxFromLaunch: startTaxFromLaunch
        });
    }

    /// @dev Full `_taxCfg` overload exposing the linear-decay fields too. Returns the superset
    ///      `TaxConfigs` (decay lives only there); pass it to the new struct-based `createToken` overload.
    function _taxCfg(
        uint16 buyTaxBps,
        uint16 sellTaxBps,
        uint32 taxDurationSeconds,
        bool startTaxFromLaunch,
        uint16 buyTaxDecayStartBps,
        uint16 sellTaxDecayStartBps,
        uint32 taxDecayDuration
    ) internal pure returns (TaxConfigs memory) {
        return TaxConfigs({
            buyTaxBps: buyTaxBps,
            sellTaxBps: sellTaxBps,
            taxDurationSeconds: taxDurationSeconds,
            startTaxFromLaunch: startTaxFromLaunch,
            buyTaxDecayStartBps: buyTaxDecayStartBps,
            sellTaxDecayStartBps: sellTaxDecayStartBps,
            taxDecayDuration: taxDecayDuration
        });
    }

    /// @dev Decay-only `TaxConfigs`: no long-term static tax, just a linear launch-tax decay. Models
    ///      a "non-taxable token that opts into tax decay".
    function _decayCfg(
        uint16 buyTaxDecayStartBps,
        uint16 sellTaxDecayStartBps,
        uint32 taxDecayDuration,
        bool startTaxFromLaunch
    ) internal pure returns (TaxConfigs memory) {
        return _taxCfg(0, 0, 0, startTaxFromLaunch, buyTaxDecayStartBps, sellTaxDecayStartBps, taxDecayDuration);
    }

    /// @dev Lifts a legacy `TaxConfigInit` into the full `TaxConfigs` (decay fields zeroed). Mirrors the
    ///      factory's `_toTaxConfigs`; use at the `initialize` / `previewTokenImplementation` /
    ///      `quoteBuyOnDeploy` call-sites, which now take `TaxConfigs`, when the test already has a
    ///      `TaxConfigInit` from `_taxCfg`/`_emptyTaxCfg`.
    function _toCfgs(TaxConfigInit memory legacy) internal pure returns (TaxConfigs memory) {
        return TaxConfigs({
            buyTaxBps: legacy.buyTaxBps,
            sellTaxBps: legacy.sellTaxBps,
            taxDurationSeconds: legacy.taxDurationSeconds,
            startTaxFromLaunch: legacy.startTaxFromLaunch,
            buyTaxDecayStartBps: 0,
            sellTaxDecayStartBps: 0,
            taxDecayDuration: 0
        });
    }

    /// @dev Empty `TaxConfigInit` — sentinel for "no tax variant" (taxDurationSeconds == 0 and, once
    ///      lifted into `TaxConfigs`, taxDecayDuration == 0 disable dispatch to the taxable impl).
    function _emptyTaxCfg() internal pure returns (TaxConfigInit memory) {
        return TaxConfigInit({buyTaxBps: 0, sellTaxBps: 0, taxDurationSeconds: 0, startTaxFromLaunch: false});
    }

    /// @dev Empty `AntiSniperConfigs` — sentinel for "no sniper protection" (protectionWindowSeconds == 0).
    function _emptyAntiSniperCfg() internal pure returns (AntiSniperConfigs memory) {
        return AntiSniperConfigs({
            maxBuyPerTxBps: 0, maxWalletBps: 0, protectionWindowSeconds: 0, whitelist: new address[](0)
        });
    }

    /// @dev Build a default `AntiSniperConfigs` (3% / 3% / 3h, empty whitelist).
    function _defaultAntiSniperCfg() internal pure returns (AntiSniperConfigs memory) {
        return AntiSniperConfigs({
            maxBuyPerTxBps: 300, maxWalletBps: 300, protectionWindowSeconds: 3 hours, whitelist: new address[](0)
        });
    }

    /// @dev Build a custom `AntiSniperConfigs`.
    function _antiSniperCfg(uint16 maxBuyBps, uint16 maxWalletBps, uint40 window, address[] memory whitelist)
        internal
        pure
        returns (AntiSniperConfigs memory)
    {
        return AntiSniperConfigs({
            maxBuyPerTxBps: maxBuyBps, maxWalletBps: maxWalletBps, protectionWindowSeconds: window, whitelist: whitelist
        });
    }

    /// @dev Deploys the creator-vault implementation, the UUPS vault factory proxy, and the six
    ///      allocation-specific bonding curves (stored in `vaultCurves`). Returns the vault factory.
    function _deployCreatorVaultInfra() internal returns (RealmCreatorVaultFactory factory) {
        address vaultImpl = address(new RealmCreatorVault());
        address vaultFactoryImpl = address(new RealmCreatorVaultFactory(vaultImpl));
        factory = RealmCreatorVaultFactory(
            address(new ERC1967Proxy(vaultFactoryImpl, abi.encodeCall(RealmCreatorVaultFactory.initialize, ())))
        );

        uint256[6] memory bpsList = [uint256(500), 1000, 1500, 2000, 2500, 3000];
        for (uint256 i = 0; i < 6; ++i) {
            (uint256 k, uint256 t0, uint256 e0) = CreatorVaultCurveConstants.paramsForBps(bpsList[i]);
            vaultCurves[i] = address(new ConstantProductBondingCurveConfigurable(k, t0, e0, 3.75 ether, 0.05 ether));
        }
    }

    /// @dev Deploys a non-default liquidity tier's seven configurable curves (no-vault base + the six
    ///      vault curves), reading constants + threshold from `CreatorVaultCurveConstants`.
    function _deployTierCurves(LiquidityTier tier) internal returns (IRealmFactory.TierCurves memory tc) {
        (uint256 threshold, uint256 maxExcess) = CreatorVaultCurveConstants.tierGraduation(tier);
        (uint256 k0, uint256 t00, uint256 e00) = CreatorVaultCurveConstants.paramsFor(tier, 0);
        tc.base = address(new ConstantProductBondingCurveConfigurable(k0, t00, e00, threshold, maxExcess));
        uint256[6] memory bpsList = [uint256(500), 1000, 1500, 2000, 2500, 3000];
        for (uint256 i = 0; i < 6; ++i) {
            (uint256 k, uint256 t0, uint256 e0) = CreatorVaultCurveConstants.paramsFor(tier, bpsList[i]);
            tc.vaults[i] = address(new ConstantProductBondingCurveConfigurable(k, t0, e0, threshold, maxExcess));
        }
    }

    /// @dev The V4 tier-graduators struct used by `setUp` (and reusable by subclasses). One graduator
    ///      per tier — the hook is fee-agnostic and reads the swap fee from the token.
    function _v4TierGraduators() internal view returns (RealmFactoryUniV4Unified.TierGraduators memory) {
        return
            RealmFactoryUniV4Unified.TierGraduators({thin: address(graduatorV4Thin), thick: address(graduatorV4Thick)});
    }

    /// @dev THIN+THICK curve bundle for the factory constructors.
    function _tierConfig() internal view returns (IRealmFactory.LiquidityTierConfig memory) {
        return IRealmFactory.LiquidityTierConfig({thin: thinCurves, thick: thickCurves});
    }

    /// @dev Full V4 tier config (curves + graduators) for the V4 factory constructor.
    function _v4TierConfig() internal view returns (RealmFactoryUniV4Unified.V4TierConfig memory) {
        return RealmFactoryUniV4Unified.V4TierConfig({curves: _tierConfig(), graduators: _v4TierGraduators()});
    }

    function setUp() public virtual {
        ForkInfra memory infra = _forkInfra();
        vm.createSelectFork(vm.envString(infra.rpcUrlEnv), infra.blockNumber);
        poolManagerAddress = infra.poolManager;
        positionManagerAddress = infra.positionManager;
        permit2Address = infra.permit2;
        universalRouter = infra.universalRouter;
        UNISWAP_V2_ROUTER = infra.uniV2Router;
        UNISWAP_FACTORY = IUniswapV2Factory(infra.uniV2Factory);
        WETH = IWETH(infra.weth);

        // Must precede the token implementations: they bake the registry's address in as a constant,
        // and a third-asset dividend configuration calls it at creation.
        dividendSwapRegistry = installDividendSwapRegistry(admin);
        // Same: the three `process*` entry points fail closed without it. The test contract is the
        // keeper because that is who calls them; suites that need a NON-keeper caller prank one.
        keepersRegistry = installKeepersRegistry(admin, address(this));

        vm.deal(creator, INITIAL_ETH_BALANCE);
        vm.deal(buyer, INITIAL_ETH_BALANCE);
        vm.deal(seller, INITIAL_ETH_BALANCE);
        vm.deal(alice, INITIAL_ETH_BALANCE);
        vm.deal(bob, INITIAL_ETH_BALANCE);

        vm.startPrank(admin);
        realmToken = new RealmToken();
        realmTaxToken = new RealmTaxableTokenUniV4();

        implementation = realmToken;
        launchpad = new RealmLaunchpad(treasury, admin);
        bondingCurve = new ConstantProductBondingCurve();
        graduatorV2 = new RealmGraduatorUniswapV2(UNISWAP_V2_ROUTER, address(launchpad), infra.uniV2PairInitCodeHash);

        // Deploy the LP fee router behind a UUPS proxy with the default tier configuration. The hook
        // forwards every LP fee to this router, which performs the marketcap-tiered treasury/creator split.
        address lpRouterImpl = address(new SwapLpFeeRouter(treasury, _defaultLpRouterCfg()));
        lpFeeRouter = SwapLpFeeRouter(
            payable(address(new ERC1967Proxy(lpRouterImpl, abi.encodeCall(SwapLpFeeRouter.initialize, ()))))
        );

        deployCodeTo(
            "RealmSwapHook.sol:RealmSwapHook",
            abi.encode(poolManagerAddress, address(lpFeeRouter), treasury),
            TEST_HOOK_ADDRESS
        );
        taxHook = RealmSwapHook(payable(TEST_HOOK_ADDRESS));

        feeHandler = new RealmMasterFeeHandler();

        // Single shared liquidity adder, mirroring the production topology (deployed once, all graduators
        // and taxable tokens point at the same one).
        address univ4LiquidityAdder = address(new RealmUniV4LiquidityAdder(positionManagerAddress, poolManagerAddress));

        graduatorV4 = new RealmGraduatorUniswapV4(
            address(launchpad),
            poolManagerAddress,
            positionManagerAddress,
            permit2Address,
            TEST_HOOK_ADDRESS,
            715832709642994126662528799866880, // DEFAULT tier graduation sqrtPriceX96 (12.25 ETH mcap)
            UniswapV4PoolConstants.TICK_UPPER,
            univ4LiquidityAdder
        );

        realmTaxTokenV2 = new RealmTaxableTokenUniV2();
        // Sniper aliases point at the merged impls: anti-sniper is a gated feature, not a distinct impl.
        realmTokenSniper = realmToken;
        realmTaxTokenSniper = realmTaxToken;
        realmTaxTokenV2Sniper = realmTaxTokenV2;

        // Creator-vault infrastructure: vault factory (UUPS proxy) + the six allocation-specific curves.
        creatorVaultFactory = _deployCreatorVaultInfra();

        // Non-default liquidity tiers: deploy the THIN/THICK curves + their V4 graduators. Tests use a
        // single hook, so the 100/50-bps graduator slots reuse the same per-tier graduator instance.
        thinCurves = _deployTierCurves(LiquidityTier.THIN);
        thickCurves = _deployTierCurves(LiquidityTier.THICK);
        graduatorV4Thin = new RealmGraduatorUniswapV4(
            address(launchpad),
            poolManagerAddress,
            positionManagerAddress,
            permit2Address,
            TEST_HOOK_ADDRESS,
            1012340326367404053977557838594048, // THIN graduation sqrtPriceX96 (6.125 ETH mcap)
            UniswapV4PoolConstants.TICK_UPPER_THIN,
            univ4LiquidityAdder
        );
        graduatorV4Thick = new RealmGraduatorUniswapV4(
            address(launchpad),
            poolManagerAddress,
            positionManagerAddress,
            permit2Address,
            TEST_HOOK_ADDRESS,
            506170163183702026988778919297024, // THICK graduation sqrtPriceX96 (24.5 ETH mcap)
            UniswapV4PoolConstants.TICK_UPPER,
            univ4LiquidityAdder
        );

        address factoryV2Impl = address(
            new RealmFactoryUniV2Unified(
                address(launchpad),
                IRealmFactory.TokenImpls({base: address(realmToken), tax: address(realmTaxTokenV2)}),
                address(bondingCurve),
                address(graduatorV2),
                address(feeHandler),
                address(creatorVaultFactory),
                vaultCurves,
                _tierConfig()
            )
        );
        factoryV2Unified = RealmFactoryUniV2Unified(
            address(new ERC1967Proxy(factoryV2Impl, abi.encodeCall(RealmFactoryAbstract.initialize, ())))
        );

        address factoryV4Impl = address(
            new RealmFactoryUniV4Unified(
                address(launchpad),
                IRealmFactory.TokenImpls({base: address(realmToken), tax: address(realmTaxToken)}),
                address(bondingCurve),
                address(graduatorV4),
                address(feeHandler),
                address(creatorVaultFactory),
                vaultCurves,
                _v4TierConfig()
            )
        );
        factoryV4Unified = RealmFactoryUniV4Unified(
            address(new ERC1967Proxy(factoryV4Impl, abi.encodeCall(RealmFactoryAbstract.initialize, ())))
        );

        // Legacy aliases — same instance, different reference name. Kept so existing tests that
        // distinguish "tax factory" vs "sniper factory" vs "plain V4 factory" don't all need to
        // be rewritten. Dispatch happens at the call site via the cfg structs.
        factoryV2 = factoryV2Unified;
        factoryV2Sniper = factoryV2Unified;
        factoryV4 = factoryV4Unified;
        factoryTax = factoryV4Unified;
        factorySniper = factoryV4Unified;
        factoryTaxSniper = factoryV4Unified;

        launchpad.whitelistFactory(address(factoryV2Unified));
        launchpad.whitelistFactory(address(factoryV4Unified));

        vm.stopPrank();
    }

    modifier createTestToken() virtual {
        vm.prank(creator);
        if (address(graduator) == address(graduatorV4)) {
            if (address(implementation) == address(realmTaxToken)) {
                testToken = factoryV4Unified.createToken(
                    "TestToken",
                    "TEST",
                    _nextValidSalt(address(factoryV4Unified), address(realmTaxToken)),
                    _fs(creator),
                    _noSs(),
                    false,
                    _taxCfg(0, 400, uint32(14 days)),
                    _emptyAntiSniperCfg()
                );
            } else {
                testToken = factoryV4Unified.createToken(
                    "TestToken",
                    "TEST",
                    _nextValidSalt(address(factoryV4Unified), address(realmToken)),
                    _fs(creator),
                    _noSs(),
                    false,
                    _emptyTaxCfg(),
                    _emptyAntiSniperCfg()
                );
            }
        } else {
            testToken = factoryV2Unified.createToken(
                "TestToken",
                "TEST",
                _nextValidSalt(address(factoryV2Unified), address(realmToken)),
                _fs(creator),
                _noSs(),
                _emptyTaxCfg(),
                _emptyAntiSniperCfg()
            );
        }
        _;
    }

    function _graduateToken() internal {
        uint256 ethReserves = launchpad.getTokenState(testToken).ethCollected;
        // Gross up by the token's ACTUAL pre-graduation buy fee (LP fee + buy tax), so tax tokens —
        // whose total fee exceeds `BASE_BUY_FEE_BPS` — still put enough into reserves to graduate.
        uint256 buyFeeBps = _currentBuyFeeBps(testToken);
        uint256 missingForGraduation = ((GRADUATION_THRESHOLD - ethReserves) * 10000) / (10000 - buyFeeBps);
        _launchpadBuy(testToken, missingForGraduation);
    }

    /// @dev The token's current pre-graduation buy fee in bps (LP fee + buy tax), as the launchpad
    ///      reads it per trade via `getLaunchpadFees`.
    function _currentBuyFeeBps(address token) internal view returns (uint256) {
        TokenState memory state = launchpad.getTokenState(token);
        IRealmToken.LaunchpadFees memory f = IRealmToken(token)
            .getLaunchpadFees(
                IRealmToken.LaunchpadTrade({
                    isBuy: true, ethReserves: state.ethCollected, releasedSupply: state.releasedSupply
                })
            );
        return uint256(f.lpFeeBps) + f.taxBps;
    }

    function _launchpadBuy(address token, uint256 value) internal {
        vm.deal(buyer, value);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: value}(token, 0, DEADLINE);
    }

    function _increaseWithFees(uint256 ethIntoReserves) internal pure returns (uint256 ethBuy) {
        ethBuy = (ethIntoReserves * 10000) / (10000 - BASE_BUY_FEE_BPS);
    }

    /// @dev Treasury's share of a pre-graduation LP fee on `testToken`; the remainder accrues to the
    ///      creator. The launchpad splits the LP fee by the token's `treasuryShareBps` (a per-venue
    ///      constant: 5000 for V2, 6000 for V4). Assumes a non-tax token, where the whole trading fee
    ///      is LP fee.
    function _treasuryShareOf(uint256 lpFee) internal view returns (uint256) {
        return lpFee * RealmToken(testToken).treasuryShareBps() / 10_000;
    }
}

contract LaunchpadBaseTestsWithUniv2Graduator is LaunchpadBaseTests {
    uint256 public SELL_TAX_BPS = 0; // 0% sell tax

    function setUp() public virtual override {
        super.setUp();

        graduator = graduatorV2;
    }
}

contract LaunchpadBaseTestsWithUniv4Graduator is LaunchpadBaseTests {
    uint256 public SELL_TAX_BPS = 0; // 0% sell tax

    function setUp() public virtual override {
        super.setUp();

        graduator = graduatorV4;
    }
}

contract LaunchpadBaseTestsWithUniv4GraduatorTaxableToken is LaunchpadBaseTests {
    uint256 public SELL_TAX_BPS = 400; // 4% sell tax

    function setUp() public virtual override {
        super.setUp();

        graduator = graduatorV4;
        implementation = realmTaxToken;
    }
}
