// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TaxTokenUniV4BaseTests} from "test/graduators/taxToken.base.t.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {IRealmClaims} from "src/interfaces/IRealmClaims.sol";
import {IRealmTaxableToken} from "src/interfaces/IRealmTaxableToken.sol";
import {LivoSwapHook} from "src/hooks/LivoSwapHook.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IV4Router} from "lib/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {IUniversalRouter} from "src/interfaces/IUniswapV4UniversalRouter.sol";
import {IPermit2} from "lib/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";

/// @notice Test-only router stub that reverts on every call. Used with `vm.etch` to exercise the
///         hook's `try/catch` fallback to `IRealmToken.accrueFees`.
contract RevertingRouter {
    fallback() external payable {
        revert("router down");
    }
}

/// @notice Test-only router stub that burns all forwarded gas in an infinite hash loop.
///         Used with `vm.etch` to exercise the hook's `ROUTER_GAS_LIMIT` defense — the OOG
///         inside the bounded call should still leave enough gas in the catch frame to run the
///         `accrueFees` fallback.
contract GasBurningRouter {
    fallback() external payable {
        bytes32 h = bytes32(uint256(1));
        // Loop until OOG. The router-side OOG must NOT propagate to the caller's frame.
        while (true) {
            h = keccak256(abi.encode(h));
        }
    }
}

/// @notice Test-only router stub that echoes the `(ethSwapAmount, tokenSwapAmount)` the hook
///         forwards, so a test can assert the marketcap basis the hook feeds the router.
contract RecordingRouter {
    event Recorded(uint256 ethSwapAmount, uint256 tokenSwapAmount, uint256 value);

    function depositLpFees(address, uint256 ethSwapAmount, uint256 tokenSwapAmount) external payable {
        emit Recorded(ethSwapAmount, tokenSwapAmount, msg.value);
    }
}

/// @notice Tests for hook-based LP fees (1% charged by LivoSwapHook).
/// @dev    All these tests run with marketcap below tier 1 (30 ETH), so the active split is
///         tier 0: 40% treasury / 60% creator.
contract LivoSwapHookLpFeesTests is TaxTokenUniV4BaseTests {
    /// @dev Tier-0 treasury BPS — keep tests symbolic so a future tier rebalance only touches one place.
    uint16 constant TIER0_TREASURY_BPS = 4000;
    /// @dev Tier-0 creator BPS = 10_000 - TIER0_TREASURY_BPS.
    uint16 constant TIER0_CREATOR_BPS = 10_000 - TIER0_TREASURY_BPS;
    uint16 constant LP_FEE_BPS = 100; // 1%

    function setUp() public override {
        super.setUp();
    }

    function _pendingCreatorFees(address token) internal view returns (uint256) {
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        return IRealmClaims(IRealmToken(token).feeHandler()).getClaimable(tokens, creator)[0];
    }

    /// @notice Buy charges 1% LP fee, split 40/60 treasury/creator at tier 0.
    function test_buyChargesLpFee_splitCreatorTreasury() public createDefaultTaxToken {
        _graduateToken();

        uint256 creatorFeesBefore = _pendingCreatorFees(testToken);
        uint256 treasuryBefore = treasury.balance;

        uint256 buyAmount = 1 ether;
        deal(buyer, buyAmount);
        _swapBuy(buyer, buyAmount, 0, true);

        uint256 creatorFeesAfter = _pendingCreatorFees(testToken);
        uint256 treasuryAfter = treasury.balance;

        uint256 creatorLpFee = creatorFeesAfter - creatorFeesBefore;
        uint256 treasuryLpFee = treasuryAfter - treasuryBefore;

        uint256 totalLpFee = (buyAmount * LP_FEE_BPS) / 10_000;
        uint256 expectedTreasury = (totalLpFee * TIER0_TREASURY_BPS) / 10_000;
        uint256 expectedCreator = totalLpFee - expectedTreasury;

        assertApproxEqAbs(creatorLpFee, expectedCreator, 1, "Creator should receive tier-0 LP fee share");
        assertApproxEqAbs(treasuryLpFee, expectedTreasury, 1, "Treasury should receive tier-0 LP fee share");
        assertApproxEqAbs(creatorLpFee + treasuryLpFee, totalLpFee, 1, "Total LP fee should be ~1%");
    }

    /// @notice Sell charges 1% LP fee split per tier-0.
    function test_sellChargesLpFee() public createDefaultTaxToken {
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, DEADLINE);
        _graduateToken();

        // Warp past tax period so only LP fee applies.
        vm.warp(block.timestamp + DEFAULT_TAX_DURATION + 1);

        uint256 creatorFeesBefore = _pendingCreatorFees(testToken);
        uint256 treasuryBefore = treasury.balance;
        uint256 buyerEthBefore = buyer.balance;

        uint256 sellAmount = IERC20(testToken).balanceOf(buyer) / 2;
        _swapSell(buyer, sellAmount, 0, true);

        uint256 ethReceived = buyer.balance - buyerEthBefore;
        uint256 creatorLpFee = _pendingCreatorFees(testToken) - creatorFeesBefore;
        uint256 treasuryLpFee = treasury.balance - treasuryBefore;
        uint256 totalLpFee = creatorLpFee + treasuryLpFee;

        // LP fee is 1% of gross ETH output; gross = ethReceived + totalLpFee.
        uint256 grossEth = ethReceived + totalLpFee;
        uint256 expectedLpFee = (grossEth * LP_FEE_BPS) / 10_000;

        assertApproxEqAbs(totalLpFee, expectedLpFee, 2, "Total LP fee should be ~1% of gross ETH");
        uint256 expectedTreasury = (expectedLpFee * TIER0_TREASURY_BPS) / 10_000;
        assertApproxEqAbs(treasuryLpFee, expectedTreasury, 2, "Treasury share should match tier-0");
    }

    /// @notice Sell stacks LP fee + sell tax during active tax period.
    function test_sellStacksLpFeeAndSellTax() public createDefaultTaxToken {
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, DEADLINE);
        _graduateToken();

        uint256 creatorFeesBefore = _pendingCreatorFees(testToken);
        uint256 treasuryBefore = treasury.balance;
        uint256 buyerEthBefore = buyer.balance;

        uint256 sellAmount = IERC20(testToken).balanceOf(buyer) / 2;
        _swapSell(buyer, sellAmount, 0, true);

        uint256 ethReceived = buyer.balance - buyerEthBefore;
        uint256 creatorFeesAccrued = _pendingCreatorFees(testToken) - creatorFeesBefore;
        uint256 treasuryLpFee = treasury.balance - treasuryBefore;

        // Creator fees = tier-0 LP creator share + 100% of sell tax.
        // Treasury gets only tier-0 LP treasury share.
        uint256 grossEth = ethReceived + creatorFeesAccrued + treasuryLpFee;

        uint256 totalLpFee = (grossEth * LP_FEE_BPS) / 10_000;
        uint256 expectedTreasuryLpFee = (totalLpFee * TIER0_TREASURY_BPS) / 10_000;
        uint256 expectedCreatorLpFee = totalLpFee - expectedTreasuryLpFee;
        uint256 expectedSellTax = (grossEth * DEFAULT_SELL_TAX_BPS) / 10_000;

        assertApproxEqAbs(treasuryLpFee, expectedTreasuryLpFee, 2, "Treasury should get tier-0 LP fee share");
        assertApproxEqAbs(
            creatorFeesAccrued,
            expectedCreatorLpFee + expectedSellTax,
            2,
            "Creator should get tier-0 LP fee share + sell tax"
        );
    }

    /// @notice After tax period expires, only LP fee remains (no sell tax).
    function test_onlyLpFeeAfterTaxExpires() public createDefaultTaxToken {
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, DEADLINE);
        _graduateToken();

        vm.warp(block.timestamp + DEFAULT_TAX_DURATION + 1);

        uint256 creatorFeesBefore = _pendingCreatorFees(testToken);
        uint256 treasuryBefore = treasury.balance;
        uint256 buyerEthBefore = buyer.balance;

        uint256 sellAmount = IERC20(testToken).balanceOf(buyer) / 2;
        _swapSell(buyer, sellAmount, 0, true);

        uint256 ethReceived = buyer.balance - buyerEthBefore;
        uint256 creatorLpFee = _pendingCreatorFees(testToken) - creatorFeesBefore;
        uint256 treasuryLpFee = treasury.balance - treasuryBefore;
        uint256 totalLpFee = creatorLpFee + treasuryLpFee;
        uint256 grossEth = ethReceived + totalLpFee;

        uint256 expectedLpFee = (grossEth * LP_FEE_BPS) / 10_000;
        uint256 expectedTreasury = (expectedLpFee * TIER0_TREASURY_BPS) / 10_000;

        assertApproxEqAbs(totalLpFee, expectedLpFee, 2, "Only LP fee (~1%) should be charged after tax expires");
        assertApproxEqAbs(treasuryLpFee, expectedTreasury, 2, "LP fee split should follow tier-0");
    }

    /// @notice Swaps revert before graduation.
    function test_noFeesBeforeGraduation() public createDefaultTaxToken {
        deal(buyer, 1 ether);
        _swapBuy(buyer, 1 ether, 0, false);
    }

    /// @notice Buy charges tier-0 LP fee split + buy tax (100% creator) during active tax period.
    function test_buyChargesBuyTaxAndLpFee() public {
        uint16 buyTax = 300; // 3%
        testToken = _createTaxToken(buyTax, DEFAULT_SELL_TAX_BPS, DEFAULT_TAX_DURATION);
        _graduateToken();

        uint256 creatorFeesBefore = _pendingCreatorFees(testToken);
        uint256 treasuryBefore = treasury.balance;

        uint256 buyAmount = 1 ether;
        deal(buyer, buyAmount);
        _swapBuy(buyer, buyAmount, 0, true);

        uint256 creatorFeesAccrued = _pendingCreatorFees(testToken) - creatorFeesBefore;
        uint256 treasuryLpFee = treasury.balance - treasuryBefore;

        uint256 totalLpFee = (buyAmount * LP_FEE_BPS) / 10_000;
        uint256 expectedTreasuryLpFee = (totalLpFee * TIER0_TREASURY_BPS) / 10_000;
        uint256 expectedCreatorLpFee = totalLpFee - expectedTreasuryLpFee;
        uint256 expectedBuyTax = (buyAmount * buyTax) / 10_000;

        assertApproxEqAbs(treasuryLpFee, expectedTreasuryLpFee, 1, "Treasury should get tier-0 LP fee share");
        assertApproxEqAbs(
            creatorFeesAccrued, expectedCreatorLpFee + expectedBuyTax, 1, "Creator should get LP share + buy tax"
        );
    }

    /// @notice After tax period expires, buy only charges LP fee (no buy tax).
    function test_buyOnlyLpFeeAfterTaxExpires() public {
        uint16 buyTax = 300;
        testToken = _createTaxToken(buyTax, DEFAULT_SELL_TAX_BPS, DEFAULT_TAX_DURATION);
        _graduateToken();

        vm.warp(block.timestamp + DEFAULT_TAX_DURATION + 1);

        uint256 creatorFeesBefore = _pendingCreatorFees(testToken);
        uint256 treasuryBefore = treasury.balance;

        uint256 buyAmount = 1 ether;
        deal(buyer, buyAmount);
        _swapBuy(buyer, buyAmount, 0, true);

        uint256 creatorLpFee = _pendingCreatorFees(testToken) - creatorFeesBefore;
        uint256 treasuryLpFee = treasury.balance - treasuryBefore;
        uint256 totalLpFee = creatorLpFee + treasuryLpFee;

        uint256 expectedLpFee = (buyAmount * LP_FEE_BPS) / 10_000;
        uint256 expectedTreasury = (expectedLpFee * TIER0_TREASURY_BPS) / 10_000;

        assertApproxEqAbs(totalLpFee, expectedLpFee, 1, "Only LP fee (~1%) should be charged after tax expires");
        assertApproxEqAbs(treasuryLpFee, expectedTreasury, 1, "LP fee split should follow tier-0");
    }

    /// @notice Both buy and sell are taxed during active tax period.
    function test_buyAndSellBothTaxed() public {
        uint16 buyTax = 300;
        testToken = _createTaxToken(buyTax, DEFAULT_SELL_TAX_BPS, DEFAULT_TAX_DURATION);

        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, DEADLINE);
        _graduateToken();

        // --- Buy ---
        uint256 creatorFeesBefore = _pendingCreatorFees(testToken);
        uint256 treasuryBefore = treasury.balance;

        uint256 buyAmount = 0.5 ether;
        deal(buyer, buyAmount);
        _swapBuy(buyer, buyAmount, 0, true);

        uint256 creatorFeesFromBuy = _pendingCreatorFees(testToken) - creatorFeesBefore;
        uint256 treasuryFromBuy = treasury.balance - treasuryBefore;

        uint256 totalLpFeeBuy = (buyAmount * LP_FEE_BPS) / 10_000;
        uint256 expectedTreasuryLpBuy = (totalLpFeeBuy * TIER0_TREASURY_BPS) / 10_000;
        uint256 expectedCreatorLpBuy = totalLpFeeBuy - expectedTreasuryLpBuy;
        uint256 expectedBuyTax = (buyAmount * buyTax) / 10_000;

        assertApproxEqAbs(treasuryFromBuy, expectedTreasuryLpBuy, 1, "Treasury LP share mismatch on buy");
        assertApproxEqAbs(
            creatorFeesFromBuy, expectedCreatorLpBuy + expectedBuyTax, 1, "Creator LP+tax mismatch on buy"
        );

        // --- Sell ---
        creatorFeesBefore = _pendingCreatorFees(testToken);
        treasuryBefore = treasury.balance;
        uint256 buyerEthBefore = buyer.balance;

        uint256 sellAmount = IERC20(testToken).balanceOf(buyer) / 4;
        _swapSell(buyer, sellAmount, 0, true);

        uint256 ethReceived = buyer.balance - buyerEthBefore;
        uint256 creatorFeesFromSell = _pendingCreatorFees(testToken) - creatorFeesBefore;
        uint256 treasuryFromSell = treasury.balance - treasuryBefore;

        uint256 grossEth = ethReceived + creatorFeesFromSell + treasuryFromSell;
        uint256 totalLpFeeSell = (grossEth * LP_FEE_BPS) / 10_000;
        uint256 expectedTreasuryLpSell = (totalLpFeeSell * TIER0_TREASURY_BPS) / 10_000;
        uint256 expectedCreatorLpSell = totalLpFeeSell - expectedTreasuryLpSell;
        uint256 expectedSellTax = (grossEth * DEFAULT_SELL_TAX_BPS) / 10_000;

        assertApproxEqAbs(treasuryFromSell, expectedTreasuryLpSell, 2, "Treasury LP share mismatch on sell");
        assertApproxEqAbs(
            creatorFeesFromSell, expectedCreatorLpSell + expectedSellTax, 2, "Creator LP+tax mismatch on sell"
        );
    }

    // ─── LivoSwapBuy / LivoSwapSell event tests ────────────────────────

    bytes32 constant HOOK_SWAP_BUY_SIG = keccak256("LivoSwapBuy(address,address,uint256,uint256,uint256)");
    bytes32 constant HOOK_SWAP_SELL_SIG = keccak256("LivoSwapSell(address,address,uint256,uint256,uint256)");

    function _findLog(Vm.Log[] memory logs, bytes32 sig) internal pure returns (Vm.Log memory) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                return logs[i];
            }
        }
        revert("event not found");
    }

    /// @notice Buy emits LivoSwapBuy with correct fields.
    function test_buyEmitsLivoSwapBuy() public createDefaultTaxToken {
        _graduateToken();

        uint256 buyAmount = 1 ether;
        deal(buyer, buyAmount);

        vm.recordLogs();
        _swapBuy(buyer, buyAmount, 0, true);
        Vm.Log memory log = _findLog(vm.getRecordedLogs(), HOOK_SWAP_BUY_SIG);

        assertEq(address(uint160(uint256(log.topics[1]))), testToken, "token mismatch");

        (uint256 ethIn, uint256 tokensOut, uint256 ethFees) = abi.decode(log.data, (uint256, uint256, uint256));

        assertEq(ethIn, buyAmount, "ethIn should be buy amount");
        assertGt(tokensOut, 0, "tokensOut should be > 0");
        // No buy tax on default token, only 1% LP fee.
        assertEq(ethFees, buyAmount / 100, "ethFees should be 1% LP fee");
    }

    /// @notice Sell emits LivoSwapSell with correct fields.
    function test_sellEmitsLivoSwapSell() public createDefaultTaxToken {
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, DEADLINE);
        _graduateToken();

        vm.warp(block.timestamp + DEFAULT_TAX_DURATION + 1);

        uint256 sellAmount = IERC20(testToken).balanceOf(buyer) / 2;

        vm.recordLogs();
        _swapSell(buyer, sellAmount, 0, true);
        Vm.Log memory log = _findLog(vm.getRecordedLogs(), HOOK_SWAP_SELL_SIG);

        assertEq(address(uint160(uint256(log.topics[1]))), testToken, "token mismatch");

        (uint256 tokensIn, uint256 ethOut, uint256 ethFees) = abi.decode(log.data, (uint256, uint256, uint256));

        assertEq(tokensIn, sellAmount, "tokensIn should be sell amount");
        assertGt(ethOut, 0, "ethOut should be > 0");
        assertApproxEqAbs(ethFees, ethOut / 100, 1, "ethFees should be ~1% LP fee");
    }

    /// @notice Buy with tax emits correct fee amount.
    function test_buyWithTaxEmitsCorrectFees() public {
        uint16 buyTax = 300;
        testToken = _createTaxToken(buyTax, DEFAULT_SELL_TAX_BPS, DEFAULT_TAX_DURATION);
        _graduateToken();

        uint256 buyAmount = 1 ether;
        deal(buyer, buyAmount);

        vm.recordLogs();
        _swapBuy(buyer, buyAmount, 0, true);
        Vm.Log memory log = _findLog(vm.getRecordedLogs(), HOOK_SWAP_BUY_SIG);

        (,, uint256 ethFees) = abi.decode(log.data, (uint256, uint256, uint256));

        uint256 expectedFees = (buyAmount * (LP_FEE_BPS + buyTax)) / 10_000;
        assertEq(ethFees, expectedFees, "ethFees should be LP fee + buy tax");
    }

    /// @notice Sell with tax emits correct fee amount.
    function test_sellWithTaxEmitsCorrectFees() public createDefaultTaxToken {
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, DEADLINE);
        _graduateToken();

        uint256 sellAmount = IERC20(testToken).balanceOf(buyer) / 2;

        vm.recordLogs();
        _swapSell(buyer, sellAmount, 0, true);
        Vm.Log memory log = _findLog(vm.getRecordedLogs(), HOOK_SWAP_SELL_SIG);

        (, uint256 ethOut, uint256 ethFees) = abi.decode(log.data, (uint256, uint256, uint256));

        uint256 expectedFees = (ethOut * (LP_FEE_BPS + DEFAULT_SELL_TAX_BPS)) / 10_000;
        assertApproxEqAbs(ethFees, expectedFees, 2, "ethFees should be LP fee + sell tax");
    }

    // ───────────────────────── router-failure defenses ────────────────────────

    /// @notice If the router reverts, the swap still succeeds and the full LP fee falls back to the
    ///         treasury. The creator receives nothing on this path — the default token has no buy tax.
    function test_swapSucceeds_whenRouterReverts() public createDefaultTaxToken {
        _graduateToken();

        // Plant a contract that reverts on every call at the router's address.
        address routerAddr = address(taxHook.FEE_ROUTER());
        vm.etch(routerAddr, type(RevertingRouter).runtimeCode);

        uint256 creatorBefore = _pendingCreatorFees(testToken);
        uint256 treasuryBefore = treasury.balance;

        uint256 buyAmount = 1 ether;
        deal(buyer, buyAmount);
        _swapBuy(buyer, buyAmount, 0, true); // must not revert

        uint256 expectedLpFee = (buyAmount * LP_FEE_BPS) / 10_000;
        assertEq(
            treasury.balance - treasuryBefore,
            expectedLpFee,
            "treasury should receive the entire LP fee via the fallback"
        );
        assertEq(
            _pendingCreatorFees(testToken),
            creatorBefore,
            "creator must not receive funds on the treasury fallback path"
        );
    }

    /// @notice If the router consumes its entire gas budget (e.g. an infinite loop in a hostile
    ///         upgrade), the swap still succeeds. The `ROUTER_GAS_LIMIT` cap reserves enough
    ///         gas in the catch frame to run the treasury fallback.
    function test_swapSucceeds_whenRouterBurnsAllForwardedGas() public createDefaultTaxToken {
        _graduateToken();

        address routerAddr = address(taxHook.FEE_ROUTER());
        vm.etch(routerAddr, type(GasBurningRouter).runtimeCode);

        uint256 creatorBefore = _pendingCreatorFees(testToken);
        uint256 treasuryBefore = treasury.balance;

        uint256 buyAmount = 1 ether;
        deal(buyer, buyAmount);
        // Give the swap a generous gas headroom; the router will OOG inside the `ROUTER_GAS_LIMIT`
        // cap and the catch frame should still have plenty to finish the swap.
        _swapBuy(buyer, buyAmount, 0, true);

        uint256 expectedLpFee = (buyAmount * LP_FEE_BPS) / 10_000;
        assertEq(
            treasury.balance - treasuryBefore,
            expectedLpFee,
            "treasury should receive the entire LP fee via the fallback after router OOG"
        );
        assertEq(_pendingCreatorFees(testToken), creatorBefore, "creator must not receive funds when the router OOGs");
    }

    // ───────────────────────── marketcap basis ──────────────────────────────

    bytes32 constant RECORDED_SIG = keccak256("Recorded(uint256,uint256,uint256)");

    /// @notice Regression: on a sell the hook must forward the FULL gross ETH the pool paid out as
    ///         the router's marketcap basis — not the swapper's net-of-fee proceeds. The hook fee is
    ///         skimmed after the pool and never changes the pool's execution price, so a sell and a
    ///         buy at the same pool state must report the same avg price (the buy legs already
    ///         forward pool-side ETH). Feeding net-of-fee here under-stated sell marketcaps by the
    ///         combined fee and could drop a sell into a lower router tier than an equivalent buy.
    function test_sellForwardsGrossEthAsMarketcapBasis() public createDefaultTaxToken {
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, DEADLINE);
        _graduateToken();

        // Spy router that echoes the (ethSwapAmount, tokenSwapAmount) the hook forwards.
        address routerAddr = address(taxHook.FEE_ROUTER());
        vm.etch(routerAddr, type(RecordingRouter).runtimeCode);

        uint256 sellAmount = IERC20(testToken).balanceOf(buyer) / 2;

        vm.recordLogs();
        _swapSell(buyer, sellAmount, 0, true);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (, uint256 ethOut, uint256 ethFees) =
            abi.decode(_findLog(logs, HOOK_SWAP_SELL_SIG).data, (uint256, uint256, uint256));
        (uint256 routedEth,, uint256 routedValue) =
            abi.decode(_findLog(logs, RECORDED_SIG).data, (uint256, uint256, uint256));

        // Sell tax + LP fee are active here, so gross strictly exceeds net: the assertion below can
        // only hold for the full gross, distinguishing the fix from the old net-of-fee behavior.
        assertGt(ethFees, 0, "sell fee must be non-zero for this regression to be meaningful");
        assertEq(routedEth, ethOut, "sell must forward gross pool ETH (LivoSwapSell.ethOut) as the marketcap basis");
        // The router receives exactly the LP fee as ETH; the sell tax bypasses it straight to accrueFees.
        assertApproxEqAbs(
            routedValue, (ethOut * LP_FEE_BPS) / 10_000, 2, "router must receive exactly the LP fee as msg.value"
        );
    }

    // ───────────────────────── accurate amounts ─────────────────────────────

    // ─── exact-output buy parity with exact-input ──────────────────────

    /// @dev Routes an exact-output buy through the Universal Router. Mirrors the helper in
    ///      `Finding02_V4ExactOutputDOS` so the asymmetry tests can run without that PoC file.
    function _swapExactOutputBuyV4(
        address caller,
        address token,
        uint128 amountOut,
        uint128 amountInMax,
        bool expectSuccess
    ) internal {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: lpFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(taxHook))
        });

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactOutputSingleParams({
                poolKey: key, zeroForOne: true, amountOut: amountOut, amountInMaximum: amountInMax, hookData: bytes("")
            })
        );
        params[1] = abi.encode(key.currency0, amountInMax);
        params[2] = abi.encode(key.currency1, amountOut);

        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_OUT_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));
        bytes memory commands = abi.encodePacked(uint8(0x10));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        vm.prank(caller);
        if (!expectSuccess) vm.expectRevert();
        IUniversalRouter(universalRouter).execute{value: amountInMax}(commands, inputs, block.timestamp);
    }

    /// @notice On an exact-output buy with only the LP fee active, the hook must charge
    ///         `feeBps%` of the swapper's TOTAL ETH out (pool input + fee), matching the
    ///         exact-input convention. The `LivoSwapBuy.ethIn` field carries that total.
    function test_exactOutputBuy_chargesCanonicalRate_lpFeeOnly() public createDefaultTaxToken {
        _graduateToken();
        // Skip past the tax window so only the 1% LP fee applies.
        vm.warp(block.timestamp + DEFAULT_TAX_DURATION + 1);

        deal(buyer, 10 ether);
        uint128 wantTokens = uint128(1e18);
        uint128 ethCap = uint128(1 ether);

        vm.recordLogs();
        _swapExactOutputBuyV4(buyer, testToken, wantTokens, ethCap, true);
        Vm.Log memory log = _findLog(vm.getRecordedLogs(), HOOK_SWAP_BUY_SIG);
        (uint256 ethIn, uint256 tokensOut, uint256 ethFees) = abi.decode(log.data, (uint256, uint256, uint256));

        assertEq(tokensOut, wantTokens, "exact-output must deliver requested tokens");
        uint256 expectedFee = (ethIn * LP_FEE_BPS) / 10_000;
        assertApproxEqAbs(ethFees, expectedFee, 1, "fee must be feeBps% of swapper's total ETH out");
    }

    /// @notice Same canonical relation with LP fee + buy tax stacked during the active tax window.
    function test_exactOutputBuy_chargesCanonicalRate_lpFeePlusBuyTax() public {
        uint16 buyTax = 300; // 3%
        testToken = _createTaxToken(buyTax, DEFAULT_SELL_TAX_BPS, DEFAULT_TAX_DURATION);
        _graduateToken();

        deal(buyer, 10 ether);
        uint128 wantTokens = uint128(1e18);
        uint128 ethCap = uint128(1 ether);

        vm.recordLogs();
        _swapExactOutputBuyV4(buyer, testToken, wantTokens, ethCap, true);
        Vm.Log memory log = _findLog(vm.getRecordedLogs(), HOOK_SWAP_BUY_SIG);
        (uint256 ethIn, uint256 tokensOut, uint256 ethFees) = abi.decode(log.data, (uint256, uint256, uint256));

        assertEq(tokensOut, wantTokens, "exact-output must deliver requested tokens");
        uint256 expectedFee = (ethIn * (LP_FEE_BPS + buyTax)) / 10_000;
        assertApproxEqAbs(ethFees, expectedFee, 2, "fee must be (LP+buyTax)% of swapper's total ETH out");
    }

    /// @notice An exact-output buy must actually deliver the fee to its recipients, not merely emit a
    ///         correct total: the treasury gets its tier-0 LP share and the creator gets its tier-0 LP
    ///         share plus the full buy tax. Runs in the active tax window so both components are non-zero.
    function test_exactOutputBuy_distributesLpFeeAndBuyTax() public {
        uint16 buyTax = 300; // 3%
        testToken = _createTaxToken(buyTax, DEFAULT_SELL_TAX_BPS, DEFAULT_TAX_DURATION);
        _graduateToken();

        uint256 creatorBefore = _pendingCreatorFees(testToken);
        uint256 treasuryBefore = treasury.balance;

        deal(buyer, 10 ether);
        uint128 wantTokens = uint128(1e18);
        uint128 ethCap = uint128(1 ether);

        vm.recordLogs();
        _swapExactOutputBuyV4(buyer, testToken, wantTokens, ethCap, true);
        Vm.Log memory log = _findLog(vm.getRecordedLogs(), HOOK_SWAP_BUY_SIG);
        // `ethIn` is the swapper's total ETH out (pool input + fee) = the grossed-up basis the hook
        // charges the fee on, so the canonical split derives directly from it.
        (uint256 ethIn,,) = abi.decode(log.data, (uint256, uint256, uint256));

        uint256 creatorFees = _pendingCreatorFees(testToken) - creatorBefore;
        uint256 treasuryLpFee = treasury.balance - treasuryBefore;

        uint256 totalLpFee = (ethIn * LP_FEE_BPS) / 10_000;
        uint256 expectedTreasuryLpFee = (totalLpFee * TIER0_TREASURY_BPS) / 10_000;
        uint256 expectedCreatorLpFee = totalLpFee - expectedTreasuryLpFee;
        uint256 expectedBuyTax = (ethIn * buyTax) / 10_000;

        assertApproxEqAbs(treasuryLpFee, expectedTreasuryLpFee, 2, "treasury should get tier-0 LP fee share");
        assertApproxEqAbs(
            creatorFees, expectedCreatorLpFee + expectedBuyTax, 3, "creator should get tier-0 LP share + buy tax"
        );
    }

    /// @notice Accurate fee amounts: buy 1 ETH (small enough that the post-swap marketcap stays
    ///         below tier 1 = 30 ETH), verify tier-0 split on the 0.01 ETH LP fee.
    function test_accurateFeeAmounts() public createDefaultTaxToken {
        _graduateToken();

        uint256 creatorFeesBefore = _pendingCreatorFees(testToken);
        uint256 treasuryBefore = treasury.balance;

        uint256 buyAmount = 1 ether;
        deal(buyer, buyAmount);
        _swapBuy(buyer, buyAmount, 0, true);

        uint256 creatorLpFee = _pendingCreatorFees(testToken) - creatorFeesBefore;
        uint256 treasuryLpFee = treasury.balance - treasuryBefore;

        uint256 totalLpFee = (buyAmount * LP_FEE_BPS) / 10_000; // 0.01 ETH
        uint256 expectedTreasury = (totalLpFee * TIER0_TREASURY_BPS) / 10_000; // 0.004 ETH
        uint256 expectedCreator = totalLpFee - expectedTreasury; // 0.006 ETH

        assertEq(creatorLpFee, expectedCreator, "Creator should receive tier-0 creator share");
        assertEq(treasuryLpFee, expectedTreasury, "Treasury should receive tier-0 treasury share");
    }

    // ───────────────────────── overall fee cap ──────────────────────────────

    /// @notice The hook caps the COMBINED fee (LP fee + active tax) at `MAX_OVERALL_FEE_BPS` (20%):
    ///         a config exactly at the cap swaps fine, one bps over reverts with `FeeTooHigh`. The
    ///         two cases differ by a single bps, so the revert is attributable to the cap alone. The
    ///         factory can't configure a token above the cap (`MAX_TOTAL_FEE_BPS` = 5%), so the
    ///         over-cap config is injected with `vm.mockCall` to exercise the runtime backstop.
    function test_swapReverts_whenCombinedFeeExceedsCap() public createDefaultTaxToken {
        _graduateToken();

        // Exactly at the 20% cap (lpFee 0 + buyTax 2000): allowed.
        _mockBuyFeeBps(testToken, 0, 2000);
        deal(buyer, 1 ether);
        _swapBuy(buyer, 1 ether, 0, true);

        // One bps over the cap (lpFee 1 + buyTax 2000 = 2001): reverts with FeeTooHigh.
        _mockBuyFeeBps(testToken, 1, 2000);
        deal(buyer, 1 ether);
        _swapBuy(buyer, 1 ether, 0, false);
    }

    /// @dev Forces `token.getSwapFees(isBuy)` to report an arbitrary lp-fee/buy-tax split, bypassing
    ///      the factory's `MAX_TOTAL_FEE_BPS` validation. Returns the windowed values directly, so
    ///      no graduation/window state is needed.
    function _mockBuyFeeBps(address token, uint16 lpFeeBps, uint16 buyTaxBps) internal {
        vm.mockCall(
            token,
            abi.encodeWithSelector(IRealmToken.getSwapFees.selector),
            abi.encode(IRealmToken.RealmTradeFees({taxBps: buyTaxBps, lpFeeBps: lpFeeBps}))
        );
    }

    // ─────────────────────── exact-output sell parity ───────────────────────

    /// @dev Routes an exact-output sell (token -> exact ETH out) through the Universal Router.
    function _swapExactOutputSellV4(
        address caller,
        address token,
        uint128 ethOut,
        uint128 tokenInMax,
        bool expectSuccess
    ) internal {
        vm.startPrank(caller);
        IERC20(token).approve(address(permit2Address), type(uint256).max);
        IPermit2(permit2Address).approve(address(token), universalRouter, type(uint160).max, type(uint48).max);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: lpFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(taxHook))
        });

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactOutputSingleParams({
                poolKey: key, zeroForOne: false, amountOut: ethOut, amountInMaximum: tokenInMax, hookData: bytes("")
            })
        );
        // Pay tokens (currency1, capped at tokenInMax), receive ETH (currency0, the exact request).
        params[1] = abi.encode(key.currency1, tokenInMax);
        params[2] = abi.encode(key.currency0, ethOut);

        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_OUT_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));
        bytes memory commands = abi.encodePacked(uint8(0x10));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        if (!expectSuccess) vm.expectRevert();
        IUniversalRouter(universalRouter).execute(commands, inputs, block.timestamp);
        vm.stopPrank();
    }

    /// @notice An exact-output sell must deliver the swapper EXACTLY the ETH they requested; the fee
    ///         is borne by selling extra tokens (the pool output is grossed up in `beforeSwap`).
    ///         Regression for the pre-fix behavior where the fee was skimmed from the output and the
    ///         swapper received `request - fee`. Runs in the active tax window so LP fee (1%) + sell
    ///         tax (4%) both apply, making the gross-up non-trivial.
    function test_exactOutputSell_deliversExactEthAndChargesFee() public createDefaultTaxToken {
        vm.deal(buyer, 5 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 3 ether}(testToken, 0, DEADLINE);
        _graduateToken();

        uint256 treasuryBefore = treasury.balance;
        uint256 creatorBefore = _pendingCreatorFees(testToken);
        uint256 buyerEthBefore = buyer.balance;
        uint256 buyerTokensBefore = IERC20(testToken).balanceOf(buyer);

        uint128 wantEth = 0.1 ether;
        _swapExactOutputSellV4(buyer, testToken, wantEth, uint128(buyerTokensBefore), true);

        // CORE: the swapper receives EXACTLY the requested ETH, not `wantEth - fee`.
        assertEq(buyer.balance - buyerEthBefore, wantEth, "exact-output sell must deliver the exact ETH requested");

        // The fee is still charged — on the grossed-up output — and routed to treasury + creator.
        uint256 treasuryLpFee = treasury.balance - treasuryBefore;
        uint256 creatorFees = _pendingCreatorFees(testToken) - creatorBefore;
        uint256 totalFee = treasuryLpFee + creatorFees;
        assertGt(totalFee, 0, "fee must still be collected on an exact-output sell");

        // Fee is charged on the gross pool output (= wantEth + totalFee) at the combined rate.
        uint256 grossEth = uint256(wantEth) + totalFee;
        uint256 expectedFee = (grossEth * (LP_FEE_BPS + DEFAULT_SELL_TAX_BPS)) / 10_000;
        assertApproxEqAbs(totalFee, expectedFee, 3, "fee must be ~(LP+sellTax)% of the grossed-up output");

        // The seller bears the fee by spending tokens.
        assertLt(IERC20(testToken).balanceOf(buyer), buyerTokensBefore, "seller must spend tokens");
    }

    /// @notice An exact-output sell must split the fee correctly between recipients, not just charge the
    ///         right total: the treasury gets its tier-0 LP share and the creator gets its tier-0 LP
    ///         share plus the full sell tax. Runs in the active tax window so both components are non-zero.
    function test_exactOutputSell_distributesLpFeeAndSellTax() public createDefaultTaxToken {
        vm.deal(buyer, 5 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 3 ether}(testToken, 0, DEADLINE);
        _graduateToken();

        uint256 treasuryBefore = treasury.balance;
        uint256 creatorBefore = _pendingCreatorFees(testToken);
        uint256 buyerTokensBefore = IERC20(testToken).balanceOf(buyer);

        uint128 wantEth = 0.1 ether;
        _swapExactOutputSellV4(buyer, testToken, wantEth, uint128(buyerTokensBefore), true);

        uint256 treasuryLpFee = treasury.balance - treasuryBefore;
        uint256 creatorFees = _pendingCreatorFees(testToken) - creatorBefore;

        // Fee is charged on the grossed-up pool output (= requested ETH + total fee withheld in beforeSwap).
        uint256 grossEth = uint256(wantEth) + treasuryLpFee + creatorFees;
        uint256 totalLpFee = (grossEth * LP_FEE_BPS) / 10_000;
        uint256 expectedTreasuryLpFee = (totalLpFee * TIER0_TREASURY_BPS) / 10_000;
        uint256 expectedCreatorLpFee = totalLpFee - expectedTreasuryLpFee;
        uint256 expectedSellTax = (grossEth * DEFAULT_SELL_TAX_BPS) / 10_000;

        assertApproxEqAbs(treasuryLpFee, expectedTreasuryLpFee, 2, "treasury should get tier-0 LP fee share");
        assertApproxEqAbs(
            creatorFees, expectedCreatorLpFee + expectedSellTax, 3, "creator should get tier-0 LP share + sell tax"
        );
    }
}
