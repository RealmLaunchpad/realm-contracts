// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseUniswapV4GraduationTests} from "test/graduators/graduationUniv4.base.t.sol";
import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {LivoSwapHook} from "src/hooks/LivoSwapHook.sol";
import {LivoGraduatorUniswapV4} from "src/graduators/LivoGraduatorUniswapV4.sol";
import {DeploymentAddressesMainnet} from "src/config/DeploymentAddresses.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPermit2} from "lib/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {IV4Router} from "lib/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {IUniversalRouter} from "src/interfaces/IUniswapV4UniversalRouter.sol";

/// @notice Base test class for LivoTaxableTokenUniV4 with LivoTaxSwapHook functionality
/// @dev Extends BaseUniswapV4GraduationTests and sets up tax-specific components
contract TaxTokenUniV4BaseTests is BaseUniswapV4GraduationTests {
    // Tax system components
    LivoTaxableTokenUniV4 public taxTokenImpl;

    // Default tax configuration
    uint16 public constant DEFAULT_BUY_TAX_BPS = 300; // 3%
    uint16 public constant DEFAULT_SELL_TAX_BPS = 500; // 5%
    uint40 public constant DEFAULT_TAX_DURATION = 14 days;

    // WETH address for tax assertions
    address public constant WETH_ADDRESS = DeploymentAddressesMainnet.WETH;

    function setUp() public virtual override {
        super.setUp();

        vm.startPrank(admin);

        // Deploy tax token implementation
        taxTokenImpl = new LivoTaxableTokenUniV4();

        // Whitelist tax-token implementation with graduatorV4 (which already has the right hook)
        launchpad.whitelistComponents(
            address(taxTokenImpl),
            address(bondingCurve),
            address(graduatorV4), // includes LivoSwapHook by default
            GRADUATION_THRESHOLD,
            MAX_THRESHOLD_EXCESS,
            GRADUATION_FEE
        );

        vm.stopPrank();

        // Set graduator to tax-enabled version for tests
        graduator = graduatorV4;
    }

    /// @notice Helper to create a tax token with custom configuration
    /// @param buyTaxBps Buy tax rate in basis points (max 500)
    /// @param sellTaxBps Sell tax rate in basis points (max 500)
    /// @param taxDurationSeconds Duration in seconds after graduation during which taxes apply
    /// @return tokenAddress The address of the created tax token
    function _createTaxToken(uint16 buyTaxBps, uint16 sellTaxBps, uint40 taxDurationSeconds)
        internal
        returns (address tokenAddress)
    {
        // Encode tax configuration with V4 integration parameters
        bytes memory tokenCalldata = taxTokenImpl.encodeTokenCalldata(buyTaxBps, sellTaxBps, taxDurationSeconds);

        vm.prank(creator);
        tokenAddress = launchpad.createToken(
            "TaxToken",
            "TAX",
            address(taxTokenImpl),
            address(bondingCurve),
            address(graduatorV4),
            creator, // token owner (will receive taxes)
            "0x003", // imageUrl
            tokenCalldata // tax configuration
        );
    }

    /// @notice Helper to get pool key with tax hook
    /// @param tokenAddress The token address
    /// @return PoolKey with tax hook configured
    function _getPoolKeyWithTaxHook(address tokenAddress) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)), // native ETH
            currency1: Currency.wrap(address(tokenAddress)),
            fee: lpFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(DeploymentAddressesMainnet.LIVO_SWAP_HOOK)
        });
    }

    /// @notice Modifier to create a default tax token for testing
    modifier createDefaultTaxToken() {
        testToken = _createTaxToken(DEFAULT_BUY_TAX_BPS, DEFAULT_SELL_TAX_BPS, DEFAULT_TAX_DURATION);
        _;
    }

    /// @notice Override _swap to use the tax hook address in the pool key
    /// @dev Both taxable and non-tax tokens use the same LivoSwapHook
    function _swap(
        address caller,
        address token,
        uint256 amountIn,
        uint256 minAmountOut,
        bool isBuy,
        bool expectSuccess
    ) internal override {
        vm.startPrank(caller);
        IERC20(token).approve(address(permit2Address), type(uint256).max);
        IPermit2(permit2Address).approve(address(token), universalRouter, type(uint160).max, type(uint48).max);

        // Use tax hook address for pools created with tax graduator
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)), // native ETH
            currency1: Currency.wrap(address(token)),
            fee: lpFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(DeploymentAddressesMainnet.LIVO_SWAP_HOOK)
        });

        bytes[] memory params = new bytes[](3);

        // First parameter: swap configuration
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: isBuy, // true if we're swapping token0 for token1 (buying tokens with eth)
                amountIn: uint128(amountIn), // amount of tokens we're swapping
                amountOutMinimum: uint128(minAmountOut), // minimum amount we expect to receive
                hookData: bytes("") // no hook data needed
            })
        );

        // Encode the Universal Router command
        uint256 V4_SWAP = 0x10;
        bytes memory commands = abi.encodePacked(uint8(V4_SWAP));
        bytes[] memory inputs = new bytes[](1);

        // Encode V4Router actions
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        // the token we are getting rid of
        Currency tokenIn = isBuy ? key.currency0 : key.currency1;
        params[1] = abi.encode(tokenIn, amountIn);
        // the token we are receiving
        Currency tokenOut = isBuy ? key.currency1 : key.currency0;
        params[2] = abi.encode(tokenOut, minAmountOut);

        // Combine actions and params into inputs
        inputs[0] = abi.encode(actions, params);

        if (!expectSuccess) {
            vm.expectRevert();
        }
        // Execute the swap
        uint256 valueIn = isBuy ? amountIn : 0;
        IUniversalRouter(universalRouter).execute{value: valueIn}(commands, inputs, block.timestamp);
        vm.stopPrank();
    }

    /// @notice make sure the hook precomputed for the tests is set in the LivoSwapHook correctly
    function test_percomputedHookInLivoSwapHook() public {
        LivoTaxableTokenUniV4 taxToken = new LivoTaxableTokenUniV4();
        address taxHook_inToken = taxToken.TAX_HOOK();

        address taxHook_inTests = DeploymentAddressesMainnet.LIVO_SWAP_HOOK;

        assertEq(taxHook_inToken, taxHook_inTests, "missmatching hook address in tests and in LivoTaxableTokenUniV4");
    }
}
