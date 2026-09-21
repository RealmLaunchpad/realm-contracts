// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DividendDistribution} from "src/tokens/DividendDistribution.sol";
import {RealmKeeperLens} from "src/RealmKeeperLens.sol";

/// @notice The dividend half of a real token, with the storage poked directly instead of earned. The
///         point is that every getter the lens reads is the REAL one, with the real ABI encoding —
///         `dividendAssets(i)` in particular, whose flat tuple the lens decodes back into `DivAsset`.
/// @dev Deliberately not `DividendDistributionLogic`: the lens never funds or distributes anything, and
///      going through `_initializeDividends` would drag a mainnet fork and the swap registry into a test
///      about reads.
abstract contract LensHarness is DividendDistribution {
    uint8 public dividendAssetCount;
    mapping(address account => uint256 balance) public balances;
    uint256 public eligibleSupply;

    function setAsset(uint256 i, address asset, uint128 owed, uint88 pending, uint40 lastDistribution) external {
        dividendAssets[i].token = asset;
        dividendAssets[i].owed = owed;
        dividendAssets[i].pendingNative = pending;
        dividendAssets[i].lastDistribution = lastDistribution;
    }

    function setCount(uint8 n) external {
        dividendAssetCount = n;
    }

    /// @dev Banked accrual, which `previewDividend` returns verbatim for an account whose checkpoint is
    ///      already current — exactly what the lens's floor filter consumes.
    function setAccrual(address account, uint256 i, uint120 rewards) external {
        dividendAccounts[account][i].rewards = rewards;
    }

    function _dividendAssetCount() internal view override returns (uint256) {
        return dividendAssetCount;
    }

    function _dividendBalanceOf(address account) internal view override returns (uint256) {
        return balances[account];
    }

    function _dividendExcluded(address) internal pure override returns (bool) {
        return false;
    }

    function _dividendEligibleSupply() internal view override returns (uint256) {
        return eligibleSupply;
    }
}

/// @notice A V2-venue token: token-space buffers and `SWAP_THRESHOLD`, no native ones.
contract V2Harness is LensHarness {
    uint256 public constant SWAP_THRESHOLD = 1e24;
    uint256 public dividendPendingTokens;
    uint256 public liquidityPendingTokens;

    function setBuffers(uint256 dividends, uint256 liquidity) external {
        dividendPendingTokens = dividends;
        liquidityPendingTokens = liquidity;
    }
}

/// @notice A V4-venue token: native buffers and the direct venue's ERC20-quote legs.
contract V4Harness is LensHarness {
    uint256 public burnPendingEth;
    uint256 public liquidityPendingEth;

    mapping(address quote => uint256[2] buffers) internal quoteBuffers;
    mapping(address quote => uint128[3] pending) internal quotePending;

    function setBuffers(uint256 burn, uint256 liquidity) external {
        burnPendingEth = burn;
        liquidityPendingEth = liquidity;
    }

    function setQuoteLeg(address quote, uint256 burn, uint256 liquidity, uint128 dividends) external {
        quoteBuffers[quote] = [burn, liquidity];
        quotePending[quote][0] = dividends;
    }

    function quoteBufferOf(address quote) external view returns (uint256, uint256, uint48, uint48) {
        return (quoteBuffers[quote][0], quoteBuffers[quote][1], 0, 0);
    }

    function quoteDividendPending(address quote) external view returns (uint128[3] memory) {
        return quotePending[quote];
    }
}

/// @notice A token of the generation that predates the payout SET: the un-indexed getters are all it
///         has, and `dividendAssetCount()` is what it is missing.
contract LegacyHarness {
    address public dividendToken;
    uint128 public dividendsOwed;
    uint88 public pendingNative;
    bool internal stale;

    mapping(address holder => uint256 accrual) internal accruals;

    constructor(address asset, uint128 owed, uint88 pending, bool isStale) {
        dividendToken = asset;
        dividendsOwed = owed;
        pendingNative = pending;
        stale = isStale;
    }

    function setAccrual(address holder, uint256 accrual) external {
        accruals[holder] = accrual;
    }

    function dividendsStale() external view returns (bool) {
        return stale;
    }

    function previewDividend(address holder) external view returns (uint256) {
        return accruals[holder];
    }
}

/// @notice A contract that is emphatically not a Realm token. The batch must survive it.
contract NotAToken {
    function hello() external pure returns (uint256) {
        return 42;
    }
}

/// @notice `RealmKeeperLens` — the read half of a dividend-keeper pass, batched.
///
/// @dev THE PROPERTIES UNDER TEST: a batch never reverts, whatever is in it; venue and generation are
///      inferred from which getters answer rather than from an address list; and the per-holder filter
///      reproduces the keeper's own `PUSH_FLOOR_BPS` rule against real accruals.
contract RealmKeeperLensTests is Test {
    address internal constant NATIVE = address(0);
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @dev The keeper's own `PUSH_FLOOR_BPS`: 0.1% of what the asset still owes.
    uint256 internal constant FLOOR_BPS = 10;

    RealmKeeperLens internal lens;
    V4Harness internal v4;
    V2Harness internal v2;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public {
        // Far enough in that `lastDistribution` can be set in the past without underflowing.
        vm.warp(365 days);
        lens = new RealmKeeperLens();

        v4 = new V4Harness();
        v4.setCount(2);
        v4.setAsset(0, NATIVE, 100e18, 5e18, uint40(block.timestamp));
        v4.setAsset(1, DAI, 200e18, 7e18, uint40(block.timestamp));
        v4.setBuffers(11e18, 13e18);

        v2 = new V2Harness();
        v2.setCount(1);
        v2.setAsset(0, address(v2), 3e18, 0, uint40(block.timestamp));
        v2.setBuffers(17e18, 19e18);
    }

    //////////////////////// helpers //////////////////////

    function _one(address token) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = token;
    }

    function _state(address token) internal view returns (RealmKeeperLens.TokenState memory) {
        return lens.keeperState(_one(token))[0];
    }

    //////////////////////// keeperState: per-asset state //////////////////////

    function test_keeperState_reportsEveryAssetOfTheSet() public view {
        RealmKeeperLens.TokenState memory s = _state(address(v4));

        assertTrue(s.isDividendToken, "not recognised as a dividend token");
        assertTrue(s.multiAsset, "current generation not detected");
        assertEq(s.assetCount, 2, "asset count");
        assertEq(s.assets.length, 2, "one entry per configured asset");

        assertEq(s.assets[0].asset, NATIVE, "asset 0");
        assertEq(s.assets[0].owed, 100e18, "asset 0 owed");
        assertEq(s.assets[0].pendingNative, 5e18, "asset 0 buffer");
        assertEq(s.assets[1].asset, DAI, "asset 1");
        assertEq(s.assets[1].owed, 200e18, "asset 1 owed");
        assertEq(s.assets[1].pendingNative, 7e18, "asset 1 buffer");
    }

    /// @dev The asset beyond `dividendAssetCount` is zeroed storage and must not be reported: a zeroed
    ///      entry is indistinguishable from an ungraduated native payout, which the keeper would fund.
    function test_keeperState_ignoresAssetsBeyondTheCount() public {
        v4.setAsset(2, USDC, 1e18, 1e18, uint40(block.timestamp));

        RealmKeeperLens.TokenState memory s = _state(address(v4));

        assertEq(s.assets.length, 2, "unconfigured asset leaked into the set");
    }

    function test_keeperState_reportsStalenessPerAsset() public {
        v4.setAsset(1, DAI, 200e18, 7e18, uint40(block.timestamp - 31 days));

        RealmKeeperLens.TokenState memory s = _state(address(v4));

        assertFalse(s.assets[0].stale, "live asset reported stale");
        assertTrue(s.assets[1].stale, "aged asset not reported stale");
        assertEq(s.assets[1].lastDistribution, uint40(block.timestamp - 31 days), "lastDistribution");
    }

    //////////////////////// keeperState: discriminators //////////////////////

    function test_keeperState_tellsTheVenuesApart() public view {
        RealmKeeperLens.TokenState memory four = _state(address(v4));
        RealmKeeperLens.TokenState memory two = _state(address(v2));

        assertTrue(four.isV4, "V4 not detected");
        assertFalse(four.isV2, "V4 token reported as V2");
        assertEq(four.burnPendingEth, 11e18, "burn buffer");
        assertEq(four.liquidityPendingEth, 13e18, "liquidity buffer");

        assertTrue(two.isV2, "V2 not detected");
        assertFalse(two.isV4, "V2 token reported as V4");
        assertEq(two.dividendPendingTokens, 17e18, "dividend token buffer");
        assertEq(two.liquidityPendingTokens, 19e18, "liquidity token buffer");
        assertEq(two.swapThreshold, v2.SWAP_THRESHOLD(), "swap threshold");
    }

    function test_keeperState_reportsTheImplementationConstants() public view {
        RealmKeeperLens.TokenState memory s = _state(address(v4));

        assertEq(s.dividendThreshold, v4.DIVIDEND_THRESHOLD(), "dividend threshold");
        assertEq(s.maxPerConversion, v4.MAX_DIVIDEND_PER_CONVERSION(), "max per conversion");
        assertEq(s.swapRegistry, v4.DIVIDEND_SWAP_REGISTRY(), "swap registry");
    }

    function test_keeperState_readsTheLegacyGenerationThroughItsOwnGetters() public {
        LegacyHarness legacy = new LegacyHarness(DAI, 42e18, 9e18, true);

        RealmKeeperLens.TokenState memory s = _state(address(legacy));

        assertTrue(s.isDividendToken, "legacy token not recognised");
        assertFalse(s.multiAsset, "legacy token reported as current generation");
        assertEq(s.assetCount, 1, "legacy tokens have exactly one asset");
        assertEq(s.assets[0].asset, DAI, "legacy asset");
        assertEq(s.assets[0].owed, 42e18, "legacy owed");
        assertEq(s.assets[0].pendingNative, 9e18, "legacy buffer");
        assertTrue(s.assets[0].stale, "legacy staleness");
    }

    //////////////////////// keeperState: tolerating the unknown //////////////////////

    /// @dev The batch is assembled off-chain from an indexer query. One bad row in it must cost that row
    ///      and nothing else — this is the `allowFailure: true` guarantee the keeper had from Multicall3.
    function test_keeperState_survivesAddressesThatAreNotTokens() public {
        address[] memory batch = new address[](5);
        batch[0] = address(v4);
        batch[1] = makeAddr("an EOA with no code");
        batch[2] = address(new NotAToken());
        batch[3] = NATIVE;
        batch[4] = address(v2);

        RealmKeeperLens.TokenState[] memory states = lens.keeperState(batch);

        assertTrue(states[0].isDividendToken, "first token lost");
        assertTrue(states[4].isDividendToken, "last token lost");
        for (uint256 i = 1; i < 4; ++i) {
            assertFalse(states[i].isDividendToken, "non-token reported as a token");
            assertEq(states[i].assets.length, 0, "non-token reported assets");
            assertEq(states[i].assetCount, 0, "non-token reported an asset count");
        }
    }

    function test_keeperState_keepsInputOrder() public {
        address[] memory batch = new address[](3);
        batch[0] = address(v2);
        batch[1] = address(new LegacyHarness(USDC, 1e18, 0, false));
        batch[2] = address(v4);

        RealmKeeperLens.TokenState[] memory states = lens.keeperState(batch);

        assertEq(states.length, 3, "one row per input");
        assertTrue(states[0].isV2, "row 0 is not the V2 token");
        assertEq(states[1].assets[0].asset, USDC, "row 1 is not the legacy token");
        assertTrue(states[2].isV4, "row 2 is not the V4 token");
    }

    function test_keeperState_acceptsAnEmptyBatch() public view {
        assertEq(lens.keeperState(new address[](0)).length, 0, "empty batch");
    }

    //////////////////////// payableHolders //////////////////////

    /// @dev `owed` is 200e18 and the floor 0.1% of it, so the cut sits at 0.2e18.
    function test_payableHolders_dropsZeroAndBelowFloorAccruals() public {
        v4.setAccrual(alice, 1, 1e18);
        v4.setAccrual(bob, 1, 0.1e18);
        v4.setAccrual(carol, 1, 0);

        address[] memory candidates = new address[](3);
        (candidates[0], candidates[1], candidates[2]) = (alice, bob, carol);

        address[] memory out = lens.payableHolders(address(v4), 1, candidates, FLOOR_BPS);

        assertEq(out.length, 1, "only the above-floor holder is worth a push");
        assertEq(out[0], alice, "wrong holder kept");
    }

    /// @dev The boundary is inclusive, matching the keeper's `>=`.
    function test_payableHolders_keepsAHolderExactlyOnTheFloor() public {
        v4.setAccrual(alice, 1, 0.2e18);

        address[] memory out = lens.payableHolders(address(v4), 1, _one(alice), FLOOR_BPS);

        assertEq(out.length, 1, "a holder exactly on the floor must be pushed");
    }

    /// @dev A zero floor still drops zero accruals — pushing to one spends gas paying nothing.
    function test_payableHolders_zeroFloorStillDropsZeroAccruals() public {
        v4.setAccrual(alice, 1, 1);

        address[] memory candidates = new address[](2);
        (candidates[0], candidates[1]) = (alice, bob);

        address[] memory out = lens.payableHolders(address(v4), 1, candidates, 0);

        assertEq(out.length, 1, "zero accrual survived a zero floor");
        assertEq(out[0], alice, "wrong holder kept");
    }

    /// @dev Accruals are per asset, so the same holder can be worth pushing on one leg and not another.
    function test_payableHolders_isPerAsset() public {
        v4.setAccrual(alice, 0, 50e18);

        assertEq(lens.payableHolders(address(v4), 0, _one(alice), FLOOR_BPS).length, 1, "asset 0");
        assertEq(lens.payableHolders(address(v4), 1, _one(alice), FLOOR_BPS).length, 0, "asset 1");
    }

    function test_payableHolders_readsTheLegacyGenerationsUnindexedPreview() public {
        LegacyHarness legacy = new LegacyHarness(DAI, 100e18, 0, false);
        legacy.setAccrual(alice, 1e18);

        address[] memory candidates = new address[](2);
        (candidates[0], candidates[1]) = (alice, bob);

        address[] memory out = lens.payableHolders(address(legacy), 0, candidates, FLOOR_BPS);

        assertEq(out.length, 1, "legacy preview not read");
        assertEq(out[0], alice, "wrong holder kept");
    }

    /// @dev Nothing owed means nothing was ever credited, so no accrual can exist to push.
    function test_payableHolders_returnsNothingWhenTheAssetOwesNothing() public {
        v4.setAsset(1, DAI, 0, 7e18, uint40(block.timestamp));
        v4.setAccrual(alice, 1, 1e18);

        assertEq(lens.payableHolders(address(v4), 1, _one(alice), FLOOR_BPS).length, 0, "owed == 0");
    }

    function test_payableHolders_returnsNothingForANonToken() public {
        address stranger = address(new NotAToken());

        assertEq(lens.payableHolders(stranger, 0, _one(alice), FLOOR_BPS).length, 0, "non-token");
    }

    //////////////////////// quoteLegs //////////////////////

    function test_quoteLegs_readsEachTokenQuotePair() public {
        v4.setQuoteLeg(DAI, 1e18, 2e18, 3e18);
        V4Harness other = new V4Harness();
        other.setQuoteLeg(USDC, 4e18, 5e18, 6e18);

        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(v4), address(other));
        address[] memory quotes = new address[](2);
        (quotes[0], quotes[1]) = (DAI, USDC);

        RealmKeeperLens.QuoteLeg[] memory legs = lens.quoteLegs(tokens, quotes);

        assertTrue(legs[0].ok && legs[1].ok, "legs not read");
        assertEq(legs[0].burnPending, 1e18, "leg 0 burn");
        assertEq(legs[0].liquidityPending, 2e18, "leg 0 liquidity");
        assertEq(legs[0].dividendPending[0], 3e18, "leg 0 dividends");
        assertEq(legs[1].burnPending, 4e18, "leg 1 burn");
        assertEq(legs[1].dividendPending[0], 6e18, "leg 1 dividends");
    }

    /// @dev A V2 token has no quote legs at all; the row is dropped, not reverted.
    function test_quoteLegs_marksUnreadableLegsNotOk() public view {
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(v2), address(v4));
        address[] memory quotes = new address[](2);
        (quotes[0], quotes[1]) = (DAI, DAI);

        RealmKeeperLens.QuoteLeg[] memory legs = lens.quoteLegs(tokens, quotes);

        assertFalse(legs[0].ok, "V2 token reported a quote leg");
        assertTrue(legs[1].ok, "V4 token's leg dropped");
    }

    function test_quoteLegs_rejectsMismatchedArrays() public {
        vm.expectRevert(RealmKeeperLens.LengthMismatch.selector);
        lens.quoteLegs(new address[](2), new address[](1));
    }

    //////////////////////// drift //////////////////////

    /// @dev The lens carries its own copy of the cap because an array length must be a file-level
    ///      constant. This is what stops the two drifting apart unnoticed.
    function test_assetCapMatchesTheToken() public view {
        assertEq(lens.MAX_DIVIDEND_ASSETS(), v4.MAX_DIVIDEND_ASSETS(), "lens and token disagree on the cap");
    }
}
