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
import {
    TaxConfigs,
    TaxConfigsWithMultiAllocation,
    TaxConfigsWithDirectAllocation,
    EarningsAllocationMultiConfig
} from "src/interfaces/IRealmTaxableToken.sol";
import {RealmFactoryAbstract} from "src/factories/RealmFactoryAbstract.sol";
import {RealmFactoryUniV2Unified} from "src/factories/RealmFactoryUniV2Unified.sol";
import {RealmFactoryUniV4Direct} from "src/factories/RealmFactoryUniV4Direct.sol";
import {RealmAssetsWhitelist} from "src/access/RealmAssetsWhitelist.sol";
import {PoolKey as CorePoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RealmTaxableTokenUniV2} from "src/tokens/RealmTaxableTokenUniV2.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {ConstantProductBondingCurve} from "src/bondingCurves/ConstantProductBondingCurve.sol";
import {ConstantProductBondingCurveConfigurable} from "src/bondingCurves/ConstantProductBondingCurveConfigurable.sol";
import {CreatorVaultCurveConstants} from "src/config/CreatorVaultCurveConstants.sol";
import {RealmCreatorVault} from "src/vaults/RealmCreatorVault.sol";
import {RealmCreatorVaultFactory} from "src/vaults/RealmCreatorVaultFactory.sol";
import {RealmGraduatorUniswapV2} from "src/graduators/RealmGraduatorUniswapV2.sol";
import {RealmDirectGraduatorUniV4} from "src/graduators/RealmDirectGraduatorUniV4.sol";
import {RealmUniV4LiquidityAdder} from "src/liquidity/RealmUniV4LiquidityAdder.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {DeploymentAddressesEthereumMainnet} from "src/config/DeploymentAddresses.sol";
import {IRealmGraduator} from "src/interfaces/IRealmGraduator.sol";
import {TokenConfig, TokenState} from "src/types/tokenData.sol";
import {IUniswapV2Router02} from "src/interfaces/IUniswapV2Router02.sol";
import {IUniswapV2Factory} from "src/interfaces/IUniswapV2Factory.sol";
import {IWETH} from "src/interfaces/IWETH.sol";
import {RealmSwapHook} from "src/hooks/RealmSwapHook.sol";
import {RealmHookAnyPair} from "src/hooks/RealmHookAnyPair.sol";
import {SwapLpFeeRouter} from "src/feeRouters/SwapLpFeeRouter.sol";
import {RealmTaxableTokenUniV4} from "src/tokens/RealmTaxableTokenUniV4.sol";
import {RealmDividendLogicUniV4} from "src/tokens/RealmDividendLogicUniV4.sol";
import {RealmEarningsLogicUniV4} from "src/tokens/RealmEarningsLogicUniV4.sol";
import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import {RealmMasterFeeHandler} from "src/feeHandlers/RealmMasterFeeHandler.sol";

contract LaunchpadBaseTests is Test {
    using stdStorage for StdStorage;

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

    /// @notice The direct-launch V4 venue (the only V4 venue), deployed in `setUp`.
    RealmDirectGraduatorUniV4 internal directGraduator;
    RealmFactoryUniV4Direct internal directFactory;
    RealmAssetsWhitelist internal assetsWhitelist;
    /// @dev Shared `RealmUniV4LiquidityAdder`, as in production.
    address internal univ4LiquidityAdder;

    /// @notice THIN/THICK tier curves (no-vault base + 6 vault curves each), built in `setUp`.
    ///         Stored so subclasses (e.g. factory-upgrade tests) can rebuild a factory with them.
    IRealmFactory.TierCurves internal thinCurves;
    IRealmFactory.TierCurves internal thickCurves;

    IRealmGraduator public graduator;

    // The unified curve factory. The legacy aliases below point to it so existing call sites that
    // read `factoryV2` / `factoryV2Sniper` keep working; it dispatches implementations based on
    // `TaxConfigs`/`AntiSniperConfigs` sentinels.
    RealmFactoryUniV2Unified public factoryV2Unified;
    RealmFactoryUniV2Unified public factoryV2;
    RealmFactoryUniV2Unified public factoryV2Sniper;

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
    uint256 public constant CREATOR_GRADUATION_COMPENSATION = 0.175 ether; // 70% of GRADUATION_FEE
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

    /// @dev Where `RealmHookAnyPair` is etched for the tests. Same permission bits in the low bytes as
    ///      `TEST_HOOK_ADDRESS` (v4 reads a hook's callbacks off its own address), different address:
    ///      the two hooks serve different pools and a pool key names exactly one of them.
    address constant TEST_ANYPAIR_HOOK_ADDRESS = 0x99999999999999999999999999999999999900cc;

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
    RealmSwapHook public taxHook;
    RealmHookAnyPair public anyPairHook;
    SwapLpFeeRouter public lpFeeRouter;

    /// @dev Treasury share of every post-graduation LP fee routed by `SwapLpFeeRouter` (flat 30/70).
    uint16 public constant LP_TREASURY_BPS = 3000;

    uint256 public constant LP_FEE_BPS_DEFAULT = 100; // 1%

    /// @dev Expected treasury share of the LP fee for a gross ETH swap amount.
    function _lpTreasuryShare(uint256 grossEth) internal pure returns (uint256) {
        uint256 totalLpFee = (grossEth * LP_FEE_BPS_DEFAULT) / 10_000;
        return (totalLpFee * LP_TREASURY_BPS) / 10_000;
    }

    /// @dev Expected creator share of the LP fee (complement of `_lpTreasuryShare`).
    function _lpCreatorShare(uint256 grossEth) internal pure returns (uint256) {
        uint256 totalLpFee = (grossEth * LP_FEE_BPS_DEFAULT) / 10_000;
        return totalLpFee - (totalLpFee * LP_TREASURY_BPS) / 10_000;
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

    /// @dev Mines the next salt whose namespaced address has the `0xeeaa` vanity suffix, for the
    ///      default `creator` deployer. Use the 3-arg overload when deploying as a different account.
    function _nextValidSalt(address factory, address impl) internal returns (bytes32 salt) {
        return _nextValidSalt(factory, impl, creator);
    }

    function _nextValidSalt(address factory, address impl, address deployer) internal returns (bytes32 salt) {
        for (uint256 i = _saltCounter;; i++) {
            salt = bytes32(i);
            if (uint16(uint160(_predictToken(factory, impl, deployer, salt))) == 0xeeaa) {
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

    /// @dev A static-tax `TaxConfigs` (no decay). Defaults to `startTaxFromLaunch: true`
    ///      (creation-anchored), preserving every existing test's behavior.
    function _taxCfg(uint16 buyTaxBps, uint16 sellTaxBps, uint32 taxDurationSeconds)
        internal
        pure
        returns (TaxConfigs memory)
    {
        return _taxCfg(buyTaxBps, sellTaxBps, taxDurationSeconds, true);
    }

    /// @dev `_taxCfg` overload that picks the tax-window anchor explicitly. No decay configured.
    function _taxCfg(uint16 buyTaxBps, uint16 sellTaxBps, uint32 taxDurationSeconds, bool startTaxFromLaunch)
        internal
        pure
        returns (TaxConfigs memory)
    {
        return _taxCfg(buyTaxBps, sellTaxBps, taxDurationSeconds, startTaxFromLaunch, 0, 0, 0);
    }

    /// @dev Full `_taxCfg` overload exposing the linear-decay fields too. Returns the superset
    ///      `TaxConfigs` (decay lives only there).
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

    /// @dev No tax at all — dispatches to the base implementation unless an allocation is set.
    function _emptyTaxCfg() internal pure returns (TaxConfigs memory cfg) {}

    /// @dev `tax` with no earnings allocation, in the shape the curve factories' `createToken` takes.
    function _noAlloc(TaxConfigs memory tax) internal pure returns (TaxConfigsWithMultiAllocation memory c) {
        c = TaxConfigsWithMultiAllocation({
            buyTaxBps: tax.buyTaxBps,
            sellTaxBps: tax.sellTaxBps,
            taxDurationSeconds: tax.taxDurationSeconds,
            startTaxFromLaunch: tax.startTaxFromLaunch,
            buyTaxDecayStartBps: tax.buyTaxDecayStartBps,
            sellTaxDecayStartBps: tax.sellTaxDecayStartBps,
            taxDecayDuration: tax.taxDecayDuration,
            earningsAllocation: _multiAlloc(0, 0, 0, address(0))
        });
    }

    /// @dev `tax` with no earnings allocation, in the shape the direct factory's `createToken` takes.
    function _noDirectAlloc(TaxConfigs memory tax) internal pure returns (TaxConfigsWithDirectAllocation memory c) {
        c.buyTaxBps = tax.buyTaxBps;
        c.sellTaxBps = tax.sellTaxBps;
        c.taxDurationSeconds = tax.taxDurationSeconds;
        c.startTaxFromLaunch = tax.startTaxFromLaunch;
        c.buyTaxDecayStartBps = tax.buyTaxDecayStartBps;
        c.sellTaxDecayStartBps = tax.sellTaxDecayStartBps;
        c.taxDecayDuration = tax.taxDecayDuration;
    }

    /// @dev An allocation paying dividends in ONE asset (`dividendToken`, empty route), or none when both
    ///      `dividendsBps` and `dividendToken` are zero.
    function _multiAlloc(uint16 burnBps, uint16 dividendsBps, uint16 liquidityBps, address dividendToken)
        internal
        pure
        returns (EarningsAllocationMultiConfig memory a)
    {
        a.burnBps = burnBps;
        a.dividendsBps = dividendsBps;
        a.liquidityBps = liquidityBps;
        if (dividendsBps != 0 || dividendToken != address(0)) {
            a.dividendTokens = new address[](1);
            a.dividendTokens[0] = dividendToken;
            a.dividendWeightsBps = new uint16[](1);
            a.dividendWeightsBps[0] = 10_000;
        }
    }

    /// @dev A DEFAULT-tier token setup.
    function _setupTiered(string memory name, string memory symbol, bytes32 salt, IRealmFactory.FeeShare[] memory fs)
        internal
        pure
        returns (IRealmFactory.TokenSetupTiered memory)
    {
        return IRealmFactory.TokenSetupTiered({
            name: name, symbol: symbol, salt: salt, feeShares: fs, liquidityTier: LiquidityTier.DEFAULT
        });
    }

    function _noVaults() internal pure returns (IRealmFactory.CreatorVault[] memory) {
        return new IRealmFactory.CreatorVault[](0);
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

    /// @dev THIN+THICK curve bundle for the factory constructors.
    function _tierConfig() internal view returns (IRealmFactory.LiquidityTierConfig memory) {
        return IRealmFactory.LiquidityTierConfig({thin: thinCurves, thick: thickCurves});
    }

    /////////////////////////// direct venue helpers ///////////////////////////

    /// @dev Whitelists `quote` at `unitsPerNativeX18` whole units per ETH by writing the rate a listing
    ///      would snapshot, so tests need no price pool per test quote. Listing itself is covered in
    ///      `realmAssetsWhitelist.t.sol`. The LIVE rate still reads the (absent) price source, so a quote
    ///      whitelisted this way also needs `_mockLiveRate`.
    function _whitelist(address quote, uint256 unitsPerNativeX18) internal {
        stdstore.target(address(assetsWhitelist)).sig(assetsWhitelist.unitsPerNativeX18.selector).with_key(quote)
            .checked_write(unitsPerNativeX18);
        _mockLiveRate(quote, unitsPerNativeX18);
    }

    /// @dev Pins `quote`'s live whitelist rate, which prices a direct launch against it.
    function _mockLiveRate(address quote, uint256 unitsPerNativeX18) internal {
        vm.mockCall(
            address(assetsWhitelist),
            abi.encodeCall(RealmAssetsWhitelist.liveUnitsPerNativeX18, (quote)),
            abi.encode(unitsPerNativeX18)
        );
    }

    /// @dev A direct-venue token setup at the 100-bps swap fee, salt mined for `creator`.
    function _directSetup(string memory name, string memory symbol, bool taxable)
        internal
        returns (RealmFactoryUniV4Direct.DirectTokenSetup memory s)
    {
        s = RealmFactoryUniV4Direct.DirectTokenSetup({
            name: name,
            symbol: symbol,
            salt: _nextValidSalt(address(directFactory), taxable ? address(realmTaxToken) : address(realmToken)),
            feeShares: _fs(creator),
            renounceOwnership: false,
            lpFeeBps: 100
        });
    }

    /// @dev One native pair holding the whole seed.
    function _nativePair() internal pure returns (RealmFactoryUniV4Direct.DirectPair[] memory p) {
        p = new RealmFactoryUniV4Direct.DirectPair[](1);
        p[0] = RealmFactoryUniV4Direct.DirectPair({quote: address(0), weightBps: 10_000});
    }

    function _noDevBuy() internal pure returns (RealmFactoryUniV4Direct.DevBuy memory d) {
        d = RealmFactoryUniV4Direct.DevBuy({
            pairIndex: 0,
            route: new CorePoolKey[](0),
            minQuoteOut: 0,
            quoteAmount: 0,
            recipients: new IRealmFactory.SupplyShare[](0)
        });
    }

    function _devBuyTo(address to) internal pure returns (RealmFactoryUniV4Direct.DevBuy memory d) {
        d = _noDevBuy();
        d.recipients = new IRealmFactory.SupplyShare[](1);
        d.recipients[0] = IRealmFactory.SupplyShare({account: to, shares: 10_000});
    }

    /// @dev A native-pair direct launch by `creator` with `tax` and no allocation, vault, sniper or dev
    ///      buy. Taxable (cloned from the taxable impl) whenever `tax` sets any rate.
    function _createDirectToken(TaxConfigs memory tax) internal returns (address token) {
        return _createDirectToken(tax, _fs(creator));
    }

    /// @dev A curve-shaped allocation config in the direct factory's shape (no quote routes).
    function _toDirectAlloc(TaxConfigsWithMultiAllocation memory c)
        internal
        pure
        returns (TaxConfigsWithDirectAllocation memory d)
    {
        d.buyTaxBps = c.buyTaxBps;
        d.sellTaxBps = c.sellTaxBps;
        d.taxDurationSeconds = c.taxDurationSeconds;
        d.startTaxFromLaunch = c.startTaxFromLaunch;
        d.buyTaxDecayStartBps = c.buyTaxDecayStartBps;
        d.sellTaxDecayStartBps = c.sellTaxDecayStartBps;
        d.taxDecayDuration = c.taxDecayDuration;
        d.earningsAllocation = c.earningsAllocation;
    }

    /// @dev A native-pair direct launch by `creator` from a curve-shaped setup (its tier is ignored; its
    ///      salt must be mined against `directFactory`) and allocation config.
    function _createDirect(IRealmFactory.TokenSetupTiered memory s, TaxConfigsWithMultiAllocation memory c)
        internal
        returns (address token)
    {
        return _createDirect(s, c, _emptyAntiSniperCfg(), _noVaults());
    }

    function _createDirect(
        IRealmFactory.TokenSetupTiered memory s,
        TaxConfigsWithMultiAllocation memory c,
        AntiSniperConfigs memory antiSniper,
        IRealmFactory.CreatorVault[] memory vaults
    ) internal returns (address token) {
        RealmFactoryUniV4Direct.DirectTokenSetup memory setup =
            RealmFactoryUniV4Direct.DirectTokenSetup({
                name: s.name,
                symbol: s.symbol,
                salt: s.salt,
                feeShares: s.feeShares,
                renounceOwnership: false,
                lpFeeBps: 100
            });
        vm.prank(creator);
        token = directFactory.createToken(
            setup, _nativePair(), _toDirectAlloc(c), antiSniper, vaults, _noDevBuy(), address(0)
        );
    }

    /// @dev A plain (non-tax) native-pair direct launch sent by `deployer`, with its own identity, fee
    ///      split and ownership choice.
    function _createDirectTokenAs(
        address deployer,
        string memory name,
        string memory symbol,
        IRealmFactory.FeeShare[] memory feeShares,
        bool renounce
    ) internal returns (address token) {
        return _createDirectTokenAs(deployer, name, symbol, feeShares, renounce, _emptyTaxCfg());
    }

    /// @dev The same with a tax; taxable (cloned from the taxable impl) whenever `tax` sets any rate.
    function _createDirectTokenAs(
        address deployer,
        string memory name,
        string memory symbol,
        IRealmFactory.FeeShare[] memory feeShares,
        bool renounce,
        TaxConfigs memory tax
    ) internal returns (address token) {
        bool taxable = tax.buyTaxBps != 0 || tax.sellTaxBps != 0 || tax.buyTaxDecayStartBps != 0
            || tax.sellTaxDecayStartBps != 0;
        RealmFactoryUniV4Direct.DirectTokenSetup memory setup = RealmFactoryUniV4Direct.DirectTokenSetup({
            name: name,
            symbol: symbol,
            salt: _nextValidSalt(
                address(directFactory), taxable ? address(realmTaxToken) : address(realmToken), deployer
            ),
            feeShares: feeShares,
            renounceOwnership: renounce,
            lpFeeBps: 100
        });
        vm.prank(deployer);
        token = directFactory.createToken(
            setup, _nativePair(), _noDirectAlloc(tax), _emptyAntiSniperCfg(), _noVaults(), _noDevBuy(), address(0)
        );
    }

    /// @dev `_createDirectToken` with an explicit fee split.
    function _createDirectToken(TaxConfigs memory tax, IRealmFactory.FeeShare[] memory feeShares)
        internal
        returns (address token)
    {
        bool taxable = tax.buyTaxBps != 0 || tax.sellTaxBps != 0 || tax.buyTaxDecayStartBps != 0
            || tax.sellTaxDecayStartBps != 0;
        RealmFactoryUniV4Direct.DirectTokenSetup memory setup = _directSetup("TestToken", "TEST", taxable);
        setup.feeShares = feeShares;
        vm.prank(creator);
        token = directFactory.createToken(
            setup, _nativePair(), _noDirectAlloc(tax), _emptyAntiSniperCfg(), _noVaults(), _noDevBuy(), address(0)
        );
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
        realmTaxToken =
            new RealmTaxableTokenUniV4(address(new RealmDividendLogicUniV4()), address(new RealmEarningsLogicUniV4()));

        implementation = realmToken;
        launchpad = new RealmLaunchpad(treasury, admin);
        bondingCurve = new ConstantProductBondingCurve();
        graduatorV2 = new RealmGraduatorUniswapV2(UNISWAP_V2_ROUTER, address(launchpad), infra.uniV2PairInitCodeHash);

        // Deploy the LP fee router behind a UUPS proxy with the default tier configuration. The hook
        // forwards every LP fee to this router, which performs the marketcap-tiered treasury/creator split.
        address lpRouterImpl = address(new SwapLpFeeRouter(treasury));
        lpFeeRouter = SwapLpFeeRouter(
            payable(address(new ERC1967Proxy(lpRouterImpl, abi.encodeCall(SwapLpFeeRouter.initialize, ()))))
        );

        deployCodeTo(
            "RealmSwapHook.sol:RealmSwapHook",
            abi.encode(poolManagerAddress, address(lpFeeRouter), treasury),
            TEST_HOOK_ADDRESS
        );
        taxHook = RealmSwapHook(payable(TEST_HOOK_ADDRESS));

        deployCodeTo(
            "RealmHookAnyPair.sol:RealmHookAnyPair",
            abi.encode(poolManagerAddress, address(lpFeeRouter), treasury),
            TEST_ANYPAIR_HOOK_ADDRESS
        );
        anyPairHook = RealmHookAnyPair(payable(TEST_ANYPAIR_HOOK_ADDRESS));

        feeHandler = new RealmMasterFeeHandler();

        // Single shared liquidity adder, mirroring the production topology (deployed once, all graduators
        // and taxable tokens point at the same one).
        univ4LiquidityAdder =
            address(new RealmUniV4LiquidityAdder(positionManagerAddress, poolManagerAddress, permit2Address));

        realmTaxTokenV2 = new RealmTaxableTokenUniV2();
        // Sniper aliases point at the merged impls: anti-sniper is a gated feature, not a distinct impl.
        realmTokenSniper = realmToken;
        realmTaxTokenSniper = realmTaxToken;
        realmTaxTokenV2Sniper = realmTaxTokenV2;

        // Creator-vault infrastructure: vault factory (UUPS proxy) + the six allocation-specific curves.
        creatorVaultFactory = _deployCreatorVaultInfra();

        // Non-default liquidity tiers: the THIN/THICK curves.
        thinCurves = _deployTierCurves(LiquidityTier.THIN);
        thickCurves = _deployTierCurves(LiquidityTier.THICK);

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

        // Legacy aliases — same instance, different reference name.
        factoryV2 = factoryV2Unified;
        factoryV2Sniper = factoryV2Unified;

        launchpad.whitelistFactory(address(factoryV2Unified));

        _deployDirectVenue(infra);

        vm.stopPrank();
    }

    /// @dev The direct V4 venue: graduator, assets whitelist (no listings) and factory proxy.
    function _deployDirectVenue(ForkInfra memory infra) internal {
        directGraduator = new RealmDirectGraduatorUniV4(
            poolManagerAddress, TEST_HOOK_ADDRESS, TEST_ANYPAIR_HOOK_ADDRESS, univ4LiquidityAdder
        );
        assetsWhitelist = RealmAssetsWhitelist(
            address(
                new ERC1967Proxy(
                    address(
                        new RealmAssetsWhitelist(
                            poolManagerAddress,
                            infra.weth,
                            infra.uniV2Factory,
                            DeploymentAddressesEthereumMainnet.UNIV3_FACTORY
                        )
                    ),
                    abi.encodeCall(RealmAssetsWhitelist.initialize, (admin))
                )
            )
        );
        address impl = address(
            new RealmFactoryUniV4Direct(
                IRealmFactory.TokenImpls({base: address(realmToken), tax: address(realmTaxToken)}),
                address(directGraduator),
                address(feeHandler),
                address(creatorVaultFactory),
                infra.weth,
                address(assetsWhitelist)
            )
        );
        directFactory = RealmFactoryUniV4Direct(
            address(new ERC1967Proxy(impl, abi.encodeCall(RealmFactoryAbstract.initialize, ())))
        );
    }

    modifier createTestToken() virtual {
        _createTestToken();
        _;
    }

    /// @dev What `createTestToken` deploys: a plain curve token on the V2 factory. Direct-venue suites
    ///      override it.
    function _createTestToken() internal virtual {
        vm.prank(creator);
        testToken = factoryV2Unified.createToken(
            _setupTiered(
                "TestToken", "TEST", _nextValidSalt(address(factoryV2Unified), address(realmToken)), _fs(creator)
            ),
            _noAlloc(_emptyTaxCfg()),
            _noSs(),
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
        );
    }

    function _graduateToken() internal virtual {
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
    ///      constant, 3000 for both V2 and V4). Assumes a non-tax token, where the whole trading fee
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

/// @notice Base for suites on the direct V4 venue: `createTestToken` launches a native-pair token that
///         is graduated in its creation transaction, so `_graduateToken` has nothing left to do.
///         `implementation = realmTaxToken` makes the test token taxable (4% sell for 14 days).
contract LaunchpadBaseTestsWithDirectV4 is LaunchpadBaseTests {
    function setUp() public virtual override {
        super.setUp();
        graduator = IRealmGraduator(address(directGraduator));
    }

    function _createTestToken() internal virtual override {
        testToken = _createDirectToken(
            address(implementation) == address(realmTaxToken) ? _taxCfg(0, 400, uint32(14 days)) : _emptyTaxCfg()
        );
    }

    function _graduateToken() internal virtual override {}
}
