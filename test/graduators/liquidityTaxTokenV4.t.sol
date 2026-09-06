// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TaxTokenUniV4BaseTests} from "test/graduators/taxToken.base.t.sol";
import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {LivoFactoryUniV4Unified} from "src/factories/LivoFactoryUniV4Unified.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {DividendDistribution} from "src/tokens/DividendDistribution.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {TaxConfigsWithAllocation, EarningsAllocationConfig} from "src/interfaces/ILivoTaxableToken.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {KeeperGated} from "src/tokens/KeeperGated.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {ILivoUniV4LiquidityAdder, LivoUniV4LiquidityAdder} from "src/liquidity/LivoUniV4LiquidityAdder.sol";
import {ILivoV4Graduator} from "src/tokens/LivoTaxableTokenUniV4Base.sol";
import {IERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";

interface IERC721Minimal {
    function balanceOf(address owner) external view returns (uint256);
}

/// @notice Stand-in for `LivoUniV4LiquidityAdder` on its zero-liquidity branch: an amount that sizes to
///         no liquidity is handed straight back to the caller. Real pools only reach this with an amount
///         far below anything a Livo pool's tick range can produce, so the branch is mocked rather than
///         contrived.
contract RefundingLiquidityAdderStub {
    function addOrTopUpSingleSidedEth(
        PoolKey calldata,
        int24,
        int24,
        uint256[2] calldata,
        int24[2] calldata,
        address,
        address
    ) external payable returns (uint128, uint256, int24) {
        (bool sent,) = msg.sender.call{value: msg.value}("");
        require(sent, "refund failed");
        return (0, 0, 0);
    }
}

/// @notice Integration tests for the V4 single-sided-ETH liquidity earnings-allocation leg: the tax ETH
///         is buffered and, on `processLiquidity`, deposited as an ETH-only bid wall below the price.
contract LiquidityTaxTokenV4Tests is TaxTokenUniV4BaseTests {
    using StateLibrary for IPoolManager;

    /// @dev Creates a taxable V4 token with a `liquidityBps` earnings allocation via the allocation-aware
    ///      `createToken` overload. Configurable buy/sell tax, creation-anchored 14-day window.
    function _createLiquidityTaxToken(uint16 buyTaxBps, uint16 sellTaxBps, uint16 liquidityBps)
        internal
        returns (address token)
    {
        ILivoFactory.TokenSetupTiered memory setup = ILivoFactory.TokenSetupTiered({
            name: "LiqToken",
            symbol: "LIQ",
            salt: _nextValidSalt(address(factoryTax), address(livoTaxToken)),
            feeShares: _fs(creator),
            liquidityTier: LiquidityTier.DEFAULT
        });
        TaxConfigsWithAllocation memory cfg = TaxConfigsWithAllocation({
            buyTaxBps: buyTaxBps,
            sellTaxBps: sellTaxBps,
            taxDurationSeconds: uint32(14 days),
            startTaxFromLaunch: true,
            buyTaxDecayStartBps: 0,
            sellTaxDecayStartBps: 0,
            taxDecayDuration: 0,
            earningsAllocation: EarningsAllocationConfig({
                burnBps: 0, dividendsBps: 0, liquidityBps: liquidityBps, dividendToken: address(0)
            })
        });
        vm.prank(creator);
        token = factoryTax.createToken(
            setup,
            cfg,
            LivoFactoryUniV4Unified.UniV4Configs({renounceOwnership: false, lpFeeBps: 100}),
            _noSs(),
            _emptyAntiSniperCfg(),
            new ILivoFactory.CreatorVault[](0),
            address(0)
        );
    }

    function test_liquidityBps_storedAtCreation() public {
        address token = _createLiquidityTaxToken(0, 400, 5000);
        assertEq(LivoTaxableTokenUniV4(payable(token)).liquidityBps(), 5000, "liquidityBps stored via new overload");
    }

    function test_v4Liquidity_accruesThenProcessMintsPosition() public {
        address token = _createLiquidityTaxToken(0, 400, 5000); // 4% sell tax; 50% of earnings → liquidity
        testToken = token;
        LivoTaxableTokenUniV4 liqToken = LivoTaxableTokenUniV4(payable(token));

        vm.deal(buyer, 5 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 2 ether}(token, 0, DEADLINE);
        _graduateToken();

        // Sell to accrue tax: hook -> accrueFees -> _allocateEthEarnings -> liquidity slice buffered as ETH.
        uint256 sellAmount = IERC20(token).balanceOf(buyer) / 2;
        _swapSell(buyer, sellAmount, 0, true);

        uint256 pending = liqToken.liquidityPendingEth();
        assertGt(pending, 0, "liquidity ETH should accrue from the sell tax");

        uint256 positionsBefore = IERC721Minimal(positionManagerAddress).balanceOf(token);
        uint256 tokenEthBefore = token.balance;

        liqToken.processLiquidity();

        assertEq(liqToken.liquidityPendingEth(), 0, "liquidity buffer drained");
        assertEq(
            IERC721Minimal(positionManagerAddress).balanceOf(token),
            positionsBefore + 1,
            "token owns one more single-sided ETH position"
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
        LivoTaxableTokenUniV4 liqToken = LivoTaxableTokenUniV4(payable(token));

        vm.deal(buyer, 5 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 2 ether}(token, 0, DEADLINE);
        _graduateToken();
        _swapSell(buyer, IERC20(token).balanceOf(buyer) / 2, 0, true);

        uint256 pending = liqToken.liquidityPendingEth();
        assertGt(pending, 0, "liquidity ETH should accrue from the sell tax");

        // Swap in an adder that places nothing and refunds — the branch a real pool only reaches for an
        // amount too small for its tick range to size.
        address stub = address(new RefundingLiquidityAdderStub());
        vm.mockCall(liqToken.graduator(), abi.encodeWithSignature("LIQUIDITY_ADDER()"), abi.encode(stub));

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
        LivoTaxableTokenUniV4(payable(token)).processLiquidity();
    }

    function test_v4ProcessLiquidity_revertsWhenNothingPending() public {
        address token = _createLiquidityTaxToken(0, 400, 5000);
        vm.expectRevert(LivoTaxableTokenUniV4.NothingToAdd.selector);
        LivoTaxableTokenUniV4(payable(token)).processLiquidity();
    }

    /// @dev Sets up a graduated token with a buy AND sell tax, so either swap direction both moves the
    ///      price and refills the liquidity buffer. Returns the token, already assigned to `testToken`.
    function _graduatedLiquidityToken() internal returns (LivoTaxableTokenUniV4 liqToken) {
        address token = _createLiquidityTaxToken(400, 400, 5000);
        testToken = token;
        liqToken = LivoTaxableTokenUniV4(payable(token));
        vm.deal(buyer, 100 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 2 ether}(token, 0, DEADLINE);
        _graduateToken();
    }

    function _currentTick() internal view returns (int24 tick) {
        PoolId poolId = _getPoolKey(testToken).toId();
        (, tick,,) = poolManager.getSlot0(poolId);
    }

    function _positionCount() internal view returns (uint256) {
        return IERC721Minimal(positionManagerAddress).balanceOf(testToken);
    }

    /// @dev Rolls a block (the once-per-block cooldown) and processes, returning the wall memory after.
    function _rollAndProcess(LivoTaxableTokenUniV4 liqToken)
        internal
        returns (uint256[2] memory ids, int24[2] memory tickLowers)
    {
        vm.roll(block.number + 1);
        liqToken.processLiquidity();
        (ids, tickLowers) = liqToken.getLiquidityWalls();
    }

    /// @dev The point of the whole reuse path: a second `processLiquidity` while the price is still just
    ///      below the wall thickens the SAME position instead of minting a second NFT.
    function test_v4ProcessLiquidity_topsUpTheWallWhilePriceStaysNear() public {
        LivoTaxableTokenUniV4 liqToken = _graduatedLiquidityToken();

        _swapSell(buyer, IERC20(testToken).balanceOf(buyer) / 4, 0, true);
        (uint256[2] memory ids, int24[2] memory tickLowers) = _rollAndProcess(liqToken);
        assertGt(ids[0], 0, "first call mints and remembers a wall");
        uint256 positionsAfterMint = _positionCount();
        uint128 liquidityAfterMint = IPositionManager(positionManagerAddress).getPositionLiquidity(ids[0]);

        // A small buy nudges the price UP (the tick DOWN, since the pair is (ETH, token)) and, thanks to
        // the buy tax, refills the buffer. The wall stays above the tick and within the reuse gap.
        _swapBuy(buyer, 0.05 ether, 0, true);
        int24 tickAfter = _currentTick();
        assertLt(tickAfter, tickLowers[0], "precondition: the wall is still entirely below the price");
        assertLt(tickLowers[0] - tickAfter, int24(2000), "precondition: and within the reuse gap");
        uint256 pending = liqToken.liquidityPendingEth();
        assertGt(pending, 0, "precondition: the buy refilled the buffer");
        uint256 tokenEthBefore = testToken.balance;

        (uint256[2] memory idsAfter, int24[2] memory tickLowersAfter) = _rollAndProcess(liqToken);

        // Same money-safety property as the mint path: the buffer is spent, not stranded or leaked.
        assertApproxEqAbs(
            tokenEthBefore - testToken.balance, pending, 1e12, "almost the whole buffer went into the wall"
        );

        assertEq(_positionCount(), positionsAfterMint, "no second NFT was minted");
        assertEq(idsAfter[0], ids[0], "the same wall is still the most recent one");
        assertEq(tickLowersAfter[0], tickLowers[0], "and its range did not move");
        assertGt(
            IPositionManager(positionManagerAddress).getPositionLiquidity(ids[0]),
            liquidityAfterMint,
            "the existing position got thicker"
        );
    }

    /// @dev A price DROP puts the current tick inside the old wall, which then holds token rather than
    ///      pure ETH. An ETH-only top-up cannot settle there, so the call must mint a fresh wall.
    function test_v4ProcessLiquidity_mintsAgainWhenPriceFallsIntoTheWall() public {
        LivoTaxableTokenUniV4 liqToken = _graduatedLiquidityToken();

        _swapSell(buyer, IERC20(testToken).balanceOf(buyer) / 4, 0, true);
        (uint256[2] memory ids, int24[2] memory tickLowers) = _rollAndProcess(liqToken);
        uint256 positionsAfterMint = _positionCount();

        // Selling pushes the tick UP, through the wall's lower tick.
        _swapSell(buyer, IERC20(testToken).balanceOf(buyer) / 2, 0, true);
        assertGe(_currentTick(), tickLowers[0], "precondition: the price fell into the old wall");

        (uint256[2] memory idsAfter,) = _rollAndProcess(liqToken);

        assertEq(_positionCount(), positionsAfterMint + 1, "a fresh wall was minted");
        assertGt(idsAfter[0], ids[0], "the new wall is the most recent one");
        assertEq(idsAfter[1], ids[0], "and the old one is remembered in the second slot");
    }

    /// @dev A price rise beyond `LIQUIDITY_WALL_REUSE_MAX_GAP` leaves the old wall stranded far below the
    ///      market. Topping it up would park the ETH as deep depth instead of a protective bid, so the
    ///      call mints at the live tick instead.
    function test_v4ProcessLiquidity_mintsAgainWhenPriceRanFarAboveTheWall() public {
        LivoTaxableTokenUniV4 liqToken = _graduatedLiquidityToken();

        _swapSell(buyer, IERC20(testToken).balanceOf(buyer) / 4, 0, true);
        (uint256[2] memory ids, int24[2] memory tickLowers) = _rollAndProcess(liqToken);
        uint256 positionsAfterMint = _positionCount();

        // A large buy moves the tick far DOWN — the wall is still ETH-only, just far too deep to be a bid.
        vm.deal(buyer, 20 ether);
        _swapBuy(buyer, 20 ether, 0, true);
        int24 tickAfter = _currentTick();
        assertLt(tickAfter, tickLowers[0], "precondition: the wall is still entirely below the price");
        assertGt(tickLowers[0] - tickAfter, int24(2000), "precondition: but beyond the reuse gap");

        (uint256[2] memory idsAfter,) = _rollAndProcess(liqToken);

        assertEq(_positionCount(), positionsAfterMint + 1, "a fresh wall was minted");
        assertEq(idsAfter[1], ids[0], "the stranded wall is kept as the second entry");
    }

    /// @dev The reason the memory holds TWO walls. Price runs up (wall 2 minted far below wall 1), then
    ///      falls back to between them: wall 2 is now in-range and unusable, but wall 1 is once again just
    ///      below the price. A one-entry memory would mint a third position here.
    function test_v4ProcessLiquidity_reusesTheOlderWallAfterAZigzag() public {
        LivoTaxableTokenUniV4 liqToken = _graduatedLiquidityToken();

        _swapSell(buyer, IERC20(testToken).balanceOf(buyer) / 4, 0, true);
        (uint256[2] memory first,) = _rollAndProcess(liqToken);

        // Run the price up far enough that the next call mints rather than tops up.
        vm.deal(buyer, 20 ether);
        _swapBuy(buyer, 20 ether, 0, true);
        (uint256[2] memory second, int24[2] memory secondLowers) = _rollAndProcess(liqToken);
        assertEq(second[1], first[0], "precondition: both walls are remembered");
        uint256 positionsAfterTwoMints = _positionCount();

        // Fall back to between the two walls: above the newer wall's lower tick, below the older one's.
        _swapSell(buyer, IERC20(testToken).balanceOf(buyer) * 4 / 10, 0, true);
        int24 tickAfter = _currentTick();
        assertGe(tickAfter, secondLowers[0], "precondition: the newer wall is now in range and unusable");
        assertLt(tickAfter, secondLowers[1], "precondition: the older wall is above the price again");
        assertLt(secondLowers[1] - tickAfter, int24(2000), "precondition: and within the reuse gap");

        uint128 olderLiquidityBefore = IPositionManager(positionManagerAddress).getPositionLiquidity(first[0]);
        (uint256[2] memory third,) = _rollAndProcess(liqToken);

        assertEq(_positionCount(), positionsAfterTwoMints, "no third NFT was minted");
        assertGt(
            IPositionManager(positionManagerAddress).getPositionLiquidity(first[0]),
            olderLiquidityBefore,
            "the older wall took the ETH"
        );
        assertEq(third[0], first[0], "and was promoted to the most-recently-used slot");
        assertEq(third[1], second[0], "with the newer wall demoted behind it");
    }

    /// @dev The assumption the whole reuse rule rests on: a topped-up wall is ETH-ONLY, so the call
    ///      settles native and nothing else. If the eligibility check ever let a wall through that the
    ///      price had entered, the position would demand token1 — and the token would be spending the
    ///      supply it holds for other buckets.
    function test_v4ProcessLiquidity_topUpSpendsNoTokens() public {
        LivoTaxableTokenUniV4 liqToken = _graduatedLiquidityToken();

        _swapSell(buyer, IERC20(testToken).balanceOf(buyer) / 4, 0, true);
        (uint256[2] memory ids,) = _rollAndProcess(liqToken);
        assertGt(ids[0], 0, "precondition: a wall exists");

        _swapBuy(buyer, 0.05 ether, 0, true);
        uint256 tokenBalanceBefore = IERC20(testToken).balanceOf(testToken);
        uint256 supplyBefore = IERC20(testToken).totalSupply();

        (uint256[2] memory idsAfter,) = _rollAndProcess(liqToken);

        assertEq(idsAfter[0], ids[0], "precondition: this call took the top-up path");
        assertEq(IERC20(testToken).balanceOf(testToken), tokenBalanceBefore, "no tokens left the contract");
        assertEq(IERC20(testToken).totalSupply(), supplyBefore, "and none were minted or burned");
    }

    /// @dev The once-per-block cap bounds what a manipulated wall placement can extract per block. It must
    ///      hold on the top-up path too, which no longer goes through the mint.
    function test_v4ProcessLiquidity_cooldownAppliesToTopUps() public {
        LivoTaxableTokenUniV4 liqToken = _graduatedLiquidityToken();

        _swapSell(buyer, IERC20(testToken).balanceOf(buyer) / 4, 0, true);
        _rollAndProcess(liqToken);

        _swapBuy(buyer, 0.05 ether, 0, true);
        vm.roll(block.number + 1);
        liqToken.processLiquidity(); // top-up

        _swapBuy(buyer, 0.05 ether, 0, true);
        vm.expectRevert(LivoTaxableTokenUniV4.ProcessCooldown.selector);
        liqToken.processLiquidity();
    }

    /// @dev The per-call spend cap must bind on the top-up path as well; the remainder stays on the
    ///      liquidity ledger rather than becoming stray ETH the sweep would re-split into other buckets.
    function test_v4ProcessLiquidity_topUpHonoursThePerCallCap() public {
        LivoTaxableTokenUniV4 liqToken = _graduatedLiquidityToken();

        _swapSell(buyer, IERC20(testToken).balanceOf(buyer) / 4, 0, true);
        (uint256[2] memory ids,) = _rollAndProcess(liqToken);

        // Overfill the buffer well past the cap, without moving the price out of the reuse window.
        uint256 cap = liqToken.MAX_EARNINGS_PER_PROCESS();
        _swapBuy(buyer, 0.05 ether, 0, true);
        vm.deal(address(liqToken), address(liqToken).balance + 5 * cap);
        liqToken.sweepStrayEth();
        uint256 pending = liqToken.liquidityPendingEth();
        assertGt(pending, cap, "precondition: the buffer exceeds the per-call cap");

        uint256 ethBefore = testToken.balance;
        (uint256[2] memory idsAfter,) = _rollAndProcess(liqToken);

        assertEq(idsAfter[0], ids[0], "precondition: this call took the top-up path");
        assertApproxEqAbs(ethBefore - testToken.balance, cap, 1e12, "at most one cap's worth was spent");
        assertApproxEqAbs(liqToken.liquidityPendingEth(), pending - cap, 1e12, "the remainder stays earmarked");
    }

    /// @dev The token grants the adder an ERC721 approval so it can top up. That approval must not become
    ///      a way for a passer-by to route the position's payouts to themselves: minting stays open to
    ///      anyone, but topping up someone else's wall does not.
    function test_v4LiquidityAdder_topUpIsOwnerOnly() public {
        LivoTaxableTokenUniV4 liqToken = _graduatedLiquidityToken();

        _swapSell(buyer, IERC20(testToken).balanceOf(buyer) / 4, 0, true);
        (uint256[2] memory ids, int24[2] memory tickLowers) = _rollAndProcess(liqToken);
        assertGt(ids[0], 0, "precondition: the token owns a wall");

        address adder = ILivoV4Graduator(liqToken.graduator()).LIQUIDITY_ADDER();
        assertTrue(
            IERC721(positionManagerAddress).isApprovedForAll(testToken, adder), "the adder is approved to top up"
        );

        address attacker = makeAddr("attacker");
        vm.deal(attacker, 1 ether);
        vm.prank(attacker);
        vm.expectRevert(LivoUniV4LiquidityAdder.NotPositionOwner.selector);
        ILivoUniV4LiquidityAdder(adder).addOrTopUpSingleSidedEth{value: 1 ether}(
            UniswapV4PoolConstants.livoPoolKey(testToken, address(taxHook)),
            14000,
            2000,
            ids,
            tickLowers,
            attacker,
            attacker
        );
    }
}
