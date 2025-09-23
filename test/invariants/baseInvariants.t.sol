// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {LivoToken} from "src/LivoToken.sol";
import {ConstantProductBondingCurve} from "src/bondingCurves/ConstantProductBondingCurve.sol";
import {LivoGraduatorUniV2} from "src/graduators/LivoGraduatorUniV2.sol";
import {TokenConfig, TokenState} from "src/types/tokenData.sol";
import {InvariantsHelperLaunchpad} from "./helper.t.sol";

contract LaunchpadInvariants is Test {

    LivoLaunchpad public launchpad;
    LivoToken public tokenImplementation;
    ConstantProductBondingCurve public bondingCurve;
    LivoGraduatorUniV2 public graduator;

    InvariantsHelperLaunchpad public helper;


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

        // the actual deployments
        tokenImplementation = new LivoToken();
        launchpad = new LivoLaunchpad(treasury, tokenImplementation);

        bondingCurve = new ConstantProductBondingCurve();
        // For graduation tests, a new graduator should be deployed, and use fork tests.
        graduator = new LivoGraduatorUniV2(UNISWAP_V2_ROUTER, address(launchpad));

        launchpad.whitelistBondingCurve(address(bondingCurve), true);
        launchpad.whitelistGraduator(address(graduator), true);

        helper = new InvariantsHelperLaunchpad(launchpad, address(bondingCurve), address(graduator));

        targetContract(address(helper));
    }

    ///////////////////////////// Cross checking against ghost variables //////////////////

    ///////////////////////////// Launchpad invariants ////////////////////////////////////

    // the launchpad eth balance should match the sum of all token ethCollected plus the treasury balance
    function invariant_launchpadEthBalance() public view {
        assertEq(
            address(launchpad).balance,
            _totalEthCollected() + launchpad.treasuryEthFeesCollected(),
            "launchpad eth balance does not match total eth collected plus treasury fees"
        );
    }

    // the sum of all msg.value from purchases for each token should be greater than the sum of eth from sells
    function invariant_tokenEthCollected() public view {
        for (uint256 i = 0; i < helper.nTokens(); i++) {
            address token = helper.tokenAt(i);
            uint256 ethCollected = helper.aggregatedEthForBuys(token);
            uint256 ethFromSells = helper.aggregatedEthFromSells(token);
            assertGe(ethCollected, ethFromSells, "token eth collected is less than eth from sells");
        }
    }

    // the sum of all msg.value from purchases for all tokens should be greater than the sum of eth from sells from all tokens
    // the sum of all token totalSupply should be less than or equal to TOTAL_SUPPLY - CREATOR_RESERVED_SUPPLY
    // the sum of all token balances should be less or equal to TOTAL_SUPPLY
    // the sum of all token purchases should be greater or equal than the sum of all token sells
    // the sum of all token purchases minus the sum of all token sells should be equal to the sum of tokens in all buyers balance
    // the sum of all token purchases minus the sum of all token sells should be equal to the total supply minus the tokens in the launchpad balance
    // the ethCollected by a token is always less than the graduation threshold plus the excess cap

    ///////////////////////////// Graduation invariants ////////////////////////////////////

    // ungraduated tokens have always an ethCollected below the graduation threshold
    // graduated tokens have 0 supply in the launchpad

    ///////////////////////////// INTERNALS ////////////////////////////////////

    function _totalEthCollected() internal view returns (uint256 totalEth) {
        for (uint256 i = 0; i < helper.nTokens(); i++) {
            totalEth += helper.ethCollected(helper.tokenAt(i));
        }
    }
}
