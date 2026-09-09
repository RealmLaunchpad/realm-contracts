// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {RobinhoodForkBase} from "test/integration/fork/robinhood/RobinhoodForkBase.t.sol";
import {DeploymentAddressesRobinhoodMainnet as Robinhood} from "src/config/DeploymentAddresses.sol";
import {RealmTaxableTokenUniV4} from "src/tokens/RealmTaxableTokenUniV4.sol";
import {DividendDistribution} from "src/tokens/DividendDistribution.sol";
import {KeeperGated} from "src/tokens/KeeperGated.sol";
import {RealmDividendSwapRegistry} from "src/dividends/RealmDividendSwapRegistry.sol";
import {SwapRejection} from "src/interfaces/IRealmDividendSwapRegistry.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @notice The whole dividend product, end to end, on the chain it ships on: a taxable token with a
///         tax allocation is created naming xStocks as its payout assets, graduates onto Robinhood's
///         Uniswap V4, gets traded there so the hook collects tax, the keeper converts the buffered tax
///         into the xStock through Robinhood's own pools, and the holders end up holding the stock.
///         Nothing is injected: every wei the holders receive was charged on a real swap.
contract RobinhoodXStockDividendsE2ETests is RobinhoodForkBase {
    address internal holder2 = makeAddr("holder2");
    address internal stranger = makeAddr("stranger");
    address internal keeperWallet = makeAddr("keeperWallet");

    receive() external payable {}

    /// @dev A graduated AAPL-paying token with a buffer past the threshold, `buyer` holding two thirds
    ///      of the float and `holder2` the other third — so a pro-rata payout has a ratio to check.
    function _liveAppleToken() internal returns (RealmTaxableTokenUniV4 token) {
        token = _graduatedXStockToken(_sole(AAPL), _w(10_000));
        uint256 third = token.balanceOf(buyer) / 3;
        vm.prank(buyer);
        token.transfer(holder2, third);

        _churn(1, 2 ether);
        assertGe(token.pendingNative(), token.DIVIDEND_THRESHOLD(), "precondition: one round trip funds a conversion");
    }

    /// @dev What `token` earned across `logs`, split by source: the tax the hook charged
    ///      (`CreatorTaxesAccrued`) and the creator's share of the LP fee the router forwarded
    ///      (`LpFeesRouted.creatorShare`). Both arrive through `accrueFees` and go through the same split.
    function _earnings(Vm.Log[] memory logs, address token) internal pure returns (uint256 tax, uint256 lpShare) {
        bytes32 taxSig = keccak256("CreatorTaxesAccrued(address,uint256)");
        bytes32 lpSig = keccak256("LpFeesRouted(address,uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 2 || address(uint160(uint256(logs[i].topics[1]))) != token) continue;
            if (logs[i].topics[0] == taxSig) {
                tax += abi.decode(logs[i].data, (uint256));
            } else if (logs[i].topics[0] == lpSig) {
                (uint256 creatorShare,,) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                lpShare += creatorShare;
            }
        }
    }

    //////////////////////// creation //////////////////////

    /// @dev The route ships with the creation and is committed on the registry against the token, so
    ///      the keeper's conversion later needs nothing but the asset index.
    function test_creation_commitsTheXStockRouteOnTheRegistry() public {
        address token = _createXStockToken(_sole(AAPL), _w(10_000));

        assertEq(dividendSwapRegistry.routeOf(token, AAPL), _xstockRoute(AAPL), "the AAPL route is on record");
        (,,,, address payout,,,) = RealmTaxableTokenUniV4(payable(token)).dividendAssets(0);
        assertEq(payout, AAPL, "and AAPL is the payout asset");
        assertTrue(RealmTaxableTokenUniV4(payable(token)).hasDividends(), "dividends are on");
    }

    /// @dev An xStock nothing can buy is refused at creation, not discovered at the first conversion:
    ///      a clone cannot be repointed, so a dead route accepted here would be permanent.
    function test_creation_refusesAnXStockNoRouteCanBuy() public {
        vm.expectPartialRevert(RealmDividendSwapRegistry.RouteRejected.selector);
        _createXStockToken(_sole(NVDA), _w(10_000));
    }

    //////////////////////// tax collection on Robinhood's V4 //////////////////////

    /// @dev Real swaps through the universal router on Robinhood's pool manager: the hook charges the
    ///      tax on both legs and the router forwards the creator's LP-fee share, the token receives both
    ///      as earnings, and `DIVIDENDS_BPS` of every accrual lands in the buffer — the buffer being the
    ///      ONLY ETH the token holds, so nothing of it is reachable by a sweep.
    function test_swaps_hookTaxFromRobinhoodsPoolFundsTheDividendBuffer() public {
        RealmTaxableTokenUniV4 token = _graduatedXStockToken(_sole(AAPL), _w(10_000));
        assertEq(token.pendingNative(), 0, "nothing buffered before the first post-graduation trade");

        vm.recordLogs();
        _churn(1, 1 ether);
        (uint256 tax, uint256 lpShare) = _earnings(vm.getRecordedLogs(), address(token));

        assertGt(tax, 0, "the hook charged tax on the buy and the sell");
        assertGt(lpShare, 0, "and the router forwarded the creator's LP-fee share");
        uint256 buffered = token.pendingNative();
        // Four accruals (tax + LP share per leg), each rounding its own 80% down.
        assertApproxEqAbs(
            buffered, (tax + lpShare) * DIVIDENDS_BPS / 10_000, 4, "80% of every accrual is buffered for holders"
        );
        assertEq(address(token).balance, buffered, "and that buffer is all the ETH the token holds");
    }

    /// @dev The tax has a window. Once it closes the hook charges none, and what still reaches the
    ///      holders from a trade is only their share of the creator's LP-fee cut.
    function test_swaps_taxWindowClosesAndOnlyTheLpShareKeepsFlowing() public {
        RealmTaxableTokenUniV4 token = _graduatedXStockToken(_sole(AAPL), _w(10_000));
        _churn(1, 1 ether);
        uint256 collectedInTheWindow = token.pendingNative();
        assertGt(collectedInTheWindow, 0, "precondition: the window collected something");

        skip(TAX_DURATION + 1);
        vm.recordLogs();
        _churn(1, 1 ether);
        (uint256 tax, uint256 lpShare) = _earnings(vm.getRecordedLogs(), address(token));

        assertEq(tax, 0, "no tax is charged after the window");
        assertApproxEqAbs(
            token.pendingNative() - collectedInTheWindow,
            lpShare * DIVIDENDS_BPS / 10_000,
            2,
            "the buffer grew by the holders' share of the LP-fee cut alone"
        );
    }

    //////////////////////// the keeper, and the holders //////////////////////

    /// @dev THE flow: the keeper converts the buffered ETH into AAPL through Robinhood's pool, the pot
    ///      is credited to the balances held at that instant, and a push pays every holder pro rata in
    ///      AAPL.
    function test_keeper_convertsTheTaxIntoAppleAndHoldersReceiveIt() public {
        RealmTaxableTokenUniV4 token = _liveAppleToken();
        uint256 buffered = token.pendingNative();
        uint256 cap = token.MAX_DIVIDEND_PER_CONVERSION();
        uint256 spend = buffered > cap ? cap : buffered;

        token.processDividends(0, 1, _noHolders());

        uint256 pot = IERC20(AAPL).balanceOf(address(token));
        assertGt(pot, 0, "the buffer was converted into AAPL on Robinhood's V4");
        assertEq(token.dividendsOwed(), pot, "every share of the pot is owed to holders");
        assertEq(token.committedDividends(AAPL), pot, "and none of it is rescuable");
        assertEq(token.pendingNative(), buffered - spend, "what the per-conversion cap left stays buffered");

        token.processDividends(0, 0, _holders(buyer, holder2));

        uint256 paidBuyer = IERC20(AAPL).balanceOf(buyer);
        uint256 paidHolder2 = IERC20(AAPL).balanceOf(holder2);
        assertGt(paidHolder2, 0, "the minority holder was paid in AAPL");
        assertApproxEqRel(paidBuyer, 2 * paidHolder2, 1e15, "pro rata: buyer holds twice holder2's balance");
        assertApproxEqRel(paidBuyer + paidHolder2, pot, 1e15, "the whole pot reached the holders");
        assertLt(token.committedDividends(AAPL), pot / 1e6, "nothing meaningful left owed");
    }

    /// @dev Two xStocks at once: the tax splits by weight into independent buffers, each converts
    ///      through its own Robinhood pool, and the holder ends up with both stocks.
    function test_keeper_twoXStocksSplitByWeightAndBothReachTheHolder() public {
        RealmTaxableTokenUniV4 token = _graduatedXStockToken(_pair(AAPL, TSLA), _w(3_000, 7_000));
        _churn(3, 2 ether);

        uint256 apple = _buffered(token, 0);
        uint256 tesla = _buffered(token, 1);
        assertGe(apple, token.DIVIDEND_THRESHOLD(), "precondition: the 30% leg crossed the threshold");
        assertApproxEqRel(apple * 7, tesla * 3, 1e12, "the tax split 30/70 between the legs");

        token.processDividends(0, 1, _noHolders());
        token.processDividends(1, 1, _noHolders());
        assertEq(token.committedDividends(AAPL), IERC20(AAPL).balanceOf(address(token)), "AAPL pot committed");
        assertEq(token.committedDividends(TSLA), IERC20(TSLA).balanceOf(address(token)), "TSLA pot committed");

        token.processDividends(0, 0, _holders(buyer));
        token.processDividends(1, 0, _holders(buyer));

        assertGt(IERC20(AAPL).balanceOf(buyer), 0, "paid in AAPL");
        assertGt(IERC20(TSLA).balanceOf(buyer), 0, "and in TSLA");
    }

    /// @dev Native and an xStock side by side: the native leg needs no conversion and no route, the
    ///      MSFT leg crosses its pool, and one holder collects both.
    function test_keeper_nativeAndXStockLegsPayTogether() public {
        RealmTaxableTokenUniV4 token = _graduatedXStockToken(_pair(address(0), MSFT), _w(5_000, 5_000));
        _churn(2, 2 ether);
        assertGe(_buffered(token, 1), token.DIVIDEND_THRESHOLD(), "precondition: both legs crossed the threshold");

        token.processDividends(0, 0, _noHolders());
        token.processDividends(1, 1, _noHolders());

        uint256 ethBefore = buyer.balance;
        token.processDividends(0, 0, _holders(buyer));
        token.processDividends(1, 0, _holders(buyer));

        assertGt(buyer.balance, ethBefore, "paid in native");
        assertGt(IERC20(MSFT).balanceOf(buyer), 0, "and in MSFT");
    }

    /// @dev Holders never depend on the keeper to be PAID. Once the pot is credited, a holder claims
    ///      their AAPL themselves, and gets exactly what the accumulator says they are owed.
    function test_holder_claimsTheirAppleWithoutAKeeper() public {
        RealmTaxableTokenUniV4 token = _liveAppleToken();
        token.processDividends(0, 1, _noHolders());

        uint256 owed = token.previewDividend(holder2);
        assertGt(owed, 0, "precondition: holder2 accrued a share");

        vm.prank(holder2);
        token.claimDividends();

        assertEq(IERC20(AAPL).balanceOf(holder2), owed, "the claim paid the accrued share, in AAPL");
        assertEq(token.previewDividend(holder2), 0, "and nothing is owed any more");
    }

    //////////////////////// what the keeper cannot do, and who cannot be the keeper //////////////////////

    /// @dev A floor the pool cannot meet fails the conversion and spends nothing: the buffer is intact
    ///      and the keeper re-quotes. This is the slippage protection the keeper gate exists to make
    ///      meaningful.
    function test_keeper_floorAboveMarketFailsWithoutSpendingTheBuffer() public {
        RealmTaxableTokenUniV4 token = _liveAppleToken();
        uint256 buffered = token.pendingNative();

        vm.expectRevert(DividendDistribution.DividendConversionFailed.selector);
        token.processDividends(0, type(uint128).max, _noHolders());

        assertEq(token.pendingNative(), buffered, "the buffer was not touched");
        assertEq(IERC20(AAPL).balanceOf(address(token)), 0, "and nothing was bought");
    }

    /// @dev The conversion takes its floor from the caller, so the caller has to be an appointed keeper.
    function test_stranger_cannotConvertTheBuffer() public {
        RealmTaxableTokenUniV4 token = _liveAppleToken();

        vm.prank(stranger);
        vm.expectRevert(KeeperGated.NotAKeeper.selector);
        token.processDividends(0, 1, _noHolders());
    }

    /// @dev Robinhood's `KEEPER_FEE`: with a funding wallet set, each conversion diverts a flat cut of
    ///      the spend to it — the keeper's gas money — before the swap, and the rest still converts.
    function test_registry_keeperFundingCutReachesTheKeeperWallet() public {
        vm.prank(admin);
        dividendSwapRegistry.setKeeperFunding(keeperWallet);
        RealmTaxableTokenUniV4 token = _liveAppleToken();

        token.processDividends(0, 1, _noHolders());

        assertEq(keeperWallet.balance, Robinhood.KEEPER_FEE, "the flat Robinhood keeper fee reached the wallet");
        assertGt(IERC20(AAPL).balanceOf(address(token)), 0, "and the conversion still bought AAPL");
    }
}

/// @notice The registry proxy Realm actually deployed on Robinhood — not the fresh copy the base above
///         installs over its address. The route the suite above ships must pass there too, and convert.
/// @dev This test contract stands in for a token: routes are keyed by the caller.
contract RobinhoodLiveRegistryTests is RobinhoodForkBase {
    RealmDividendSwapRegistry internal live = RealmDividendSwapRegistry(Robinhood.DIVIDEND_SWAP_REGISTRY);

    receive() external payable {}

    /// @dev Only the fork — no stack, and no etching over the live proxy.
    function setUp() public override {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"), ROBINHOOD_FORK_BLOCK);
    }

    function test_liveRegistry_acceptsTheAppleRouteAndBuysThroughIt() public {
        bytes memory route = _xstockRoute(AAPL);
        assertEq(
            uint8(live.validateRoute(AAPL, route)), uint8(SwapRejection.OK), "the deployed proxy accepts the route"
        );

        live.registerRoute(AAPL, route);
        vm.deal(address(this), 0.1 ether);
        uint256 bought = live.swapNativeToAsset{value: 0.1 ether}(AAPL, 1, address(this));

        assertGt(bought, 0, "and converts through it");
        assertEq(IERC20(AAPL).balanceOf(address(this)), bought, "delivering the AAPL to the recipient");
    }

    function test_liveRegistry_refusesTheDrainedNvdaPool() public view {
        assertTrue(live.validateRoute(NVDA, _xstockRoute(NVDA)) != SwapRejection.OK, "a route nothing can buy through");
    }
}
