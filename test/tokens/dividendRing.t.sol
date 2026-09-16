// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTests, LaunchpadBaseTestsWithUniv2Graduator} from "test/launchpad/base.t.sol";
import {V2SwapHelpers} from "test/e2e/base/V2SwapHelpers.t.sol";
import {RealmTaxableTokenUniV2} from "src/tokens/RealmTaxableTokenUniV2.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {TaxConfigsWithAllocation, EarningsAllocationConfig} from "src/interfaces/IRealmTaxableToken.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Vm} from "lib/forge-std/src/Vm.sol";

/// @notice The round-robin dividend push: holders enrolled on pool trades, one of them paid by every
///         subsequent pool trade, and the whole thing unable to revert the trade it rides on.
/// @dev The push is venue-agnostic — `RealmToken._update` triggers it and `DividendDistributionLogic`
///      performs it, neither of which knows about V2 or V4 — so it is exercised once, here, on the venue
///      with the cheapest test harness.
contract DividendRingTests is LaunchpadBaseTestsWithUniv2Graduator, V2SwapHelpers {
    address internal holder2 = makeAddr("holder2");

    function setUp() public override(LaunchpadBaseTests, LaunchpadBaseTestsWithUniv2Graduator) {
        super.setUp();
        vm.deal(holder2, 10 ether);
    }

    /// @dev A graduated token paying native dividends, with `buyer` holding the whole float.
    function _nativeToken() internal returns (RealmTaxableTokenUniV2 token) {
        return _token(0);
    }

    /// @dev The same token taxed on BOTH sides, so every trade splits into two `_update` calls.
    function _taxedBothWays() internal returns (RealmTaxableTokenUniV2 token) {
        return _token(400);
    }

    function _token(uint16 buyTaxBps) internal returns (RealmTaxableTokenUniV2 token) {
        IRealmFactory.TokenSetupTiered memory setup = IRealmFactory.TokenSetupTiered({
            name: "Ring",
            symbol: "RING",
            salt: _nextValidSalt(address(factoryV2Unified), address(realmTaxTokenV2)),
            feeShares: _fs(creator),
            liquidityTier: LiquidityTier.DEFAULT
        });
        TaxConfigsWithAllocation memory cfg = TaxConfigsWithAllocation({
            buyTaxBps: buyTaxBps,
            sellTaxBps: 400,
            taxDurationSeconds: uint32(14 days),
            startTaxFromLaunch: true,
            buyTaxDecayStartBps: 0,
            sellTaxDecayStartBps: 0,
            taxDecayDuration: 0,
            earningsAllocation: EarningsAllocationConfig({
                burnBps: 0, dividendsBps: 5_000, liquidityBps: 0, dividendToken: address(0)
            })
        });
        vm.prank(creator);
        address addr = factoryV2Unified.createToken(
            setup, cfg, _noSs(), _emptyAntiSniperCfg(), new IRealmFactory.CreatorVault[](0), address(0)
        );
        testToken = addr;
        _launchpadBuy(addr, 1 ether);
        _graduateToken();
        return RealmTaxableTokenUniV2(payable(addr));
    }

    function _noHolders() internal pure returns (address[] memory list) {
        list = new address[](0);
    }

    /// @dev Funds a distribution so every current holder has something owed to them.
    function _distribute(RealmTaxableTokenUniV2 token) internal {
        vm.deal(address(this), 1 ether);
        token.accrueFees{value: 1 ether}();
        token.processDividends(0, _noHolders());
    }

    /// @dev Puts the block number on an even slot so the push's `block.number % length` cursor lands on
    ///      ring index 0 with two members. The cursor is deliberately not stored, so a test that cares
    ///      which member is served has to pin the block rather than read a counter.
    function _aimCursorAtIndexZero() internal {
        vm.roll(block.number + (block.number % 2));
    }

    receive() external payable {}

    ///////////////////////// enrolment /////////////////////////

    function test_buyingThroughThePoolEnrolsTheBuyer() public {
        RealmTaxableTokenUniV2 token = _nativeToken();
        assertEq(token.dividendRingLength(), 0, "nothing is enrolled by a launchpad launch");

        _swapBuyV2(holder2, address(token), 1 ether, 0, true);

        assertEq(token.dividendRingLength(), 1, "the buyer joined");
        assertEq(token.dividendRing(0), holder2, "and is the sole member");
    }

    /// @dev The pool and the token are `_dividendExcluded`, so they accrue nothing — a membership for one
    ///      of them would be a slot in the rotation that can only ever pay zero.
    function test_theCounterpartyPoolIsNeverEnrolled() public {
        RealmTaxableTokenUniV2 token = _nativeToken();
        _swapBuyV2(holder2, address(token), 1 ether, 0, true);
        _swapSellV2(buyer, address(token), IERC20(address(token)).balanceOf(buyer) / 10, 0, true);

        assertEq(token.dividendRingLength(), 2, "the two traders, and only them");
        assertTrue(token.dividendRing(0) != token.pair() && token.dividendRing(1) != token.pair(), "not the pool");
    }

    function test_sellingOutLeavesTheRing() public {
        RealmTaxableTokenUniV2 token = _nativeToken();
        _swapBuyV2(holder2, address(token), 1 ether, 0, true);
        assertEq(token.dividendRingLength(), 1, "enrolled");

        _swapSellV2(holder2, address(token), IERC20(address(token)).balanceOf(holder2), 0, true);

        assertEq(token.dividendRingLength(), 0, "a holder under the minimum is dropped");
    }

    /// @dev The trade hook only sees the two sides of a trade, so a launchpad buyer who never trades is
    ///      invisible to it. This is their way in, and it is open to anyone.
    function test_anyoneCanEnrolAHolderThatNeverTraded() public {
        RealmTaxableTokenUniV2 token = _nativeToken();
        assertEq(token.dividendRingLength(), 0, "the launchpad buyer was never enrolled");

        vm.prank(holder2);
        token.updateDividendRing(buyer);

        assertEq(token.dividendRingLength(), 1, "enrolled by a stranger");
        assertEq(token.dividendRing(0), buyer, "the launchpad buyer");
    }

    function test_enrolmentIsIdempotent() public {
        RealmTaxableTokenUniV2 token = _nativeToken();
        token.updateDividendRing(buyer);
        token.updateDividendRing(buyer);

        assertEq(token.dividendRingLength(), 1, "a second call adds nothing");
    }

    ///////////////////////// the push /////////////////////////

    function test_aPoolTradePaysARingMemberWithoutAClaim() public {
        RealmTaxableTokenUniV2 token = _nativeToken();
        _swapBuyV2(holder2, address(token), 1 ether, 0, true);
        _distribute(token);

        uint256 owed = token.previewDividend(holder2, 0);
        assertGt(owed, 0, "the holder accrued a share of the distribution");

        // `buyer` joins on this sell, so the ring is [holder2, buyer] by the time the cursor reads it.
        _aimCursorAtIndexZero();
        uint256 before = holder2.balance;
        _swapSellV2(buyer, address(token), IERC20(address(token)).balanceOf(buyer) / 10, 0, true);

        assertEq(holder2.balance - before, owed, "somebody else's trade paid the holder in full");
        assertEq(token.previewDividend(holder2, 0), 0, "and cleared what was owed");
    }

    /// @dev ⚠️ The property the whole design rests on. A member whose `receive()` burns every wei of the
    ///      stipend must cost the trader that stipend and nothing else — not their trade.
    function test_aMemberThatCannotBePaidDoesNotBreakTheTrade() public {
        RealmTaxableTokenUniV2 token = _nativeToken();
        _swapBuyV2(holder2, address(token), 1 ether, 0, true);
        _distribute(token);
        uint256 owed = token.previewDividend(holder2, 0);
        uint256 ledgerBefore = token.dividendsOwed();

        // An `INVALID` opcode: consumes everything it is given and reverts.
        vm.etch(holder2, hex"fe");

        _aimCursorAtIndexZero();
        _swapSellV2(buyer, address(token), IERC20(address(token)).balanceOf(buyer) / 10, 0, true);

        assertEq(token.previewDividend(holder2, 0), owed, "the failed push left the accrual untouched");
        assertEq(token.dividendsOwed(), ledgerBefore, "and the ledger still counts it");
    }

    /// @dev Nothing has been distributed yet, so there is nothing to push and the trade must not start
    ///      paying for settles that can only write zero.
    function test_tradingBeforeAnyDistributionPushesNothing() public {
        RealmTaxableTokenUniV2 token = _nativeToken();
        _swapBuyV2(holder2, address(token), 1 ether, 0, true);

        uint256 before = holder2.balance;
        _swapSellV2(buyer, address(token), IERC20(address(token)).balanceOf(buyer) / 10, 0, true);

        assertEq(holder2.balance, before, "no distribution, no payout");
    }

    ///////////////////////// one push per trade /////////////////////////

    /// @dev `DividendPaid(address,address,uint256)`.
    bytes32 internal constant DIVIDEND_PAID = keccak256("DividendPaid(address,address,uint256)");

    function _dividendPaidCount(Vm.Log[] memory logs) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == DIVIDEND_PAID) ++n;
        }
    }

    /// @dev ⚠️ A TAXED transfer is TWO `_update` calls — the tax leg and the remainder — and both have the
    ///      pool on one side. The token itself is excluded from the trigger precisely so the tax leg does
    ///      not push: otherwise a taxed buy would pay two members and, worse, would hand control to the
    ///      first of them halfway through a transfer that has not finished moving anything to the buyer.
    function test_aTaxedTradePushesExactlyOnce() public {
        RealmTaxableTokenUniV2 token = _taxedBothWays();
        _swapBuyV2(holder2, address(token), 1 ether, 0, true);
        _distribute(token);
        assertGt(token.previewDividend(holder2, 0), 0, "the member is owed something");

        _aimCursorAtIndexZero();
        vm.recordLogs();
        _swapSellV2(buyer, address(token), IERC20(address(token)).balanceOf(buyer) / 10, 0, true);

        assertEq(_dividendPaidCount(vm.getRecordedLogs()), 1, "one member paid, once");
    }

    /// @dev The V2 swap-back sells the token's OWN balance into the pair from inside the transfer hook.
    ///      That leg has the pool on one side and the token on the other, so it must not push either —
    ///      a payout from there would run mid-router-call.
    function test_theSwapBackLegDoesNotPush() public {
        RealmTaxableTokenUniV2 token = _taxedBothWays();
        _swapBuyV2(holder2, address(token), 1 ether, 0, true);

        // Tax up the token's own balance past `SWAP_THRESHOLD` so the next sell triggers the swap-back.
        _swapSellV2(buyer, address(token), IERC20(address(token)).balanceOf(buyer) / 4, 0, true);
        _distribute(token);

        assertGe(
            IERC20(address(token)).balanceOf(address(token)),
            token.SWAP_THRESHOLD(),
            "the next sell will trigger the swap-back"
        );

        _aimCursorAtIndexZero();
        vm.recordLogs();
        _swapSellV2(buyer, address(token), IERC20(address(token)).balanceOf(buyer) / 4, 0, true);

        assertEq(token.lastSwapbackBlock(), uint48(block.number), "the swap-back really ran");
        assertEq(_dividendPaidCount(vm.getRecordedLogs()), 1, "and added no second push");
    }
}
