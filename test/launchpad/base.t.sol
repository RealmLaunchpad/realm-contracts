// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {LivoToken} from "src/LivoToken.sol";
import {ConstantProductBondingCurve} from "src/bondingCurves/ConstantProductBondingCurve.sol";
import {LivoGraduatorUniV2} from "src/graduators/LivoGraduatorUniV2.sol";
import {TokenConfig, TokenState} from "src/types/tokenData.sol";

contract LaunchpadBaseTest is Test {
    LivoLaunchpad public launchpad;
    LivoToken public tokenImplementation;
    ConstantProductBondingCurve public bondingCurve;
    LivoGraduatorUniV2 public graduator;

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

        tokenImplementation = new LivoToken();
        launchpad = new LivoLaunchpad(treasury, tokenImplementation);

        bondingCurve = new ConstantProductBondingCurve();
        // For graduation tests, a new graduator should be deployed, and use fork tests.
        graduator = new LivoGraduatorUniV2(UNISWAP_V2_ROUTER, address(launchpad));

        launchpad.whitelistBondingCurve(address(bondingCurve), true);
        launchpad.whitelistGraduator(address(graduator), true);

        vm.deal(creator, INITIAL_ETH_BALANCE);
        vm.deal(buyer, INITIAL_ETH_BALANCE);
        vm.deal(seller, INITIAL_ETH_BALANCE);
        vm.deal(alice, INITIAL_ETH_BALANCE);
        vm.deal(bob, INITIAL_ETH_BALANCE);
    }

    modifier createTestToken() {
        vm.prank(creator);
        testToken = launchpad.createToken(
            "TestToken", "TEST", "ipfs://test-metadata", address(bondingCurve), address(graduator)
        );

        _;
    }
}
