// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseUniswapV4FeesTests, BaseUniswapV4ClaimFeesBase} from "test/graduators/graduationUniv4.claimFees.t.sol";
import {BaseUniswapV4GraduationTests} from "test/graduators/graduationUniv4.base.t.sol";
import {TaxTokenUniV4BaseTests} from "test/graduators/taxToken.base.t.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @notice Base for multi-recipient V4 fee tests — creates tokens with a multi-recipient `feeReceivers`
///         and overrides claim/claimable helpers to route through the master fee handler.
abstract contract MultiRecipientV4BaseTests is BaseUniswapV4FeesTests {
    address public shareholder1;
    address public shareholder2;

    uint256 constant SHARE_1 = 7000;
    uint256 constant SHARE_2 = 3000;

    function setUp() public virtual override {
        super.setUp();
        shareholder1 = makeAddr("shareholder1");
        shareholder2 = makeAddr("shareholder2");
    }

    function _feeShares() internal view returns (IRealmFactory.FeeShare[] memory arr) {
        arr = new IRealmFactory.FeeShare[](2);
        arr[0] = IRealmFactory.FeeShare({account: shareholder1, shares: SHARE_1, directFeesEnabled: false});
        arr[1] = IRealmFactory.FeeShare({account: shareholder2, shares: SHARE_2, directFeesEnabled: false});
    }

    function _createTokenForCreator(string memory name, string memory symbol, bytes32)
        internal
        virtual
        override
        returns (address)
    {
        vm.prank(creator);
        address token = factoryV4.createToken(
            name,
            symbol,
            _nextValidSalt(address(factoryV4), address(realmToken)),
            _feeShares(),
            _noSs(),
            false,
            _emptyTaxCfg(),
            _emptyAntiSniperCfg()
        );
        return token;
    }

    /// @dev Override: collect fees by claiming through the master handler for each shareholder
    function _collectFees(address token) internal override {
        _collectFees(_singleToken(token));
    }

    function _collectFees(address[] memory tokens) internal override {
        vm.prank(shareholder1);
        feeHandler.claim(tokens);
        vm.prank(shareholder2);
        feeHandler.claim(tokens);
    }

    /// @dev Override: claimable comes from the master handler
    function _claimable(address token, address account) internal view override returns (uint256) {
        return feeHandler.getClaimable(_singleToken(token), account)[0];
    }
}

// ============================================
// V4 + multi-recipient master fee handler + RealmToken (normal)
// ============================================

contract UniswapV4ClaimFees_MultiRecipient_NormalToken is MultiRecipientV4BaseTests {
    function setUp() public override {
        super.setUp();
    }

    /// @notice Graduation succeeds with multi-recipient master fee config
    function test_graduation_withMultiRecipientFees() public createAndGraduateToken {
        assertTrue(launchpad.getTokenState(testToken).graduated, "token should be graduated");
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
        assertApproxEqAbs(s1Earned * 3000, s2Earned * 7000, 1e12, "fee split should respect 70/30 shares");
    }

    /// @notice Total fees across shareholders match the expected tier-0 creator LP share
    function test_totalFeesMatchExpected() public createAndGraduateToken generateFeesWithBuySwap(1 ether) {
        uint256 s1Before = shareholder1.balance;
        uint256 s2Before = shareholder2.balance;

        _collectFees(testToken);

        uint256 totalShareholderFees = (shareholder1.balance - s1Before) + (shareholder2.balance - s2Before);

        // The graduation compensation AND the creator's share of the pre-graduation LP fee on the
        // graduating buy are both routed through the master handler to shareholders.
        uint256 gradMissing = (GRADUATION_THRESHOLD * 10000) / (10000 - BASE_BUY_FEE_BPS);
        uint256 gradTradingFee = (gradMissing * BASE_BUY_FEE_BPS) / 10000;
        uint256 graduationDeposits =
            CREATOR_GRADUATION_COMPENSATION + (gradTradingFee - _treasuryShareOf(gradTradingFee));
        uint256 lpFeesOnly = totalShareholderFees - graduationDeposits;

        // Treasury LP share sent during swap by hook; shareholders get the creator's tier-0 share
        assertApproxEqAbs(
            lpFeesOnly, _lpCreatorShareTier0(1 ether), 2, "shareholder LP fees should be the tier-0 creator share"
        );
    }

    /// @notice getClaimable on master handler returns correct values before claim
    function test_getClaimable_multiRecipient() public createAndGraduateToken generateFeesWithBuySwap(1 ether) {
        vm.prank(shareholder1);
        feeHandler.claim(_singleToken(testToken));

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

        vm.prank(alice);
        feeHandler.claim(_singleToken(testToken));

        assertEq(alice.balance, aliceBefore, "non-shareholder should not receive fees");
    }
}

// ============================================
// V4 + multi-recipient master fee handler + TaxToken
// ============================================

contract UniswapV4ClaimFees_MultiRecipient_TaxToken is TaxTokenUniV4BaseTests, MultiRecipientV4BaseTests {
    function setUp() public override(TaxTokenUniV4BaseTests, MultiRecipientV4BaseTests) {
        super.setUp();
        implementation = IRealmToken(address(taxTokenImpl));
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

    function _createTokenForCreator(string memory name, string memory symbol, bytes32)
        internal
        override
        returns (address)
    {
        vm.prank(creator);
        address token = factoryTax.createToken(
            name,
            symbol,
            _nextValidSalt(address(factoryTax), address(realmTaxToken)),
            _feeShares(),
            _noSs(),
            false,
            _taxCfg(0, DEFAULT_SELL_TAX_BPS, uint32(DEFAULT_TAX_DURATION)),
            _emptyAntiSniperCfg()
        );
        return token;
    }

    /// @notice Graduation succeeds with multi-recipient fees + tax token
    function test_graduation_withMultiRecipientFees_taxToken() public createAndGraduateToken {
        assertTrue(launchpad.getTokenState(testToken).graduated, "token should be graduated");
    }

    /// @notice Shareholders can claim LP fees from buy swaps
    function test_shareholdersCanClaimLpFees_taxToken() public createAndGraduateToken generateFeesWithBuySwap(1 ether) {
        uint256 s1Before = shareholder1.balance;
        uint256 s2Before = shareholder2.balance;

        _collectFees(testToken);

        uint256 s1Earned = shareholder1.balance - s1Before;
        uint256 s2Earned = shareholder2.balance - s2Before;

        assertGt(s1Earned, 0, "shareholder1 should earn fees");
        assertGt(s2Earned, 0, "shareholder2 should earn fees");
    }

    /// @notice Sell taxes are routed through the master handler and claimable by shareholders
    function test_sellTaxes_routedThroughMultiRecipientConfig() public createAndGraduateToken {
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
