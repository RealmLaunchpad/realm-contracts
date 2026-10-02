// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TaxTokenUniV4BaseTests} from "test/graduators/taxToken.base.t.sol";
import {RealmTaxableTokenUniV4} from "src/tokens/RealmTaxableTokenUniV4.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {DividendDistribution} from "src/tokens/DividendDistribution.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {TaxConfigsWithMultiAllocation} from "src/interfaces/IRealmTaxableToken.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {KeeperGated} from "src/tokens/KeeperGated.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {IRealmUniV4LiquidityAdder, RealmUniV4LiquidityAdder} from "src/liquidity/RealmUniV4LiquidityAdder.sol";
import {RealmTaxableTokenUniV4Base} from "src/tokens/RealmTaxableTokenUniV4Base.sol";
import {IERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";

/// @notice Stand-in for `RealmLpLocker.addWall` on the adder's zero-liquidity branch: an amount that sizes
///         to no liquidity is handed straight back to the caller. Real pools only reach this with an amount
///         far below anything a Realm pool's tick range can produce, so the branch is mocked rather than
///         contrived.
contract RefundingLpLockerStub {
    function addWall(address, uint256) external payable returns (uint128, uint256, uint256) {
        (bool sent,) = msg.sender.call{value: msg.value}("");
        require(sent, "refund failed");
        return (0, 0, 0);
    }
}

/// @notice Integration tests for the V4 single-sided-ETH liquidity earnings-allocation leg: the tax ETH
///         is buffered and, on `processLiquidity`, deposited as an ETH-only bid wall below the price.
contract LiquidityTaxTokenV4Tests is TaxTokenUniV4BaseTests {
    using StateLibrary for IPoolManager;

    /// @dev Creates a taxable V4 token with a `liquidityBps` earnings allocation via
    ///      `createToken`. Configurable buy/sell tax, creation-anchored 14-day window.
    function _createLiquidityTaxToken(uint16 buyTaxBps, uint16 sellTaxBps, uint16 liquidityBps)
        internal
        returns (address token)
    {
        IRealmFactory.TokenSetupTiered memory setup = IRealmFactory.TokenSetupTiered({
            name: "LiqToken",
            symbol: "LIQ",
            salt: _nextValidSalt(address(directFactory), address(realmTaxToken)),
            feeShares: _fs(creator),
            liquidityTier: LiquidityTier.DEFAULT
        });
        TaxConfigsWithMultiAllocation memory cfg = TaxConfigsWithMultiAllocation({
            buyTaxBps: buyTaxBps,
            sellTaxBps: sellTaxBps,
            taxDurationSeconds: uint32(14 days),
            startTaxFromLaunch: true,
            buyTaxDecayStartBps: 0,
            sellTaxDecayStartBps: 0,
            taxDecayDuration: 0,
            earningsAllocation: _multiAlloc(0, 0, liquidityBps, address(0))
        });
        token = _createDirect(setup, cfg, _emptyAntiSniperCfg(), new IRealmFactory.CreatorVault[](0));
    }

    function test_liquidityBps_storedAtCreation() public {
        address token = _createLiquidityTaxToken(0, 400, 5000);
        assertEq(RealmTaxableTokenUniV4(payable(token)).liquidityBps(), 5000, "liquidityBps stored at creation");
    }

    function test_v4Liquidity_accruesThenProcessMintsPosition() public {
        address token = _createLiquidityTaxToken(0, 400, 5000); // 4% sell tax; 50% of earnings → liquidity
        testToken = token;
        RealmTaxableTokenUniV4 liqToken = RealmTaxableTokenUniV4(payable(token));

        vm.deal(buyer, 5 ether);
        _swap(buyer, token, 2 ether, 0, true, true);
        _graduateToken();

        // Sell to accrue tax: hook -> accrueFees -> _allocateEthEarnings -> liquidity slice buffered as ETH.
        uint256 sellAmount = IERC20(token).balanceOf(buyer) / 2;
        _swapSell(buyer, sellAmount, 0, true);

        uint256 pending = liqToken.liquidityPendingEth();
        assertGt(pending, 0, "liquidity ETH should accrue from the sell tax");

        uint256 positionsBefore = lpLocker.positionIds(token).length;
        uint256 tokenEthBefore = token.balance;

        liqToken.processLiquidity();

        assertEq(liqToken.liquidityPendingEth(), 0, "liquidity buffer drained");
        assertEq(
            lpLocker.positionIds(token).length, positionsBefore + 1, "the locker holds one more wall for the token"
        );
        // The buffered ETH left the token (into the position); only rounding dust may remain.
        assertLt(token.balance, tokenEthBefore, "buffered ETH deposited into the position");
        assertApproxEqAbs(tokenEthBefore - token.balance, pending, 1e12, "almost the whole buffer went to liquidity");
    }

    /// @dev ETH the adder hands back must stay on the liquidity ledger. `liquidityPendingEth` is debited by
    ///      the full `ethIn` up front, so without the credit-back the returned ETH becomes stray and the
    ///      permissionless `sweepStrayEth` re-splits an allocation earmarked for liquidity into the burn /
    ///      dividend / fund buckets.
    function test_v4ProcessLiquidity_unplacedEthStaysEarmarked() public {
        address token = _createLiquidityTaxToken(0, 400, 5000);
        testToken = token;
        RealmTaxableTokenUniV4 liqToken = RealmTaxableTokenUniV4(payable(token));

        vm.deal(buyer, 5 ether);
        _swap(buyer, token, 2 ether, 0, true, true);
        _graduateToken();
        _swapSell(buyer, IERC20(token).balanceOf(buyer) / 2, 0, true);

        uint256 pending = liqToken.liquidityPendingEth();
        assertGt(pending, 0, "liquidity ETH should accrue from the sell tax");

        // Swap in a locker that places nothing and refunds — the branch a real pool only reaches for an
        // amount too small for its tick range to size.
        address stub = address(new RefundingLpLockerStub());
        vm.mockCall(liqToken.graduator(), abi.encodeWithSignature("LP_LOCKER()"), abi.encode(stub));

        uint256 ethBefore = token.balance;
        liqToken.processLiquidity();

        assertEq(liqToken.liquidityPendingEth(), pending, "refunded ETH stays earmarked for liquidity");
        assertEq(token.balance, ethBefore, "and never left the token");
    }

    /// @dev This one has NO slippage parameter at all — the wall lands at whatever price the caller has
    ///      arranged — so it is the entry point that most needs the gate.
    function test_v4ProcessLiquidity_refusesANonKeeper() public {
        address token = _createLiquidityTaxToken(0, 400, 5000);
        vm.prank(makeAddr("randomCaller"));
        vm.expectRevert(KeeperGated.NotAKeeper.selector);
        RealmTaxableTokenUniV4(payable(token)).processLiquidity();
    }

    function test_v4ProcessLiquidity_revertsWhenNothingPending() public {
        address token = _createLiquidityTaxToken(0, 400, 5000);
        vm.expectRevert(RealmTaxableTokenUniV4Base.NothingToAdd.selector);
        RealmTaxableTokenUniV4(payable(token)).processLiquidity();
    }

    /// @dev Sets up a graduated token with a buy AND sell tax, so either swap direction both moves the
    ///      price and refills the liquidity buffer. Returns the token, already assigned to `testToken`.
    function _graduatedLiquidityToken() internal returns (RealmTaxableTokenUniV4 liqToken) {
        address token = _createLiquidityTaxToken(400, 400, 5000);
        testToken = token;
        liqToken = RealmTaxableTokenUniV4(payable(token));
        vm.deal(buyer, 100 ether);
        _swap(buyer, token, 2 ether, 0, true, true);
        _graduateToken();
    }

    function _currentTick() internal view returns (int24 tick) {
        PoolId poolId = _getPoolKey(testToken).toId();
        (, tick,,) = poolManager.getSlot0(poolId);
    }

    function _positionCount() internal view returns (uint256) {
        return lpLocker.positionIds(testToken).length;
    }

    /// @dev Rolls a block (the once-per-block cooldown) and processes, returning the wall the next add
    ///      would use — the one this add used, since processing moves no price.
    function _rollAndProcess(RealmTaxableTokenUniV4 liqToken) internal returns (uint256 wall, int24 tickLower) {
        vm.roll(block.number + 1);
        liqToken.processLiquidity();
        (tickLower,, wall) = lpLocker.nextWall(testToken, address(0));
    }

    /// @dev The grid range the next add would use: its lower tick.
    function _nextRange() internal view returns (int24 tickLower) {
        (tickLower,,) = lpLocker.nextWall(testToken, address(0));
    }

    /// @dev The point of the fixed grid: a second `processLiquidity` while the price stays in the same
    ///      range thickens the SAME position instead of minting a second NFT.
    function test_v4ProcessLiquidity_topsUpTheWallWhilePriceStaysInRange() public {
        RealmTaxableTokenUniV4 liqToken = _graduatedLiquidityToken();

        _swapSell(buyer, IERC20(testToken).balanceOf(buyer) / 4, 0, true);
        (uint256 wall, int24 lower) = _rollAndProcess(liqToken);
        assertGt(wall, 0, "first call mints a wall");
        assertEq(lower % lpLocker.WALL_RANGE_TICKS(), 0, "on the grid");
        assertGt(lower, _currentTick(), "entirely below the price (above the tick: the pair is (ETH, token))");
        uint256 positionsAfterMint = _positionCount();
        uint128 liquidityAfterMint = IPositionManager(positionManagerAddress).getPositionLiquidity(wall);

        // A small buy refills the buffer (buy tax) without leaving the range.
        _swapBuy(buyer, 0.05 ether, 0, true);
        assertEq(_nextRange(), lower, "precondition: the price is still in the same range");
        uint256 pending = liqToken.liquidityPendingEth();
        assertGt(pending, 0, "precondition: the buy refilled the buffer");
        uint256 tokenEthBefore = testToken.balance;

        (uint256 wallAfter,) = _rollAndProcess(liqToken);

        // Same money-safety property as the mint path: the buffer is spent, not stranded or leaked.
        assertApproxEqAbs(
            tokenEthBefore - testToken.balance, pending, 1e12, "almost the whole buffer went into the wall"
        );
        assertEq(_positionCount(), positionsAfterMint, "no second NFT was minted");
        assertEq(wallAfter, wall, "the same wall");
        assertGt(
            IPositionManager(positionManagerAddress).getPositionLiquidity(wall),
            liquidityAfterMint,
            "the existing position got thicker"
        );
    }

    /// @dev A price DROP into the wall's range makes the range below it the target: a fresh wall there.
    function test_v4ProcessLiquidity_mintsTheNextRangeDownWhenPriceFallsIntoTheWall() public {
        RealmTaxableTokenUniV4 liqToken = _graduatedLiquidityToken();

        _swapSell(buyer, IERC20(testToken).balanceOf(buyer) / 4, 0, true);
        (uint256 wall, int24 lower) = _rollAndProcess(liqToken);
        uint256 positionsAfterMint = _positionCount();

        // Selling pushes the tick UP, through the wall's lower tick.
        _swapSell(buyer, IERC20(testToken).balanceOf(buyer), 0, true);
        assertGe(_currentTick(), lower, "precondition: the price fell into the wall");

        (uint256 wallAfter, int24 lowerAfter) = _rollAndProcess(liqToken);

        assertEq(_positionCount(), positionsAfterMint + 1, "a fresh wall was minted");
        assertTrue(wallAfter != wall, "a different position");
        assertGe(lowerAfter, lower + lpLocker.WALL_RANGE_TICKS(), "in a range further down");
    }

    /// @dev A price RISE across a range boundary makes a higher range the target: a fresh wall there.
    function test_v4ProcessLiquidity_mintsAHigherRangeWhenPriceRisesAcrossABoundary() public {
        RealmTaxableTokenUniV4 liqToken = _graduatedLiquidityToken();

        _swapSell(buyer, IERC20(testToken).balanceOf(buyer) / 4, 0, true);
        (uint256 wall, int24 lower) = _rollAndProcess(liqToken);
        uint256 positionsAfterMint = _positionCount();

        vm.deal(buyer, 20 ether);
        _swapBuy(buyer, 20 ether, 0, true);
        assertLt(_nextRange(), lower, "precondition: the price crossed into a higher range");

        (uint256 wallAfter,) = _rollAndProcess(liqToken);

        assertEq(_positionCount(), positionsAfterMint + 1, "a fresh wall was minted");
        assertTrue(wallAfter != wall, "a different position");
    }

    /// @dev Positions are bounded by the ranges visited, not by how often the price moves: back in a
    ///      range it has already walled, the old wall is topped up rather than a new one minted.
    function test_v4ProcessLiquidity_reusesTheWallWhenPriceReturnsToItsRange() public {
        RealmTaxableTokenUniV4 liqToken = _graduatedLiquidityToken();

        _swapSell(buyer, IERC20(testToken).balanceOf(buyer) / 4, 0, true);
        (uint256 first, int24 firstLower) = _rollAndProcess(liqToken);

        // Up into a higher range: a second wall.
        vm.deal(buyer, 20 ether);
        _swapBuy(buyer, 20 ether, 0, true);
        (uint256 second,) = _rollAndProcess(liqToken);
        assertTrue(second != first, "precondition: a second wall");
        uint256 positionsAfterTwoMints = _positionCount();

        // Back down, in small steps, until the first wall's range is the target again.
        for (uint256 i; i < 50 && _nextRange() < firstLower; ++i) {
            _swapSell(buyer, IERC20(testToken).balanceOf(buyer) / 20, 0, true);
        }
        assertEq(_nextRange(), firstLower, "precondition: back in the first wall's range");

        uint128 firstLiquidityBefore = IPositionManager(positionManagerAddress).getPositionLiquidity(first);
        (uint256 third,) = _rollAndProcess(liqToken);

        assertEq(_positionCount(), positionsAfterTwoMints, "no third NFT was minted");
        assertEq(third, first, "the first wall took the deposit");
        assertGt(
            IPositionManager(positionManagerAddress).getPositionLiquidity(first),
            firstLiquidityBefore,
            "and got thicker"
        );
    }

    /// @dev The assumption the grid rests on: a topped-up wall is ETH-ONLY, so the call settles native
    ///      and nothing else. If the target range ever included the price, the position would demand token1 — and the token would be spending the
    ///      supply it holds for other buckets.
    function test_v4ProcessLiquidity_topUpSpendsNoTokens() public {
        RealmTaxableTokenUniV4 liqToken = _graduatedLiquidityToken();

        _swapSell(buyer, IERC20(testToken).balanceOf(buyer) / 4, 0, true);
        (uint256 wall,) = _rollAndProcess(liqToken);
        assertGt(wall, 0, "precondition: a wall exists");

        _swapBuy(buyer, 0.05 ether, 0, true);
        uint256 tokenBalanceBefore = IERC20(testToken).balanceOf(testToken);
        uint256 supplyBefore = IERC20(testToken).totalSupply();

        (uint256 wallAfter,) = _rollAndProcess(liqToken);

        assertEq(wallAfter, wall, "precondition: this call took the top-up path");
        assertEq(IERC20(testToken).balanceOf(testToken), tokenBalanceBefore, "no tokens left the contract");
        assertEq(IERC20(testToken).totalSupply(), supplyBefore, "and none were minted or burned");
    }

    /// @dev The once-per-block cap bounds what a manipulated wall placement can extract per block. It must
    ///      hold on the top-up path too, which no longer goes through the mint.
    function test_v4ProcessLiquidity_cooldownAppliesToTopUps() public {
        RealmTaxableTokenUniV4 liqToken = _graduatedLiquidityToken();

        _swapSell(buyer, IERC20(testToken).balanceOf(buyer) / 4, 0, true);
        _rollAndProcess(liqToken);

        _swapBuy(buyer, 0.05 ether, 0, true);
        vm.roll(block.number + 1);
        liqToken.processLiquidity(); // top-up

        _swapBuy(buyer, 0.05 ether, 0, true);
        vm.expectRevert(RealmTaxableTokenUniV4Base.ProcessCooldown.selector);
        liqToken.processLiquidity();
    }

    /// @dev The per-call spend cap must bind on the top-up path as well; the remainder stays on the
    ///      liquidity ledger rather than becoming stray ETH the sweep would re-split into other buckets.
    function test_v4ProcessLiquidity_topUpHonoursThePerCallCap() public {
        RealmTaxableTokenUniV4 liqToken = _graduatedLiquidityToken();

        _swapSell(buyer, IERC20(testToken).balanceOf(buyer) / 4, 0, true);
        (uint256 wall,) = _rollAndProcess(liqToken);

        // Overfill the buffer well past the cap, without moving the price out of the range.
        uint256 cap = liqToken.MAX_EARNINGS_PER_PROCESS();
        _swapBuy(buyer, 0.05 ether, 0, true);
        vm.deal(address(liqToken), address(liqToken).balance + 5 * cap);
        liqToken.sweepStrayEth();
        uint256 pending = liqToken.liquidityPendingEth();
        assertGt(pending, cap, "precondition: the buffer exceeds the per-call cap");

        uint256 ethBefore = testToken.balance;
        (uint256 wallAfter,) = _rollAndProcess(liqToken);

        assertEq(wallAfter, wall, "precondition: this call took the top-up path");
        assertApproxEqAbs(ethBefore - testToken.balance, cap, 1e12, "at most one cap's worth was spent");
        assertApproxEqAbs(liqToken.liquidityPendingEth(), pending - cap, 1e12, "the remainder stays earmarked");
    }

    /// @dev The locker, which owns the walls, grants the adder an ERC721 approval so it can top up. That
    ///      approval must not become a way for a passer-by to route the position's payouts to themselves:
    ///      minting stays open to anyone, but topping up someone else's wall does not.
    function test_v4LiquidityAdder_topUpIsOwnerOnly() public {
        RealmTaxableTokenUniV4 liqToken = _graduatedLiquidityToken();

        _swapSell(buyer, IERC20(testToken).balanceOf(buyer) / 4, 0, true);
        (uint256 wall,) = _rollAndProcess(liqToken);
        assertGt(wall, 0, "precondition: the token owns a wall");

        address adder = lpLocker.LIQUIDITY_ADDER();
        assertTrue(
            IERC721(positionManagerAddress).isApprovedForAll(address(lpLocker), adder),
            "the adder is approved to top up the locker's walls"
        );

        address attacker = makeAddr("attacker");
        vm.deal(attacker, 1 ether);
        PoolKey memory key = UniswapV4PoolConstants.realmPoolKey(testToken, address(taxHook), _poolFee(testToken));
        vm.prank(attacker);
        vm.expectRevert(RealmUniV4LiquidityAdder.NotPositionOwner.selector);
        IRealmUniV4LiquidityAdder(adder).topUpSingleSided{value: 1 ether}(key, key.currency0, 1 ether, wall, attacker);
    }
}
