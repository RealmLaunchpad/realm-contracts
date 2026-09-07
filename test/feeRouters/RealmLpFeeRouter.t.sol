// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RealmLpFeeRouter} from "src/feeRouters/RealmLpFeeRouter.sol";
import {IRealmLpFeeRouter} from "src/interfaces/IRealmLpFeeRouter.sol";

/// @notice Treasury sink that intentionally rejects ETH so we can exercise the router's revert path.
contract RejectEth {
    receive() external payable {
        revert("rejected");
    }
}

/// @notice Stub token mimicking the `RealmToken` surface the router calls:
///         `totalSupply()` for marketcap math and `accrueFees()` for the creator slice.
contract MockRealmToken {
    uint256 internal _supply;
    uint256 public lastAccrued;
    uint256 public accrueCount;

    constructor(uint256 supply_) {
        _supply = supply_;
    }

    function totalSupply() external view returns (uint256) {
        return _supply;
    }

    function accrueFees() external payable {
        lastAccrued = msg.value;
        accrueCount++;
    }

    receive() external payable {}
}

/// @notice Tests for the marketcap-tiered LP fee router. Verifies tier resolution, the deposit
///         split, transfer semantics, access control, upgrade authorization, and the new
///         `LpFeesRouted(token, creator, treasury, liquidity)` event signature.
contract RealmLpFeeRouterTests is Test {
    event LpFeesRouted(address indexed token, uint256 creatorShare, uint256 treasuryShare, uint256 liquidityShare);

    // Mirrors the production-default tier policy.
    uint256 constant T1 = 30 ether;
    uint256 constant T2 = 150 ether;
    uint256 constant T3 = 300 ether;
    uint256 constant T4 = 600 ether;
    uint256 constant T5 = 900 ether;
    uint256 constant T6 = 1500 ether;

    uint16 constant TIER0_TREASURY_BPS = 4000;
    uint16 constant TIER1_TREASURY_BPS = 3500;
    uint16 constant TIER2_TREASURY_BPS = 3000;
    uint16 constant TIER3_TREASURY_BPS = 2500;
    uint16 constant TIER4_TREASURY_BPS = 2000;
    uint16 constant TIER5_TREASURY_BPS = 1500;
    uint16 constant TIER6_TREASURY_BPS = 1000;

    uint256 constant TOTAL_SUPPLY = 1_000_000_000e18;

    RealmLpFeeRouter router;
    RealmLpFeeRouter impl;
    MockRealmToken token;
    address treasury = makeAddr("treasury");
    address admin = makeAddr("admin");
    address attacker = makeAddr("attacker");

    function setUp() public {
        token = new MockRealmToken(TOTAL_SUPPLY);

        RealmLpFeeRouter.Config memory cfg = _defaultCfg();

        vm.startPrank(admin);
        impl = new RealmLpFeeRouter(treasury, cfg);
        router = RealmLpFeeRouter(
            payable(address(new ERC1967Proxy(address(impl), abi.encodeCall(RealmLpFeeRouter.initialize, ()))))
        );
        vm.stopPrank();
    }

    function _defaultCfg() internal pure returns (RealmLpFeeRouter.Config memory cfg) {
        cfg.thresholds = [T1, T2, T3, T4, T5, T6];
        cfg.treasuryBps = [
            TIER0_TREASURY_BPS,
            TIER1_TREASURY_BPS,
            TIER2_TREASURY_BPS,
            TIER3_TREASURY_BPS,
            TIER4_TREASURY_BPS,
            TIER5_TREASURY_BPS,
            TIER6_TREASURY_BPS
        ];
    }

    /// @dev Returns `(ethSwapAmount, tokenSwapAmount)` pair that yields `targetMcEth` marketcap
    ///      given the total supply: marketcap = ethSwapAmount * supply / tokenSwapAmount → with
    ///      ethSwapAmount = 1 ether, tokenSwapAmount = 1e18 * supply / targetMcEth.
    function _swapVolumeFor(uint256 targetMcEth)
        internal
        pure
        returns (uint256 ethSwapAmount, uint256 tokenSwapAmount)
    {
        ethSwapAmount = 1 ether;
        tokenSwapAmount = (ethSwapAmount * TOTAL_SUPPLY) / targetMcEth;
    }

    // ───────────────────────── treasury immutable ─────────────────────────

    function test_treasury_isImmutable() public view {
        assertEq(router.TREASURY(), treasury);
    }

    // ───────────────────────── deposit splits ─────────────────────────

    function _depositAndCheckSplit(uint256 lpFee, uint256 targetMcEth, uint16 expectedTreasuryBps) internal {
        (uint256 e, uint256 t) = _swapVolumeFor(targetMcEth);
        uint256 treasuryBefore = treasury.balance;
        uint256 tokenBefore = token.lastAccrued();
        uint256 expectedTreasury = (lpFee * expectedTreasuryBps) / 10_000;
        uint256 expectedCreator = lpFee - expectedTreasury;

        deal(address(this), lpFee);
        // Verify the router emits the new 4-arg event with `liquidityShare = 0`.
        vm.expectEmit(true, false, false, true);
        emit LpFeesRouted(address(token), expectedCreator, expectedTreasury, 0);
        router.depositLpFees{value: lpFee}(address(token), e, t);

        assertEq(treasury.balance - treasuryBefore, expectedTreasury, "treasury balance delta");
        assertEq(token.lastAccrued() - tokenBefore, expectedCreator, "creator share via accrueFees");
    }

    function test_deposit_tier0_split() public {
        _depositAndCheckSplit(1 ether, 12 ether, TIER0_TREASURY_BPS);
    }

    function test_deposit_tier1_split() public {
        _depositAndCheckSplit(1 ether, 50 ether, TIER1_TREASURY_BPS);
    }

    function test_deposit_tier2_split() public {
        _depositAndCheckSplit(1 ether, 200 ether, TIER2_TREASURY_BPS);
    }

    function test_deposit_tier3_split() public {
        _depositAndCheckSplit(1 ether, 400 ether, TIER3_TREASURY_BPS);
    }

    function test_deposit_tier4_split() public {
        _depositAndCheckSplit(1 ether, 700 ether, TIER4_TREASURY_BPS);
    }

    function test_deposit_tier5_split() public {
        _depositAndCheckSplit(1 ether, 1000 ether, TIER5_TREASURY_BPS);
    }

    function test_deposit_tier6_split() public {
        _depositAndCheckSplit(1 ether, 2000 ether, TIER6_TREASURY_BPS);
    }

    /// @notice Exact tier-boundary marketcap maps to the upper tier (inclusive lower bound).
    function test_deposit_tier1_inclusiveLowerBound() public {
        _depositAndCheckSplit(1 ether, T1, TIER1_TREASURY_BPS);
    }

    function test_deposit_zeroValue_isNoop() public {
        uint256 treasuryBefore = treasury.balance;
        uint256 accrueCountBefore = token.accrueCount();
        (uint256 e, uint256 t) = _swapVolumeFor(12 ether);
        router.depositLpFees(address(token), e, t);
        assertEq(treasury.balance, treasuryBefore, "treasury untouched on zero deposit");
        assertEq(token.accrueCount(), accrueCountBefore, "creator path should not be hit on zero value");
    }

    /// @notice Zero treasuryBps in a tier means the creator gets the full deposit and no transfer
    ///         is attempted to the treasury (the .call branch is skipped).
    function test_deposit_zeroTreasuryShare_skipsTreasuryCall() public {
        RealmLpFeeRouter.Config memory cfg = _defaultCfg();
        cfg.treasuryBps[6] = 0; // full creator share at top tier

        // Use a rejecting treasury to prove the treasury branch is entirely skipped.
        address rejectingTreasury = address(new RejectEth());
        RealmLpFeeRouter implBad = new RealmLpFeeRouter(rejectingTreasury, cfg);
        RealmLpFeeRouter routerBad = RealmLpFeeRouter(
            payable(address(new ERC1967Proxy(address(implBad), abi.encodeCall(RealmLpFeeRouter.initialize, ()))))
        );

        (uint256 e, uint256 t) = _swapVolumeFor(2000 ether); // tier 6
        deal(address(this), 1 ether);
        routerBad.depositLpFees{value: 1 ether}(address(token), e, t);
        assertEq(token.lastAccrued(), 1 ether, "creator should receive full amount when treasury BPS == 0");
    }

    function test_deposit_treasuryRejects_reverts() public {
        address rejectingTreasury = address(new RejectEth());
        RealmLpFeeRouter implBad = new RealmLpFeeRouter(rejectingTreasury, _defaultCfg());
        RealmLpFeeRouter routerBad = RealmLpFeeRouter(
            payable(address(new ERC1967Proxy(address(implBad), abi.encodeCall(RealmLpFeeRouter.initialize, ()))))
        );

        (uint256 e, uint256 t) = _swapVolumeFor(12 ether);
        deal(address(this), 1 ether);
        vm.expectRevert(RealmLpFeeRouter.TreasuryTransferFailed.selector);
        routerBad.depositLpFees{value: 1 ether}(address(token), e, t);
    }

    function test_deposit_zeroTokenAmount_routesAsTier0() public {
        // Degenerate swap (no tokens crossed): marketcap formula returns 0, so the router falls
        // back to tier 0.
        uint256 lpFee = 1 ether;
        uint256 expectedTreasury = (lpFee * uint256(TIER0_TREASURY_BPS)) / 10_000;
        deal(address(this), lpFee);
        uint256 treasuryBefore = treasury.balance;
        router.depositLpFees{value: lpFee}(address(token), 1 ether, 0);
        assertEq(treasury.balance - treasuryBefore, expectedTreasury, "tier 0 treasury share on zero token amount");
        assertEq(token.lastAccrued(), lpFee - expectedTreasury, "creator gets the rest");
    }

    // ───────────────────────── access control & upgrades ─────────────────────────

    function test_initialize_revertsOnSecondCall() public {
        vm.expectRevert();
        router.initialize();
    }

    function test_upgradeTo_revertsForNonOwner() public {
        RealmLpFeeRouter newImpl = new RealmLpFeeRouter(treasury, _defaultCfg());
        vm.prank(attacker);
        vm.expectRevert();
        router.upgradeToAndCall(address(newImpl), "");
    }

    function test_upgradeTo_succeedsForOwner() public {
        RealmLpFeeRouter newImpl = new RealmLpFeeRouter(treasury, _defaultCfg());
        vm.prank(admin);
        router.upgradeToAndCall(address(newImpl), "");
        // Sanity-check the immutable comes from the new impl.
        assertEq(router.TREASURY(), treasury);
    }

    // ───────────────────────── constructor validation ─────────────────────────

    function test_constructor_revertsOnZeroTreasury() public {
        vm.expectRevert(RealmLpFeeRouter.InvalidTreasury.selector);
        new RealmLpFeeRouter(address(0), _defaultCfg());
    }

    function test_constructor_revertsOnNonAscendingThresholds() public {
        RealmLpFeeRouter.Config memory cfg = _defaultCfg();
        cfg.thresholds[3] = cfg.thresholds[2]; // break strict-ascending order
        vm.expectRevert(RealmLpFeeRouter.InvalidThresholds.selector);
        new RealmLpFeeRouter(treasury, cfg);
    }

    /// @notice Regression: `thresholds[0] == 0` would silently make tier 0 unreachable.
    function test_constructor_revertsOnZeroFirstThreshold() public {
        RealmLpFeeRouter.Config memory cfg = _defaultCfg();
        cfg.thresholds[0] = 0;
        vm.expectRevert(RealmLpFeeRouter.InvalidThresholds.selector);
        new RealmLpFeeRouter(treasury, cfg);
    }

    function test_constructor_revertsOnTreasuryBpsAbove100Pct() public {
        RealmLpFeeRouter.Config memory cfg = _defaultCfg();
        cfg.treasuryBps[2] = 10_001;
        vm.expectRevert(RealmLpFeeRouter.InvalidTreasuryBps.selector);
        new RealmLpFeeRouter(treasury, cfg);
    }

    // ───────────────────────── IRealmLpFeeRouter interface ─────────────────────────

    function test_interface_id_matchesSelector() public pure {
        // Smoke test: the canonical selector must remain stable across upgrades.
        bytes4 sel = IRealmLpFeeRouter.depositLpFees.selector;
        assertEq(sel, bytes4(keccak256("depositLpFees(address,uint256,uint256)")));
    }

    receive() external payable {}
}
