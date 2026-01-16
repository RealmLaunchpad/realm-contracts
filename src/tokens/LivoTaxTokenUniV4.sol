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
import {LivoGraduatorUniswapV4} from "src/graduators/LivoGraduatorUniswapV4.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";

/// @title LivoTaxTokenUniV4
/// @notice ERC20 token implementation with time-limited buy/sell taxes enforced via Uniswap V4 hooks
/// @dev Extends LivoToken to add tax configuration that is queried by LivoTaxSwapHook
contract LivoTaxTokenUniV4 is LivoToken, ILivoTokenTaxable {
    /// @notice Maximum allowed tax rate (500 basis points = 5%)
    uint16 public constant MAX_TAX_BPS = 500;

    /// @notice Maximum duration for the tax period after graduation timestamp
    uint40 public constant MAX_TAX_DURATION_SECONDS = 14 days;

    ///////////////////////////////// uniswap v4 related /////////////////////////////////////////

    /// @notice LP fees in pips, i.e. 1e6 = 100%, so 10000 = 1%
    /// @dev 10000 pips = 1%
    /// @dev IMPORTANT: this needs to match the graduator settings. Clearly a weak point. 
    /// @dev this weak structure is done to save gas by having these as constants in the token and make deployment cheaper
    uint24 constant LP_FEE = 10000;

    // todo include a test that makes sure this token contract has the same settings as the graduator. 
    /// @notice Tick spacing used to be 200 for volatile pairs in univ3. (60 for 0.3% fee tier)
    /// @dev IMPORTANT: this needs to match the graduator settings. Clearly a weak point. 
    /// @dev this weak structure is done to save gas by having these as constants in the token and make deployment cheaper
    int24 public constant TICK_SPACING = 200;

    /// @notice Pool manager for lock state checking
    /// @dev Ethereum mainnet address. Needs change if deployed in other chains
    IPoolManager public constant UNIV4_POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);

    /// @notice V4 Router for executing tax swaps
    /// @dev Ethereum mainnet address. Needs change if deployed in other chains
    address public constant UNIV4_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;

    /// @notice the hook address which will charge the buy/sell taxes
    /// todo update this tax hook address when mined
    address constant TAX_HOOK = 0xf84841AB25aCEcf0907Afb0283aB6Da38E5FC044;

    //////////////////////// potentially immutable //////////////////

    LivoLaunchpad public launchpad;

    /// @notice Buy tax rate in basis points (set during initialization, cannot be changed)
    uint16 public buyTaxBps;

    /// @notice Sell tax rate in basis points (set during initialization, cannot be changed)
    uint16 public sellTaxBps;

    /// @notice Duration in seconds after graduation during which taxes apply (set during initialization, cannot be changed)
    uint40 public taxDurationSeconds;

    /////////////////////////// pure storage ///////////////////////

    /// @notice Timestamp when token graduated (0 if not graduated)
    uint40 public graduationTimestamp;

    /// @notice Reentrancy guard for tax swap
    bool private _inSwap;

    //////////////////////// Errors //////////////////////

    error InvalidTaxRate(uint16 rate);
    error InvalidTaxDuration();
    error InvalidTaxCalldata();

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
    /// @param tokenCalldata Extended tax config: (buyTaxBps, sellTaxBps, taxDurationSeconds, UNIV4_ROUTER, hook, fee, tickSpacing)
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
        _initializeTaxConfig(graduator_, tokenCalldata, supplyReceiver_);

        // storage variables inherited from LivoToken
        _tokenName = name_;
        _tokenSymbol = symbol_;
        graduator = graduator_;
        pair = pair_;

        launchpad = LivoLaunchpad(supplyReceiver_);

        // all is minted back to the launchpad
        _mint(supplyReceiver_, totalSupply_);
    }

    function getTaxConfig() external view returns (TaxConfig memory config) {
        address taxRecipient = launchpad.getTokenOwner(address(this));

        config = TaxConfig({
            buyTaxBps: buyTaxBps,
            sellTaxBps: sellTaxBps,
            taxDurationSeconds: taxDurationSeconds,
            graduationTimestamp: graduationTimestamp,
            taxRecipient: taxRecipient
        });
    }

    /// @notice Internal helper to decode and validate tax configuration
    /// @dev Separated to reduce stack depth in initialize()
    function _initializeTaxConfig(address graduator_, bytes memory tokenCalldata, address supplyReceiver_) internal {
        
        (
            uint16 _buyTaxBps,
            uint16 _sellTaxBps,
            uint40 _taxDurationSeconds
        ) = _decodeTokenCalldata(tokenCalldata);

        // Validate tax rates
        if (_buyTaxBps > MAX_TAX_BPS) revert InvalidTaxRate(_buyTaxBps);
        if (_sellTaxBps > MAX_TAX_BPS) revert InvalidTaxRate(_sellTaxBps);
        if (_taxDurationSeconds > MAX_TAX_DURATION_SECONDS) revert InvalidTaxDuration();

        // Store tax configuration
        buyTaxBps = _buyTaxBps;
        sellTaxBps = _sellTaxBps;
        taxDurationSeconds = _taxDurationSeconds;
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

    /// @notice Encodes the tax configuration parameters for token initialization
    /// @dev Frontend should call this on the deployed implementation contract to construct tokenCalldata
    /// @param _buyTaxBps Buy tax rate in basis points (max 500 = 5%)
    /// @param _sellTaxBps Sell tax rate in basis points (max 500 = 5%)
    /// @param _taxDurationSeconds Duration in seconds after graduation during which taxes apply
    /// @return Encoded bytes to pass as tokenCalldata to initialize()
    function encodeTokenCalldata(
        uint16 _buyTaxBps,
        uint16 _sellTaxBps,
        uint40 _taxDurationSeconds
    ) external pure returns (bytes memory) {
        return abi.encode(_buyTaxBps, _sellTaxBps, _taxDurationSeconds);
    }

    function _decodeTokenCalldata(bytes memory tokenCalldata) internal returns (uint16 _buyTaxBps, uint16 _sellTaxBps, uint40 _taxDurationSeconds) {
        (_buyTaxBps, _sellTaxBps, _taxDurationSeconds) = abi.decode(tokenCalldata, (uint16, uint16, uint40));
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
        if (!TransientStateLibrary.isUnlocked(UNIV4_POOL_MANAGER)) return;

        _inSwap = true;
        _swapAccumulatedTaxes(accumulated);
        _inSwap = false;
    }

    /// @notice Swaps accumulated token taxes to ETH and sends to token creator
    /// @param amount The amount of tokens to swap
    function _swapAccumulatedTaxes(uint256 amount) internal {
        // Approve router to spend tokens
        _approve(address(this), UNIV4_ROUTER, amount);

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(this)),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(TAX_HOOK)
        });

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

        // Get tax recipient (token owner) from the launchpad dynamically, as it can be updated there
        address tokenOwner = launchpad.getTokenOwner(address(this));

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(swapParams);
        // SETTLE: currency, amount, payerIsUser (false = router pays from its balance, but we approved it)
        params[1] = abi.encode(Currency.wrap(address(this)), amount, false);
        // TAKE: currency, recipient, amount (max = take all output)
        params[2] = abi.encode(Currency.wrap(address(0)), tokenOwner, type(uint256).max);

        bytes memory data = abi.encode(actions, params);

        // Execute swap via V4 router - ETH goes directly to tokenOwner
        // solhint-disable-next-line avoid-low-level-calls
        (bool success,) = UNIV4_ROUTER.call(abi.encodeWithSignature("executeActions(bytes)", data));
        // If swap fails, we silently continue - tokens remain accumulated for next attempt
        // This prevents a failing swap from blocking all token transfers
        if (!success) {
            // Reset approval on failure
            _approve(address(this), UNIV4_ROUTER, 0);
        }
    }
}
