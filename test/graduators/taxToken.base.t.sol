// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseUniswapV4GraduationTests} from "test/graduators/graduationUniv4.base.t.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {RealmFactoryUniV4Unified} from "src/factories/RealmFactoryUniV4Unified.sol";
import {RealmTaxableTokenUniV4} from "src/tokens/RealmTaxableTokenUniV4.sol";
import {LivoSwapHook} from "src/hooks/LivoSwapHook.sol";
import {RealmGraduatorUniswapV4} from "src/graduators/RealmGraduatorUniswapV4.sol";
import {DeploymentAddressesEthereumMainnet} from "src/config/DeploymentAddresses.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {RealmToken} from "src/tokens/RealmToken.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPermit2} from "lib/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {IV4Router} from "lib/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {IUniversalRouter} from "src/interfaces/IUniswapV4UniversalRouter.sol";

/// @notice Base test class for RealmTaxableTokenUniV4 with LivoTaxSwapHook functionality
/// @dev Extends BaseUniswapV4GraduationTests and sets up tax-specific components
contract TaxTokenUniV4BaseTests is BaseUniswapV4GraduationTests {
    // Tax system components
    RealmTaxableTokenUniV4 public taxTokenImpl;

    // Default tax configuration
    uint16 public constant DEFAULT_SELL_TAX_BPS = 400; // 4%
    uint40 public constant DEFAULT_TAX_DURATION = 14 days;

    // WETH address for tax assertions
    address public constant WETH_ADDRESS = DeploymentAddressesEthereumMainnet.WETH;

    function setUp() public virtual override {
        super.setUp();
        taxTokenImpl = new RealmTaxableTokenUniV4();

        // Set graduator to tax-enabled version for tests
        graduator = graduatorV4;
    }

    /// @notice Helper to create a tax token with custom configuration
    /// @param sellTaxBps Sell tax rate in basis points (max 400)
    /// @param taxDurationSeconds Duration in seconds after graduation during which taxes apply
    /// @return tokenAddress The address of the created tax token
    function _createTaxToken(uint16 buyTaxBps, uint16 sellTaxBps, uint40 taxDurationSeconds)
        internal
        returns (address tokenAddress)
    {
        vm.prank(creator);
        tokenAddress = factoryTax.createToken(
            "TaxToken",
            "TAX",
            _nextValidSalt(address(factoryTax), address(realmTaxToken)),
            _fs(creator),
            _noSs(),
            false,
            _taxCfg(buyTaxBps, sellTaxBps, uint32(taxDurationSeconds)),
            _emptyAntiSniperCfg()
        );
    }

    /// @notice Helper to create a tax token whose tax window starts at graduation (not launch).
    /// @param buyTaxBps Buy tax rate in basis points
    /// @param sellTaxBps Sell tax rate in basis points
    /// @param taxDurationSeconds Tax window duration, measured from graduation
    /// @return tokenAddress The address of the created tax token
    function _createTaxTokenFromGraduation(uint16 buyTaxBps, uint16 sellTaxBps, uint40 taxDurationSeconds)
        internal
        returns (address tokenAddress)
    {
        vm.prank(creator);
        tokenAddress = factoryTax.createToken(
            "TaxToken",
            "TAX",
            _nextValidSalt(address(factoryTax), address(realmTaxToken)),
            _fs(creator),
            _noSs(),
            false,
            _taxCfg(buyTaxBps, sellTaxBps, uint32(taxDurationSeconds), false),
            _emptyAntiSniperCfg()
        );
    }

    /// @notice Helper to create a DECAY-only token (no long-term static tax) with a linear launch-tax
    ///         decay, creation-anchored. Exercises the V4 hook serving a decaying `getTaxConfig`.
    /// @param buyDecayStartBps Buy decay rate at launch (decays to 0 over `decayDuration`)
    /// @param sellDecayStartBps Sell decay rate at launch
    /// @param decayDuration Decay window length in seconds (from launch)
    function _createDecayToken(uint16 buyDecayStartBps, uint16 sellDecayStartBps, uint32 decayDuration)
        internal
        returns (address tokenAddress)
    {
        IRealmFactory.TokenSetupTiered memory setup = IRealmFactory.TokenSetupTiered({
            name: "DecayToken",
            symbol: "DCY",
            salt: _nextValidSalt(address(factoryTax), address(realmTaxToken)),
            feeShares: _fs(creator),
            liquidityTier: LiquidityTier.DEFAULT
        });
        vm.prank(creator);
        tokenAddress = factoryTax.createToken(
            setup,
            _decayCfg(buyDecayStartBps, sellDecayStartBps, decayDuration, true),
            RealmFactoryUniV4Unified.UniV4Configs({renounceOwnership: false, lpFeeBps: 100}),
            _noSs(),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            address(0)
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
            hooks: IHooks(address(taxHook))
        });
    }

    /// @notice Modifier to create a default tax token for testing
    modifier createDefaultTaxToken() {
        testToken = _createTaxToken(0, DEFAULT_SELL_TAX_BPS, DEFAULT_TAX_DURATION);
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
    ) internal virtual override {
        vm.startPrank(caller);
        IERC20(token).approve(address(permit2Address), type(uint256).max);
        IPermit2(permit2Address).approve(address(token), universalRouter, type(uint160).max, type(uint48).max);

        // Use tax hook address for pools created with tax graduator
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)), // native ETH
            currency1: Currency.wrap(address(token)),
            fee: lpFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(taxHook))
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
