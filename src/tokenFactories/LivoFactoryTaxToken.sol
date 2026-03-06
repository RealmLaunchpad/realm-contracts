// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";

import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";

import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {ILivoTaxableTokenUniV4} from "src/interfaces/ILivoTaxableTokenUniV4.sol";

import {ILivoLaunchpad} from "src/interfaces/ILivoLaunchpad.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {ILivoGraduator} from "src/interfaces/ILivoGraduator.sol";
import {ILivoBondingCurve} from "src/interfaces/ILivoBondingCurve.sol";
import {ILivoFeeHandler} from "src/interfaces/ILivoFeeHandler.sol";
import {ILivoFeeSplitter} from "src/interfaces/ILivoFeeSplitter.sol";

/// @notice This can be used for univ2 or univ4 tokens. Just with different graduators
contract LivoFactoryTaxToken is ILivoFactory {
    error InvalidSellTaxBps();
    error InvalidTaxDuration();

    /// @notice max configurable sell tax
    uint256 public constant MAX_SELL_TAX_BPS = 500;

    /// @notice max configurable sell tax duration
    uint256 public constant MAX_SELL_TAX_DURATION_SECONDS = 14 days;

    /// @notice Taxable token implementation contract used as the clone source
    ILivoTaxableTokenUniV4 public immutable TOKEN_IMPLEMENTATION;
    /// @notice Launchpad where tokens are registered after creation
    ILivoLaunchpad public immutable LAUNCHPAD;
    /// @notice Graduator contract that handles token graduation to Uniswap V4
    ILivoGraduator public immutable GRADUATOR;
    /// @notice Bonding curve used for token pricing before graduation
    ILivoBondingCurve public immutable BONDING_CURVE;
    /// @notice Fee handler contract for managing creator and treasury fees
    ILivoFeeHandler public immutable FEE_HANDLER;
    /// @notice Fee splitter implementation contract used as the clone source
    ILivoFeeSplitter public immutable FEE_SPLITTER_IMPLEMENTATION;

    /// @notice Initializes the factory with its immutable dependencies
    constructor(
        address launchpad,
        address tokenImplementation,
        address bondingCurve,
        address graduator,
        address feeHandler,
        address feeSplitterImplementation
    ) {
        LAUNCHPAD = ILivoLaunchpad(launchpad);
        TOKEN_IMPLEMENTATION = ILivoTaxableTokenUniV4(tokenImplementation);
        BONDING_CURVE = ILivoBondingCurve(bondingCurve);
        GRADUATOR = ILivoGraduator(graduator);
        FEE_HANDLER = ILivoFeeHandler(feeHandler);
        FEE_SPLITTER_IMPLEMENTATION = ILivoFeeSplitter(feeSplitterImplementation);
    }

    /// @notice Deploys a new taxable token clone with sell tax configuration
    function createToken(
        string calldata name,
        string calldata symbol,
        address feeReceiver,
        bytes32 salt,
        uint16 sellTaxBps,
        uint32 taxDurationSeconds
    ) external returns (address token) {
        require(feeReceiver != address(0), InvalidFeeReceiver());
        token = _createAndInitializeTaxToken(name, symbol, feeReceiver, salt, sellTaxBps, taxDurationSeconds);
    }

    /// @notice Deploys a new taxable token clone with a fee splitter
    function createTokenWithFeeSplit(
        string calldata name,
        string calldata symbol,
        address[] calldata recipients,
        uint256[] calldata sharesBps,
        bytes32 salt,
        uint16 sellTaxBps,
        uint32 taxDurationSeconds
    ) external returns (address token, address feeSplitter) {
        feeSplitter = _deployFeeSplitter(symbol, salt);
        token = _createAndInitializeTaxToken(name, symbol, feeSplitter, salt, sellTaxBps, taxDurationSeconds);
        ILivoFeeSplitter(feeSplitter).initialize(address(FEE_HANDLER), token, recipients, sharesBps);
        emit FeeSplitterCreated(token, feeSplitter, recipients, sharesBps);
    }

    function _deployFeeSplitter(string calldata symbol, bytes32 salt) internal returns (address feeSplitter) {
        // forge-lint: disable-next-line
        bytes32 salt_ = keccak256(abi.encodePacked(msg.sender, block.timestamp, symbol, salt));
        bytes32 splitterSalt = keccak256(abi.encodePacked(salt_, "feeSplitter"));
        feeSplitter = Clones.cloneDeterministic(address(FEE_SPLITTER_IMPLEMENTATION), splitterSalt);
    }

    function _createAndInitializeTaxToken(
        string calldata name,
        string calldata symbol,
        address feeReceiver,
        bytes32 salt,
        uint16 sellTaxBps,
        uint32 taxDurationSeconds
    ) internal returns (address token) {
        require(bytes(name).length > 0 && bytes(symbol).length > 0, InvalidNameOrSymbol());
        require(bytes(symbol).length <= 32, InvalidNameOrSymbol());

        require(sellTaxBps <= MAX_SELL_TAX_BPS, InvalidSellTaxBps());
        require(taxDurationSeconds <= MAX_SELL_TAX_DURATION_SECONDS, InvalidTaxDuration());

        // forge-lint: disable-next-line
        bytes32 salt_ = keccak256(abi.encodePacked(msg.sender, block.timestamp, symbol, salt));
        // minimal proxy pattern to deploy a new LivoToken instance
        token = Clones.cloneDeterministic(address(TOKEN_IMPLEMENTATION), salt_);

        emit TokenCreated(
            token, name, symbol, msg.sender, address(LAUNCHPAD), address(GRADUATOR), address(FEE_HANDLER), feeReceiver
        );

        // Creates the Uniswap Pair or whatever other initialization is necessary
        // in the case of univ4, the pair will be the address of the pool manager,
        // to which tokens cannot be transferred until graduation
        address pair = GRADUATOR.initialize(token);

        _initializeToken(
            token,
            ILivoToken.InitializeParams({
                name: name,
                symbol: symbol,
                tokenOwner: msg.sender,
                graduator: address(GRADUATOR),
                pair: pair,
                launchpad: address(LAUNCHPAD),
                feeHandler: address(FEE_HANDLER),
                feeReceiver: feeReceiver
            }),
            sellTaxBps,
            taxDurationSeconds
        );

        // this will emit another event (from the launchpad)
        LAUNCHPAD.launchToken(token, BONDING_CURVE);
    }

    function _initializeToken(
        address token,
        ILivoToken.InitializeParams memory initParams,
        uint16 sellTaxBps,
        uint32 taxDurationSeconds
    ) internal {
        LivoTaxableTokenUniV4(payable(token)).initialize(initParams, sellTaxBps, uint40(taxDurationSeconds));
    }
}
