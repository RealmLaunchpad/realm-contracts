// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseUniswapV4GraduationTests} from "test/graduators/graduationUniv4.base.t.sol";
import {LivoTaxTokenUniV4} from "src/tokens/LivoTaxTokenUniV4.sol";
import {LivoTaxSwapHook} from "src/hooks/LivoTaxSwapHook.sol";
import {LivoGraduatorUniswapV4WithTaxHooks} from "src/graduators/LivoGraduatorUniswapV4WithTaxHooks.sol";
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

/// @notice Base test class for LivoTaxTokenUniV4 with LivoTaxSwapHook functionality
/// @dev Extends BaseUniswapV4GraduationTests and sets up tax-specific components
contract TaxTokenUniV4BaseTests is BaseUniswapV4GraduationTests {
    // Tax system components
    LivoTaxSwapHook public taxHook;
    LivoTaxTokenUniV4 public taxTokenImpl;
    LivoGraduatorUniswapV4WithTaxHooks public graduatorWithTaxHooks;

    // Standard LivoToken implementation (for backward compatibility tests)
    LivoToken public standardTokenImpl;

    // Default tax configuration
    uint16 public constant DEFAULT_BUY_TAX_BPS = 300; // 3%
    uint16 public constant DEFAULT_SELL_TAX_BPS = 500; // 5%
    uint40 public constant DEFAULT_TAX_DURATION = 14 days;

    // WETH address for tax assertions
    address public constant WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // TODO: Replace with actual pre-computed hook address
    // Required permissions: AFTER_SWAP_FLAG (0x04) | AFTER_SWAP_RETURNS_DELTA_FLAG (0x40) = 0x44
    // Hook address must have these flags encoded in its address per UniV4 requirements
    address payable public constant PRECOMPUTED_HOOK_ADDRESS = payable(0xf84841AB25aCEcf0907Afb0283aB6Da38E5FC044); // PLACEHOLDER
    // I think this is only used to deploy, but since we are etching, it is not needed in this test
    bytes32 constant HOOK_SALT = bytes32(uint256(0x3b57));

    function setUp() public virtual override {
        super.setUp();

        vm.startPrank(admin);

        // Deploy hook directly to pre-computed address using deployCodeTo
        // This bypasses the temp deployment issue where BaseHook constructor validates
        // that the deployed address has correct permission flags (0x44)
        deployCodeTo("LivoTaxSwapHook.sol:LivoTaxSwapHook", abi.encode(poolManager), PRECOMPUTED_HOOK_ADDRESS);
        taxHook = LivoTaxSwapHook(PRECOMPUTED_HOOK_ADDRESS);

        // Deploy tax token implementation
        taxTokenImpl = new LivoTaxTokenUniV4();

        // Deploy graduator with tax hooks
        graduatorWithTaxHooks = new LivoGraduatorUniswapV4WithTaxHooks(
            address(launchpad),
            address(liquidityLock),
            poolManagerAddress,
            positionManagerAddress,
            permit2Address,
            PRECOMPUTED_HOOK_ADDRESS
        );

        // Whitelist tax token implementation with tax graduator
        launchpad.whitelistComponents(
            address(taxTokenImpl),
            address(bondingCurve),
            address(graduatorWithTaxHooks),
            GRADUATION_THRESHOLD,
            MAX_THRESHOLD_EXCESS,
            GRADUATION_FEE
        );

        // Also deploy standard token implementation for backward compatibility tests
        standardTokenImpl = new LivoToken();

        // Whitelist standard token with tax graduator (for backward compatibility testing)
        launchpad.whitelistComponents(
            address(standardTokenImpl),
            address(bondingCurve),
            address(graduatorWithTaxHooks),
            GRADUATION_THRESHOLD,
            MAX_THRESHOLD_EXCESS,
            GRADUATION_FEE
        );

        vm.stopPrank();

        // Set graduator to tax-enabled version for tests
        graduator = graduatorWithTaxHooks;
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
            address(graduatorWithTaxHooks),
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
            hooks: IHooks(PRECOMPUTED_HOOK_ADDRESS)
        });
    }

    /// @notice Modifier to create a default tax token for testing
    modifier createDefaultTaxToken() {
        testToken = _createTaxToken(DEFAULT_BUY_TAX_BPS, DEFAULT_SELL_TAX_BPS, DEFAULT_TAX_DURATION);
        _;
    }

    /// @notice Override _swap to use the tax hook address in the pool key
    /// @dev The base class uses hooks: IHooks(address(0)), but tax token pools use the tax hook
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
            hooks: IHooks(PRECOMPUTED_HOOK_ADDRESS)
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
}
