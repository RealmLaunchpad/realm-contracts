// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {ConstantProductBondingCurve} from "src/bondingCurves/ConstantProductBondingCurve.sol";
import {LivoGraduatorUniswapV2} from "src/graduators/LivoGraduatorUniswapV2.sol";
import {LivoGraduatorUniswapV4} from "src/graduators/LivoGraduatorUniswapV4.sol";
import {LivoUniV4LiquidityAdder} from "src/liquidity/LivoUniV4LiquidityAdder.sol";
import {UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants.sol";
import {LivoFactoryAbstract} from "src/factories/LivoFactoryAbstract.sol";
import {LivoFactoryUniV4Unified} from "src/factories/LivoFactoryUniV4Unified.sol";
import {LivoFactoryUniV2Unified} from "src/factories/LivoFactoryUniV2Unified.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {LivoSwapHook} from "src/hooks/LivoSwapHook.sol";
import {DeploymentAddressesEthereumMainnet} from "src/config/DeploymentAddresses.sol";
import {LivoMasterFeeHandler} from "src/feeHandlers/LivoMasterFeeHandler.sol";
import {TokenConfig, TokenState} from "src/types/tokenData.sol";
import {InvariantsHelperLaunchpad} from "./helper.t.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

contract LaunchpadInvariants is Test {
    LivoLaunchpad public launchpad;
    LivoToken public tokenImplementation;
    ConstantProductBondingCurve public bondingCurve;
    LivoGraduatorUniswapV2 public graduatorV2;
    LivoGraduatorUniswapV4 public graduatorV4;
    LivoFactoryUniV2Unified public factoryV2;
    LivoFactoryUniV4Unified public factoryV4;
    LivoMasterFeeHandler public feeHandler;

    InvariantsHelperLaunchpad public helper;

    address constant poolManagerAddress = DeploymentAddressesEthereumMainnet.UNIV4_POOL_MANAGER;
    address constant positionManagerAddress = DeploymentAddressesEthereumMainnet.UNIV4_POSITION_MANAGER;
    address constant permit2Address = DeploymentAddressesEthereumMainnet.PERMIT2;

    // Hook address with correct Uniswap V4 permission bits; deployCodeTo() overrides whatever is at this address
    address constant TEST_HOOK_ADDRESS = 0x2ca2764a626de36331E20b08aEd13E5C7A0240cC;

    address public treasury = makeAddr("treasury");
    address public creator = makeAddr("creator");
    address public buyer = makeAddr("buyer");
    address public seller = makeAddr("seller");

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    address public testToken;

    address public admin = makeAddr("admin");

    uint256 public constant INITIAL_ETH_BALANCE = 100 ether;
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 public constant OWNER_RESERVED_SUPPLY = 10_000_000e18;
    uint16 public constant BASE_BUY_FEE_BPS = 100;
    uint16 public constant BASE_SELL_FEE_BPS = 100;

    // Uniswap V2 router address on mainnet
    address constant UNISWAP_V2_ROUTER = DeploymentAddressesEthereumMainnet.UNIV2_ROUTER;
    // for fork tests
    uint256 constant BLOCKNUMBER = 23327777;

    // used for both combinations of curves,graduators for univ2 and univ4
    uint256 constant GRADUATION_THRESHOLD = 3.75 ether;
    uint256 constant MAX_THRESHOLD_EXCESS = 0.1 ether;

    function setUp() public virtual {
        string memory mainnetRpcUrl = vm.envString("MAINNET_RPC_URL");
        vm.createSelectFork(mainnetRpcUrl, BLOCKNUMBER);

        vm.startPrank(admin);

        // the actual deployments
        tokenImplementation = new LivoToken();
        launchpad = new LivoLaunchpad(treasury, admin);

        bondingCurve = new ConstantProductBondingCurve();
        // For graduation tests, a new graduatorV2 should be deployed, and use fork tests.
        graduatorV2 = new LivoGraduatorUniswapV2(
            UNISWAP_V2_ROUTER, address(launchpad), DeploymentAddressesEthereumMainnet.UNIV2_PAIR_INIT_CODE_HASH
        );
        // These invariants only exercise pre-graduation bonding-curve trades, so the hook never routes a
        // fee and its LP-fee router is a dummy. Deploy a real `LivoLpFeeRouter` here if a handler ever
        // starts performing post-graduation V4 swaps.
        deployCodeTo(
            "LivoSwapHook.sol:LivoSwapHook",
            abi.encode(poolManagerAddress, makeAddr("lpFeeRouterDummy"), treasury),
            TEST_HOOK_ADDRESS
        );
        feeHandler = new LivoMasterFeeHandler();

        address univ4LiquidityAdder = address(new LivoUniV4LiquidityAdder(positionManagerAddress, poolManagerAddress));
        graduatorV4 = new LivoGraduatorUniswapV4(
            address(launchpad),
            poolManagerAddress,
            positionManagerAddress,
            permit2Address,
            TEST_HOOK_ADDRESS,
            715832709642994126662528799866880, // DEFAULT tier graduation sqrtPriceX96 (12.25 ETH mcap)
            UniswapV4PoolConstants.TICK_UPPER,
            univ4LiquidityAdder
        );

        // The unified factories take a base and a tax token impl. The invariant helper only ever uses
        // the base path (no tax), so we pass `tokenImplementation` for both slots. Anti-sniper is a
        // gated feature of the same impl, so no separate impl is needed.
        // Creator-vault + non-default-tier curves are unused in this suite (only the DEFAULT base path
        // is exercised), so they are left zero.
        address[6] memory emptyVaultCurves;
        ILivoFactory.LiquidityTierConfig memory emptyTierConfig;
        address factoryV2Impl = address(
            new LivoFactoryUniV2Unified(
                address(launchpad),
                ILivoFactory.TokenImpls({base: address(tokenImplementation), tax: address(tokenImplementation)}),
                address(bondingCurve),
                address(graduatorV2),
                address(feeHandler),
                address(0),
                emptyVaultCurves,
                emptyTierConfig
            )
        );
        factoryV2 = LivoFactoryUniV2Unified(
            address(new ERC1967Proxy(factoryV2Impl, abi.encodeCall(LivoFactoryAbstract.initialize, ())))
        );

        LivoFactoryUniV4Unified.V4TierConfig memory emptyV4Tier;
        address factoryV4Impl = address(
            new LivoFactoryUniV4Unified(
                address(launchpad),
                ILivoFactory.TokenImpls({base: address(tokenImplementation), tax: address(tokenImplementation)}),
                address(bondingCurve),
                address(graduatorV4),
                address(feeHandler),
                address(0),
                emptyVaultCurves,
                emptyV4Tier
            )
        );
        factoryV4 = LivoFactoryUniV4Unified(
            address(new ERC1967Proxy(factoryV4Impl, abi.encodeCall(LivoFactoryAbstract.initialize, ())))
        );

        launchpad.whitelistFactory(address(factoryV2));
        launchpad.whitelistFactory(address(factoryV4));
        vm.stopPrank();

        helper = new InvariantsHelperLaunchpad(launchpad, factoryV2, factoryV4, address(tokenImplementation));

        targetContract(address(helper));
    }

    ///////////////////////////// Cross checking against ghost variables //////////////////

    ///////////////////////////// Launchpad invariants ////////////////////////////////////

    /// @notice the launchpad eth balance should match the sum of all token ethCollected plus the treasury balance
    function invariant_launchpadEthBalance() public view {
        assertEq(
            address(launchpad).balance, _totalEthCollected(), "launchpad eth balance does not match total eth collected"
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

    /// @notice each non-graduated token should have a balance in the launchpad above OWNER_RESERVED_SUPPLY
    function invariant_nonGraduatedTokensAboveOwnerReserved() public view {
        for (uint256 i = 0; i < helper.nTokens(); i++) {
            address token = helper.tokenAt(i);
            assertGt(
                IERC20(token).balanceOf(address(launchpad)),
                OWNER_RESERVED_SUPPLY,
                "non-graduated token has balance in launchpad below OWNER_RESERVED_SUPPLY"
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
                GRADUATION_THRESHOLD,
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
