// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SwapLpFeeRouter} from "src/feeRouters/SwapLpFeeRouter.sol";
import {ISwapLpFeeRouter} from "src/interfaces/ISwapLpFeeRouter.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @notice Treasury sink that intentionally rejects ETH so we can exercise the router's revert path.
contract RejectEth {
    receive() external payable {
        revert("rejected");
    }
}

/// @notice Stub token mimicking the `RealmToken` surface the router calls: `accrueFees()` for the
///         creator slice, and its ERC20 twin, which PULLS the approved amount exactly as the real token
///         does (so the test sees whether the approval was sized to the split).
contract MockRealmToken {
    uint256 public lastAccrued;
    uint256 public accrueCount;
    address public lastAsset;
    uint256 public lastAssetAmount;

    function accrueFees() external payable {
        lastAccrued = msg.value;
        accrueCount++;
    }

    function accrueFees(address asset, uint256 amount) external {
        lastAsset = asset;
        lastAssetAmount = amount;
        accrueCount++;
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
    }

    receive() external payable {}
}

/// @notice A plain 18-decimal ERC20 standing in for a quote currency.
contract MockQuote is ERC20 {
    constructor() ERC20("Quote", "Q") {}

    function mintTo(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice A quote that burns 10% of every transfer. The router must split what it RECEIVED, not what
///         it was told to pull, or it would hand out more than it holds.
contract FeeOnTransferQuote is MockQuote {
    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) return super._update(from, to, value);
        uint256 fee = value / 10;
        super._update(from, address(0xdEaD), fee);
        super._update(from, to, value - fee);
    }
}

/// @notice Tests for the flat 30/70 LP fee router. Verifies the deposit split, transfer semantics,
///         access control, upgrade authorization, and the
///         `LpFeesRouted(token, creator, treasury, liquidity)` event signature.
contract SwapLpFeeRouterTests is Test {
    event LpFeesRouted(address indexed token, uint256 creatorShare, uint256 treasuryShare, uint256 liquidityShare);

    uint16 constant TREASURY_BPS = 3000;

    SwapLpFeeRouter router;
    SwapLpFeeRouter impl;
    MockRealmToken token;
    address treasury = makeAddr("treasury");
    address admin = makeAddr("admin");
    address attacker = makeAddr("attacker");

    function setUp() public {
        token = new MockRealmToken();

        vm.startPrank(admin);
        impl = new SwapLpFeeRouter(treasury);
        router = SwapLpFeeRouter(
            payable(address(new ERC1967Proxy(address(impl), abi.encodeCall(SwapLpFeeRouter.initialize, ()))))
        );
        vm.stopPrank();
    }

    // ───────────────────────── immutables / constants ─────────────────────────

    function test_treasury_isImmutable() public view {
        assertEq(router.TREASURY(), treasury);
    }

    function test_treasuryBps_is30Pct() public view {
        assertEq(router.TREASURY_BPS(), TREASURY_BPS);
    }

    // ───────────────────────── deposit splits ─────────────────────────

    function _depositAndCheckSplit(uint256 lpFee, uint256 ethSwapAmount, uint256 tokenSwapAmount) internal {
        uint256 treasuryBefore = treasury.balance;
        uint256 expectedTreasury = (lpFee * TREASURY_BPS) / 10_000;
        uint256 expectedCreator = lpFee - expectedTreasury;

        deal(address(this), lpFee);
        vm.expectEmit(true, false, false, true);
        emit LpFeesRouted(address(token), expectedCreator, expectedTreasury, 0);
        router.depositLpFees{value: lpFee}(address(token), ethSwapAmount, tokenSwapAmount);

        assertEq(treasury.balance - treasuryBefore, expectedTreasury, "treasury balance delta");
        assertEq(token.lastAccrued(), expectedCreator, "creator share via accrueFees");
    }

    function test_deposit_split_30_70() public {
        _depositAndCheckSplit(1 ether, 1 ether, 1e24);
    }

    /// @notice The swap amounts are ABI ballast: any value (including a degenerate zero token amount
    ///         or huge marketcap) yields the same flat split.
    function test_deposit_split_ignoresSwapAmounts() public {
        _depositAndCheckSplit(1 ether, 1 ether, 0);
        _depositAndCheckSplit(1 ether, 0, 0);
        _depositAndCheckSplit(1 ether, 1 ether, 1);
        _depositAndCheckSplit(1 ether, 1, type(uint256).max);
    }

    function testFuzz_deposit_split(uint96 lpFee, uint256 e, uint256 t) public {
        vm.assume(lpFee > 0);
        _depositAndCheckSplit(lpFee, e, t);
    }

    function test_deposit_zeroValue_isNoop() public {
        uint256 treasuryBefore = treasury.balance;
        uint256 accrueCountBefore = token.accrueCount();
        router.depositLpFees(address(token), 1 ether, 1e24);
        assertEq(treasury.balance, treasuryBefore, "treasury untouched on zero deposit");
        assertEq(token.accrueCount(), accrueCountBefore, "creator path should not be hit on zero value");
    }

    /// @notice A deposit too small to yield a non-zero treasury share goes entirely to the creator and
    ///         skips the treasury `.call` branch.
    function test_deposit_dust_skipsTreasuryCall() public {
        address rejectingTreasury = address(new RejectEth());
        SwapLpFeeRouter implBad = new SwapLpFeeRouter(rejectingTreasury);
        SwapLpFeeRouter routerBad = SwapLpFeeRouter(
            payable(address(new ERC1967Proxy(address(implBad), abi.encodeCall(SwapLpFeeRouter.initialize, ()))))
        );

        deal(address(this), 3);
        routerBad.depositLpFees{value: 3}(address(token), 1 ether, 1e24); // 3 * 3000 / 10000 == 0
        assertEq(token.lastAccrued(), 3, "creator should receive the full dust deposit");
    }

    function test_deposit_treasuryRejects_reverts() public {
        address rejectingTreasury = address(new RejectEth());
        SwapLpFeeRouter implBad = new SwapLpFeeRouter(rejectingTreasury);
        SwapLpFeeRouter routerBad = SwapLpFeeRouter(
            payable(address(new ERC1967Proxy(address(implBad), abi.encodeCall(SwapLpFeeRouter.initialize, ()))))
        );

        deal(address(this), 1 ether);
        vm.expectRevert(SwapLpFeeRouter.TreasuryTransferFailed.selector);
        routerBad.depositLpFees{value: 1 ether}(address(token), 1 ether, 1e24);
    }

    // ───────────────────────── ERC20 deposit splits ─────────────────────────

    event LpAssetFeesRouted(
        address indexed token,
        address indexed asset,
        uint256 creatorShare,
        uint256 treasuryShare,
        uint256 liquidityShare
    );

    /// @dev `address(0)` is the native sentinel and belongs on the payable overload; accepting it here
    ///      would make an ERC20 call on an address with no code and split nothing.
    function test_depositLpFeesAsset_revertsOnNativeSentinel() public {
        vm.expectRevert(SwapLpFeeRouter.InvalidAsset.selector);
        router.depositLpFees(address(token), address(0), 1 ether, 0, 0);
    }

    /// @dev Zero pulls nothing and touches neither destination — the shape the hook relies on when a
    ///      ledger happens to be empty.
    function test_depositLpFeesAsset_zeroAmountIsNoop() public {
        MockQuote quote = new MockQuote();
        uint256 accrueCountBefore = token.accrueCount();
        router.depositLpFees(address(token), address(quote), 0, 0, 0);
        assertEq(quote.balanceOf(treasury), 0, "treasury untouched");
        assertEq(token.accrueCount(), accrueCountBefore, "creator path not hit");
    }

    /// @dev The same flat 30/70 the native overload applies, in the quote's own units, PULLED from the
    ///      caller rather than received as value.
    function test_depositLpFeesAsset_split_30_70() public {
        MockQuote quote = new MockQuote();
        quote.mintTo(address(this), 1_000e18);
        quote.approve(address(router), type(uint256).max);

        vm.expectEmit(true, true, false, true);
        emit LpAssetFeesRouted(address(token), address(quote), 700e18, 300e18, 0);
        router.depositLpFees(address(token), address(quote), 1_000e18, 0, 0);

        assertEq(quote.balanceOf(treasury), 300e18, "treasury's 30%, in the quote");
        assertEq(token.lastAsset(), address(quote), "the token was told which currency");
        assertEq(token.lastAssetAmount(), 700e18, "creator's 70%");
        assertEq(quote.balanceOf(address(token)), 700e18, "and the token pulled exactly that");
        assertEq(quote.balanceOf(address(router)), 0, "the router keeps nothing");
    }

    /// @dev A fee-on-transfer quote delivers less than `amount`. The router splits what ARRIVED — if it
    ///      split the nominal amount instead, the creator's approval would exceed its balance and the
    ///      whole routing would revert.
    function test_depositLpFeesAsset_feeOnTransfer_splitsOnReceivedAmount() public {
        FeeOnTransferQuote quote = new FeeOnTransferQuote();
        quote.mintTo(address(this), 1_000e18);
        quote.approve(address(router), type(uint256).max);

        router.depositLpFees(address(token), address(quote), 1_000e18, 0, 0);

        // 10% burned on the pull: 900 received, then 30/70 of that, and 10% burned again on each leg out.
        assertEq(quote.balanceOf(treasury), 270e18 - 27e18, "treasury got 30% of what arrived, less its own fee");
        assertEq(token.lastAssetAmount(), 630e18, "the creator slice is 70% of what arrived, not of the nominal");
        assertEq(quote.balanceOf(address(router)), 0, "and nothing is stranded in the router");
    }

    // ───────────────────────── access control & upgrades ─────────────────────────

    function test_initialize_revertsOnSecondCall() public {
        vm.expectRevert();
        router.initialize();
    }

    function test_upgradeTo_revertsForNonOwner() public {
        SwapLpFeeRouter newImpl = new SwapLpFeeRouter(treasury);
        vm.prank(attacker);
        vm.expectRevert();
        router.upgradeToAndCall(address(newImpl), "");
    }

    function test_upgradeTo_succeedsForOwner() public {
        address newTreasury = makeAddr("newTreasury");
        SwapLpFeeRouter newImpl = new SwapLpFeeRouter(newTreasury);
        vm.prank(admin);
        router.upgradeToAndCall(address(newImpl), "");
        // Sanity-check the immutable comes from the new impl.
        assertEq(router.TREASURY(), newTreasury);
    }

    // ───────────────────────── constructor validation ─────────────────────────

    function test_constructor_revertsOnZeroTreasury() public {
        vm.expectRevert(SwapLpFeeRouter.InvalidTreasury.selector);
        new SwapLpFeeRouter(address(0));
    }

    // ───────────────────────── ISwapLpFeeRouter interface ─────────────────────────

    /// @dev The wire format both hook generations dispatch on must stay stable across upgrades.
    ///      Asserted by CALLING each selector rather than reading `.selector`, which Solidity refuses to
    ///      resolve now that `depositLpFees` is overloaded for ERC20-quoted pools. Both calls are
    ///      zero-amount, which every implementation must treat as a no-op that still succeeds.
    function test_interface_selectors_dispatch() public {
        (bool nativeOk,) = address(router).call{value: 0}(
            abi.encodeWithSignature("depositLpFees(address,uint256,uint256)", address(0xbeef), uint256(0), uint256(0))
        );
        assertTrue(nativeOk, "native depositLpFees selector must dispatch");

        (bool assetOk,) = address(router)
            .call(
                abi.encodeWithSignature(
                    "depositLpFees(address,address,uint256,uint256,uint256)",
                    address(0xbeef),
                    address(0xdead),
                    uint256(0),
                    uint256(0),
                    uint256(0)
                )
            );
        assertTrue(assetOk, "asset depositLpFees selector must dispatch");
    }

    receive() external payable {}
}
