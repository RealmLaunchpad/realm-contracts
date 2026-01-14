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

    // TODO: Replace with actual pre-computed hook address
    // Required permissions: AFTER_SWAP_FLAG (0x04) | AFTER_SWAP_RETURNS_DELTA_FLAG (0x40) = 0x44
    // Hook address must have these flags encoded in its address per UniV4 requirements
    address public constant PRECOMPUTED_HOOK_ADDRESS = 0xf84841AB25aCEcf0907Afb0283aB6Da38E5FC044; // PLACEHOLDER
    // I think this is only used to deploy, but since we are etching, it is not needed in this test
    bytes32 constant HOOK_SALT = bytes32(uint256(0x3b57));

    function setUp() public virtual override {
        super.setUp();

        vm.startPrank(admin);

        // Deploy hook directly to pre-computed address using deployCodeTo
        // This bypasses the temp deployment issue where BaseHook constructor validates
        // that the deployed address has correct permission flags (0x44)
        deployCodeTo(
            "LivoTaxSwapHook.sol:LivoTaxSwapHook",
            abi.encode(poolManager),
            PRECOMPUTED_HOOK_ADDRESS
        );
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
        // Encode tax configuration
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

    /// @notice Helper to create a standard (non-taxable) token with the tax hook graduator
    /// @dev Used for backward compatibility testing
    /// @return tokenAddress The address of the created standard token
    function _createStandardTokenWithTaxHookGraduator() internal returns (address tokenAddress) {
        vm.prank(creator);
        tokenAddress = launchpad.createToken(
            "StandardToken",
            "STD",
            address(standardTokenImpl),
            address(bondingCurve),
            address(graduatorWithTaxHooks), // Uses tax hook graduator
            creator,
            "0x003",
            "" // No tokenCalldata needed for standard token
        );
    }

    /// @notice Helper to get pool key with tax hook
    /// @param tokenAddress The token address
    /// @return PoolKey with tax hook configured
    function _getPoolKeyWithTaxHook(address tokenAddress) internal view returns (PoolKey memory) {
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
}
