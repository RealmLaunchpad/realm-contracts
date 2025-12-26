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
    LivoToken public implementation;
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
    uint256 public constant OWNER_RESERVED_SUPPLY = 10_000_000e18;
    uint16 public constant BASE_BUY_FEE_BPS = 100;
    uint16 public constant BASE_SELL_FEE_BPS = 100;

    // used for both combinations of curves,graduators for univ2 and univ4
    uint256 constant GRADUATION_THRESHOLD = 7956000000000052224; // ~8 ether
    uint256 constant MAX_THRESHOLD_EXCESS = 0.1 ether;
    uint256 constant GRADUATION_FEE = 0.5 ether;

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

    // Uniswap V2 router address on mainnet
    address constant UNISWAP_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    IUniswapV2Factory constant UNISWAP_FACTORY = IUniswapV2Factory(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f);
    IWETH constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    // This is the price setpoint, but does not include trading fees
    uint256 constant GRADUATION_PRICE = 39011306440; // ETH/token (eth per token, expressed in wei)

    LiquidityLockUniv4WithFees public liquidityLock;
    LivoGraduatorUniswapV2 public graduatorV2;
    LivoGraduatorUniswapV4 public graduatorV4;

    function setUp() public virtual {
        string memory mainnetRpcUrl = vm.envString("MAINNET_RPC_URL");
        vm.createSelectFork(mainnetRpcUrl, BLOCKNUMBER);

        vm.deal(creator, INITIAL_ETH_BALANCE);
        vm.deal(buyer, INITIAL_ETH_BALANCE);
        vm.deal(seller, INITIAL_ETH_BALANCE);
        vm.deal(alice, INITIAL_ETH_BALANCE);
        vm.deal(bob, INITIAL_ETH_BALANCE);

        vm.startPrank(admin);
        implementation = new LivoToken();
        launchpad = new LivoLaunchpad(treasury);
        bondingCurve = new ConstantProductBondingCurve();

        // V2 graduator
        graduatorV2 = new LivoGraduatorUniswapV2(UNISWAP_V2_ROUTER, address(launchpad));
        launchpad.whitelistComponents(
            address(implementation),
            address(bondingCurve),
            address(graduatorV2),
            GRADUATION_THRESHOLD,
            MAX_THRESHOLD_EXCESS,
            GRADUATION_FEE
        );

        // V4 graduator
        liquidityLock = new LiquidityLockUniv4WithFees(positionManagerAddress);
        graduatorV4 = new LivoGraduatorUniswapV4(
            address(launchpad), address(liquidityLock), poolManagerAddress, positionManagerAddress, permit2Address
        );
        launchpad.whitelistComponents(
            address(implementation),
            address(bondingCurve),
            address(graduatorV4),
            GRADUATION_THRESHOLD,
            MAX_THRESHOLD_EXCESS,
            GRADUATION_FEE
        );

        vm.stopPrank();
    }

    modifier createTestToken() {
        vm.prank(creator);
        // this graduator is not defined here in the base, so it will be address(0) unless inherited by LaunchpadBaseTestsWithUniv2Graduator or V4
        testToken = launchpad.createToken(
            "TestToken", "TEST", address(implementation), address(bondingCurve), address(graduator), creator, "0x003"
        );
        _;
    }

    function _graduateToken() internal {
        uint256 ethReserves = launchpad.getTokenState(testToken).ethCollected;
        uint256 missingForGraduation = _increaseWithFees(GRADUATION_THRESHOLD - ethReserves);
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
    function setUp() public virtual override {
        super.setUp();

        graduator = graduatorV2;
    }
}

contract LaunchpadBaseTestsWithUniv4Graduator is LaunchpadBaseTests {
    function setUp() public virtual override {
        super.setUp();

        graduator = graduatorV4;
    }
}
