// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseUniswapV4FeesTests, UniswapV4ClaimFeesViewFunctionsBase} from "test/graduators/graduationUniv4.claimFees.t.sol";
import {BaseUniswapV4GraduationTests} from "test/graduators/graduationUniv4.base.t.sol";
import {TaxTokenUniV4BaseTests} from "test/graduators/taxToken.base.t.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";

contract UniswapV4ClaimFeesViewFunctions_TaxToken is TaxTokenUniV4BaseTests, UniswapV4ClaimFeesViewFunctionsBase {
    function setUp() public override(TaxTokenUniV4BaseTests, BaseUniswapV4FeesTests) {
        super.setUp();
        implementation = ILivoToken(address(taxTokenImpl));
    }

    function _expectsSellTaxes() internal pure override returns (bool) {
        return true;
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

    modifier createAndGraduateToken() override {
        bytes memory tokenCalldata = taxTokenImpl.encodeTokenCalldata(DEFAULT_SELL_TAX_BPS, DEFAULT_TAX_DURATION);

        vm.prank(creator);
        testToken = launchpad.createToken(
            "TestToken",
            "TEST",
            address(implementation),
            address(bondingCurve),
            address(graduator),
            creator,
            "0x12",
            tokenCalldata
        );

        _graduateToken();
        _;
    }

    modifier twoGraduatedTokensWithBuys(uint256 buyAmount) override {
        bytes memory tokenCalldata = taxTokenImpl.encodeTokenCalldata(DEFAULT_SELL_TAX_BPS, DEFAULT_TAX_DURATION);

        vm.startPrank(creator);
        testToken1 = launchpad.createToken(
            "TestToken1",
            "TEST1",
            address(implementation),
            address(bondingCurve),
            address(graduator),
            creator,
            "0x1a3a",
            tokenCalldata
        );
        testToken2 = launchpad.createToken(
            "TestToken2",
            "TEST2",
            address(implementation),
            address(bondingCurve),
            address(graduator),
            creator,
            "0x1a3a",
            tokenCalldata
        );
        vm.stopPrank();

        uint256 buyAmount1 = _increaseWithFees(GRADUATION_THRESHOLD + MAX_THRESHOLD_EXCESS / 3);
        uint256 buyAmount2 = _increaseWithFees(GRADUATION_THRESHOLD + MAX_THRESHOLD_EXCESS / 2);
        vm.deal(buyer, 100 ether);
        vm.startPrank(buyer);
        launchpad.buyTokensWithExactEth{value: buyAmount1}(testToken1, 0, DEADLINE);
        launchpad.buyTokensWithExactEth{value: buyAmount2}(testToken2, 0, DEADLINE);

        assertTrue(launchpad.getTokenState(testToken1).graduated, "Token1 should be graduated");
        assertTrue(launchpad.getTokenState(testToken2).graduated, "Token2 should be graduated");

        _swap(buyer, testToken1, buyAmount, 1, true, true);
        _swap(buyer, testToken2, buyAmount, 1, true, true);
        vm.stopPrank();
        _;
    }
}
