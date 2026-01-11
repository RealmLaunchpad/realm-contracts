// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LivoToken} from "src/tokens/LivoToken.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {ILivoTokenTaxable} from "src/interfaces/ILivoTokenTaxable.sol";
import {ILivoLaunchpad} from "src/interfaces/ILivoLaunchpad.sol";

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

    /// @notice Address receiving tax payments (set during initialization, cannot be changed)
    address public taxRecipient;

    /// @notice Timestamp when token graduated (0 if not graduated)
    uint40 public graduationTimestamp;

    //////////////////////// Errors //////////////////////

    error InvalidTaxRate(uint16 rate);
    error InvalidTaxDuration();
    error InvalidTaxRecipient();
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
    /// @param pair_ Address of the Uniswap pair (pool manager for V4)
    /// @param supplyReceiver_ Address receiving the total supply of tokens
    /// @param totalSupply_ Total supply to mint
    /// @param tokenCalldata Extra initialization parameters containing tax configuration
    /// @dev tokenCalldata must be abi.encode(TaxConfig) format
    function initialize(
        string memory name_,
        string memory symbol_,
        address graduator_,
        address pair_,
        address supplyReceiver_,
        uint256 totalSupply_,
        bytes memory tokenCalldata
    ) external override(ILivoToken, LivoToken) initializer {
        // Perform standard token initialization (duplicated from LivoToken)
        require(graduator_ != address(0), InvalidGraduator());

        // Decode tax configuration from tokenCalldata
        if (tokenCalldata.length == 0) revert InvalidTaxCalldata();

        (uint16 _buyTaxBps, uint16 _sellTaxBps, uint40 _taxDurationSeconds) =
            abi.decode(tokenCalldata, (uint16, uint16, uint40));

        // Validate tax rates
        if (_buyTaxBps > MAX_TAX_BPS) revert InvalidTaxRate(_buyTaxBps);
        if (_sellTaxBps > MAX_TAX_BPS) revert InvalidTaxRate(_sellTaxBps);

        // Validate tax duration
        if (_taxDurationSeconds > MAX_TAX_DURATION_SECONDS) revert InvalidTaxDuration();
        // Get tax recipient (token owner) from the launchpad
        // msg.sender at this point is the LivoLaunchpad contract calling initialize
        // todo supplyReceiver perhaps should be directly called `launchpad` to make this less confusing
        address _taxRecipient = ILivoLaunchpad(supplyReceiver_).getTokenOwner(address(this));
        
        if (_taxRecipient == address(0)) revert InvalidTaxRecipient();

        // Store tax configuration
        buyTaxBps = _buyTaxBps;
        sellTaxBps = _sellTaxBps;
        taxDurationSeconds = _taxDurationSeconds;
        taxRecipient = _taxRecipient;

        // storage variables inherited from LivoToken
        _tokenName = name_;
        _tokenSymbol = symbol_;
        graduator = graduator_;
        pair = pair_;

        // all is minted back to the launchpad
        _mint(supplyReceiver_, totalSupply_);
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
    /// @return Encoded bytes to pass as tokenCalldata to initialize()
    function encodeTokenCalldata(uint16 _buyTaxBps, uint16 _sellTaxBps, uint40 _taxDurationSeconds)
        external
        pure
        returns (bytes memory)
    {
        return abi.encode(_buyTaxBps, _sellTaxBps, _taxDurationSeconds);
    }
}
