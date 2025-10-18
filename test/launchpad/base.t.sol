// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {LivoToken} from "src/LivoToken.sol";
import {ConstantProductBondingCurve} from "src/bondingCurves/ConstantProductBondingCurve.sol";
import {LivoGraduatorUniswapV2} from "src/graduators/LivoGraduatorUniswapV2.sol";
import {LivoGraduatorUniswapV4} from "src/graduators/LivoGraduatorUniswapV4.sol";
import {ILivoGraduator} from "src/interfaces/ILivoGraduator.sol";
import {TokenConfig, TokenState} from "src/types/tokenData.sol";
import {LiquidityLockUniv4WithFees} from "src/locks/LiquidityLockUniv4WithFees.sol";
import {ILiquidityLockUniv4WithFees} from "src/interfaces/ILiquidityLockUniv4WithFees.sol";
import {IUniswapV2Router02} from "src/interfaces/IUniswapV2Router02.sol";
import {IUniswapV2Factory} from "src/interfaces/IUniswapV2Factory.sol";
import {IWETH} from "src/interfaces/IWETH.sol";

contract LaunchpadBaseTests is Test {
    LivoLaunchpad public launchpad;
    LivoToken public tokenImplementation;
    ConstantProductBondingCurve public bondingCurve;

    ILivoGraduator public graduator;

    address public treasury = makeAddr("treasury");
    address public creator = makeAddr("creator");
    address public buyer = makeAddr("buyer");
    address public seller = makeAddr("seller");

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    address public admin = makeAddr("admin");

    address public testToken;

    uint256 public constant INITIAL_ETH_BALANCE = 100 ether;
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 public constant CREATOR_RESERVED_SUPPLY = 10_000_000e18;
    uint256 public constant BASE_GRADUATION_THRESHOLD = 7956000000000052224;
    uint256 public constant BASE_GRADUATION_FEE = 0.5 ether;
    uint16 public constant BASE_BUY_FEE_BPS = 100;
    uint16 public constant BASE_SELL_FEE_BPS = 100;

    uint256 MAX_THRESHOLD_EXCESS;

    // we don't test deadlines mostly
    uint256 constant DEADLINE = type(uint256).max;
    address constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // for fork tests
    uint256 constant BLOCKNUMBER = 23327777;

    // uniswapv4 addresses in mainnet
    address constant poolManagerAddress = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant positionManagerAddress = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;

    address constant permit2Address = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant universalRouter = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;

    address constant uniswapV4NftAddress = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;

    // Uniswap V2 contracts on mainnet
    IUniswapV2Factory constant UNISWAP_FACTORY = IUniswapV2Factory(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f);
    IWETH constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    // This is the price setpoint, but does not include trading fees
    uint256 constant GRADUATION_PRICE = 39011306440; // ETH/token (eth per token, expressed in wei)

    LiquidityLockUniv4WithFees public liquidityLock;

    function setUp() public virtual {
        string memory mainnetRpcUrl = vm.envString("MAINNET_RPC_URL");
        vm.createSelectFork(mainnetRpcUrl, BLOCKNUMBER);

        vm.startPrank(admin);
        tokenImplementation = new LivoToken();
        launchpad = new LivoLaunchpad(treasury, address(tokenImplementation));
        bondingCurve = new ConstantProductBondingCurve();
        vm.stopPrank();

        vm.deal(creator, INITIAL_ETH_BALANCE);
        vm.deal(buyer, INITIAL_ETH_BALANCE);
        vm.deal(seller, INITIAL_ETH_BALANCE);
        vm.deal(alice, INITIAL_ETH_BALANCE);
        vm.deal(bob, INITIAL_ETH_BALANCE);

        MAX_THRESHOLD_EXCESS = launchpad.graduationExcessCap();
    }

    modifier createTestToken() {
        vm.prank(creator);
        // this graduator is not defined here in the base, so it will be address(0) unless inherited by LaunchpadBaseTestsWithUniv2Graduator or V4
        testToken = launchpad.createToken("TestToken", "TEST", address(bondingCurve), address(graduator));
        _;
    }

    function _graduateToken() internal {
        uint256 ethReserves = launchpad.getTokenState(testToken).ethCollected;
        uint256 missingForGraduation = _increaseWithFees(BASE_GRADUATION_THRESHOLD - ethReserves);
        _launchpadBuy(testToken, missingForGraduation);
    }

    function _launchpadBuy(address token, uint256 value) internal {
        vm.deal(buyer, value);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: value}(token, 0, DEADLINE);
    }

    function _increaseWithFees(uint256 ethIntoReserves) internal pure returns (uint256 ethBuy) {
        ethBuy = (ethIntoReserves * 10000) / (10000 - BASE_BUY_FEE_BPS);
    }
}

contract LaunchpadBaseTestsWithUniv2Graduator is LaunchpadBaseTests {
    // Uniswap V2 router address on mainnet
    address constant UNISWAP_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

    function setUp() public virtual override {
        super.setUp();

        // For graduation tests, a new graduator should be deployed, and use fork tests.
        vm.prank(admin);
        graduator = new LivoGraduatorUniswapV2(UNISWAP_V2_ROUTER, address(launchpad));

        vm.prank(admin);
        launchpad.whitelistCurveAndGraduator(address(bondingCurve), address(graduator), true);
    }
}

contract LaunchpadBaseTestsWithUniv4Graduator is LaunchpadBaseTests {
    function setUp() public virtual override {
        super.setUp();

        vm.prank(admin);
        liquidityLock = new LiquidityLockUniv4WithFees(uniswapV4NftAddress, positionManagerAddress);

        // For graduation tests, a new graduator should be deployed, and use fork tests.
        vm.prank(admin);
        graduator = new LivoGraduatorUniswapV4(
            address(launchpad),
            address(liquidityLock),
            poolManagerAddress,
            positionManagerAddress,
            permit2Address
        );

        vm.prank(admin);
        launchpad.whitelistCurveAndGraduator(address(bondingCurve), address(graduator), true);
    }
}
