// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TaxTokenUniV4BaseTests} from "test/graduators/taxToken.base.t.sol";
import {RealmUniV4LiquidityAdder} from "src/liquidity/RealmUniV4LiquidityAdder.sol";
import {UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants.sol";
// The repo vendors TWO v4-core copies with nominally distinct (but field-identical) types: the adder's
// interface speaks `lib/v4-core`, while the shared V4 test base speaks `@uniswap/v4-core`. The pool key
// handed to the adder therefore comes from `UniswapV4PoolConstants` (already the right type) and pool
// state is read through the base's own key — the same boundary `RealmUniv4BuyBacks` navigates.
import {PoolKey as CorePoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {IERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {Currency} from "lib/v4-core/src/types/Currency.sol";

/// @notice Unit tests for the shared single-sided liquidity helper, called by the V4 graduator (launch
///         bands) and the LP locker (bid walls). Where a wall lands is the locker's call; these pin the
///         adder's own guards, custody and dust handling.
contract RealmUniV4LiquidityAdderTests is TaxTokenUniV4BaseTests {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    RealmUniV4LiquidityAdder internal adder;
    IPositionManager internal posm;

    address internal nftHolder = makeAddr("nftHolder");
    address internal dustHolder = makeAddr("dustHolder");

    int24 internal constant SPACING = UniswapV4PoolConstants.TICK_SPACING;

    function setUp() public virtual override {
        super.setUp();
        adder = new RealmUniV4LiquidityAdder(address(positionManagerAddress), permit2Address);
        posm = IPositionManager(positionManagerAddress);

        testToken = _createTaxToken(0, DEFAULT_SELL_TAX_BPS, DEFAULT_TAX_DURATION);
        _poolBuy(testToken, 2 ether);
        _graduateToken();
        testPoolFee = _poolFee(testToken);
    }

    /// @dev Cached so `_key()` makes no call that would consume a pending `expectRevert`.
    uint24 internal testPoolFee;

    /// @dev The key in the type the ADDER expects.
    function _key() internal view returns (CorePoolKey memory) {
        return UniswapV4PoolConstants.realmPoolKey(testToken, address(taxHook), testPoolFee);
    }

    function _currentTick() internal view returns (int24 tick) {
        (, tick,,) = poolManager.getSlot0(_getPoolKeyWithTaxHook(testToken).toId());
    }

    /// @dev A spacing-aligned ETH-only range: entirely above the current tick, 70 spacings wide.
    function _ethRange() internal view returns (int24 lower, int24 upper) {
        lower = ((_currentTick() / SPACING) * SPACING) + SPACING;
        upper = lower + 70 * SPACING;
    }

    function _addEth(uint256 amount) internal returns (uint128) {
        (int24 lower, int24 upper) = _ethRange();
        return
            adder.addSingleSided{value: amount}(_key(), _key().currency0, amount, lower, upper, nftHolder, dustHolder);
    }

    receive() external payable {}

    ///////////////////////// input guards /////////////////////////

    /// @dev The general entry point's own guards. Every caller in the repo passes well-formed inputs, so
    ///      these branches are only reachable from a future one — and each protects against funds settling
    ///      on the wrong side or stranding here, which this contract has no withdrawal path to undo.
    function test_addSingleSided_revertsOnCurrencyMismatch() public {
        CorePoolKey memory key = _key();
        int24 tick = _currentTick();
        int24 lower = ((tick / SPACING) * SPACING) + SPACING;

        // Neither side of the pair.
        vm.deal(address(this), 1 ether);
        vm.expectRevert(RealmUniV4LiquidityAdder.CurrencyMismatch.selector);
        adder.addSingleSided{value: 1 ether}(
            key, Currency.wrap(makeAddr("elsewhere")), 1 ether, lower, lower + SPACING, nftHolder, dustHolder
        );

        // Native, but the value sent does not match the amount it must settle.
        vm.expectRevert(RealmUniV4LiquidityAdder.CurrencyMismatch.selector);
        adder.addSingleSided{value: 1 ether}(
            key, key.currency0, 0.5 ether, lower, lower + SPACING, nftHolder, dustHolder
        );

        // An ERC20 side settles from a PULL, so any value sent alongside would strand in the adder.
        vm.expectRevert(RealmUniV4LiquidityAdder.CurrencyMismatch.selector);
        adder.addSingleSided{value: 1 wei}(key, key.currency1, 1e18, lower, lower + SPACING, nftHolder, dustHolder);
    }

    /// @dev A zero deposit is caught before any currency check, so it never reaches the pool manager.
    function test_addSingleSided_revertsOnZeroAmount() public {
        int24 tick = _currentTick();
        int24 lower = ((tick / SPACING) * SPACING) + SPACING;
        vm.expectRevert(RealmUniV4LiquidityAdder.NoEthProvided.selector);
        adder.addSingleSided(_key(), _key().currency0, 0, lower, lower + SPACING, nftHolder, dustHolder);
    }

    ///////////////////////// tick placement /////////////////////////

    /// @dev The explicit-range entry point does NOT snap for the caller: a range that straddles the
    ///      current tick needs token1, which the call never settles, so the mint must revert rather than
    ///      silently produce a two-sided position the adder cannot fund.
    function test_explicitRangeBelowTheCurrentTickReverts() public {
        int24 tick = _currentTick();
        int24 lower = ((tick / SPACING) * SPACING) - 10 * SPACING;
        vm.deal(address(this), 1 ether);
        vm.expectRevert();
        adder.addSingleSided{value: 1 ether}(
            _key(), _key().currency0, 1 ether, lower, lower + 4 * SPACING, nftHolder, dustHolder
        );
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
        uint128 liquidity = _addEth(1 ether);

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
        (int24 lower, int24 upper) = _ethRange();
        CorePoolKey memory key = _key();
        vm.prank(stranger);
        uint128 liquidity =
            adder.addSingleSided{value: 1 ether}(key, key.currency0, 1 ether, lower, upper, nftHolder, dustHolder);
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

        uint128 liquidity =
            adder.addSingleSided{value: 1 wei}(key, key.currency0, 1 wei, -700_000, 800_000, nftHolder, dustHolder);

        assertEq(liquidity, 0, "one wei sizes to nothing across a range this wide");
        assertEq(dustHolder.balance - dustBefore, 1 wei, "and the wei went back to the excess receiver");
        assertEq(address(adder).balance, adderBefore, "the adder kept nothing of it");
    }
}
