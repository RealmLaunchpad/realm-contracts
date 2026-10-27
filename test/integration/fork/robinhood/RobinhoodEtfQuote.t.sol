// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RobinhoodForkBase} from "test/integration/fork/robinhood/RobinhoodForkBase.t.sol";
import {RealmTaxableTokenUniV4} from "src/tokens/RealmTaxableTokenUniV4.sol";
import {RealmAssetsWhitelist} from "src/access/RealmAssetsWhitelist.sol";
import {RealmFactoryUniV4Direct} from "src/factories/RealmFactoryUniV4Direct.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {TaxConfigsWithDirectAllocation} from "src/interfaces/IRealmTaxableToken.sol";
import {RealmEtf} from "src/etf/RealmEtf.sol";
import {RealmEtfAssets} from "src/etf/RealmEtfAssets.sol";
import {RealmEtfFactory} from "src/etf/RealmEtfFactory.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "lib/v4-core/src/types/PoolId.sol";
import {Currency} from "lib/v4-core/src/types/Currency.sol";
import {IHooks} from "lib/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "lib/v4-core/src/libraries/Hooks.sol";
// `RealmEtfAssets` is built on the `@uniswap` remapping, whose structs are distinct types.
import {PoolKey as EtfPoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency as EtfCurrency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks as EtfIHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @notice A Realm ETF as a direct-venue quote: listed by its factory at creation, at its NAV (`Venue.VAULT`) through USDG, a launch
///         against it opening at the default market cap in native, and a native dev buy zapped
///         native -> USDG -> shares through the ETF's own hook pool.
contract RobinhoodEtfQuoteTests is RobinhoodForkBase {
    using PoolIdLibrary for PoolKey;

    /// @dev The ETF suite's block: its component pools were probed here.
    uint256 internal constant ETF_FORK_BLOCK = 92_800_000;

    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant USDG_HOOK = 0x06a889870C8f83640D6816319f72e2aA579b6080;
    uint24 internal constant USDG_FEE = 0x800000;
    address internal constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address internal constant META = 0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35;
    address internal constant NVDA_V3 = 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3;

    RealmEtf internal etf;
    PoolKey internal etfKey;

    function _forkInfra() internal view virtual override returns (ForkInfra memory infra) {
        infra = super._forkInfra();
        infra.blockNumber = ETF_FORK_BLOCK;
    }

    function setUp() public virtual override {
        super.setUp();
        RealmEtfAssets registry = RealmEtfAssets(
            address(
                new ERC1967Proxy(
                    address(
                        new RealmEtfAssets(
                            poolManagerAddress, address(0x1f7d7550B1b028f7571E69A784071F0205FD2EfA), address(0), USDG
                        )
                    ),
                    abi.encodeCall(RealmEtfAssets.initialize, (admin))
                )
            )
        );
        vm.startPrank(admin);
        registry.setApprover(admin, true);
        RealmEtfAssets.Route memory r;
        r.venue = RealmEtfAssets.Venue.V4;
        r.key = _etfRouteKey(SPY);
        registry.setRoute(SPY, r);
        r.key = _etfRouteKey(META);
        registry.setRoute(META, r);
        delete r.key;
        (r.venue, r.pool) = (RealmEtfAssets.Venue.V3, NVDA_V3);
        registry.setRoute(NVDA, r);

        RealmEtfFactory factory = RealmEtfFactory(
            address(
                new ERC1967Proxy(
                    address(new RealmEtfFactory(registry, assetsWhitelist)),
                    abi.encodeCall(RealmEtfFactory.initialize, (admin))
                )
            )
        );
        // The factory lists every new ETF priced through USDG, so USDG goes first, against native.
        assetsWhitelist.setApprover(address(factory), true);
        assetsWhitelist.setApprover(admin, true);
        RealmAssetsWhitelist.PriceSource memory src;
        src.venue = RealmAssetsWhitelist.Venue.V4;
        src.key = PoolKey(Currency.wrap(address(0)), Currency.wrap(USDG), USDG_FEE, 10, IHooks(USDG_HOOK));
        assetsWhitelist.setWhitelisted(USDG, src);
        address hook = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                    | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            ) | (uint160(0x4444) << 144)
        );
        deployCodeTo("RealmEtfHook.sol:RealmEtfHook", abi.encode(IPoolManager(poolManagerAddress), factory), hook);
        factory.setHook(hook);
        vm.stopPrank();

        address[] memory assets = new address[](3);
        (assets[0], assets[1], assets[2]) = (SPY, META, NVDA);
        uint16[] memory weights = new uint16[](3);
        (weights[0], weights[1], weights[2]) = (5_000, 3_000, 2_000);
        deal(USDG, creator, 1_000e6);
        vm.startPrank(creator);
        IERC20(USDG).approve(address(factory), 1_000e6);
        etf = RealmEtf(
            factory.createEtf("Tech ETF", "TECH", RealmEtf.Mode.FIXED, assets, weights, 1_000e6, new uint256[](3))
        );
        vm.stopPrank();
        etfKey = _key(address(etf), USDG, 0, 1, hook);
    }

    /// @dev `asset`'s hookless 0.3% V4 pool against USDG.
    function _etfRouteKey(address asset) internal pure returns (EtfPoolKey memory) {
        (address c0, address c1) = asset < USDG ? (asset, USDG) : (USDG, asset);
        return EtfPoolKey(EtfCurrency.wrap(c0), EtfCurrency.wrap(c1), 3000, 60, EtfIHooks(address(0)));
    }

    function _key(address a, address b, uint24 fee, int24 spacing, address hooks)
        internal
        pure
        returns (PoolKey memory)
    {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), fee, spacing, IHooks(hooks));
    }

    /// @dev Whole shares per native = USDG per native over USDG per share (NAV), 6 vs 18 decimals included.
    function test_listing_ratesTheEtfAtItsNavInNative() public view {
        uint256 usdgPerShare = etf.convertToAssets(1e18); // raw USDG, 6 decimals
        uint256 expected = assetsWhitelist.unitsPerNativeX18(USDG) * 1e6 / usdgPerShare;
        assertApproxEqRel(assetsWhitelist.unitsPerNativeX18(address(etf)), expected, 1e12, "NAV through USDG");
        assertEq(assetsWhitelist.referenceOf(address(etf)), USDG);
        RealmAssetsWhitelist.PriceSource memory src = assetsWhitelist.priceSource(address(etf));
        assertEq(uint8(src.venue), uint8(RealmAssetsWhitelist.Venue.VAULT));
        assertEq(src.pool, address(etf));
        assertEq(PoolId.unwrap(src.key.toId()), PoolId.unwrap(etfKey.toId()), "routes zaps through the ETF's pool");
    }

    /// @dev The launch opens at the default market cap in native, and a native dev buy reaches the token
    ///      through native -> USDG -> shares (the shares hop through the ETF's hook pool).
    function test_launch_quotedInTheEtfWithANativeDevBuy() public {
        (,, uint256 marketCapX18) = directFactory.previewLaunchTick(address(etf));
        uint256 capInNative = marketCapX18 * 1e18 / assetsWhitelist.unitsPerNativeX18(address(etf));
        assertApproxEqRel(capInNative, directFactory.LAUNCH_MARKET_CAP_X18(), 0.01e18, "default cap in native");

        RealmFactoryUniV4Direct.DirectPair[] memory pairs = new RealmFactoryUniV4Direct.DirectPair[](1);
        pairs[0] = RealmFactoryUniV4Direct.DirectPair({quote: address(etf), weightBps: 10_000});
        TaxConfigsWithDirectAllocation memory noTax;
        vm.deal(creator, 0.01 ether);
        vm.prank(creator);
        address token = directFactory.createToken{value: 0.01 ether}(
            _directSetup("ETF Coin", "ETFC", false),
            pairs,
            noTax,
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            _devBuyTo(creator),
            address(0)
        );
        assertEq(RealmTaxableTokenUniV4(payable(token)).quotes(1), address(etf), "the ETF is the token's quote");
        assertGt(IERC20(token).balanceOf(creator), 0, "dev buy delivered");
    }
}
