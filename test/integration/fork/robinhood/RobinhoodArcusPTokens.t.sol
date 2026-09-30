// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RobinhoodForkBase} from "test/integration/fork/robinhood/RobinhoodForkBase.t.sol";
import {DeploymentAddressesRobinhoodMainnet as Robinhood} from "src/config/DeploymentAddresses.sol";
import {RealmTaxableTokenUniV4} from "src/tokens/RealmTaxableTokenUniV4.sol";
import {DividendDistribution} from "src/tokens/DividendDistribution.sol";
import {RealmAssetsWhitelist} from "src/access/RealmAssetsWhitelist.sol";
import {RealmDividendSwapRegistry} from "src/dividends/RealmDividendSwapRegistry.sol";
import {RealmFactoryUniV4Direct} from "src/factories/RealmFactoryUniV4Direct.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {TaxConfigsWithDirectAllocation} from "src/interfaces/IRealmTaxableToken.sol";
import {Hop} from "src/interfaces/IRealmDividendSwapRegistry.sol";
import {DividendRouteLib} from "src/libraries/DividendRouteLib.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "lib/v4-core/src/types/PoolId.sol";
import {Currency} from "lib/v4-core/src/types/Currency.sol";
import {IHooks} from "lib/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "lib/v4-core/src/libraries/StateLibrary.sol";

/// @notice Arcus leveraged pTokens on Robinhood mainnet, as direct-venue quotes and as dividend payout
///         assets, through their real Uniswap V4 pools. Each pToken trades only against USDG, behind an
///         Arcus hook that re-centers two narrow ranges around its NAV — so a pool can sit in the gap
///         between them, reading zero in-range liquidity while swaps still fill. pGLD5x is parked there at
///         the pinned block; pHOOD3x is not.
/// @dev Also the retired-asset fallback end to end: a retired payout asset or quote stops converting and
///      its buffer pays holders in its own currency, through a pot of its own.
contract RobinhoodArcusPTokensTests is RobinhoodForkBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev Later than the rStock suites' block: the Arcus pools were probed here.
    uint256 internal constant ARCUS_FORK_BLOCK = 76_000_000;

    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant USDG_HOOK = 0x06a889870C8f83640D6816319f72e2aA579b6080;
    uint24 internal constant USDG_FEE = 0x800000;

    address internal constant PHOOD3X = 0xe24CABDf76DD1c2576049167eB1755C84b985C36;
    address internal constant PGLD5X = 0x37A2aFaa98648f2e13658623885F821ac8365609;
    address internal constant HOOK_FA3D = 0xFA3dA20EC661AA26F9f93E4421Fab6989c4B4800;
    address internal constant HOOK_F28A = 0xf28A89AF20fABDB89Af9D033bB0a98D17212c880;

    address internal holder2 = makeAddr("holder2");

    receive() external payable {}

    function _forkInfra() internal view virtual override returns (ForkInfra memory infra) {
        infra = super._forkInfra();
        infra.blockNumber = ARCUS_FORK_BLOCK;
    }

    //////////////////////// pools, listings, routes //////////////////////

    function _arcusKey(address pToken) internal pure returns (PoolKey memory) {
        (uint24 fee, address hook) = pToken == PHOOD3X ? (uint24(8_500), HOOK_FA3D) : (uint24(4_250), HOOK_F28A);
        (address c0, address c1) = pToken < USDG ? (pToken, USDG) : (USDG, pToken);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), fee, 10, IHooks(hook));
    }

    function _usdgKey() internal pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(USDG), USDG_FEE, 10, IHooks(USDG_HOOK));
    }

    function _v4Source(PoolKey memory key) internal pure returns (RealmAssetsWhitelist.PriceSource memory src) {
        src.venue = RealmAssetsWhitelist.Venue.V4;
        src.key = key;
    }

    /// @dev USDG against native, then `pToken` against USDG: the listing the ops script broadcasts.
    function _listArcus(address pToken) internal {
        vm.prank(admin);
        assetsWhitelist.setApprover(address(this), true);
        assetsWhitelist.setWhitelisted(USDG, _v4Source(_usdgKey()));
        assetsWhitelist.setWhitelisted(pToken, _v4Source(_arcusKey(pToken)));
    }

    /// @dev 0x04 + [USDG hop, pToken hop]: native -> USDG -> pToken.
    function _arcusRoute(address pToken) internal pure returns (bytes memory) {
        PoolKey memory k = _arcusKey(pToken);
        Hop[] memory hops = new Hop[](2);
        hops[0] = Hop({currency: USDG, fee: USDG_FEE, tickSpacing: 10, hooks: USDG_HOOK});
        hops[1] = Hop({currency: pToken, fee: k.fee, tickSpacing: 10, hooks: address(k.hooks)});
        return DividendRouteLib.encodeV4(hops);
    }

    function _inRangeLiquidity(address pToken) internal view returns (uint128) {
        return IPoolManager(poolManagerAddress).getLiquidity(_arcusKey(pToken).toId());
    }

    /// @dev A native-pair token paying its dividends in `pToken`, with `buyer` two thirds of the float and
    ///      `holder2` a third.
    function _pTokenPayer(address pToken) internal returns (RealmTaxableTokenUniV4 token) {
        bytes[] memory routes = new bytes[](1);
        routes[0] = _arcusRoute(pToken);
        token = _graduatedRStockToken(_createRStockToken(_sole(pToken), _w(10_000), routes));
        uint256 third = token.balanceOf(buyer) / 3;
        vm.prank(buyer);
        token.transfer(holder2, third);
    }

    /// @dev Empties `who`'s `asset` balance, so the next loop iteration measures from zero.
    function _drop(address asset, address who) internal {
        uint256 bal = IERC20(asset).balanceOf(who);
        vm.prank(who);
        IERC20(asset).transfer(address(1), bal);
    }

    function _retire(address asset, bool retired) internal {
        vm.prank(admin);
        dividendSwapRegistry.setRetired(asset, retired);
    }

    //////////////////////// listing and launch //////////////////////

    /// @dev Both pTokens list against USDG — the gap-parked one included, which the old in-range liquidity
    ///      check refused — and price live, which is what a launch reads.
    function test_listing_arcusPTokensListAgainstUsdg_evenParkedInTheGap() public {
        assertEq(_inRangeLiquidity(PGLD5X), 0, "premise: pGLD5x sits in the gap at the pinned block");
        assertGt(_inRangeLiquidity(PHOOD3X), 0, "premise: pHOOD3x does not");

        _listArcus(PHOOD3X);
        assetsWhitelist.setWhitelisted(PGLD5X, _v4Source(_arcusKey(PGLD5X)));

        for (uint256 i; i < 2; ++i) {
            address p = i == 0 ? PHOOD3X : PGLD5X;
            assertGt(assetsWhitelist.unitsPerNativeX18(p), 0, "listed");
            assertEq(assetsWhitelist.referenceOf(p), USDG, "priced through USDG");
            assertEq(assetsWhitelist.liveUnitsPerNativeX18(p), assetsWhitelist.unitsPerNativeX18(p), "live rate reads");
        }
    }

    /// @dev A launch quoted in a pToken parked in the gap: priced from its live rate, never reverting on
    ///      the pool's empty range.
    function test_launch_quotedInAGapParkedPToken() public {
        _listArcus(PGLD5X);
        RealmFactoryUniV4Direct.DirectPair[] memory pairs = new RealmFactoryUniV4Direct.DirectPair[](1);
        pairs[0] = RealmFactoryUniV4Direct.DirectPair({quote: PGLD5X, weightBps: 10_000});
        TaxConfigsWithDirectAllocation memory noTax;

        vm.prank(creator);
        address token = directFactory.createToken(
            _directSetup("Gold Levered", "GLDL", false),
            pairs,
            noTax,
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            _noDevBuy(),
            address(0)
        );
        assertEq(RealmTaxableTokenUniV4(payable(token)).quotes(1), PGLD5X, "the pToken is the token's quote");
    }

    //////////////////////// dividend conversion //////////////////////

    /// @dev The keeper converts the native buffer native -> USDG -> pToken through the real Arcus pool,
    ///      for a liquid pool and for one parked in the gap, and the holders are paid in the pToken.
    function test_dividends_convertThroughArcusPools_includingTheGap() public {
        for (uint256 i; i < 2; ++i) {
            address p = i == 0 ? PHOOD3X : PGLD5X;
            RealmTaxableTokenUniV4 token = _pTokenPayer(p);
            token.accrueFees{value: 0.2 ether}();
            assertGt(token.pendingNative(), 0, "precondition: buffered");

            token.processDividends(0, true, 0, 1, _holders(buyer, holder2));

            assertGt(IERC20(p).balanceOf(buyer), 0, "buyer paid in the pToken");
            assertApproxEqRel(IERC20(p).balanceOf(buyer), 2 * IERC20(p).balanceOf(holder2), 1e15, "pro rata");
            _drop(p, buyer);
            _drop(p, holder2);
        }
    }

    //////////////////////// retirement //////////////////////

    /// @dev Retired: the native buffer is not converted but credited AS NATIVE through the native pot,
    ///      beside the pToken already bought, which stays claimable. Un-retired: conversions resume and the
    ///      pot stays claimable.
    function test_retire_paysTheNativeBufferAsNativeAndUnretireResumes() public {
        RealmTaxableTokenUniV4 token = _pTokenPayer(PHOOD3X);
        token.accrueFees{value: 0.2 ether}();
        token.processDividends(0, true, 0, 1, _noHolders());
        uint256 boughtOwed = token.previewDividend(holder2, 0);
        assertGt(boughtOwed, 0, "precondition: holder2 is owed pHOOD3x");

        _retire(PHOOD3X, true);
        vm.roll(block.number + 1);
        token.accrueFees{value: 0.1 ether}();
        uint256 buffered = token.pendingNative();
        uint256 pTokenHeld = IERC20(PHOOD3X).balanceOf(address(token));

        vm.expectEmit(true, true, false, true, address(token));
        emit DividendDistribution.DividendFallbackFunded(0, address(0), buffered);
        token.processDividends(0, true, 0, 1, _noHolders());

        assertEq(token.pendingNative(), 0, "the whole buffer moved, no conversion cap");
        assertEq(IERC20(PHOOD3X).balanceOf(address(token)), pTokenHeld, "nothing was bought");
        assertEq(token.dividendFallbackMask(), 1, "the native pot exists");
        (, uint120 potOwed,) = token.dividendFallbacks(0);
        assertEq(potOwed, buffered, "the pot owes the buffer");
        uint256 fallbackOwed = token.previewDividendFallback(holder2, 0);
        assertApproxEqRel(fallbackOwed, buffered / 3, 1e15, "holder2's third of it, in native");
        assertEq(token.previewDividend(holder2, 0), boughtOwed, "the pHOOD3x claim is untouched");

        // The pot is committed: a sweep cannot recycle it.
        token.sweepStrayEth();
        assertGe(address(token).balance, potOwed, "sweep left the pot");

        // A transfer settles the pot like any leg: the claim moves with the balance history, not after it.
        vm.prank(holder2);
        token.transfer(buyer, 1);
        assertEq(token.previewDividendFallback(holder2, 0), fallbackOwed, "settled on transfer");

        _retire(PHOOD3X, false);
        vm.roll(block.number + 1);
        token.accrueFees{value: 0.1 ether}();
        token.processDividends(0, true, 0, 1, _noHolders());
        assertGt(IERC20(PHOOD3X).balanceOf(address(token)), pTokenHeld, "un-retired: converting again");
        assertEq(token.previewDividendFallback(holder2, 0), fallbackOwed, "and the pot is still claimable");

        uint256 ethBefore = holder2.balance;
        uint256 pOwed = token.previewDividend(holder2, 0);
        vm.prank(holder2);
        token.claimDividends();
        assertEq(holder2.balance - ethBefore, fallbackOwed, "claim paid the native pot");
        assertEq(IERC20(PHOOD3X).balanceOf(holder2), pOwed, "and the pHOOD3x");
        assertEq(token.previewDividendFallback(holder2, 0), 0, "nothing left in the pot for holder2");
    }

    /// @dev A retired QUOTE: the token's pHOOD3x buffer cannot be sold back to native any more, so it pays
    ///      holders in pHOOD3x through that quote's pot — pushed by the keeper's ordinary native batch.
    function test_retiredQuote_paysTheQuoteBufferInTheQuote() public {
        _listArcus(PHOOD3X);
        RealmTaxableTokenUniV4 token = _pTokenQuotedNativePayer();
        address pair = token.pair();
        vm.startPrank(pair);
        token.transfer(buyer, 2e24);
        token.transfer(holder2, 1e24);
        vm.stopPrank();

        uint256 amount = 10e18;
        deal(PHOOD3X, address(this), amount);
        IERC20(PHOOD3X).approve(address(token), amount);
        token.accrueFees(PHOOD3X, amount);
        uint256 buffered = token.quoteDividendPending(PHOOD3X)[0];
        assertGt(buffered, 0, "precondition: the quote buffer holds pHOOD3x");

        _retire(PHOOD3X, true);
        vm.expectEmit(true, true, false, true, address(token));
        emit DividendDistribution.DividendFallbackFunded(0, PHOOD3X, buffered);
        token.processDividends(0, PHOOD3X, 0, 1, _noHolders());

        assertEq(token.quoteDividendPending(PHOOD3X)[0], 0, "the quote buffer moved whole");
        assertEq(token.dividendFallbackMask(), 2, "pot 1 (the pHOOD3x quote) exists");
        uint256 owed2 = token.previewDividendFallback(holder2, 1);
        assertGt(owed2, 0, "holder2 is owed pHOOD3x");

        // The owner cannot rescue the pot.
        uint256 held = IERC20(PHOOD3X).balanceOf(address(token));
        vm.prank(creator);
        token.rescueTokens(PHOOD3X);
        assertEq(IERC20(PHOOD3X).balanceOf(address(token)), held, "pot reserved against rescue");

        vm.roll(block.number + 1);
        token.processDividends(0, true, 0, 0, _holders(holder2));
        assertEq(IERC20(PHOOD3X).balanceOf(holder2), owed2, "the native batch pushed the quote pot");
    }

    /// @dev A direct token quoted in pHOOD3x only, paying native dividends: its pHOOD3x buffer sells
    ///      pHOOD3x -> USDG -> native through the quote route.
    function _pTokenQuotedNativePayer() internal returns (RealmTaxableTokenUniV4) {
        RealmFactoryUniV4Direct.DirectPair[] memory pairs = new RealmFactoryUniV4Direct.DirectPair[](1);
        pairs[0] = RealmFactoryUniV4Direct.DirectPair({quote: PHOOD3X, weightBps: 10_000});
        TaxConfigsWithDirectAllocation memory c;
        c.earningsAllocation.dividendsBps = DIVIDENDS_BPS;
        c.earningsAllocation.dividendTokens = _sole(address(0));
        c.earningsAllocation.dividendWeightsBps = _w(10_000);
        c.quoteRoutes = new bytes[](1);
        c.quoteRoutes[0] = _arcusRoute(PHOOD3X);

        vm.prank(creator);
        return RealmTaxableTokenUniV4(
            payable(directFactory.createToken(
                    _directSetup("Hood Levered", "HOODL", true),
                    pairs,
                    c,
                    _emptyAntiSniperCfg(),
                    new IRealmFactory.CreatorVault[](0),
                    _noDevBuy(),
                    address(0)
                ))
        );
    }
}
