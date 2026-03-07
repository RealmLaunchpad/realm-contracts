// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseUniswapV4FeesTests, BaseUniswapV4ClaimFeesBase} from "test/graduators/graduationUniv4.claimFees.t.sol";
import {BaseUniswapV4GraduationTests} from "test/graduators/graduationUniv4.base.t.sol";
import {TaxTokenUniV4BaseTests} from "test/graduators/taxToken.base.t.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {ILivoFeeHandler} from "src/interfaces/ILivoFeeHandler.sol";
import {ILivoFeeSplitter} from "src/interfaces/ILivoFeeSplitter.sol";
import {LivoFeeSplitter} from "src/feeSplitters/LivoFeeSplitter.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @notice Base for fee-splitter V4 tests — creates tokens via `createTokenWithFeeSplit()`
///         and overrides claim/claimable helpers to go through the splitter
abstract contract FeeSplitterV4BaseTests is BaseUniswapV4FeesTests {
    address public splitterAddress;

    address public shareholder1;
    address public shareholder2;

    uint256 constant SHARE_1 = 7000;
    uint256 constant SHARE_2 = 3000;

    function setUp() public virtual override {
        super.setUp();
        shareholder1 = makeAddr("shareholder1");
        shareholder2 = makeAddr("shareholder2");
    }

    function _recipients() internal view returns (address[] memory r) {
        r = new address[](2);
        r[0] = shareholder1;
        r[1] = shareholder2;
    }

    function _sharesBps() internal pure returns (uint256[] memory s) {
        s = new uint256[](2);
        s[0] = SHARE_1;
        s[1] = SHARE_2;
    }

    function _createTokenForCreator(string memory name, string memory symbol, bytes32 metadata)
        internal
        virtual
        override
        returns (address)
    {
        vm.prank(creator);
        (address token, address splitter) =
            factoryV4.createTokenWithFeeSplit(name, symbol, _recipients(), _sharesBps(), metadata);
        splitterAddress = splitter;
        return token;
    }

    /// @dev Override: collect fees by claiming through the splitter for shareholder1
    function _collectFees(address token) internal override {
        _collectFees(_singleToken(token));
    }

    function _collectFees(address[] memory tokens) internal override {
        // first accrue LP fees in the V4 handler
        feeHandlerV4.accrueTokenFees(tokens);

        // then each shareholder claims from the splitter
        vm.prank(shareholder1);
        ILivoFeeHandler(splitterAddress).claim(tokens);
        vm.prank(shareholder2);
        ILivoFeeHandler(splitterAddress).claim(tokens);
    }

    /// @dev Override: claimable comes from the splitter
    function _claimable(address token, address account) internal view override returns (uint256) {
        return ILivoFeeHandler(splitterAddress).getClaimable(_singleToken(token), account)[0];
    }
}

// ============================================
// V4 + FeeSplitter + LivoToken (normal)
// ============================================

contract UniswapV4ClaimFees_Splitter_NormalToken is FeeSplitterV4BaseTests {
    function setUp() public override {
        super.setUp();
    }

    /// @notice Graduation succeeds with fee splitter
    function test_graduation_withFeeSplitter() public createAndGraduateToken {
        assertTrue(launchpad.getTokenState(testToken).graduated, "token should be graduated");
    }

    /// @notice token.feeHandler() returns the splitter, not the real handler
    function test_feeHandler_isSplitter() public createAndGraduateToken {
        assertEq(ILivoToken(testToken).feeHandler(), splitterAddress, "feeHandler should be splitter");
        assertEq(ILivoToken(testToken).feeReceiver(), splitterAddress, "feeReceiver should be splitter");
    }

    /// @notice splitter.liquidityPositionOwner() delegates to real handler
    function test_liquidityPositionOwner_delegatesToRealHandler() public createAndGraduateToken {
        address positionOwner = ILivoFeeHandler(splitterAddress).liquidityPositionOwner();
        assertEq(positionOwner, address(feeHandlerV4), "positionOwner should be the real V4 handler");
    }

    /// @notice LP position is registered on the real V4 handler (not the splitter)
    function test_positionRegisteredOnRealHandler() public createAndGraduateToken {
        uint256 positionId = feeHandlerV4.positionIds(testToken, 0);
        assertGt(positionId, 0, "position should be registered on real handler");
    }

    /// @notice After graduation + buy swap, shareholders can claim LP fees
    function test_shareholdersCanClaimLpFees() public createAndGraduateToken generateFeesWithBuySwap(1 ether) {
        uint256 s1Before = shareholder1.balance;
        uint256 s2Before = shareholder2.balance;

        _collectFees(testToken);

        uint256 s1Earned = shareholder1.balance - s1Before;
        uint256 s2Earned = shareholder2.balance - s2Before;

        assertGt(s1Earned, 0, "shareholder1 should earn fees");
        assertGt(s2Earned, 0, "shareholder2 should earn fees");

        // 70/30 split
        assertApproxEqAbs(
            s1Earned * 3000, s2Earned * 7000, 1e12, "fee split should respect 70/30 shares"
        );
    }

    /// @notice Total fees across shareholders + treasury match expected 1% LP fee
    function test_totalFeesMatchExpected() public createAndGraduateToken generateFeesWithBuySwap(1 ether) {
        uint256 s1Before = shareholder1.balance;
        uint256 s2Before = shareholder2.balance;
        uint256 treasuryBefore = treasury.balance;

        _collectFees(testToken);

        uint256 totalShareholderFees = (shareholder1.balance - s1Before) + (shareholder2.balance - s2Before);
        uint256 treasuryFees = treasury.balance - treasuryBefore;

        // graduation compensation (0.1 ETH) is routed through the splitter to shareholders
        uint256 graduationCompensation = CREATOR_GRADUATION_COMPENSATION;
        uint256 lpFeesOnly = totalShareholderFees - graduationCompensation;

        // total LP fees = creator share + treasury share ≈ 1% of buy amount
        assertApproxEqAbs(
            lpFeesOnly + treasuryFees, 1 ether / 100, 1, "total LP fees should be 1% of buy amount"
        );
    }

    /// @notice getClaimable on splitter returns correct values before claim
    function test_getClaimable_splitter() public createAndGraduateToken generateFeesWithBuySwap(1 ether) {
        // accruing shouldn't be necessary, we can claim directly
        // claim from upstream into splitter
        vm.prank(shareholder1);
        ILivoFeeHandler(splitterAddress).claim(_singleToken(testToken));

        // after shareholder1 claims, their claimable should be 0
        uint256 s1Claimable = _claimable(testToken, shareholder1);
        assertEq(s1Claimable, 0, "shareholder1 claimable should be 0 after claim");

        // shareholder2 should still have claimable
        uint256 s2Claimable = _claimable(testToken, shareholder2);
        assertGt(s2Claimable, 0, "shareholder2 should have claimable fees");
    }

    /// @notice Non-shareholder gets nothing
    function test_nonShareholderGetsNothing() public createAndGraduateToken generateFeesWithBuySwap(1 ether) {
        uint256 aliceBefore = alice.balance;

        feeHandlerV4.accrueTokenFees(_singleToken(testToken));
        vm.prank(alice);
        ILivoFeeHandler(splitterAddress).claim(_singleToken(testToken));

        assertEq(alice.balance, aliceBefore, "non-shareholder should not receive fees");
    }
}

// ============================================
// V4 + FeeSplitter + TaxToken
// ============================================

contract UniswapV4ClaimFees_Splitter_TaxToken is TaxTokenUniV4BaseTests, FeeSplitterV4BaseTests {
    function setUp() public override(TaxTokenUniV4BaseTests, FeeSplitterV4BaseTests) {
        super.setUp();
        implementation = ILivoToken(address(taxTokenImpl));
        SELL_TAX_BPS = DEFAULT_SELL_TAX_BPS;
    }

    function _swap(
        address caller,
        address token,
        uint256 amountIn,
        uint256 minAmountOut,
        bool isBuy,
        bool expectSuccess
    ) internal override(BaseUniswapV4GraduationTests, TaxTokenUniV4BaseTests) {
        TaxTokenUniV4BaseTests._swap(caller, token, amountIn, minAmountOut, isBuy, expectSuccess);
    }

    function _createTokenForCreator(string memory name, string memory symbol, bytes32 metadata)
        internal
        override
        returns (address)
    {
        vm.prank(creator);
        (address token, address splitter) = factoryTax.createTokenWithFeeSplit(
            name, symbol, _recipients(), _sharesBps(), metadata, DEFAULT_SELL_TAX_BPS, uint32(DEFAULT_TAX_DURATION)
        );
        splitterAddress = splitter;
        return token;
    }

    /// @notice Graduation succeeds with fee splitter + tax token
    function test_graduation_withFeeSplitter_taxToken() public createAndGraduateToken {
        assertTrue(launchpad.getTokenState(testToken).graduated, "token should be graduated");
    }

    /// @notice token.feeHandler() returns the splitter
    function test_feeHandler_isSplitter_taxToken() public createAndGraduateToken {
        assertEq(ILivoToken(testToken).feeHandler(), splitterAddress, "feeHandler should be splitter");
        assertEq(ILivoToken(testToken).feeReceiver(), splitterAddress, "feeReceiver should be splitter");
    }

    /// @notice splitter.liquidityPositionOwner() delegates to real handler
    function test_liquidityPositionOwner_delegatesToRealHandler_taxToken() public createAndGraduateToken {
        address positionOwner = ILivoFeeHandler(splitterAddress).liquidityPositionOwner();
        assertEq(positionOwner, address(feeHandlerV4), "positionOwner should be the real V4 handler");
    }

    /// @notice LP position registered on the real V4 handler
    function test_positionRegisteredOnRealHandler_taxToken() public createAndGraduateToken {
        uint256 positionId = feeHandlerV4.positionIds(testToken, 0);
        assertGt(positionId, 0, "position should be registered on real handler");
    }

    /// @notice Shareholders can claim LP fees from buy swaps
    function test_shareholdersCanClaimLpFees_taxToken()
        public
        createAndGraduateToken
        generateFeesWithBuySwap(1 ether)
    {
        uint256 s1Before = shareholder1.balance;
        uint256 s2Before = shareholder2.balance;

        _collectFees(testToken);

        uint256 s1Earned = shareholder1.balance - s1Before;
        uint256 s2Earned = shareholder2.balance - s2Before;

        assertGt(s1Earned, 0, "shareholder1 should earn fees");
        assertGt(s2Earned, 0, "shareholder2 should earn fees");
    }

    /// @notice Sell taxes are routed through the splitter and claimable by shareholders
    function test_sellTaxes_routedThroughSplitter() public createAndGraduateToken {
        deal(buyer, 10 ether);
        // buy first so buyer has tokens
        _swapBuy(buyer, 2 ether, 10e18, true);

        uint256 s1Before = shareholder1.balance;
        uint256 s2Before = shareholder2.balance;

        // sell generates sell tax
        _swapSell(buyer, 100_000_000e18, 0.1 ether, true);

        // accrue and claim
        _collectFees(testToken);

        uint256 s1Earned = shareholder1.balance - s1Before;
        uint256 s2Earned = shareholder2.balance - s2Before;

        // shareholders should receive sell tax fees (in addition to graduation compensation + LP fees)
        assertGt(s1Earned + s2Earned, 0, "shareholders should receive sell tax fees");
    }
}
