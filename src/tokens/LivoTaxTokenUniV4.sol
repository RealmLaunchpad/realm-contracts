// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LivoToken} from "src/tokens/LivoToken.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {ILivoTokenTaxable} from "src/interfaces/ILivoTokenTaxable.sol";
import {ILivoLaunchpad} from "src/interfaces/ILivoLaunchpad.sol";

// UniswapV4 imports for tax swap functionality
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IV4Router} from "lib/v4-periphery/src/interfaces/IV4Router.sol";

/// @title LivoTaxTokenUniV4
/// @notice ERC20 token implementation with time-limited buy/sell taxes enforced via Uniswap V4 hooks
/// @dev Extends LivoToken to add tax configuration that is queried by LivoTaxSwapHook
contract LivoTaxTokenUniV4 is LivoToken, ILivoTokenTaxable {
    /// @notice Maximum allowed tax rate (500 basis points = 5%)
    uint16 public constant MAX_TAX_BPS = 500;

    /// @notice Maximum duration for the tax period after graduation timestamp
    uint40 public constant MAX_TAX_DURATION_SECONDS = 14 days;

    /// @notice Buy tax rate in basis points (set during initialization, cannot be changed)
    uint16 public buyTaxBps;

    /// @notice Sell tax rate in basis points (set during initialization, cannot be changed)
    uint16 public sellTaxBps;

    /// @notice Duration in seconds after graduation during which taxes apply (set during initialization, cannot be changed)
    uint40 public taxDurationSeconds;

    // todo change this to tokenOwner
    /// @notice Address receiving tax payments (set during initialization, cannot be changed)
    address public taxRecipient;

    /// @notice Timestamp when token graduated (0 if not graduated)
    uint40 public graduationTimestamp;

    // todo all these args ... can we have them as immutable args with the immutable cloning thing?
    /// @notice Pool manager for lock state checking
    IPoolManager public poolManager;

    /// @notice V4 Router for executing tax swaps
    address public v4Router;

    /// @notice Pool key for this token's ETH pair
    PoolKey public poolKey;

    /// @notice Reentrancy guard for tax swap
    bool private _inSwap;

    //////////////////////// Errors //////////////////////

    error InvalidTaxRate(uint16 rate);
    error InvalidTaxDuration();
    error InvalidTaxRecipient();
    error InvalidTaxCalldata();
    error InvalidV4Router();
    error InvalidHook();

    //////////////////////////////////////////////////////

    /// @notice Creates a new LivoTaxTokenUniV4 instance which will be used as implementation for clones
    /// @dev Token configuration is set during initialization, not in constructor
    constructor() LivoToken() {
        // Constructor body intentionally left empty
        // All initialization happens in initialize() due to minimal proxy pattern
    }

    /// @notice Initializes the token clone with its parameters including tax configuration
    /// @param name_ The token name
    /// @param symbol_ The token symbol
    /// @param graduator_ Address of the graduator contract
    /// @param pair_ Address of the pool manager for V4
    /// @param supplyReceiver_ Address receiving the total supply of tokens (launchpad)
    /// @param totalSupply_ Total supply to mint
    /// @param tokenCalldata Extended tax config: (buyTaxBps, sellTaxBps, taxDurationSeconds, v4Router, hook, fee, tickSpacing)
    function initialize(
        string memory name_,
        string memory symbol_,
        address graduator_,
        address pair_,
        address supplyReceiver_,
        uint256 totalSupply_,
        bytes memory tokenCalldata
    ) external override(ILivoToken, LivoToken) initializer {
        require(graduator_ != address(0), InvalidGraduator());
        if (tokenCalldata.length == 0) revert InvalidTaxCalldata();

        // Decode and validate tax configuration (scoped to limit stack)
        _initializeTaxConfig(tokenCalldata, supplyReceiver_);

        // Store V4 integration parameters
        poolManager = IPoolManager(pair_);

        // storage variables inherited from LivoToken
        _tokenName = name_;
        _tokenSymbol = symbol_;
        graduator = graduator_;
        pair = pair_;

        // all is minted back to the launchpad
        _mint(supplyReceiver_, totalSupply_);
    }

    /// @notice Internal helper to decode and validate tax configuration
    /// @dev Separated to reduce stack depth in initialize()
    function _initializeTaxConfig(bytes memory tokenCalldata, address supplyReceiver_) internal {
        (
            uint16 _buyTaxBps,
            uint16 _sellTaxBps,
            uint40 _taxDurationSeconds,
            address _v4Router,
            address _hook,
            uint24 _fee,
            int24 _tickSpacing
        ) = abi.decode(tokenCalldata, (uint16, uint16, uint40, address, address, uint24, int24));

        // Validate tax rates
        if (_buyTaxBps > MAX_TAX_BPS) revert InvalidTaxRate(_buyTaxBps);
        if (_sellTaxBps > MAX_TAX_BPS) revert InvalidTaxRate(_sellTaxBps);
        if (_taxDurationSeconds > MAX_TAX_DURATION_SECONDS) revert InvalidTaxDuration();
        if (_v4Router == address(0)) revert InvalidV4Router();
        if (_hook == address(0)) revert InvalidHook();

        // Get tax recipient (token owner) from the launchpad
        address _taxRecipient = ILivoLaunchpad(supplyReceiver_).getTokenOwner(address(this));
        if (_taxRecipient == address(0)) revert InvalidTaxRecipient();

        // Store tax configuration
        buyTaxBps = _buyTaxBps;
        sellTaxBps = _sellTaxBps;
        taxDurationSeconds = _taxDurationSeconds;
        taxRecipient = _taxRecipient;
        v4Router = _v4Router;

        // Construct pool key for this token's ETH pair
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(this)),
            fee: _fee,
            tickSpacing: _tickSpacing,
            hooks: IHooks(_hook)
        });
    }

    /// @notice Marks the token as graduated and records the timestamp
    /// @dev Can only be called by the pre-set graduator contract
    /// @dev Overrides LivoToken.markGraduated() to add timestamp tracking
    function markGraduated() external override(ILivoToken, LivoToken) {
        require(msg.sender == graduator, OnlyGraduatorAllowed());

        graduated = true;
        graduationTimestamp = uint40(block.timestamp);
        emit Graduated();
    }

    /// @notice Returns the complete tax configuration for this token
    /// @dev Called by LivoTaxSwapHook to determine tax rates and validity
    /// @return config The complete tax configuration including rates, duration, timestamp, and recipient
    function getTaxConfig() external view override returns (TaxConfig memory config) {
        return TaxConfig({
            buyTaxBps: buyTaxBps,
            sellTaxBps: sellTaxBps,
            taxDurationSeconds: taxDurationSeconds,
            graduationTimestamp: graduationTimestamp,
            taxRecipient: taxRecipient
        });
    }

    /// @notice Encodes the tax configuration parameters for token initialization
    /// @dev Frontend should call this on the deployed implementation contract to construct tokenCalldata
    /// @param _buyTaxBps Buy tax rate in basis points (max 500 = 5%)
    /// @param _sellTaxBps Sell tax rate in basis points (max 500 = 5%)
    /// @param _taxDurationSeconds Duration in seconds after graduation during which taxes apply
    /// @param _v4Router Address of the V4 router for executing tax swaps
    /// @param _hook Address of the LivoTaxSwapHook
    /// @param _fee Pool fee in hundredths of a bip
    /// @param _tickSpacing Pool tick spacing
    /// @return Encoded bytes to pass as tokenCalldata to initialize()
    function encodeTokenCalldata(
        uint16 _buyTaxBps,
        uint16 _sellTaxBps,
        uint40 _taxDurationSeconds,
        address _v4Router,
        address _hook,
        uint24 _fee,
        int24 _tickSpacing  // todo the frontend has no idea about this, and they should not now. Get this info from somewhere else. Call the graduator perhaps. 
    ) external pure returns (bytes memory) {
        return abi.encode(_buyTaxBps, _sellTaxBps, _taxDurationSeconds, _v4Router, _hook, _fee, _tickSpacing);
    }

    //////////////////////// internal functions ////////////////////////

    /// @notice Override _update to trigger accumulated tax swap when conditions are met
    /// @dev Swaps accumulated token taxes to ETH when:
    ///      1. Token has graduated
    ///      2. Accumulated balance exceeds 0.1% of total supply
    ///      3. PoolManager is unlocked (not during a V4 swap)
    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);

        // Skip if: already swapping, not graduated, or transfer to self (accumulation from hook)
        if (_inSwap || graduationTimestamp == 0 || to == address(this)) return;

        // Check accumulated balance vs threshold (0.1% of supply)
        uint256 accumulated = balanceOf(address(this));
        uint256 threshold = totalSupply() / 1000;
        if (accumulated < threshold) return;

        // Only swap if PoolManager is unlocked (not during V4 swaps)
        // During V4 swaps, the manager is locked, so this check prevents reentrancy
        if (!TransientStateLibrary.isUnlocked(poolManager)) return;

        _inSwap = true;
        _swapAccumulatedTaxes(accumulated);
        _inSwap = false;
    }

    /// @notice Swaps accumulated token taxes to ETH and sends to taxRecipient
    /// @param amount The amount of tokens to swap
    function _swapAccumulatedTaxes(uint256 amount) internal {
        // Approve router to spend tokens
        _approve(address(this), v4Router, amount);

        // Build swap action: TOKEN -> ETH (zeroForOne = false)
        IV4Router.ExactInputSingleParams memory swapParams = IV4Router.ExactInputSingleParams({
            poolKey: poolKey,
            zeroForOne: false, // TOKEN (currency1) -> ETH (currency0)
            amountIn: uint128(amount),
            amountOutMinimum: 0, // No slippage protection - MEV risk accepted for simplicity
            hookData: ""
        });

        // Encode actions: SWAP + SETTLE + TAKE
        // Action codes from v4-periphery/src/libraries/Actions.sol
        bytes memory actions = new bytes(3);
        actions[0] = bytes1(uint8(0x06)); // SWAP_EXACT_IN_SINGLE
        actions[1] = bytes1(uint8(0x0b)); // SETTLE
        actions[2] = bytes1(uint8(0x0e)); // TAKE

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(swapParams);
        // SETTLE: currency, amount, payerIsUser (false = router pays from its balance, but we approved it)
        params[1] = abi.encode(Currency.wrap(address(this)), amount, false);
        // TAKE: currency, recipient, amount (max = take all output)
        params[2] = abi.encode(Currency.wrap(address(0)), taxRecipient, type(uint256).max);

        bytes memory data = abi.encode(actions, params);

        // Execute swap via V4 router - ETH goes directly to taxRecipient
        // solhint-disable-next-line avoid-low-level-calls
        (bool success,) = v4Router.call(abi.encodeWithSignature("executeActions(bytes)", data));
        // If swap fails, we silently continue - tokens remain accumulated for next attempt
        // This prevents a failing swap from blocking all token transfers
        if (!success) {
            // Reset approval on failure
            _approve(address(this), v4Router, 0);
        }
    }
}
