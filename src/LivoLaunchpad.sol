// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import "src/LivoToken.sol";
import "src/interfaces/ILivoBondingCurve.sol";
import "src/interfaces/ILivoGraduator.sol";
import {TokenConfig, TokenState, TokenDataLib} from "src/types/tokenData.sol";

contract LivoLaunchpad is Ownable {
    using SafeERC20 for IERC20;
    using TokenDataLib for TokenConfig;
    using TokenDataLib for TokenState;

    /// 100% in basis points
    uint256 public constant BASIS_POINTS = 10_000;

    /// @notice the total supply of all deployed tokens
    uint256 private constant TOTAL_SUPPLY = 1_000_000e18; // 1M tokens

    // question consider if this should be immutable or not
    /// @notice LivoToken ERC20 implementation address
    IERC20 public tokenImplementation;

    /// @notice The amount of ETH held in a token balance that is required for graduation
    uint256 public baseGraduationThreshold = 20 ether;

    /// @notice The base graduation fee in ETH, paid at graduation to the treasury
    uint256 public baseGraduationFee = 0.1 ether;

    /// @notice Base creator fee in basis points (100 bps = 1%), paid in tokens at graduation
    uint16 public baseCreatorFeeBps = 100;

    /// @notice Total fees collected by the treasury
    uint256 public treasuryEthFeesCollected;

    /// @notice Livo Treasury, receiver of all trading/graduation fees
    address public treasury;

    /// @notice Trading fees in basis points (100 bps = 1%). Updates to these only affect future tokens
    uint16 public baseBuyFeeBps = 100; // 1%
    uint16 public baseSellFeeBps = 100; // 1%
    /// @notice Each trade has fees, that fee is split between the creator and the treasury. This is the share for the creator
    uint16 public creatorFeeShareBps;

    /// @notice Which Bonding Curve addresses can be selected at token creation
    mapping(address => bool) public whitelistedBondingCurves;

    /// @notice Which Graduator addresses can be selected at token creation
    mapping(address => bool) public whitelistedGraduators;

    /// @notice Mapping of token address to its configuration
    mapping(address => TokenConfig) public tokenConfigs;

    /// @notice Mapping of token address to its state
    mapping(address => TokenState) public tokenStates;

    /// @notice Mapping to track used symbols to prevent duplicates
    mapping(bytes32 => bool) public usedSymbols;

    ///////////////////// Errors /////////////////////

    error InvalidBondingCurve();
    error InvalidGraduator();
    error InvalidNameOrSymbol();
    error InvalidAmount();
    error InvalidParameter(uint256 parameter);
    error InvalidAddress();
    error InvalidToken();
    error NotEnoughSupply();
    error AlreadyGraduated();
    error InsufficientETHReserves();
    error GraduationCriteriaNotMet();
    error EthTransferFailed();
    error DeadlineExceeded();
    error SlippageExceeded();
    error CallerIsNotCreator();
    error NothingToClaim();
    error SymbolAlreadyUsed();

    ///////////////////// Events /////////////////////

    event TokenCreated( // open field for additional data
    address indexed token, address indexed creator, string name, string symbol, address bondingCurve, string metadata);

    event LivoTokenPurchased(
        address indexed token, address indexed buyer, uint256 ethAmount, uint256 tokenAmount, uint256 fee
    );

    event LivoTokenSold(
        address indexed token, address indexed seller, uint256 tokenAmount, uint256 ethAmount, uint256 fee
    );

    event TokenGraduated(address indexed token, uint256 ethCollected, uint256 tokensForGraduation);

    event TreasuryFeesCollected(address indexed treasury, uint256 amount);
    event TokenImplementationUpdated(IERC20 newImplementation);
    event GraduationThresholdUpdated(uint256 newThreshold);
    event TreasuryAddressUpdated(address newTreasury);
    event CreatorFeeShareUpdated(uint256 newCreatorFeeBps);
    event BondingCurveWhitelisted(address indexed bondingCurve, bool whitelisted);
    event GraduatorWhitelisted(address indexed graduator, bool whitelisted);
    event TradingFeesUpdated(uint96 buyFeeBps, uint96 sellFeeBps);
    event GraduationFeeUpdated(uint256 newGraduationFee);
    event CreatorEthFeesClaimed(address indexed token, address indexed creator, uint256 amount);

    /////////////////////////////////////////////////

    constructor(address _treasury, IERC20 _tokenImplementation) Ownable(msg.sender) {
        treasury = _treasury;
        tokenImplementation = _tokenImplementation;
    }

    function createToken(
        string calldata name,
        string calldata symbol,
        string calldata metadata,
        address bondingCurve,
        address graduator
    ) external payable returns (address) {
        require(bytes(name).length > 0 && bytes(symbol).length > 0, InvalidNameOrSymbol());

        _registerSymbol(symbol);

        require(whitelistedBondingCurves[bondingCurve], InvalidBondingCurve());
        require(whitelistedGraduators[graduator], InvalidGraduator());

        address creator = msg.sender;

        // todo is it better to have a minimal proxy and spend the gas in reading state vars or to deploy a new contract every time?

        // minimal proxy pattern to deploy a new LivoToken instance
        address tokenClone = Clones.clone(address(tokenImplementation));
        // Initialize the new token instance
        // It is responsibility of the token to distribute supply to the creator
        // so that we can update the token implementation with new rules for future tokens
        LivoToken(tokenClone).initialize(
            name, symbol, creator, address(this), graduator, TOTAL_SUPPLY, baseBuyFeeBps, baseSellFeeBps
        );

        uint256 _creatorReservedSupply = TOTAL_SUPPLY * creatorFeeShareBps / BASIS_POINTS;

        // at creation all tokens are held by this contract
        tokenConfigs[tokenClone] = TokenConfig({
            bondingCurve: ILivoBondingCurve(bondingCurve),
            graduator: ILivoGraduator(graduator),
            creator: creator,
            graduationEthFee: baseGraduationFee,
            graduationThreshold: baseGraduationThreshold,
            creatorReservedSupply: _creatorReservedSupply,
            buyFeeBps: baseBuyFeeBps,
            sellFeeBps: baseSellFeeBps,
            creatorFeeBps: creatorFeeShareBps
        });

        // all other tokenState fields are correctly initialized to 0 or false
        tokenStates[tokenClone].circulatingSupply = _creatorReservedSupply;

        emit TokenCreated(tokenClone, creator, name, symbol, bondingCurve, metadata);

        return tokenClone;
    }

    function buyToken(address token, uint256 minTokenAmount, uint256 deadline) external payable {
        TokenConfig storage tokenConfig = tokenConfigs[token];
        TokenState storage tokenState = tokenStates[token];

        require(msg.value > 0, InvalidAmount());
        require(tokenConfig.exists(), InvalidToken());
        require(tokenState.notGraduated(), AlreadyGraduated());
        require(block.timestamp <= deadline, DeadlineExceeded());

        // this applies the trading fees
        (uint256 ethForReserves, uint256 ethFee, uint256 tokensToReceive) = _quoteBuy(token, msg.value);

        require(tokensToReceive >= IERC20(token).balanceOf(address(this)), NotEnoughSupply());
        require(tokensToReceive >= minTokenAmount, SlippageExceeded());

        tokenState.ethCollected += ethForReserves;
        tokenState.circulatingSupply += tokensToReceive;

        _registerEthFees(ethFee, tokenConfig.creatorFeeBps, tokenState);

        IERC20(token).safeTransfer(msg.sender, tokensToReceive);

        emit LivoTokenPurchased(token, msg.sender, msg.value, tokensToReceive, ethFee);
    }

    function sellToken(address token, uint256 tokenAmount, uint256 minEthAmount, uint256 deadline) external {
        TokenConfig storage tokenConfig = tokenConfigs[token];
        TokenState storage tokenState = tokenStates[token];

        require(tokenConfig.exists(), InvalidToken());
        require(tokenState.notGraduated(), AlreadyGraduated());
        require(tokenAmount > 0, InvalidAmount());
        require(block.timestamp <= deadline, DeadlineExceeded());

        (uint256 ethFromReserves, uint256 ethFee, uint256 ethForSeller) = _quoteSell(token, tokenAmount);

        // Hopefully this scenario never happens
        require(tokenState.ethCollected >= ethFromReserves, InsufficientETHReserves());
        require(ethForSeller >= minEthAmount, SlippageExceeded());

        tokenState.ethCollected -= ethFromReserves;
        tokenState.circulatingSupply -= tokenAmount;

        // review fee asymmetries 1% != 1% down, so 1% sell != 1% buy ... ?
        _registerEthFees(ethFee, tokenConfig.creatorFeeBps, tokenState);

        // funds transfers
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);
        _transferEth(msg.sender, ethForSeller);

        emit LivoTokenSold(token, msg.sender, tokenAmount, ethForSeller, ethFee);
    }

    function graduateToken(address tokenAddress) external payable {
        TokenConfig storage tokenConfig = tokenConfigs[tokenAddress];
        TokenState storage tokenState = tokenStates[tokenAddress];
        IERC20 token = IERC20(tokenAddress);

        require(tokenState.notGraduated(), AlreadyGraduated());
        require(TokenDataLib.meetsGraduationCriteria(tokenState, tokenConfig), GraduationCriteriaNotMet());

        tokenState.graduated = true;

        // review if tokenAddress donations can mess up this
        uint256 ethCollected = tokenState.ethCollected;
        uint256 ethForGraduation = ethCollected - tokenConfig.graduationEthFee;
        treasuryEthFeesCollected += tokenConfig.graduationEthFee;

        uint256 tokensForCreator = tokenConfig.creatorReservedSupply;
        uint256 tokensForGraduation = token.balanceOf(address(this)) - tokensForCreator;

        token.safeTransfer(tokenConfig.creator, tokensForCreator);
        token.safeTransfer(address(tokenConfig.graduator), tokensForGraduation);

        tokenConfig.graduator.graduateToken{value: ethForGraduation}(tokenAddress);

        emit TokenGraduated(tokenAddress, ethForGraduation, tokensForGraduation);
    }

    function claimCreatorEthFees(address token) external {
        TokenConfig storage tokenConfig = tokenConfigs[token];
        TokenState storage tokenState = tokenStates[token];

        address creator = tokenConfig.creator;
        uint256 amount = tokenState.creatorFeesCollected;

        require(creator == msg.sender, CallerIsNotCreator());
        require(amount > 0, NothingToClaim());

        tokenState.creatorFeesCollected = 0;

        _transferEth(creator, amount);

        emit CreatorEthFeesClaimed(token, creator, amount);
    }

    //////////////////////////// view functions //////////////////////////

    function quoteBuy(address token, uint256 ethValue)
        external
        view
        returns (uint256 ethForPurchase, uint256 ethFee, uint256 tokensToReceive)
    {
        return _quoteBuy(token, ethValue);
    }

    function quoteSell(address token, uint256 tokenAmount)
        external
        view
        returns (uint256 ethFromSale, uint256 ethFee, uint256 ethForSeller)
    {
        return _quoteSell(token, tokenAmount);
    }

    function getCurrentPrice(address token) external view returns (uint256) {
        TokenConfig storage tokenConfig = tokenConfigs[token];

        require(tokenConfig.exists(), InvalidToken());
        // review this bonding curve interface
        return tokenConfig.bondingCurve.getEthForTokens(tokenStates[token].circulatingSupply, 1e18);
    }

    function meetsGraduationCriteria(address token) public view returns (bool) {
        return tokenStates[token].ethCollected >= tokenConfigs[token].minimumEthForGraduation();
    }

    function getTokenState(address token) external view returns (TokenState memory) {
        return tokenStates[token];
    }

    function getTokenConfig(address token) external view returns (TokenConfig memory) {
        return tokenConfigs[token];
    }

    //////////////////////////// Admin functions //////////////////////////

    /// @notice Updates the ERC20 token implementation, which only affects new token deployments
    function setLivoTokenImplementation(IERC20 newImplementation) external onlyOwner {
        require(address(newImplementation) != address(0), InvalidAddress());
        tokenImplementation = newImplementation;
        emit TokenImplementationUpdated(newImplementation);
    }

    /// @notice Updates the graduation threshold, which only affects new token deployments
    function setGraduationThreshold(uint256 ethAmount) external onlyOwner {
        baseGraduationThreshold = ethAmount;
        emit GraduationThresholdUpdated(ethAmount);
    }

    /// @notice Updates the graduation fee, which only affects new token deployments
    function setGraduationFee(uint256 ethAmount) external onlyOwner {
        baseGraduationFee = ethAmount;
        emit GraduationFeeUpdated(ethAmount);
    }

    /// @notice Updates the buy/sell fees, which only affects new token deployments
    function setTradingFees(uint16 buyFeeBps, uint16 sellFeeBps) external onlyOwner {
        require(buyFeeBps <= BASIS_POINTS, InvalidParameter(buyFeeBps));
        require(sellFeeBps <= BASIS_POINTS, InvalidParameter(sellFeeBps));
        baseBuyFeeBps = buyFeeBps;
        baseSellFeeBps = sellFeeBps;
        emit TradingFeesUpdated(buyFeeBps, sellFeeBps);
    }

    /// @notice Whitelists a bonding curve that can be chosen by future tokens
    function whitelistBondingCurve(address bondingCurve, bool whitelisted) external onlyOwner {
        whitelistedBondingCurves[bondingCurve] = whitelisted;
        emit BondingCurveWhitelisted(bondingCurve, whitelisted);
    }

    /// @dev blacklisted graduators will still be able to graduate the tokens that where created with them
    function whitelistGraduator(address graduator, bool whitelisted) external onlyOwner {
        // todo validation of the graduation manager?
        whitelistedGraduators[graduator] = whitelisted;
        emit GraduatorWhitelisted(graduator, whitelisted);
    }

    function setTreasuryAddress(address recipient) external onlyOwner {
        treasury = recipient;
        emit TreasuryAddressUpdated(recipient);
    }

    function collectTreasuryFees() external onlyOwner {
        uint256 amount = treasuryEthFeesCollected;
        if (amount == 0) return;

        treasuryEthFeesCollected = 0;

        _transferEth(treasury, amount);

        emit TreasuryFeesCollected(treasury, amount);
    }

    //////////////////////////// Internal functions //////////////////////////

    function _quoteBuy(address token, uint256 ethValue)
        internal
        view
        returns (uint256 ethForPurchase, uint256 ethFee, uint256 tokensToReceive)
    {
        TokenConfig storage tokenConfig = tokenConfigs[token];

        ethFee = (ethValue * tokenConfig.buyFeeBps) / BASIS_POINTS;
        ethForPurchase = ethValue - ethFee;

        tokensToReceive = tokenConfig.bondingCurve.getTokensForEth(tokenStates[token].circulatingSupply, ethForPurchase);
        return (ethForPurchase, ethFee, tokensToReceive);
    }

    function _quoteSell(address token, uint256 tokenAmount)
        internal
        view
        returns (uint256 ethFromSale, uint256 ethFee, uint256 ethForSeller)
    {
        TokenConfig storage tokenConfig = tokenConfigs[token];

        ethFromSale = tokenConfig.bondingCurve.getEthForTokens(tokenStates[token].circulatingSupply, tokenAmount);
        ethFee = (ethFromSale * tokenConfig.sellFeeBps) / BASIS_POINTS;
        ethForSeller = ethFromSale - ethFee;

        return (ethFromSale, ethFee, ethForSeller);
    }

    function _registerEthFees(uint256 ethFee, uint16 creatorFeeBps, TokenState storage tokenState) internal {
        uint256 creatorFee = (ethFee * creatorFeeBps) / BASIS_POINTS;
        uint256 treasuryFee = ethFee - creatorFee;

        tokenState.creatorFeesCollected += creatorFee;
        treasuryEthFeesCollected += treasuryFee;
    }

    function _transferEth(address recipient, uint256 amount) internal {
        if (amount == 0) return;
        // review potential reentrancies. Make sure this call is always done at the end of the transaction
        (bool success,) = recipient.call{value: amount}("");
        require(success, EthTransferFailed());
    }

    function _registerSymbol(string calldata symbol) internal {
        require(bytes(symbol).length <= 32, InvalidNameOrSymbol());

        bytes32 symbolHash = bytes32(bytes(symbol));
        require(!usedSymbols[symbolHash], SymbolAlreadyUsed());
        usedSymbols[symbolHash] = true;
    }
}
