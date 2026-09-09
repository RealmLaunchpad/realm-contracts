// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTestsWithUniv2Graduator} from "test/launchpad/base.t.sol";
import {RealmTaxableTokenUniV2} from "src/tokens/RealmTaxableTokenUniV2.sol";
import {RealmTaxableToken} from "src/tokens/RealmTaxableToken.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {
    TaxConfigsWithAllocation,
    EarningsAllocationConfig,
    IRealmTaxableToken
} from "src/interfaces/IRealmTaxableToken.sol";

/// @notice Pins the storage packing the taxable tokens depend on for gas, and the creation-time-only
///         nature of the earnings allocation.
///
/// @dev Why a test and not a comment: tokens are non-upgradeable CLONES. Reordering the inheritance list
///      — `DividendDistribution` before `EarningsAllocation`, say — silently relays every field, and the
///      first symptom would be live tokens reading each other's storage. There is no migration from that.
///      The source carries a ⚠️ about it; this is the part that actually fails when someone ignores it.
///
/// @dev The assertions rebuild each packed word from the public getters and compare it against the raw
///      slot. That pins the slot INDEX and every field's OFFSET at once. If unrelated storage is ever
///      added ahead of these, the slot index moves and this test fails — which is exactly the moment a
///      human should look at it, so update the constants deliberately rather than reflexively.
contract TaxTokenStorageLayoutTests is LaunchpadBaseTestsWithUniv2Graduator {
    /// @dev `pair` + `graduated` + `hasSniperProt` + `hasDividends` + `dividendAssetCount`. `_update`
    ///      loads this slot on every transfer, which is the entire reason `hasDividends` and the payout
    ///      count live on `RealmToken` instead of beside the rest of the dividend state — the transfer
    ///      hook learns how many assets to settle without a cold read.
    uint256 internal constant WARM_FLAGS_SLOT = 10;

    /// @dev The three `EarningsAllocation` bps + the eight tax fields: 240 bits, one slot. The per-trade
    ///      tax read and the earnings-split read must hit the SAME warm slot.
    /// @dev Moved 21 -> 19 when the dividend round machinery was replaced by the streaming accumulator,
    ///      which needs three global slots instead of five, then 19 -> 20 when the treasury sweep's
    ///      persistence marker (`failedConversionBlock`) took a full word ahead of it, then 20 -> 26 when
    ///      the payout became a SET: `dividendAssets` is three slots per asset (15..23),
    ///      `dividendAccounts` 24 and `dividendWeightsBps` 25. `failedConversionBlock` no longer needs a
    ///      word of its own — inside a struct array it cannot leak into the head of this slot — but the
    ///      arrays that replaced it occupy whole slots, so the effect is the same.
    uint256 internal constant TAX_AND_ALLOCATION_SLOT = 26;

    /// @dev The V2 swap-back counters, which the packing above pushes into the following slot.
    uint256 internal constant SWAPBACK_COUNTERS_SLOT = 27;

    /// @dev First `DivAsset` of the payout set. Three slots each: the hot slot (accumulator + the three
    ///      clocks + the precision exponent), then `token` + `rate`, then the ledger + the buffer.
    uint256 internal constant DIVIDEND_ASSETS_SLOT = 15;

    RealmTaxableTokenUniV2 internal tok;

    /// @dev Built in `setUp` on purpose. Foundry runs `setUp` and each test as SEPARATE transactions, so
    ///      the transient `tokenFactory` set during the deploy is cleared by the time a test body runs —
    ///      which is the only way to observe the creation-only guard the way a real later transaction
    ///      would. Creating the token inside the test instead would leave the deploy tx still open and
    ///      the guard trivially satisfiable.
    function setUp() public override {
        super.setUp();
        tok = _token();
    }

    /// @dev A token with every packed field set to a DISTINCT non-zero value, so a field landing at the
    ///      wrong offset cannot coincidentally still match.
    function _token() internal returns (RealmTaxableTokenUniV2 token) {
        IRealmFactory.TokenSetupTiered memory setup = IRealmFactory.TokenSetupTiered({
            name: "Layout",
            symbol: "LAY",
            salt: _nextValidSalt(address(factoryV2Unified), address(realmTaxTokenV2)),
            feeShares: _fs(creator),
            liquidityTier: LiquidityTier.DEFAULT
        });
        TaxConfigsWithAllocation memory cfg = TaxConfigsWithAllocation({
            buyTaxBps: 300,
            sellTaxBps: 400,
            taxDurationSeconds: uint32(14 days),
            startTaxFromLaunch: true,
            buyTaxDecayStartBps: 900,
            sellTaxDecayStartBps: 1_100,
            taxDecayDuration: 600,
            earningsAllocation: EarningsAllocationConfig({
                burnBps: 1_000, dividendsBps: 2_000, liquidityBps: 1_500, dividendToken: address(0)
            })
        });
        vm.prank(creator);
        address addr = factoryV2Unified.createToken(
            setup, cfg, _noSs(), _emptyAntiSniperCfg(), new IRealmFactory.CreatorVault[](0), address(0)
        );
        return RealmTaxableTokenUniV2(payable(addr));
    }

    function _slot(address token, uint256 index) internal view returns (uint256) {
        return uint256(vm.load(token, bytes32(index)));
    }

    ///////////////////////// packing /////////////////////////

    /// @dev The tax fields and the allocation bps must occupy ONE slot, at the documented offsets. A
    ///      mismatch here means the inheritance order changed and every deployed clone's layout with it.
    function test_allocationBpsShareOneSlotWithTheTaxFields() public {
        RealmTaxableTokenUniV2 token = tok;
        uint256 word = _slot(address(token), TAX_AND_ALLOCATION_SLOT);

        assertEq(uint16(word), token.burnBps(), "burnBps at byte 0");
        assertEq(uint16(word >> 16), token.dividendsBps(), "dividendsBps at byte 2");
        assertEq(uint16(word >> 32), token.liquidityBps(), "liquidityBps at byte 4");
        assertEq(uint16(word >> 48), token.buyTaxBps(), "buyTaxBps at byte 6");
        assertEq(uint16(word >> 64), token.sellTaxBps(), "sellTaxBps at byte 8");
        assertEq(uint40(word >> 80), token.taxDurationSeconds(), "taxDurationSeconds at byte 10");
        assertEq((word >> 120) & 0xff, token.startTaxFromLaunch() ? 1 : 0, "startTaxFromLaunch at byte 15");
        assertEq(uint16(word >> 128), token.buyTaxDecayStartBps(), "buyTaxDecayStartBps at byte 16");
        assertEq(uint16(word >> 144), token.sellTaxDecayStartBps(), "sellTaxDecayStartBps at byte 18");
        assertEq(uint40(word >> 160), token.taxDecayDuration(), "taxDecayDuration at byte 20");

        // Every value is distinct and non-zero, so the reads above cannot pass by coincidence.
        assertTrue(token.burnBps() != 0 && token.buyTaxBps() != 0, "fixture actually populated the slot");
    }

    /// @dev `hasDividends` must ride in the slot `_update` already loads. If it slips into a slot of its
    ///      own, every transfer of every token — dividend-paying or not — pays for a cold SLOAD.
    function test_hasDividendsPacksIntoTheWarmFlagsSlot() public {
        RealmTaxableTokenUniV2 token = tok;
        uint256 word = _slot(address(token), WARM_FLAGS_SLOT);

        assertEq(address(uint160(word)), token.pair(), "pair at byte 0");
        assertEq((word >> 160) & 0xff, token.graduated() ? 1 : 0, "graduated at byte 20");
        assertEq((word >> 168) & 0xff, token.hasSniperProt() ? 1 : 0, "hasSniperProt at byte 21");
        assertEq((word >> 176) & 0xff, token.hasDividends() ? 1 : 0, "hasDividends at byte 22");
        assertEq((word >> 184) & 0xff, token.dividendAssetCount(), "dividendAssetCount at byte 23");
        assertTrue(token.hasDividends(), "fixture opted into dividends, so the flag is observable");
        assertEq(token.dividendAssetCount(), 1, "the fixture pays in one asset, and says so");
    }

    /// @dev The hot slot of a `DivAsset` is what makes a single-asset token cost what it always did: the
    ///      "has anything been distributed since this account last moved?" test and the settle
    ///      arithmetic both read this ONE slot, and only reach `token` in the next one when a payout is
    ///      made. A field slipping out of it would put a second SLOAD on every transfer of every
    ///      dividend token.
    function test_dividendAssetHotSlotHoldsTheAccumulatorAndBothClocks() public {
        RealmTaxableTokenUniV2 token = tok;
        // Graduation starts the clocks, which is what makes the packed fields observable at all.
        testToken = address(token);
        _launchpadBuy(address(token), 1 ether);
        _graduateToken();

        uint256 hot = _slot(address(token), DIVIDEND_ASSETS_SLOT);
        (
            uint128 rewardPerTokenStored,
            uint40 lastDistribution,
            uint40 lastProcessBlock,
            uint8 precisionExp,
            address asset,,,
        ) = token.dividendAssets(0);

        assertEq(uint128(hot), rewardPerTokenStored, "rewardPerTokenStored at byte 0");
        assertEq(uint40(hot >> 128), lastDistribution, "lastDistribution at byte 16");
        assertEq(uint40(hot >> 168), lastProcessBlock, "lastProcessBlock at byte 21");
        assertEq(uint8(hot >> 208), precisionExp, "precisionExp at byte 26");
        assertGt(lastDistribution, 0, "graduation started the clocks, so the slot is actually populated");

        uint256 second = _slot(address(token), DIVIDEND_ASSETS_SLOT + 1);
        assertEq(address(uint160(second)), asset, "the payout asset is in the SECOND slot");
    }

    /// @dev The counters were pushed out of the tax slot by the allocation bps. Documented as a
    ///      deliberate trade (one extra cold SLOAD on the swap-back path only) — pinned so the trade
    ///      stays the one that was actually reviewed.
    function test_swapbackCountersLiveInTheFollowingSlot() public {
        RealmTaxableTokenUniV2 token = tok;
        assertEq(_slot(address(token), SWAPBACK_COUNTERS_SLOT), 0, "counters start empty in their own slot");

        // Drive a swap-back so the counters are actually written, then confirm they landed here.
        testToken = address(token);
        _launchpadBuy(address(token), 1 ether);
        _graduateToken();
        vm.roll(block.number + 1);

        uint256 word = _slot(address(token), SWAPBACK_COUNTERS_SLOT);
        assertEq(uint48(word), token.lastSwapbackBlock(), "lastSwapbackBlock at byte 0");
        assertEq(uint8(word >> 48), token.swapbacksThisBlock(), "swapbacksThisBlock at byte 6");
    }

    ///////////////////////// the allocation is creation-only /////////////////////////

    /// @dev The split is chosen once, by the factory, inside the deploy transaction. `tokenFactory` is
    ///      transient and therefore zero in every later transaction, so no caller — not the creator, not
    ///      the launchpad owner, nobody — can re-point a live token's earnings afterwards.
    function test_earningsAllocationCannotBeSetAfterCreation() public {
        RealmTaxableTokenUniV2 token = tok;

        vm.expectRevert();
        IRealmTaxableToken(payable(address(token))).initializeEarningsAllocation(9_000, 0, 0);

        vm.prank(creator);
        vm.expectRevert();
        IRealmTaxableToken(payable(address(token))).initializeEarningsAllocation(9_000, 0, 0);

        vm.prank(address(factoryV2Unified));
        vm.expectRevert();
        IRealmTaxableToken(payable(address(token))).initializeEarningsAllocation(9_000, 0, 0);

        assertEq(token.burnBps(), 1_000, "the creation-time split is unchanged");
        assertEq(token.dividendsBps(), 2_000, "unchanged");
        assertEq(token.liquidityBps(), 1_500, "unchanged");
    }

    /// @dev Same for the dividend-config overload — it is the same guard, but it is a second entry point
    ///      and would be an easy one to add without the check.
    function test_dividendConfigCannotBeSetAfterCreation() public {
        RealmTaxableTokenUniV2 token = tok;

        vm.prank(creator);
        vm.expectRevert();
        IRealmTaxableToken(payable(address(token))).initializeEarningsAllocation(0, 10_000, 0, address(0));

        assertEq(token.dividendsBps(), 2_000, "the creation-time dividend share is unchanged");
    }
}
