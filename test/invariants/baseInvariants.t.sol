// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {LivoToken} from "src/LivoToken.sol";
import {ConstantProductBondingCurve} from "src/bondingCurves/ConstantProductBondingCurve.sol";
import {LivoGraduatorUniswapV2} from "src/graduators/LivoGraduatorUniswapV2.sol";
import {LivoGraduatorUniswapV4} from "src/graduators/LivoGraduatorUniswapV4.sol";
import {TokenConfig, TokenState} from "src/types/tokenData.sol";
import {InvariantsHelperLaunchpad} from "./helper.t.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

contract LaunchpadInvariants is Test {
    LivoLaunchpad public launchpad;
    LivoToken public tokenImplementation;
    ConstantProductBondingCurve public bondingCurve;
    LivoGraduatorUniswapV2 public graduatorV2;
    LivoGraduatorUniswapV4 public graduatorV4;

    InvariantsHelperLaunchpad public helper;

    address constant poolManagerAddress = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    address public treasury = makeAddr("treasury");
    address public creator = makeAddr("creator");
    address public buyer = makeAddr("buyer");
    address public seller = makeAddr("seller");

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    address public testToken;

    uint256 public constant INITIAL_ETH_BALANCE = 100 ether;
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 public constant CREATOR_RESERVED_SUPPLY = 10_000_000e18;
    uint256 public constant BASE_GRADUATION_THRESHOLD = 7956000000000052224;
    uint256 public constant BASE_GRADUATION_FEE = 0.5 ether;
    uint16 public constant BASE_BUY_FEE_BPS = 100;
    uint16 public constant BASE_SELL_FEE_BPS = 100;

    // Uniswap V2 router address on mainnet
    address constant UNISWAP_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    // for fork tests
    uint256 constant BLOCKNUMBER = 23327777;



    function setUp() public virtual {
        string memory mainnetRpcUrl = vm.envString("MAINNET_RPC_URL");
        vm.createSelectFork(mainnetRpcUrl, BLOCKNUMBER);

        // deploy another contract to skip that address with 1 wei
        LivoToken throwAway = new LivoToken();
        throwAway; // silence compiler

        // the actual deployments
        tokenImplementation = new LivoToken();
        launchpad = new LivoLaunchpad(treasury, tokenImplementation);

        bondingCurve = new ConstantProductBondingCurve();
        // For graduation tests, a new graduatorV2 should be deployed, and use fork tests.
        graduatorV2 = new LivoGraduatorUniswapV2(UNISWAP_V2_ROUTER, address(launchpad));

        launchpad.whitelistCurveAndGraduator(address(bondingCurve), address(graduatorV2), true);
        launchpad.whitelistCurveAndGraduator(address(bondingCurve), address(graduatorV4), true);

        helper =
            new InvariantsHelperLaunchpad(launchpad, address(bondingCurve), address(graduatorV2), address(graduatorV4));

        targetContract(address(helper));
    }

    ///////////////////////////// Cross checking against ghost variables //////////////////

    ///////////////////////////// Launchpad invariants ////////////////////////////////////

    /// @notice the launchpad eth balance should match the sum of all token ethCollected plus the treasury balance
    function invariant_launchpadEthBalance() public view {
        assertEq(
            address(launchpad).balance,
            _totalEthCollected() + launchpad.treasuryEthFeesCollected(),
            "launchpad eth balance does not match total eth collected plus treasury fees"
        );
    }

    /// @notice the sum of all msg.value from purchases for each token should be greater than the sum of eth from sells
    function invariant_tokenEthCollected() public view {
        for (uint256 i = 0; i < helper.nTokens(); i++) {
            address token = helper.tokenAt(i);
            uint256 ethCollected = helper.aggregatedEthForBuys(token);
            uint256 ethFromSells = helper.aggregatedEthFromSells(token);
            assertGe(ethCollected, ethFromSells, "token eth collected is less than eth from sells");
        }
    }

    /// @notice the sum of all msg.value from purchases for all tokens should be greater than the sum of eth from sells from all tokens
    function invariant_allTokensEthCollected() public view {
        assertGe(
            helper.globalAggregatedEthForBuys(),
            helper.globalAggregatedEthFromSells(),
            "total eth collected is less than total eth from sells"
        );
    }

    /// @notice each non-graduated token should have a balance in the launchpad above CREATOR_RESERVED_SUPPLY
    function invariant_nonGraduatedTokensAboveCreatorReserved() public view {
        for (uint256 i = 0; i < helper.nTokens(); i++) {
            address token = helper.tokenAt(i);
            assertGt(
                IERC20(token).balanceOf(address(launchpad)),
                CREATOR_RESERVED_SUPPLY,
                "non-graduated token has balance in launchpad below CREATOR_RESERVED_SUPPLY"
            );
        }
    }

    /// @notice the sum of all token purchases should be greater or equal than the sum of all token sells
    function invariant_tokensBoughtGreaterThanSold() public view {
        assertGe(
            helper.globalAggregatedTokensBought(),
            helper.globalAggregatedTokensSold(),
            "total tokens bought is less than total tokens sold"
        );
    }

    /// @notice For each non-graduated token, the sum of all token purchases minus the sum of all token sells should be equal to the sum of tokens in all buyers balance
    function invariant_tokensBoughtMinusSoldEqualsBalances() public view {
        for (uint256 i = 0; i < helper.nTokens(); i++) {
            address token = helper.tokenAt(i);
            uint256 totalBalances = 0;
            for (uint256 j = 0; j < helper.nActors(); j++) {
                totalBalances += IERC20(token).balanceOf(helper.actorAt(j));
            }
            // the tokens bought are the tokens that left the launchpad
            assertEq(
                helper.aggregatedTokensBought(token) - helper.aggregatedTokensSold(token),
                totalBalances,
                "total tokens bought minus total tokens sold does not equal total balances"
            );
        }
    }

    /// @notice for each token, the sum of all token purchases minus the sum of all token sells should be equal to the total supply minus the tokens in the launchpad balance
    function invariant_tokensBoughtMinusSoldEqualsTotalSupplyMinusLaunchpadBalance() public view {
        for (uint256 i = 0; i < helper.nTokens(); i++) {
            address token = helper.tokenAt(i);
            uint256 launchpadBalance = IERC20(token).balanceOf(address(launchpad));
            // the tokens bought are the tokens that left the launchpad
            assertEq(
                helper.aggregatedTokensBought(token) - helper.aggregatedTokensSold(token),
                TOTAL_SUPPLY - launchpadBalance,
                "tokens that left the launchpad does not equal total supply minus launchpad balance"
            );
        }
    }

    ///////////////////////////// Graduation invariants ////////////////////////////////////

    /// @notice ungraduated tokens have always an ethCollected below the graduation threshold
    function invariant_ungraduatedBelowGraduationThreshold() public view {
        uint256 nTokens = helper.nTokens();
        for (uint256 i = 0; i < nTokens; i++) {
            address token = helper.tokenAt(i);
            TokenState memory state = launchpad.getTokenState(token);
            assertLt(
                state.ethCollected,
                launchpad.baseEthGraduationThreshold(),
                "ungraduated token has ethCollected above graduation threshold"
            );
        }
    }

    /// @notice graduated tokens have 0 supply in the launchpad, and ethCollected has been reset to 0
    function invariant_graduatedTokensZeroSupplyInLaunchpad() public view {
        uint256 nGraduatedTokens = helper.nGraduatedTokens();
        for (uint256 i = 0; i < nGraduatedTokens; i++) {
            address token = helper.graduatedTokenAt(i);
            uint256 launchpadBalance = IERC20(token).balanceOf(address(launchpad));
            assertEq(launchpadBalance, 0, "graduated token has non zero balance in launchpad");
            TokenState memory state = launchpad.getTokenState(token);
            assertEq(state.ethCollected, 0, "graduated token has non zero ethCollected");
        }
    }

    ///////////////////////////// INTERNALS ////////////////////////////////////

    function _totalEthCollected() internal view returns (uint256 totalEth) {
        for (uint256 i = 0; i < helper.nTokens(); i++) {
            totalEth += helper.ethCollected(helper.tokenAt(i));
        }
    }
}
