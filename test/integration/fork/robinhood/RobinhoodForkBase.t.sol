// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TaxTokenUniV4BaseTests} from "test/graduators/taxToken.base.t.sol";
import {DeploymentAddressesRobinhoodMainnet as Robinhood} from "src/config/DeploymentAddresses.sol";
import {RealmTaxableTokenUniV4} from "src/tokens/RealmTaxableTokenUniV4.sol";
import {RealmFactoryUniV4Unified} from "src/factories/RealmFactoryUniV4Unified.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {TaxConfigsWithMultiAllocation, EarningsAllocationMultiConfig} from "src/interfaces/IRealmTaxableToken.sol";
import {Hop} from "src/interfaces/IRealmDividendSwapRegistry.sol";
import {DividendRouteLib} from "src/libraries/DividendRouteLib.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @notice Forks Robinhood Chain mainnet and deploys the Realm stack on it, for suites that need what
///         only that chain has: Robinhood's own Uniswap V4 and its xStocks — the tokenized stocks Realm
///         tokens pay dividends in. Needs `ROBINHOOD_RPC_URL`, and the token implementations retargeted
///         to Robinhood (`just chain-robinhood`, or `just test-robinhood-fork`): they bake the chain's
///         addresses in and refuse to construct on any other chain id.
/// @dev Pinned to a block, like every fork suite: the xStock pools below were probed at exactly this
///      block, and a token's route is permanent, so a moving fork would turn a pool drying up into a
///      failing test about nothing.
abstract contract RobinhoodForkBase is TaxTokenUniV4BaseTests {
    uint256 internal constant ROBINHOOD_FORK_BLOCK = 58_000_000;

    /// @dev xStocks, each with the hookless native-ETH V4 pool it converts through. Picked by buying
    ///      through every candidate in `routes.robinhood.mainnet.json` at `ROBINHOOD_FORK_BLOCK` and
    ///      keeping the one that delivered most — the `PickDividendRoutes` method.
    address internal constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address internal constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address internal constant MSFT = 0xe93237C50D904957Cf27E7B1133b510C669c2e74;
    /// @dev Every ETH pool NVDA has is a hooked dynamic-fee one, and all of them are drained at the fork
    ///      block: no route can buy it. The asset a creation must refuse.
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant NVDA_HOOK = 0x344A66eE5826D8Cb59a6F4e1fD802BaF2d64A5c7;

    /// @dev The tax shape every token here launches with: the V4 maximum on both legs (100 bps LP fee
    ///      leaves 400 for tax), 80% of it to holders and the rest to the creator's fund.
    uint16 internal constant LAUNCH_BUY_TAX_BPS = 400;
    uint16 internal constant LAUNCH_SELL_TAX_BPS = 400;
    uint32 internal constant TAX_DURATION = 14 days;
    uint16 internal constant DIVIDENDS_BPS = 8_000;

    function _forkInfra() internal view override returns (ForkInfra memory) {
        return ForkInfra({
            rpcUrlEnv: "ROBINHOOD_RPC_URL",
            blockNumber: ROBINHOOD_FORK_BLOCK,
            poolManager: Robinhood.UNIV4_POOL_MANAGER,
            positionManager: Robinhood.UNIV4_POSITION_MANAGER,
            permit2: Robinhood.PERMIT2,
            universalRouter: Robinhood.UNIV4_UNIVERSAL_ROUTER,
            uniV2Router: Robinhood.UNIV2_ROUTER,
            uniV2Factory: Robinhood.UNIV2_FACTORY,
            uniV2PairInitCodeHash: Robinhood.UNIV2_PAIR_INIT_CODE_HASH,
            weth: Robinhood.WETH
        });
    }

    //////////////////////// routes //////////////////////

    function _v4Route(address asset, uint24 fee, int24 spacing, address hooks) internal pure returns (bytes memory) {
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({currency: asset, fee: fee, tickSpacing: spacing, hooks: hooks});
        return DividendRouteLib.encodeV4(hops);
    }

    /// @dev The route a creation ships for `asset`; empty for native, which needs none.
    function _xstockRoute(address asset) internal pure returns (bytes memory) {
        if (asset == AAPL) return _v4Route(AAPL, 8_000, 80, address(0));
        if (asset == TSLA) return _v4Route(TSLA, 50_000, 1_000, address(0));
        if (asset == MSFT) return _v4Route(MSFT, 10_000, 200, address(0));
        if (asset == NVDA) return _v4Route(NVDA, 0x800000, 10, NVDA_HOOK);
        return "";
    }

    //////////////////////// tokens //////////////////////

    /// @dev A taxable V4 token paying `DIVIDENDS_BPS` of its tax to holders in `assets`, through the
    ///      multi-allocation `createToken` overload — the only creation path that carries routes, and so
    ///      the one a frontend uses for an xStock.
    function _createXStockToken(address[] memory assets, uint16[] memory weights) internal returns (address token) {
        bytes[] memory routes = new bytes[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            routes[i] = _xstockRoute(assets[i]);
        }
        IRealmFactory.TokenSetupTiered memory setup = IRealmFactory.TokenSetupTiered({
            name: "xStock Dividends",
            symbol: "XDIV",
            salt: _nextValidSalt(address(factoryTax), address(realmTaxToken)),
            feeShares: _fs(creator),
            liquidityTier: LiquidityTier.DEFAULT
        });
        TaxConfigsWithMultiAllocation memory cfg = TaxConfigsWithMultiAllocation({
            buyTaxBps: LAUNCH_BUY_TAX_BPS,
            sellTaxBps: LAUNCH_SELL_TAX_BPS,
            taxDurationSeconds: TAX_DURATION,
            startTaxFromLaunch: true,
            buyTaxDecayStartBps: 0,
            sellTaxDecayStartBps: 0,
            taxDecayDuration: 0,
            earningsAllocation: EarningsAllocationMultiConfig({
                burnBps: 0,
                dividendsBps: DIVIDENDS_BPS,
                liquidityBps: 0,
                dividendTokens: assets,
                dividendWeightsBps: weights,
                dividendRoutes: routes
            })
        });
        vm.prank(creator);
        token = factoryTax.createToken(
            setup,
            cfg,
            RealmFactoryUniV4Unified.UniV4Configs({renounceOwnership: false, lpFeeBps: 100}),
            _noSs(),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            address(0)
        );
    }

    /// @dev Created, bought into on the launchpad and graduated onto Robinhood's V4, with `buyer`
    ///      holding the float. Graduation activates every dividend leg.
    function _graduatedXStockToken(address[] memory assets, uint16[] memory weights)
        internal
        returns (RealmTaxableTokenUniV4 token)
    {
        address addr = _createXStockToken(assets, weights);
        testToken = addr;
        _launchpadBuy(addr, 2 ether);
        _graduateToken();
        return RealmTaxableTokenUniV4(payable(addr));
    }

    /// @dev Round-trips `ethPerTrip` through the pool `trips` times — a buy and a full sell-back by
    ///      `alice` — so the hook collects tax on both legs. Each trip lands roughly 8% of its size in
    ///      the token as tax, `DIVIDENDS_BPS` of which the dividend buffers keep.
    function _churn(uint256 trips, uint256 ethPerTrip) internal {
        for (uint256 i; i < trips; ++i) {
            _swapBuy(alice, ethPerTrip, 0, true);
            _swapSell(alice, IERC20(testToken).balanceOf(alice), 0, true);
        }
    }

    function _sole(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    function _pair(address a, address b) internal pure returns (address[] memory list) {
        list = new address[](2);
        list[0] = a;
        list[1] = b;
    }

    function _w(uint16 a) internal pure returns (uint16[] memory list) {
        list = new uint16[](1);
        list[0] = a;
    }

    function _w(uint16 a, uint16 b) internal pure returns (uint16[] memory list) {
        list = new uint16[](2);
        list[0] = a;
        list[1] = b;
    }

    function _noHolders() internal pure returns (address[] memory list) {
        list = new address[](0);
    }

    function _holders(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    function _holders(address a, address b) internal pure returns (address[] memory list) {
        list = new address[](2);
        list[0] = a;
        list[1] = b;
    }

    function _buffered(RealmTaxableTokenUniV4 token, uint256 i) internal view returns (uint256 pendingNative) {
        (,,,,,,,, pendingNative,) = token.dividendAssets(i);
    }
}
