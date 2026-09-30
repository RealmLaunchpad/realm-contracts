// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IUniswapV2Router} from "src/interfaces/IUniswapV2Router.sol";
import {UniswapV2Venue} from "src/libraries/UniswapV2Venue.sol";

/// @dev Records the liquidity-add it was called with, and hands back configurable amounts.
contract MockRouter {
    bool public wasEthPath;
    address public lastToken;
    uint256 public lastTokenDesired;
    uint256 public lastQuoteDesired; // msg.value of addLiquidityETH
    uint256 internal rToken;
    uint256 internal rQuote;
    uint256 internal rLiq;

    function setReturns(uint256 t, uint256 q, uint256 l) external {
        (rToken, rQuote, rLiq) = (t, q, l);
    }

    function WETH() external pure returns (address) {
        return address(0xE);
    }

    function factory() external pure returns (address) {
        return address(0xF);
    }

    function addLiquidityETH(address token, uint256 amountTokenDesired, uint256, uint256, address, uint256)
        external
        payable
        returns (uint256, uint256, uint256)
    {
        wasEthPath = true;
        lastToken = token;
        lastTokenDesired = amountTokenDesired;
        lastQuoteDesired = msg.value;
        return (rToken, rQuote, rLiq);
    }
}

/// @dev Exposes the internal library functions as external calls.
contract VenueHarness {
    function supplyEth(MockRouter r, address token, address quote, uint256 tokenAmount, uint256 nativeValue)
        external
        payable
        returns (uint256, uint256, uint256)
    {
        return UniswapV2Venue.supplyLiquidity(
            IUniswapV2Router(address(r)), token, quote, tokenAmount, nativeValue, address(0xdEaD)
        );
    }
}

/// @notice Unit-tests that the V2 venue stays the native-value `addLiquidityETH` path.
contract UniswapV2VenueTest is Test {
    VenueHarness harness;
    MockRouter router;

    address constant TOKEN = address(0xABCD);

    function setUp() public {
        harness = new VenueHarness();
        router = new MockRouter();
    }

    function test_scaleConstants() public pure {
        assertEq(UniswapV2Venue.QUOTE_TO_NATIVE_SCALE, 1, "eth scale");
    }

    function test_ethVenue_usesNativeValuePath() public {
        router.setReturns(1000e18, 3e18, 5e18);
        vm.deal(address(harness), 3e18);

        (uint256 amountToken, uint256 amountNative, uint256 liquidity) =
            harness.supplyEth(router, TOKEN, router.WETH(), 1000e18, 3e18);

        assertTrue(router.wasEthPath(), "should take addLiquidityETH");
        assertEq(router.lastQuoteDesired(), 3e18, "native value forwarded as msg.value");
        assertEq(amountToken, 1000e18);
        assertEq(amountNative, 3e18, "native returned as-is (scale 1)");
        assertEq(liquidity, 5e18);
    }
}
