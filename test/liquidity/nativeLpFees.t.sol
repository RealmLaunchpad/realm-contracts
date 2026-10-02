// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {TaxTokenUniV4BaseTests} from "test/graduators/taxToken.base.t.sol";
import {QuoteCoin} from "test/graduators/directLaunchQuotes.t.sol";
import {RealmTaxableTokenUniV4} from "src/tokens/RealmTaxableTokenUniV4.sol";
import {RealmTaxableToken} from "src/tokens/RealmTaxableToken.sol";
import {RealmSwapHook} from "src/hooks/RealmSwapHook.sol";
import {RealmSwapper} from "src/swapper/RealmSwapper.sol";
import {SwapLpFeeRouter} from "src/feeRouters/SwapLpFeeRouter.sol";
import {RealmLpLocker} from "src/liquidity/RealmLpLocker.sol";
import {RealmFactoryUniV4Direct} from "src/factories/RealmFactoryUniV4Direct.sol";
import {IRealmLpLocker} from "src/interfaces/IRealmLpLocker.sol";
import {ISwapLpFeeRouterTokenFees} from "src/interfaces/ISwapLpFeeRouterTokenFees.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {IRealmClaims} from "src/interfaces/IRealmClaims.sol";
import {IRealmMasterFeeHandler} from "src/interfaces/IRealmMasterFeeHandler.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {TaxConfigsWithMultiAllocation} from "src/interfaces/IRealmTaxableToken.sol";
import {IRealmUniV4LiquidityAdder} from "src/liquidity/RealmUniV4LiquidityAdder.sol";
import {UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {PoolKey as CorePoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo, PositionInfoLibrary} from "lib/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {IPermit2} from "lib/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {IUniversalRouter, IV4RouterSwaps} from "src/interfaces/IUniswapV4UniversalRouter.sol";

/// @notice Poses as a Realm token to reach the locker: it names another token's wall as its candidate.
contract FakeWallToken {
    uint256 internal immutable VICTIM_WALL;

    constructor(uint256 victimWall) {
        VICTIM_WALL = victimWall;
    }

    function poolFee() external pure returns (uint24) {
        return 10_000;
    }

    function getLiquidityWalls(address) external view returns (uint256[2] memory ids, int24[2] memory lowers) {
        ids[0] = VICTIM_WALL;
        lowers;
    }

    function attack(RealmLpLocker locker) external payable {
        locker.addWall{value: msg.value}(address(0), msg.value);
    }
}

/// @notice The native-pool-fee design end to end: the pool charges the LP fee, the hook only the tax; the
///         locker collects the protocol positions' fees and routes them 30/70; token-side fees wait in the
///         router until a keeper converts them; walls are collected before a top-up.
contract NativeLpFeesTests is TaxTokenUniV4BaseTests {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using PositionInfoLibrary for PositionInfo;

    QuoteCoin internal qc;

    function setUp() public override {
        super.setUp();
        // These tests drive collection and conversion themselves.
        manualLpFees = true;
        qc = new QuoteCoin();
        _whitelist(address(qc), 3_500e18);
    }

    /////////////////////////// MODIFIERS ///////////////////////////

    modifier plainToken() {
        testToken = _createDirectToken(_emptyTaxCfg());
        _;
    }

    modifier taxedToken(uint16 buyBps, uint16 sellBps) {
        testToken = _createTaxToken(buyBps, sellBps, DEFAULT_TAX_DURATION);
        _;
    }

    modifier liquidityToken() {
        testToken = _createLiquidityToken();
        _;
    }

    modifier qcToken() {
        vm.prank(creator);
        testToken = directFactory.createToken(
            _directSetup("QcToken", "QCT", false),
            _qcPair(),
            _noDirectAlloc(_emptyTaxCfg()),
            _emptyAntiSniperCfg(),
            _noVaults(),
            _noDevBuy(),
            address(0)
        );
        _;
    }

    modifier buy(uint256 ethIn) {
        vm.deal(buyer, ethIn);
        _swap(buyer, testToken, ethIn, 0, true, true);
        _;
    }

    modifier sell(uint256 tokensIn) {
        _swap(buyer, testToken, tokensIn, 0, false, true);
        _;
    }

    modifier collect() {
        _collect(testToken);
        _;
    }

    /////////////////////////// HELPERS ///////////////////////////

    function _qcPair() internal view returns (RealmFactoryUniV4Direct.DirectPair[] memory p) {
        p = new RealmFactoryUniV4Direct.DirectPair[](1);
        p[0] = RealmFactoryUniV4Direct.DirectPair({quote: address(qc), weightBps: 10_000});
    }

    function _createLiquidityToken() internal returns (address) {
        IRealmFactory.TokenSetupTiered memory setup = IRealmFactory.TokenSetupTiered({
            name: "LiqToken",
            symbol: "LIQ",
            salt: _nextValidSalt(address(directFactory), address(realmTaxToken)),
            feeShares: _fs(creator),
            liquidityTier: LiquidityTier.DEFAULT
        });
        TaxConfigsWithMultiAllocation memory cfg = TaxConfigsWithMultiAllocation({
            buyTaxBps: 400,
            sellTaxBps: 400,
            taxDurationSeconds: uint32(14 days),
            startTaxFromLaunch: true,
            buyTaxDecayStartBps: 0,
            sellTaxDecayStartBps: 0,
            taxDecayDuration: 0,
            earningsAllocation: _multiAlloc(0, 0, 5000, address(0))
        });
        return _createDirect(setup, cfg, _emptyAntiSniperCfg(), _noVaults());
    }

    function _collect(address token) internal {
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        lpLocker.collect(tokens);
    }

    function _nativeClaimable(address token, address account) internal view returns (uint256) {
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        return IRealmClaims(IRealmToken(token).feeHandler()).getClaimable(tokens, account)[0];
    }

    function _pending(address token) internal view returns (uint256 quoteSide, uint256 tokenSide) {
        (, uint256[] memory q, uint256[] memory t) = lpLocker.pendingFees(token);
        return (q[0], t[0]);
    }

    function _nativeKey(address token) internal view returns (CorePoolKey memory) {
        return UniswapV4PoolConstants.realmPoolKey(token, address(taxHook), _poolFee(token));
    }

    function _tick(address token) internal view returns (int24 tick) {
        PoolKey memory key = abi.decode(abi.encode(_nativeKey(token)), (PoolKey));
        (, tick,,) = IPoolManager(poolManagerAddress).getSlot0(key.toId());
    }

    /// @dev Uncollected fees of position `id`, recomputed here from v4-core's counters.
    function _owed(uint256 id) internal view returns (uint256 owed0, uint256 owed1) {
        (PoolKey memory key, PositionInfo info) = IPositionManager(positionManagerAddress).getPoolAndPositionInfo(id);
        PoolId poolId = key.toId();
        IPoolManager pm = IPoolManager(poolManagerAddress);
        (uint128 liq, uint256 last0, uint256 last1) =
            pm.getPositionInfo(poolId, positionManagerAddress, info.tickLower(), info.tickUpper(), bytes32(id));
        (uint256 in0, uint256 in1) = pm.getFeeGrowthInside(poolId, info.tickLower(), info.tickUpper());
        unchecked {
            owed0 = FullMath.mulDiv(in0 - last0, liq, FixedPoint128.Q128);
            owed1 = FullMath.mulDiv(in1 - last1, liq, FixedPoint128.Q128);
        }
    }

    /// @dev An exact-input swap on the token's ERC20 (`qc`) pool, with no fee settlement after it.
    function _swapQc(address caller, bool isBuy, uint256 amountIn) internal {
        CorePoolKey memory coreKey =
            UniswapV4PoolConstants.realmPoolKey(testToken, address(qc), address(anyPairHook), _poolFee(testToken));
        PoolKey memory key = abi.decode(abi.encode(coreKey), (PoolKey));
        bool quoteIsC0 = address(qc) < testToken;
        address tokenIn = isBuy ? address(qc) : testToken;
        bool inIsC0 = isBuy ? quoteIsC0 : !quoteIsC0;

        vm.startPrank(caller);
        IERC20(tokenIn).approve(permit2Address, type(uint256).max);
        IPermit2(permit2Address).approve(tokenIn, universalRouter, type(uint160).max, type(uint48).max);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4RouterSwaps.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: inIsC0,
                amountIn: uint128(amountIn),
                amountOutMinimum: 0,
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(inIsC0 ? key.currency0 : key.currency1, amountIn);
        params[2] = abi.encode(inIsC0 ? key.currency1 : key.currency0, uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)),
            params
        );
        IUniversalRouter(universalRouter).execute(abi.encodePacked(uint8(0x10)), inputs, block.timestamp);
        vm.stopPrank();
    }

    /// @dev Index of the first log matching `emitter` and `topic0`, or `type(uint256).max`.
    function _indexOf(Vm.Log[] memory logs, address emitter, bytes32 topic0) internal pure returns (uint256) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics[0] == topic0) return i;
        }
        return type(uint256).max;
    }

    /////////////////////////// NO DOUBLE CHARGE ///////////////////////////

    /// @dev when a taxed token is bought, then the hook takes only the tax and the pool takes its fee
    ///      tier on the rest, which the locker can collect
    function test_buy_assertTraderPaysPoolFeePlusTaxOnly() public taxedToken(300, 400) {
        assertEq(IRealmToken(testToken).getSwapFees(true).lpFeeBps, 0, "no hook-charged LP fee on buys");
        assertEq(IRealmToken(testToken).getSwapFees(false).lpFeeBps, 0, "nor on sells");
        assertEq(_poolFee(testToken), 10_000, "the 100-bps tier is a 1% pool");

        vm.deal(buyer, 1 ether);
        vm.recordLogs();
        _swap(buyer, testToken, 1 ether, 0, true, true);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _indexOf(logs, address(taxHook), RealmSwapHook.LpFeesForwarded.selector),
            type(uint256).max,
            "the hook forwards no LP fee"
        );
        uint256 tax = abi.decode(
            _firstLogData(
                logs, address(taxHook), RealmSwapHook.CreatorTaxesAccrued.selector, bytes32(uint256(uint160(testToken)))
            ),
            (uint256)
        );
        assertEq(tax, 1 ether * 300 / 10_000, "the hook takes the 3% tax");
        (uint256 quoteFee,) = _pending(testToken);
        assertApproxEqAbs(quoteFee, (1 ether - tax) / 100, 2, "the pool takes 1% of the rest, once");
    }

    /// @dev when a third party provides liquidity in range and a buy crosses it, then it earns the pool fee
    function test_thirdPartyLp_assertEarnsPoolFees() public plainToken buy(1 ether) {
        // Alice turns her bag into a token-only band just under the price, where the next buy walks.
        uint256 bag = IERC20(testToken).balanceOf(buyer) / 2;
        vm.prank(buyer);
        IERC20(testToken).transfer(alice, bag);
        int24 upper = (_tick(testToken) / 200) * 200 - (_tick(testToken) < 0 ? int24(200) : int24(0));
        CorePoolKey memory key = _nativeKey(testToken);
        uint256 id = IPositionManager(positionManagerAddress).nextTokenId();
        vm.startPrank(alice);
        IERC20(testToken).approve(univ4LiquidityAdder, bag);
        IRealmUniV4LiquidityAdder(univ4LiquidityAdder)
            .addSingleSided(key, key.currency1, bag, upper - 4_000, upper, alice, alice);
        vm.stopPrank();
        assertEq(IERC721(positionManagerAddress).ownerOf(id), alice, "alice owns her position");

        vm.deal(buyer, 3 ether);
        _swap(buyer, testToken, 3 ether, 0, true, true);

        (uint256 owedEth,) = _owed(id);
        assertGt(owedEth, 0, "alice's position earned the pool fee in ETH");

        // She collects it herself, like any LP.
        uint256 before = alice.balance;
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(id, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, alice);
        vm.prank(alice);
        IPositionManager(positionManagerAddress)
            .modifyLiquidities(
                abi.encode(abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR)), params),
                block.timestamp
            );
        assertEq(alice.balance - before, owedEth, "and collects exactly what she earned");
    }

    /////////////////////////// LOCKER COLLECT ///////////////////////////

    /// @dev when the locker collects a native pool's fees, then they are split 30/70 treasury/creator on the spot
    function test_collect_nativeQuote_assertSplits30_70() public plainToken buy(2 ether) {
        (uint256 quoteFee, uint256 tokenFee) = _pending(testToken);
        assertGt(quoteFee, 0, "precondition: ETH fees owed");
        assertEq(tokenFee, 0, "a buy pays no token-side fee");
        uint256 treasuryBefore = treasury.balance;
        uint256 creatorBefore = _nativeClaimable(testToken, creator);

        vm.expectEmit(true, true, false, true, address(lpLocker));
        emit IRealmLpLocker.LpFeesCollected(testToken, address(0), quoteFee, 0);
        _collect(testToken);

        uint256 treasuryShare = quoteFee * 3_000 / 10_000;
        assertEq(treasury.balance - treasuryBefore, treasuryShare, "30% to the treasury");
        assertEq(_nativeClaimable(testToken, creator) - creatorBefore, quoteFee - treasuryShare, "70% to the creator");
        (quoteFee,) = _pending(testToken);
        assertEq(quoteFee, 0, "nothing left to collect");
        assertEq(address(lpLocker).balance, 0, "and the locker keeps nothing");
    }

    /// @dev when the locker collects an ERC20 pool's fees, then they are split 30/70 in that quote
    function test_collect_erc20Quote_assertSplits30_70() public qcToken {
        qc.mintTo(buyer, 1_000e6);
        _swapQc(buyer, true, 1_000e6);
        (uint256 quoteFee,) = _pending(testToken);
        assertApproxEqAbs(quoteFee, 10e6, 1, "the 1% pool fee, in the quote");

        address[] memory tokens = new address[](1);
        tokens[0] = testToken;
        uint256 treasuryBefore = qc.balanceOf(treasury);
        uint256 creatorBefore = feeHandler.getClaimable(tokens, address(qc), creator)[0];
        _collect(testToken);

        uint256 treasuryShare = quoteFee * 3_000 / 10_000;
        assertEq(qc.balanceOf(treasury) - treasuryBefore, treasuryShare, "30% to the treasury, in the quote");
        assertEq(
            feeHandler.getClaimable(tokens, address(qc), creator)[0] - creatorBefore,
            quoteFee - treasuryShare,
            "70% to the creator, in the quote"
        );
        assertEq(qc.balanceOf(address(lpLocker)), 0, "and the locker keeps nothing");
    }

    /// @dev when fees accrued on both sides, then `pendingFees` equals exactly what `collect` takes
    function test_pendingFees_assertMatchesCollect() public plainToken buy(2 ether) {
        _swap(buyer, testToken, IERC20(testToken).balanceOf(buyer) / 3, 0, false, true);
        (address[] memory quotes, uint256[] memory q, uint256[] memory t) = lpLocker.pendingFees(testToken);
        assertEq(quotes.length, 1, "one entry per pool");
        assertEq(quotes[0], address(0), "the native pool");
        assertGt(q[0], 0, "ETH side owed");
        assertGt(t[0], 0, "token side owed");

        vm.recordLogs();
        _collect(testToken);
        (uint256 quoteAmount, uint256 tokenAmount) = abi.decode(
            _firstLogData(
                vm.getRecordedLogs(),
                address(lpLocker),
                IRealmLpLocker.LpFeesCollected.selector,
                bytes32(uint256(uint160(testToken)))
            ),
            (uint256, uint256)
        );
        assertEq(quoteAmount, q[0], "quote side exact");
        assertEq(tokenAmount, t[0], "token side exact");
    }

    /////////////////////////// TOKEN-SIDE FEES ///////////////////////////

    /// @dev when a sell's fee is collected, then the token side waits in the router until a keeper converts
    ///      it, emitting `LpTokenFeesConverted` before the routing event
    function test_sellFees_assertPendingThenKeeperConverts() public plainToken buy(2 ether) {
        _swap(buyer, testToken, IERC20(testToken).balanceOf(buyer) / 3, 0, false, true);
        (, uint256 tokenFee) = _pending(testToken);
        _collect(testToken);
        assertEq(lpFeeRouter.pendingTokenFees(testToken, address(0)), tokenFee, "parked in the router");
        assertEq(IERC20(testToken).balanceOf(address(lpLocker)), 0, "not in the locker");

        vm.prank(alice);
        vm.expectRevert(SwapLpFeeRouter.NotAKeeper.selector);
        lpFeeRouter.convertTokenFees(testToken, address(0), 0);

        uint256 treasuryBefore = treasury.balance;
        vm.recordLogs();
        uint256 out = lpFeeRouter.convertTokenFees(testToken, address(0), 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(lpFeeRouter.pendingTokenFees(testToken, address(0)), 0, "bucket drained");
        assertEq(treasury.balance - treasuryBefore, out * 3_000 / 10_000, "proceeds split 30/70");
        uint256 converted =
            _indexOf(logs, address(lpFeeRouter), ISwapLpFeeRouterTokenFees.LpTokenFeesConverted.selector);
        uint256 routed = _indexOf(logs, address(lpFeeRouter), SwapLpFeeRouter.LpFeesRouted.selector);
        assertLt(converted, routed, "LpTokenFeesConverted precedes LpFeesRouted");
        (uint256 tokenIn, uint256 quoteOut) = abi.decode(logs[converted].data, (uint256, uint256));
        assertEq(tokenIn, tokenFee, "sold the whole bucket");
        assertEq(quoteOut, out, "for what the router split");
    }

    /// @dev when a keeper burns the pending token-side fees instead of converting them, then they leave the
    ///      supply and no quote is split
    function test_sellFees_assertKeeperBurnsPending() public plainToken buy(2 ether) {
        _swap(buyer, testToken, IERC20(testToken).balanceOf(buyer) / 3, 0, false, true);
        (, uint256 tokenFee) = _pending(testToken);
        _collect(testToken);

        vm.prank(alice);
        vm.expectRevert(SwapLpFeeRouter.NotAKeeper.selector);
        lpFeeRouter.burnTokenFees(testToken, address(0));

        uint256 supplyBefore = IERC20(testToken).totalSupply();
        uint256 treasuryBefore = treasury.balance;
        assertEq(lpFeeRouter.burnTokenFees(testToken, address(0)), tokenFee, "burned the whole bucket");

        assertEq(lpFeeRouter.pendingTokenFees(testToken, address(0)), 0, "bucket drained");
        assertEq(IERC20(testToken).balanceOf(address(lpFeeRouter)), 0, "nothing left in the router");
        assertEq(supplyBefore - IERC20(testToken).totalSupply(), tokenFee, "supply reduced");
        assertEq(treasury.balance, treasuryBefore, "nothing split");

        vm.expectRevert(SwapLpFeeRouter.NothingToConvert.selector);
        lpFeeRouter.burnTokenFees(testToken, address(0));
    }

    /// @dev A plain direct token with the tightest caps (0.1% per tx and per wallet) for an hour; `alice`
    ///      is whitelisted so she can trade enough to make the fees outgrow the caps.
    /////////////////////////// SNIPER WINDOW ///////////////////////////

    modifier sniperCappedToken() {
        address[] memory whitelist = new address[](1);
        whitelist[0] = alice;
        vm.prank(creator);
        testToken = directFactory.createToken(
            _directSetup("CapToken", "CAP", false),
            _nativePair(),
            _noDirectAlloc(_emptyTaxCfg()),
            _antiSniperCfg(10, 10, 1 hours, whitelist),
            _noVaults(),
            _noDevBuy(),
            address(0)
        );
        _;
    }

    /// @dev when, inside the sniper window, collected token-side fees exceed both caps, then the pool ->
    ///      locker hop (read as a buy) and the locker -> router deposit are not capped
    function test_collect_inSniperWindow_assertTokenFeesAboveCapsDoNotRevert() public sniperCappedToken {
        uint256 cap = 1_000_000_000e18 * 10 / 10_000;
        vm.deal(alice, 50 ether);
        _swap(alice, testToken, 50 ether, 0, true, true);
        _swap(alice, testToken, IERC20(testToken).balanceOf(alice), 0, false, true);
        (, uint256 tokenFee) = _pending(testToken);
        assertGt(tokenFee, cap, "the token side alone exceeds the per-tx and per-wallet caps");

        _collect(testToken);
        assertEq(lpFeeRouter.pendingTokenFees(testToken, address(0)), tokenFee, "all of it parked in the router");
        assertGt(IERC20(testToken).balanceOf(address(lpFeeRouter)), cap, "the router holds more than the wallet cap");

        // router -> swapper hands over the whole bucket, also above the wallet cap
        assertGt(lpFeeRouter.convertTokenFees(testToken, address(0), 1), 0, "the bucket converts inside the window");
    }

    /// @dev when the swapper sells a Realm token, then `RealmTokenSellInitiated` precedes the hook's sell event
    function test_sellToken_assertPrecursorEventBeforeHookSell() public plainToken buy(1 ether) {
        uint256 amount = IERC20(testToken).balanceOf(buyer) / 4;
        vm.startPrank(buyer);
        IERC20(testToken).approve(address(realmSwapper), amount);
        vm.recordLogs();
        uint256 out = realmSwapper.sellToken(testToken, address(0), amount, 1, buyer);
        vm.stopPrank();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 initiated = _indexOf(logs, address(realmSwapper), RealmSwapper.RealmTokenSellInitiated.selector);
        uint256 hookSell = _indexOf(logs, address(taxHook), RealmSwapHook.RealmSwapSell.selector);
        assertLt(initiated, hookSell, "the precursor comes first");
        assertLt(hookSell, type(uint256).max, "and the hook's sell follows");
        assertEq(abi.decode(logs[initiated].data, (uint256)), amount, "the precursor carries the amount being sold");
        assertGt(out, 0, "the seller got paid");
    }

    /////////////////////////// WALLS ///////////////////////////

    /// @dev when a remembered wall has accrued fees and is topped up, then its fees are collected first and
    ///      only principal comes back as the refund
    function test_addWall_topUp_assertCollectsFeesFirstAndRefundsPrincipal() public liquidityToken buy(3 ether) {
        RealmTaxableTokenUniV4 token = RealmTaxableTokenUniV4(payable(testToken));
        _swap(buyer, testToken, IERC20(testToken).balanceOf(buyer) / 4, 0, false, true);
        vm.roll(block.number + 1);
        token.processLiquidity();
        (uint256[2] memory ids, int24[2] memory lowers) = token.getLiquidityWalls();
        assertGt(ids[0], 0, "precondition: a wall");

        // Trade through the wall and back above it, so it earns on both sides and is reusable again.
        uint256 ethBefore = buyer.balance;
        _swap(buyer, testToken, IERC20(testToken).balanceOf(buyer) / 10, 0, false, true);
        _swap(buyer, testToken, (buyer.balance - ethBefore) * 3 / 2, 0, true, true);
        int24 gap = lowers[0] - _tick(testToken);
        assertTrue(gap > 0 && gap <= 2_000, "precondition: the wall is above the price, within the reuse gap");
        (uint256 owedEth, uint256 owedToken) = _owed(ids[0]);
        assertGt(owedEth, 1e12, "precondition: the wall owes ETH fees");
        assertGt(owedToken, 0, "and token fees");

        vm.roll(block.number + 1);
        uint256 amountIn = token.liquidityPendingEth();
        if (amountIn > 1 ether) amountIn = 1 ether;
        uint128 liquidityBefore = IPositionManager(positionManagerAddress).getPositionLiquidity(ids[0]);
        vm.recordLogs();
        token.processLiquidity();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint256[2] memory idsAfter,) = token.getLiquidityWalls();
        assertEq(idsAfter[0], ids[0], "precondition: the top-up path");
        assertGt(IPositionManager(positionManagerAddress).getPositionLiquidity(ids[0]), liquidityBefore, "topped up");
        (uint256 collectedEth, uint256 collectedToken) = abi.decode(
            _firstLogData(
                logs, address(lpLocker), IRealmLpLocker.LpFeesCollected.selector, bytes32(uint256(uint160(testToken)))
            ),
            (uint256, uint256)
        );
        assertEq(collectedEth, owedEth, "the wall's ETH fees were collected first");
        assertEq(collectedToken, owedToken, "and its token fees");
        (owedEth, owedToken) = _owed(ids[0]);
        assertEq(owedEth + owedToken, 0, "nothing left owed on the wall");

        (uint256 added,,) = abi.decode(
            _firstLogData(logs, testToken, RealmTaxableToken.LiquidityAdded.selector, bytes32(0)),
            (uint256, uint256, uint256)
        );
        // Fees mixed into the refund would understate `added` by at least `collectedEth`.
        assertLe(amountIn - added, 1e9, "the pool took the principal, only rounding came back");
        assertEq(address(lpLocker).balance, 0, "the locker keeps no ETH");
        assertEq(IERC20(testToken).balanceOf(address(lpLocker)), 0, "nor tokens");
    }

    /// @dev when a contract posing as a token names another token's wall, then it cannot touch that wall
    function test_addWall_fromNonToken_assertCannotTouchOthersPositions() public liquidityToken buy(3 ether) {
        RealmTaxableTokenUniV4 token = RealmTaxableTokenUniV4(payable(testToken));
        _swap(buyer, testToken, IERC20(testToken).balanceOf(buyer) / 4, 0, false, true);
        vm.roll(block.number + 1);
        token.processLiquidity();
        (uint256[2] memory ids,) = token.getLiquidityWalls();
        uint128 liquidityBefore = IPositionManager(positionManagerAddress).getPositionLiquidity(ids[0]);

        FakeWallToken fake = new FakeWallToken(ids[0]);
        vm.deal(address(fake), 1 ether);
        // Its candidate is dropped (not its wall) and its own "pool" does not exist: nothing to mint into.
        vm.expectRevert();
        fake.attack{value: 1 ether}(lpLocker);

        assertEq(
            IPositionManager(positionManagerAddress).getPositionLiquidity(ids[0]), liquidityBefore, "victim untouched"
        );
        (address owner,,) = lpLocker.positionMeta(ids[0]);
        assertEq(owner, testToken, "still the victim's wall");
        assertEq(lpLocker.positionIds(address(fake)).length, 0, "and nothing registered for the fake");
    }

    /// @dev when anyone but the graduator registers a seed, then it reverts
    function test_registerSeed_fromNonGraduator_assertReverts() public plainToken {
        uint256 seed = lpLocker.positionIds(testToken)[0];
        vm.expectRevert(RealmLpLocker.OnlyGraduator.selector);
        lpLocker.registerSeed(alice, seed);
    }

    /// @dev when collect is called for an address with no positions, then it does nothing
    function test_collect_unknownToken_assertNoop() public {
        _collect(makeAddr("nobody"));
        (address[] memory quotes,,) = lpLocker.pendingFees(makeAddr("nobody"));
        assertEq(quotes.length, 0, "no pools, no entries");
    }
}
