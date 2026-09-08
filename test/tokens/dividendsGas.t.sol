// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";
import {TaxTokenUniV4BaseTests} from "test/graduators/taxToken.base.t.sol";
import {RealmTaxableTokenUniV4} from "src/tokens/RealmTaxableTokenUniV4.sol";
import {RealmFactoryUniV4Unified} from "src/factories/RealmFactoryUniV4Unified.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {
    TaxConfigsWithAllocation,
    EarningsAllocationConfig,
    TaxConfigsWithMultiAllocation,
    EarningsAllocationMultiConfig
} from "src/interfaces/IRealmTaxableToken.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @notice The hot-path gas measurement the dividends design hangs on.
///
/// Dividends buy their trustlessness with a per-account write on the transfer path, and the design
/// document is explicit that this is "the one number that could kill the design". So it is measured
/// here rather than modelled: two IDENTICAL tokens, one with a dividend allocation and one without,
/// and the same transfers run against both.
///
/// What matters is the DELTA, and that a token WITHOUT dividends pays nothing — the whole point of
/// putting `hasDividends` in the warm `pair` slot `_update` already loads.
contract DividendsGasTests is TaxTokenUniV4BaseTests {
    address internal holderA = makeAddr("gasHolderA");
    address internal holderB = makeAddr("gasHolderB");

    function _create(uint16 dividendsBps) internal returns (RealmTaxableTokenUniV4) {
        IRealmFactory.TokenSetupTiered memory setup = IRealmFactory.TokenSetupTiered({
            name: "GasTok",
            symbol: "GAS",
            salt: _nextValidSalt(address(factoryTax), address(realmTaxToken)),
            feeShares: _fs(creator),
            liquidityTier: LiquidityTier.DEFAULT
        });
        TaxConfigsWithAllocation memory cfg = TaxConfigsWithAllocation({
            buyTaxBps: 0,
            sellTaxBps: 400,
            taxDurationSeconds: uint32(14 days),
            startTaxFromLaunch: true,
            buyTaxDecayStartBps: 0,
            sellTaxDecayStartBps: 0,
            taxDecayDuration: 0,
            earningsAllocation: EarningsAllocationConfig({
                burnBps: 0, dividendsBps: dividendsBps, liquidityBps: 0, dividendToken: address(0)
            })
        });
        vm.prank(creator);
        address token = factoryTax.createToken(
            setup,
            cfg,
            RealmFactoryUniV4Unified.UniV4Configs({renounceOwnership: false, lpFeeBps: 100}),
            _noSs(),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            address(0)
        );
        testToken = token;
        _launchpadBuy(token, 2 ether);
        _graduateToken();

        // Route one lot of earnings through both tokens, identically, so both set-ups are symmetric
        // and the dividend token has a buffer big enough to fund a stream when a measurement wants one.
        vm.deal(address(this), 1 ether);
        RealmTaxableTokenUniV4(payable(token)).accrueFees{value: 1 ether}();
        return RealmTaxableTokenUniV4(payable(token));
    }

    receive() external payable {}

    /// @dev Three wallet-to-wallet transfers, chosen to isolate the three cases the accumulator design
    ///      cares about: the ONE-OFF first-ever touch of an account slot, a steady-state transfer while
    ///      the stream is running, and a second transfer in the SAME block, where the accumulator cannot
    ///      have moved and nothing is written.
    /// @param streaming whether to fund a live stream first. IDLE is the common case by a wide margin —
    ///        a 15-minute drip fires only after a distribution — and it is the case where the feature
    ///        costs almost nothing, because `lastDividendUpdate == dividendPeriodFinish` short-circuits
    ///        the whole hook on one warm SLOAD.
    function _measure(RealmTaxableTokenUniV4 token, bool streaming)
        internal
        returns (uint256 firstEver, uint256 warm, uint256 sameBlock)
    {
        IERC20 erc = IERC20(address(token));
        uint256 unit = erc.balanceOf(buyer) / 100;

        if (streaming && token.hasDividends()) token.processDividends(0, new address[](0));

        // 1. Both account slots are zero, so both pay the zero->non-zero SSTORE if the accumulator has
        //    moved. Once per account per token, forever — not a recurring cost.
        skip(1);
        vm.startPrank(buyer);
        uint256 g = gasleft();
        erc.transfer(holderA, unit);
        firstEver = g - gasleft();

        // 2. Steady state: both slots are warm and non-zero, and a second of the stream has elapsed.
        skip(1);
        g = gasleft();
        erc.transfer(holderA, unit);
        warm = g - gasleft();

        // 3. Same block as the transfer above: the accumulator cannot have advanced, so every account
        //    is already checkpointed at the current value and nothing is written at all.
        g = gasleft();
        erc.transfer(holderA, unit);
        sameBlock = g - gasleft();
        vm.stopPrank();
    }

    function test_gas_hotPathOverheadOfDividends() public {
        RealmTaxableTokenUniV4 plainIdle = _create(0);
        (uint256 pFirst, uint256 pWarm, uint256 pSame) = _measure(plainIdle, false);

        RealmTaxableTokenUniV4 divIdle = _create(5_000);
        (uint256 iFirst, uint256 iWarm, uint256 iSame) = _measure(divIdle, false);

        RealmTaxableTokenUniV4 divLive = _create(5_000);
        (uint256 sFirst, uint256 sWarm, uint256 sSame) = _measure(divLive, true);

        console.log("--- wallet-to-wallet transfer, execution gas ---");
        console.log("no dividends       : firstEver / warm / sameBlock", pFirst, pWarm, pSame);
        console.log("dividends, idle    : firstEver / warm / sameBlock", iFirst, iWarm, iSame);
        console.log("dividends, streaming: firstEver / warm / sameBlock", sFirst, sWarm, sSame);

        // A token WITHOUT dividends must stay in its old envelope: the gate is a bit in the `pair`
        // slot `_update` already loads, so the only cost is a JUMP into an empty virtual hook.
        assertLt(pFirst, 60_000, "a non-dividend token's transfer must not have regressed");

        // IDLE — the case that dominates. Between streams the accumulator cannot move, so the hook
        // short-circuits on the global slot and writes nothing, ever.
        assertLt(iFirst - pFirst, 6_000, "an idle dividend token barely costs anything");
        assertLt(iWarm - pWarm, 4_000, "and keeps costing barely anything on every later transfer");

        // STREAMING, ONE-OFF. Two accounts each paying a zero->non-zero SSTORE the first time they are
        // ever settled, plus the global slot and the eligible-supply reads.
        assertLt(sFirst - pFirst, 60_000, "first-ever settle of two account slots mid-stream");

        // STREAMING, STEADY STATE: warm account slots plus the global one.
        assertLt(sWarm - pWarm, 12_000, "a steady-state transfer while the stream is running");

        // STREAMING, SAME BLOCK: the accumulator cannot have advanced, so `paid == rpt` on both sides
        // and the hook falls through without a single write.
        assertLt(sSame - pSame, 4_000, "a same-block repeat writes nothing");
    }

    /// @dev The numbers above are deltas on `_update` alone. What a USER pays is the whole
    ///      transaction, so the percentages that matter are measured against that: a V4 pool swap and a
    ///      plain wallet-to-wallet transfer, both including the 21k intrinsic cost, and both in steady
    ///      state (every account slot already touched once).
    function test_gas_wholeOperationOverhead() public {
        RealmTaxableTokenUniV4 plain = _create(0);
        (uint256 pTransfer, uint256 pBuy, uint256 pSell) = _measureOperations(plain);

        RealmTaxableTokenUniV4 div = _create(5_000);
        (uint256 dTransfer, uint256 dBuy, uint256 dSell) = _measureOperations(div);

        console.log("--- whole user operation, incl. 21k intrinsic, steady state ---");
        console.log("transfer  no-div / div / +bps", pTransfer, dTransfer, _bps(pTransfer, dTransfer));
        console.log("V4 buy    no-div / div / +bps", pBuy, dBuy, _bps(pBuy, dBuy));
        console.log("V4 sell   no-div / div / +bps", pSell, dSell, _bps(pSell, dSell));

        // A pool trade is the operation that competes with other launchpads on gas. Only ONE side of
        // it is ever settled — the `pair` is excluded — so the overhead lands on a single account slot
        // plus the shared accumulator slot.
        assertLt(_bps(pBuy, dBuy), 1_000, "a V4 buy must stay under +10%");
        assertLt(_bps(pSell, dSell), 1_000, "a V4 sell must stay under +10%");
        // A bare transfer has no pool cost to amortise against, so the same absolute overhead is a much
        // larger fraction of it. Still bounded, and only while a stream is actually running.
        assertLt(_bps(pTransfer, dTransfer), 4_000, "a wallet-to-wallet transfer must stay under +40%");
    }

    /// @dev Steady-state cost of the three operations a user actually performs, each measured as a
    ///      whole transaction (21k intrinsic included).
    /// @dev Measured with a LIVE STREAM and a second of elapsed time before each measured call, i.e.
    ///      the worst case rather than the common one: between distributions the accumulator cannot
    ///      move and the hook writes nothing at all.
    function _measureOperations(RealmTaxableTokenUniV4 token)
        internal
        returns (uint256 transferGas, uint256 buyGas, uint256 sellGas)
    {
        IERC20 erc = IERC20(address(token));
        testToken = address(token);
        uint256 unit = erc.balanceOf(buyer) / 1000;

        if (token.hasDividends()) token.processDividends(0, new address[](0));

        // Warm every account slot first, so what is left is the recurring cost rather than the
        // one-off zero->non-zero write. The `skip` before the warm-up matters: with the accumulator
        // unmoved the hook writes nothing, so a same-block warm-up would not warm the account slots at
        // all and every "steady state" number below would really be a first-touch one.
        skip(1);
        vm.startPrank(buyer);
        erc.transfer(holderA, unit);
        erc.transfer(holderA, unit);
        skip(1);
        uint256 g = gasleft();
        erc.transfer(holderA, unit);
        transferGas = g - gasleft() + 21_000;
        vm.stopPrank();

        vm.deal(holderB, 1 ether);
        _swapBuy(holderB, 0.01 ether, 0, true); // warm holderB's slot
        skip(1);
        _swapBuy(holderB, 0.01 ether, 0, true); // and settle it once the accumulator has moved
        skip(1);
        g = gasleft();
        _swapBuy(holderB, 0.01 ether, 0, true);
        buyGas = g - gasleft() + 21_000;

        uint256 sellAmount = erc.balanceOf(holderB) / 8;
        _swapSell(holderB, sellAmount, 0, true); // warm the sell path
        skip(1);
        _swapSell(holderB, sellAmount, 0, true); // and settle it once the accumulator has moved
        skip(1);
        g = gasleft();
        _swapSell(holderB, sellAmount, 0, true);
        sellGas = g - gasleft() + 21_000;
    }

    /// @dev Overhead of `withDiv` over `baseline`, in basis points.
    function _bps(uint256 baseline, uint256 withDiv) internal pure returns (uint256) {
        if (baseline == 0 || withDiv <= baseline) return 0;
        return ((withDiv - baseline) * 10_000) / baseline;
    }

    ///////////////////////// several payout assets /////////////////////////

    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @dev The same token as `_create`, paying in a SET of assets. Everything else is identical, so the
    ///      only difference between the measurements is how many assets the transfer hook settles.
    function _createMulti(address[] memory assets, uint16[] memory weights) internal returns (RealmTaxableTokenUniV4) {
        IRealmFactory.TokenSetupTiered memory setup = IRealmFactory.TokenSetupTiered({
            name: "GasTok",
            symbol: "GAS",
            salt: _nextValidSalt(address(factoryTax), address(realmTaxToken)),
            feeShares: _fs(creator),
            liquidityTier: LiquidityTier.DEFAULT
        });
        TaxConfigsWithMultiAllocation memory cfg = TaxConfigsWithMultiAllocation({
            buyTaxBps: 0,
            sellTaxBps: 400,
            taxDurationSeconds: uint32(14 days),
            startTaxFromLaunch: true,
            buyTaxDecayStartBps: 0,
            sellTaxDecayStartBps: 0,
            taxDecayDuration: 0,
            earningsAllocation: EarningsAllocationMultiConfig({
                burnBps: 0,
                dividendsBps: 5_000,
                liquidityBps: 0,
                dividendTokens: assets,
                dividendWeightsBps: weights,
                dividendRoutes: new bytes[](0)
            })
        });
        vm.prank(creator);
        address token = factoryTax.createToken(
            setup,
            cfg,
            RealmFactoryUniV4Unified.UniV4Configs({renounceOwnership: false, lpFeeBps: 100}),
            _noSs(),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            address(0)
        );
        testToken = token;
        _launchpadBuy(token, 2 ether);
        _graduateToken();
        vm.deal(address(this), 3 ether);
        RealmTaxableTokenUniV4(payable(token)).accrueFees{value: 3 ether}();
        return RealmTaxableTokenUniV4(payable(token));
    }

    /// @dev Puts EVERY configured asset into a live stream, so the measurement below is the worst case:
    ///      every leg has to be settled on every transfer.
    function _fundEveryAsset(RealmTaxableTokenUniV4 token) internal {
        uint256 n = token.dividendAssetCount();
        for (uint256 i; i < n; ++i) {
            token.processDividends(uint8(i), 0, new address[](0));
        }
    }

    /// @dev Steady-state transfer cost as the payout set grows. This is the number the deployer has to
    ///      be shown: every extra payout asset is another per-account slot settled on both sides of every
    ///      transfer while that asset's stream is running — and with staggered thresholds, something is
    ///      almost always running.
    function test_gas_perExtraDividendAsset() public {
        address[] memory one = new address[](1);
        one[0] = address(0);
        uint16[] memory w1 = new uint16[](1);
        w1[0] = 10_000;

        address[] memory two = new address[](2);
        two[0] = address(0);
        two[1] = DAI;
        uint16[] memory w2 = new uint16[](2);
        w2[0] = 5_000;
        w2[1] = 5_000;

        address[] memory three = new address[](3);
        three[0] = address(0);
        three[1] = DAI;
        three[2] = USDC;
        uint16[] memory w3 = new uint16[](3);
        w3[0] = 4_000;
        w3[1] = 3_000;
        w3[2] = 3_000;

        uint256 g1 = _measureMulti(_createMulti(one, w1));
        uint256 g2 = _measureMulti(_createMulti(two, w2));
        uint256 g3 = _measureMulti(_createMulti(three, w3));

        console.log("--- steady-state transfer, all streams live, execution gas ---");
        console.log("1 asset / 2 assets / 3 assets", g1, g2, g3);
        console.log("marginal per extra asset: 2nd / 3rd", g2 - g1, g3 - g2);

        assertGt(g2, g1, "a second payout asset costs something");
        assertLt(g3 - g2, 40_000, "and the third costs about the same as the second, not more");
    }

    /// @dev One steady-state transfer with every stream running and every account slot already warm.
    function _measureMulti(RealmTaxableTokenUniV4 token) internal returns (uint256 used) {
        IERC20 erc = IERC20(address(token));
        _fundEveryAsset(token);

        uint256 unit = erc.balanceOf(buyer) / 1000;
        skip(1);
        vm.startPrank(buyer);
        erc.transfer(holderA, unit); // warm both account slots for every asset
        skip(1);
        uint256 g = gasleft();
        erc.transfer(holderA, unit);
        used = g - gasleft();
        vm.stopPrank();
    }

    /// @dev The gate has to be free, not merely cheap: every non-dividend Realm token pays it forever.
    function test_gas_nonDividendTokenPaysNothingMeasurable() public {
        RealmTaxableTokenUniV4 plain = _create(0);
        IERC20 erc = IERC20(address(plain));
        uint256 unit = erc.balanceOf(buyer) / 100;

        vm.startPrank(buyer);
        erc.transfer(holderA, unit); // warm everything
        uint256 g = gasleft();
        erc.transfer(holderA, unit);
        uint256 used = g - gasleft();
        vm.stopPrank();

        console.log("non-dividend warm transfer gas", used);
        assertLt(used, 40_000, "warm transfer on a non-dividend token");
    }
}
