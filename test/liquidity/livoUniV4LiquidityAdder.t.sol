// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TaxTokenUniV4BaseTests} from "test/graduators/taxToken.base.t.sol";
import {LivoUniV4LiquidityAdder} from "src/liquidity/LivoUniV4LiquidityAdder.sol";
import {UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants.sol";
// The repo vendors TWO v4-core copies with nominally distinct (but field-identical) types: the adder's
// interface speaks `lib/v4-core`, while the shared V4 test base speaks `@uniswap/v4-core`. The pool key
// handed to the adder therefore comes from `UniswapV4PoolConstants` (already the right type) and pool
// state is read through the base's own key — the same boundary `LivoUniv4BuyBacks` navigates.
import {PoolKey as CorePoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo, PositionInfoLibrary} from "lib/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";

/// @notice Unit tests for the shared single-sided-ETH liquidity helper. It is called by the V4
///         graduator AND by every taxable token's liquidity earnings leg, so a mistake in the tick
///         placement would silently affect both. The properties that matter are all about WHERE the
///         range lands: an ETH-only position must sit entirely above the current tick, or the mint
///         needs token1 that the call never settles and reverts.
contract LivoUniV4LiquidityAdderTests is TaxTokenUniV4BaseTests {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using PositionInfoLibrary for PositionInfo;

    LivoUniV4LiquidityAdder internal adder;
    IPositionManager internal posm;

    address internal nftHolder = makeAddr("nftHolder");
    address internal dustHolder = makeAddr("dustHolder");

    int24 internal constant SPACING = UniswapV4PoolConstants.TICK_SPACING;

    function setUp() public virtual override {
        super.setUp();
        adder = new LivoUniV4LiquidityAdder(address(positionManagerAddress), address(poolManager));
        posm = IPositionManager(positionManagerAddress);

        testToken = _createTaxToken(0, DEFAULT_SELL_TAX_BPS, DEFAULT_TAX_DURATION);
        _launchpadBuy(testToken, 2 ether);
        _graduateToken();
    }

    /// @dev The key in the type the ADDER expects.
    function _key() internal view returns (CorePoolKey memory) {
        return UniswapV4PoolConstants.livoPoolKey(testToken, address(taxHook));
    }

    function _currentTick() internal view returns (int24 tick) {
        (, tick,,) = poolManager.getSlot0(_getPoolKeyWithTaxHook(testToken).toId());
    }

    /// @dev The ticks of the position minted by the most recent call.
    function _lastPositionTicks() internal view returns (int24 lower, int24 upper) {
        (, PositionInfo info) = posm.getPoolAndPositionInfo(posm.nextTokenId() - 1);
        return (info.tickLower(), info.tickUpper());
    }

    receive() external payable {}

    ///////////////////////// input guards /////////////////////////

    function test_revertsWithoutEth() public {
        vm.expectRevert(LivoUniV4LiquidityAdder.NoEthProvided.selector);
        adder.addSingleSidedEthBelowPrice(_key(), 14_000, nftHolder, dustHolder);
    }

    function test_revertsOnNonPositiveTickWidth() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(LivoUniV4LiquidityAdder.InvalidTickWidth.selector);
        adder.addSingleSidedEthBelowPrice{value: 1 ether}(_key(), 0, nftHolder, dustHolder);

        vm.deal(address(this), 1 ether);
        vm.expectRevert(LivoUniV4LiquidityAdder.InvalidTickWidth.selector);
        adder.addSingleSidedEthBelowPrice{value: 1 ether}(_key(), -SPACING, nftHolder, dustHolder);
    }

    ///////////////////////// tick placement /////////////////////////

    /// @dev THE property. An ETH-only position must live strictly above the current tick; one wei of
    ///      overlap would require token1 the call does not settle, and the mint reverts. The lower bound
    ///      must also be spacing-aligned or the position manager rejects it.
    function test_wallLandsStrictlyAboveTheCurrentTickAndOnTheSpacingGrid() public {
        int24 tickBefore = _currentTick();
        vm.deal(address(this), 1 ether);
        adder.addSingleSidedEthBelowPrice{value: 1 ether}(_key(), 70 * SPACING, nftHolder, dustHolder);

        (int24 lower, int24 upper) = _lastPositionTicks();
        assertGt(lower, tickBefore, "the range starts strictly above the current tick");
        assertEq(lower % SPACING, 0, "lower bound is spacing-aligned");
        assertEq(upper % SPACING, 0, "upper bound is spacing-aligned");
        assertEq(upper - lower, 70 * SPACING, "the range spans exactly the requested width");
    }

    /// @dev The snap is "smallest multiple of spacing strictly above the current tick", and it must hold
    ///      wherever the price sits. Solidity truncates toward zero, so positive and negative ticks take
    ///      different branches of `_ceilToSpacing` — the negative side is the one that silently rounds
    ///      the wrong way if the correction is dropped.
    function testFuzz_wallIsAlwaysAboveTheCurrentTick(uint256 buySeed) public {
        // Move the price around before placing the wall so the current tick lands at varied offsets
        // relative to the spacing grid.
        uint256 amount = bound(buySeed, 0.01 ether, 3 ether);
        vm.deal(buyer, amount);
        _swapBuy(buyer, amount, 0, true);

        int24 tickBefore = _currentTick();
        vm.deal(address(this), 0.5 ether);
        adder.addSingleSidedEthBelowPrice{value: 0.5 ether}(_key(), 10 * SPACING, nftHolder, dustHolder);

        (int24 lower,) = _lastPositionTicks();
        assertGt(lower, tickBefore, "strictly above, at any price");
        assertLe(lower - tickBefore, SPACING, "and no further above than one spacing step");
        assertEq(lower % SPACING, 0, "still on the grid");
    }

    /// @dev The explicit-range entry point does NOT snap for the caller: a range that straddles the
    ///      current tick needs token1, which the call never settles, so the mint must revert rather than
    ///      silently produce a two-sided position the adder cannot fund.
    function test_explicitRangeBelowTheCurrentTickReverts() public {
        int24 tick = _currentTick();
        int24 lower = ((tick / SPACING) * SPACING) - 10 * SPACING;
        vm.deal(address(this), 1 ether);
        vm.expectRevert();
        adder.addSingleSidedEth{value: 1 ether}(_key(), lower, lower + 4 * SPACING, nftHolder, dustHolder);
    }

    ///////////////////////// custody /////////////////////////

    /// @dev The adder takes no custody: the NFT goes to `nftReceiver` and the leftover ETH is swept to
    ///      `excessEthReceiver` in the same call. It has no withdrawal path, so anything it retains is
    ///      retained forever — which is why the bound here is wei, not "roughly nothing".
    /// @dev Measured: the position manager's SWEEP leaves exactly 1 wei behind per mint. Harmless, but
    ///      it IS permanently stranded, so this asserts a tight ceiling rather than pretending it is 0 —
    ///      if that ever grows into a real amount, this test is what notices.
    function test_takesNoCustodyBeyondWeiDust() public {
        vm.deal(address(this), 1 ether);
        uint256 tokenId = posm.nextTokenId();
        uint128 liquidity =
            adder.addSingleSidedEthBelowPrice{value: 1 ether}(_key(), 70 * SPACING, nftHolder, dustHolder);

        assertGt(liquidity, 0, "liquidity was actually minted");
        assertLe(address(adder).balance, 10, "at most wei-scale dust is stranded in the adder");
        assertEq(IERC721(address(posm)).ownerOf(tokenId), nftHolder, "NFT went to the requested receiver");
        assertEq(posm.getPositionLiquidity(tokenId), liquidity, "and carries the reported liquidity");

        // The liquidity is sized FROM `msg.value`, so in the normal case the position absorbs essentially
        // all of it and the SWEEP has nothing to return — it is a safety net for the rounding edge, not a
        // routine refund. What matters is only that nothing meaningful is retained by the adder.
        assertLe(dustHolder.balance + address(adder).balance, 1 ether, "nothing was conjured");
    }

    /// @dev Anyone may call it for any pool: it holds no funds and takes no approvals, so there is
    ///      nothing to protect. Guarding it would only make the token's own `processLiquidity` harder.
    function test_isPermissionless() public {
        address stranger = makeAddr("stranger");
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        uint128 liquidity =
            adder.addSingleSidedEthBelowPrice{value: 1 ether}(_key(), 70 * SPACING, nftHolder, dustHolder);
        assertGt(liquidity, 0, "a stranger can deepen a pool at their own expense");
    }

    /// @dev An amount that sizes to ZERO liquidity must come back, not revert: v4-core's
    ///      `Position.update` rejects a zero `liquidityDelta` with `CannotUpdateEmptyPosition`, which
    ///      would take down whatever called the adder — the graduation transaction, or a token's
    ///      `processLiquidity`. Needs a range whose lower sqrt price is far below 1, i.e. a pool where
    ///      the token has appreciated past parity with native; the guard returns before touching the
    ///      pool, so the key here never has to exist.
    function test_dustThatSizesToNoLiquidityIsReturnedInsteadOfReverting() public {
        CorePoolKey memory key = _key();
        uint256 dustBefore = dustHolder.balance;
        uint256 adderBefore = address(adder).balance; // graduation in `setUp` left the usual 1 wei
        vm.deal(address(this), 1 ether);

        uint128 liquidity = adder.addSingleSidedEth{value: 1 wei}(key, -700_000, 800_000, nftHolder, dustHolder);

        assertEq(liquidity, 0, "one wei sizes to nothing across a range this wide");
        assertEq(dustHolder.balance - dustBefore, 1 wei, "and the wei went back to the excess receiver");
        assertEq(address(adder).balance, adderBefore, "the adder kept nothing of it");
    }

    /// @dev A width that would push the top past the highest spacing-aligned tick is clamped rather than
    ///      reverting inside TickMath, so a deeply depreciated pool still gets a (narrower) wall.
    function test_excessiveWidthIsClampedToTheMaxUsableTick() public {
        int24 maxUsable = (TickMath.MAX_TICK / SPACING) * SPACING;
        vm.deal(address(this), 1 ether);
        adder.addSingleSidedEthBelowPrice{value: 1 ether}(_key(), maxUsable, nftHolder, dustHolder);

        (, int24 upper) = _lastPositionTicks();
        assertEq(upper, maxUsable, "clamped to the top of the grid instead of reverting");
    }
}
