// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {ConstantProductBondingCurve} from "src/bondingCurves/ConstantProductBondingCurve.sol";

// This is a test file to test the bonding curve ConstantProductBondingCurve
contract ConstantProductBondingCurveTest is Test {
    ConstantProductBondingCurve public curve;

    uint256 constant TOTAL_SUPPLY = 1_000_000_000e18;

    // Graduation parameters
    // These ones are set in the LivoLaunchpad contract, and the curves need to be compliant with them
    uint256 constant GRADUATION_THRESHOLD = 7956000000000052224; // ~7.956 ETH
    uint256 constant GRADUATION_ETH_FEE = 0.5 ether;
    uint256 constant GRADUATION_TOKEN_CREATOR_REWARD = 10_000_000e18;

    function setUp() public {
        curve = new ConstantProductBondingCurve();
    }

    function _uniswapV2EstimatedPrice(uint256 tokenReserves, uint256 ethReserves) internal pure returns (uint256) {
        if (tokenReserves == 0 || ethReserves == 0) return 0;
        return (ethReserves * 1e18) / tokenReserves;
    }

    /////////////////////// TESTING BASIC FUNCTION SHAPE ////////////////////////////////
    function test_tokenReservesAtZeroEthSupply() public {
        uint256 tokenReserves = curve.getTokenReserves(0);
        assertEq(tokenReserves, TOTAL_SUPPLY, "Token reserves should be 1B at start");
    }

    function test_tokenReservesAtGraduation() public {
        uint256 tokenReserves = curve.getTokenReserves(GRADUATION_THRESHOLD);
        // here we accept a 0.1%  error as 200,000,000 is pretty much arbitrary
        // note that 1M are for the token creator, included in this tokenReserves
        assertApproxEqRel(
            tokenReserves, 201_000_000e18, 0.001e18, "Token reserves should be 201M at graduation (1M for creator)"
        );
    }

    function test_buyTokensWithExactEth_initialState() public {
        uint256 tokenReserves = TOTAL_SUPPLY;
        uint256 ethReserves = 0;
        uint256 ethAmount = 1;

        uint256 tokens = curve.buyTokensWithExactEth(tokenReserves, ethReserves, ethAmount);
        assertTrue(tokens > 0, "Should mint non-zero amount of tokens");
    }

    function test_buyFunctionsMatchInPrice() public {
        vm.skip(true);
        uint256 ethReserves = 1e18;
        uint256 tokenReserves = curve.getTokenReserves(ethReserves);
        uint256 ethAmount = 1e18;

        uint256 tokensReceived = curve.buyTokensWithExactEth(tokenReserves, ethReserves, ethAmount);
        uint256 ethRequired = curve.buyExactTokens(tokenReserves, ethReserves, tokensReceived);

        // accept a difference of 0.01% between the two functions
        assertApproxEqRel(ethRequired, ethAmount, 0.0001e18, "Buy functions should match in price");
    }

    function test_tokenPriceAtGraduationPoint_matchesUniswap() public view {
        // reserves pre-graduation
        uint256 tokenReserves = curve.getTokenReserves(GRADUATION_THRESHOLD);
        uint256 ethReserves = GRADUATION_THRESHOLD;
        // the buy value cannot be too hight, otherwise we affect the price too much
        uint256 buyValue = 0.000001e18;
        uint256 tokensReceived = curve.buyTokensWithExactEth(tokenReserves, ethReserves, buyValue);
        uint256 curvePrice = (1e18 * buyValue) / tokensReceived; // ETH/tokens

        // then we take the graduation fee and tokens for creators, and calculate the Uniswap price
        uint256 tokenReservesForUniswap = tokenReserves - GRADUATION_TOKEN_CREATOR_REWARD;
        uint256 ethReservesForUniswap = ethReserves - GRADUATION_ETH_FEE;
        uint256 uniswapPrice = _uniswapV2EstimatedPrice(tokenReservesForUniswap, ethReservesForUniswap);

        // accept an price change of %0.001 between uniswap and bonding curve at the moment of graduation
        assertApproxEqRel(curvePrice, uniswapPrice, 0.00001e18, "Token prices should match at graduation point");
    }

    function test_fuzz_buyTokensWithExactEth(uint256 ethReserves, uint256 ethAmount) public {

        // This is way outside the expected range, as tokens would be graduated when reserves are about 8 ETH, but just in case
        ethReserves = bound(ethReserves, 0, 37e18);
        ethAmount = bound(ethAmount, 0, 37e18);

        // token reserves are calculated internally from the ethReserves so it doesn't matter what we pass here
        uint256 tokensReceived = curve.buyTokensWithExactEth(1, ethReserves, ethAmount);
    }

    // This basically tests that a buy can happen after the first small purchase. Not the most useful test though. 
    function test_sellExactTokens_initialState() public {
        uint256 ethReserves = 1e18;
        uint256 tokenReserves = curve.getTokenReserves(ethReserves);
        uint256 tokenAmount = 1000e18;

        uint256 ethReceived = curve.sellExactTokens(tokenReserves, ethReserves, tokenAmount);
        assertTrue(ethReceived > 0, "Should receive non-zero amount of ETH");
    }

    function test_sellTokenPriceAtGraduationPoint_matchesUniswap() public view {
        uint256 tokenReserves = curve.getTokenReserves(GRADUATION_THRESHOLD);
        uint256 ethReserves = GRADUATION_THRESHOLD;
        uint256 sellAmount = 1000e18;
        uint256 ethReceived = curve.sellExactTokens(tokenReserves, ethReserves, sellAmount);
        uint256 curvePrice = (1e18 * ethReceived) / sellAmount;

        uint256 tokenReservesForUniswap = tokenReserves - GRADUATION_TOKEN_CREATOR_REWARD;
        uint256 ethReservesForUniswap = ethReserves - GRADUATION_ETH_FEE;
        uint256 uniswapPrice = _uniswapV2EstimatedPrice(tokenReservesForUniswap, ethReservesForUniswap);

        assertApproxEqRel(curvePrice, uniswapPrice, 0.00001e18, "Sell prices should match at graduation point");
    }

    function test_fuzz_sellExactTokens(uint256 ethReserves, uint256 tokenAmount) public {
        ethReserves = bound(ethReserves, 0.000001e18, 37e18);
        uint256 tokenReserves = curve.getTokenReserves(ethReserves);
        tokenAmount = bound(tokenAmount, 1e18, tokenReserves / 10);

        uint256 ethReceived = curve.sellExactTokens(tokenReserves, ethReserves, tokenAmount);
        assertTrue(ethReceived > 0, "Should receive ETH when selling tokens");
    }

    function test_fuzz_buyAndSell(uint256 ethReserves, uint256 ethAmount, uint256 tokenAmount) public {
        ethReserves = bound(ethReserves, 0, 30e18);
        uint256 tokenReserves = curve.getTokenReserves(ethReserves);

        ethAmount = bound(ethAmount, 0.000001e18, 2e18);
        uint256 tokensReceived = curve.buyTokensWithExactEth(tokenReserves, ethReserves, ethAmount);
        ethReserves += ethAmount;
        console.log('before updating tokenReserves');
        tokenReserves -= tokensReceived;
        console.log('after updating tokenReserves');

        uint256 ethReceived = curve.sellExactTokens(tokenReserves, ethReserves, tokensReceived);

        // we accept a loss of up to 0.1% in the buy+sell process
        assertApproxEqRel(ethReceived, ethAmount, 0.00000001e18, "Should get back almost all ETH after buy+sell");
    }
}
