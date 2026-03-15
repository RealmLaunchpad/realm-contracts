// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {ConstantProductBondingCurve} from "src/bondingCurves/ConstantProductBondingCurve.sol";
import {LivoGraduatorUniswapV2} from "src/graduators/LivoGraduatorUniswapV2.sol";
import {LivoGraduatorUniswapV4} from "src/graduators/LivoGraduatorUniswapV4.sol";
import {DeploymentAddressesMainnet} from "src/config/DeploymentAddresses.sol";
import {ILivoGraduator} from "src/interfaces/ILivoGraduator.sol";
import {TokenConfig, TokenState} from "src/types/tokenData.sol";
import {LiquidityLockUniv4WithFees} from "src/locks/LiquidityLockUniv4WithFees.sol";
import {ILiquidityLockUniv4WithFees} from "src/interfaces/ILiquidityLockUniv4WithFees.sol";
import {IUniswapV2Router02} from "src/interfaces/IUniswapV2Router02.sol";
import {IUniswapV2Factory} from "src/interfaces/IUniswapV2Factory.sol";
import {IWETH} from "src/interfaces/IWETH.sol";
import {LivoSwapHook} from "src/hooks/LivoSwapHook.sol";
import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {LivoFactoryBase} from "src/tokenFactories/LivoFactoryBase.sol";
import {LivoFactoryTaxToken} from "src/tokenFactories/LivoFactoryTaxToken.sol";
import {LivoFeeHandlerUniV2} from "src/feeHandlers/LivoFeeHandlerUniV2.sol";
import {LivoFeeHandlerUniV4} from "src/feeHandlers/LivoFeeHandlerUniV4.sol";
import {LivoFeeSplitter} from "src/feeSplitters/LivoFeeSplitter.sol";

contract TestLivoFactory is LivoFactoryBase {
    constructor(
        address launchpad,
        address tokenImplementation,
        address bondingCurve,
        address graduator,
        address feeHandler,
        address feeSplitterImplementation
    ) LivoFactoryBase(launchpad, tokenImplementation, bondingCurve, graduator, feeHandler, feeSplitterImplementation) {}
}

contract LaunchpadBaseTests is Test {
    LivoLaunchpad public launchpad;

    LivoToken public livoToken;
    LivoTaxableTokenUniV4 public livoTaxToken;

    ILivoToken public implementation;

    ConstantProductBondingCurve public bondingCurve;

    ILivoGraduator public graduator;

    TestLivoFactory public factoryV2;
    TestLivoFactory public factoryV4;
    LivoFactoryTaxToken public factoryTax;
    LivoFeeHandlerUniV2 public feeHandler;
    LivoFeeHandlerUniV4 public feeHandlerV4;

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
    uint256 public constant CREATOR_GRADUATION_COMPENSATION = 0.05 ether;
    uint256 constant GRADUATION_FEE = 0.25 ether;
    uint16 public constant BASE_BUY_FEE_BPS = 100;
    uint16 public constant BASE_SELL_FEE_BPS = 100;

    uint256 constant GRADUATION_THRESHOLD = 3.75 ether;
    uint256 constant MAX_THRESHOLD_EXCESS = 0.05 ether;

    // we don't test deadlines mostly
    uint256 constant DEADLINE = type(uint256).max;
    address constant DEAD_ADDRESS = DeploymentAddressesMainnet.DEAD_ADDRESS;

    // for fork tests
    uint256 constant BLOCKNUMBER = 23327777;

    // uniswapv4 addresses in mainnet
    address constant poolManagerAddress = DeploymentAddressesMainnet.UNIV4_POOL_MANAGER;
    address constant positionManagerAddress = DeploymentAddressesMainnet.UNIV4_POSITION_MANAGER;
    address constant permit2Address = DeploymentAddressesMainnet.PERMIT2;
    address constant universalRouter = DeploymentAddressesMainnet.UNIV4_UNIVERSAL_ROUTER;

    // Uniswap V2 router address on mainnet
    address constant UNISWAP_V2_ROUTER = DeploymentAddressesMainnet.UNIV2_ROUTER;
    IUniswapV2Factory constant UNISWAP_FACTORY = IUniswapV2Factory(DeploymentAddressesMainnet.UNIV2_FACTORY);
    IWETH constant WETH = IWETH(DeploymentAddressesMainnet.WETH);

    // This is the effective price when buying at graduation (from bonding curve slope)
    uint256 constant GRADUATION_PRICE = 12373924040; // ETH/token (eth per token, expressed in wei)
    // This is the pool setpoint price derived from SQRT_PRICEX96_GRADUATION
    uint256 constant POOL_SETPOINT_PRICE = 12249999999; // ETH/token (eth per token, expressed in wei)

    LiquidityLockUniv4WithFees public liquidityLock;
    LivoGraduatorUniswapV2 public graduatorV2;
    LivoGraduatorUniswapV4 public graduatorV4;
    LivoSwapHook public taxHook;

    function setUp() public virtual {
        string memory mainnetRpcUrl = vm.envString("MAINNET_RPC_URL");
        vm.createSelectFork(mainnetRpcUrl, BLOCKNUMBER);

        vm.deal(creator, INITIAL_ETH_BALANCE);
        vm.deal(buyer, INITIAL_ETH_BALANCE);
        vm.deal(seller, INITIAL_ETH_BALANCE);
        vm.deal(alice, INITIAL_ETH_BALANCE);
        vm.deal(bob, INITIAL_ETH_BALANCE);

        vm.startPrank(admin);
        livoToken = new LivoToken();
        livoTaxToken = new LivoTaxableTokenUniV4();

        // todo do we need this outside this setup ?
        implementation = livoToken;
        launchpad = new LivoLaunchpad(treasury);
        bondingCurve = new ConstantProductBondingCurve();
        graduatorV2 = new LivoGraduatorUniswapV2(UNISWAP_V2_ROUTER, address(launchpad));

        liquidityLock = new LiquidityLockUniv4WithFees(positionManagerAddress);

        deployCodeTo(
            "LivoSwapHook.sol:LivoSwapHook",
            abi.encode(poolManagerAddress, address(launchpad)),
            DeploymentAddressesMainnet.LIVO_SWAP_HOOK
        );
        taxHook = LivoSwapHook(payable(DeploymentAddressesMainnet.LIVO_SWAP_HOOK));

        feeHandler = new LivoFeeHandlerUniV2();

        feeHandlerV4 = new LivoFeeHandlerUniV4(
            address(launchpad),
            address(liquidityLock),
            poolManagerAddress,
            positionManagerAddress,
            DeploymentAddressesMainnet.LIVO_SWAP_HOOK
        );

        graduatorV4 = new LivoGraduatorUniswapV4(
            address(launchpad),
            address(liquidityLock),
            poolManagerAddress,
            positionManagerAddress,
            permit2Address,
            DeploymentAddressesMainnet.LIVO_SWAP_HOOK
        );
        feeHandlerV4.setAuthorizedGraduator(address(graduatorV4), true);

        LivoFeeSplitter feeSplitterImpl = new LivoFeeSplitter();

        factoryV2 = new TestLivoFactory(
            address(launchpad),
            address(livoToken),
            address(bondingCurve),
            address(graduatorV2),
            address(feeHandler),
            address(feeSplitterImpl)
        );

        factoryV4 = new TestLivoFactory(
            address(launchpad),
            address(livoToken),
            address(bondingCurve),
            address(graduatorV4),
            address(feeHandlerV4),
            address(feeSplitterImpl)
        );

        factoryTax = new LivoFactoryTaxToken(
            address(launchpad),
            address(livoTaxToken),
            address(bondingCurve),
            address(graduatorV4),
            address(feeHandlerV4),
            address(feeSplitterImpl)
        );

        launchpad.whitelistFactory(address(factoryV2));
        launchpad.whitelistFactory(address(factoryV4));
        launchpad.whitelistFactory(address(factoryTax));

        vm.stopPrank();
    }

    modifier createTestToken() virtual {
        vm.prank(creator);
        if (address(graduator) == address(graduatorV4)) {
            if (address(implementation) == address(livoTaxToken)) {
                testToken = factoryTax.createToken("TestToken", "TEST", creator, "0x003", 0, 500, uint32(14 days));
            } else {
                testToken = factoryV4.createToken("TestToken", "TEST", creator, "0x003");
            }
        } else {
            testToken = factoryV2.createToken("TestToken", "TEST", creator, "0x003");
        }
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
    uint256 public SELL_TAX_BPS = 0; // 0% sell tax

    function setUp() public virtual override {
        super.setUp();

        graduator = graduatorV2;
    }
}

contract LaunchpadBaseTestsWithUniv4Graduator is LaunchpadBaseTests {
    uint256 public SELL_TAX_BPS = 0; // 0% sell tax

    function setUp() public virtual override {
        super.setUp();

        graduator = graduatorV4;
    }
}

contract LaunchpadBaseTestsWithUniv4GraduatorTaxableToken is LaunchpadBaseTests {
    uint256 public SELL_TAX_BPS = 500; // 5% sell tax

    function setUp() public virtual override {
        super.setUp();

        graduator = graduatorV4;
        /// todo question do we need this?
        implementation = livoTaxToken;
    }
}
