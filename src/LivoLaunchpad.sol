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
    uint256 private constant TOTAL_SUPPLY = 1_000_000_000e18; // 1B tokens

    // question consider if this should be immutable or not
    /// @notice LivoToken ERC20 implementation address
    IERC20 public tokenImplementation;

    /// @notice The amount of ETH held in a token balance that is required for liquidity at graduation
    uint256 public baseEthForGraduationLiquidity = 7.5 ether;

    /// @notice The base graduation fee in ETH, paid at graduation to the treasury
    uint256 public baseGraduationFee;

    /// @notice Base creator fee in basis points (100 bps = 1%), paid in tokens at graduation
    uint16 public creatorReservedSupplyBasisPoints = 100;

    /// @notice Total fees collected by the treasury
    uint256 public treasuryEthFeesCollected;

    /// @notice Livo Treasury, receiver of all trading/graduation fees
    address public treasury;

    /// @notice Trading fees in basis points (100 bps = 1%). Updates to these only affect future tokens
    uint16 public baseBuyFeeBps;
    uint16 public baseSellFeeBps;

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

    event TokenCreated(
        address indexed token,
        address indexed creator,
        string name,
        string symbol,
        address bondingCurve,
        address graduator,
        string metadata
    );

    event TokenGraduated(address indexed token, uint256 ethCollected, uint256 tokensForGraduation, address uniPair);

    event LivoTokenBuy(
        address indexed token, address indexed buyer, uint256 ethAmount, uint256 tokenAmount, uint256 fee
    );

    event LivoTokenSell(
        address indexed token, address indexed seller, uint256 tokenAmount, uint256 ethAmount, uint256 fee
    );

    event TreasuryFeesCollected(address indexed treasury, uint256 amount);

    event TokenImplementationUpdated(IERC20 newImplementation);
    event RequiredEthForGraduationLiquidityUpdated(uint256 newThreshold);
    event TreasuryAddressUpdated(address newTreasury);
    event TradingFeesUpdated(uint16 buyFeeBps, uint16 sellFeeBps);
    event GraduationFeeUpdated(uint256 newGraduationFee);

    event BondingCurveWhitelisted(address indexed bondingCurve, bool whitelisted);
    event GraduatorWhitelisted(address indexed graduator, bool whitelisted);

    /////////////////////////////////////////////////

    constructor(address _treasury, IERC20 _tokenImplementation) Ownable(msg.sender) {
        // Set initial values and emit events for off-chain indexers
        setTreasuryAddress(_treasury);
        setLivoTokenImplementation(_tokenImplementation);

        setLiquidityForGraduation(7.5 ether);
        setGraduationFee(0.5 ether);
        // buy/sell fees at 1%
        setTradingFees(100, 100);
    }

    function createToken(
        string calldata name,
        string calldata symbol,
        string calldata metadata,
        address bondingCurve,
        address graduator
    ) external returns (address) {
        require(bytes(name).length > 0 && bytes(symbol).length > 0, InvalidNameOrSymbol());

        _registerSymbol(symbol);

        require(whitelistedBondingCurves[bondingCurve], InvalidBondingCurve());
        require(whitelistedGraduators[graduator], InvalidGraduator());

        // minimal proxy pattern to deploy a new LivoToken instance
        // Deploying the contracts with new() costs 3-4 times more gas than cloning
        // trading will be a bit more expensive, as variables cannot be immutable
        address tokenClone = Clones.clone(address(tokenImplementation));
        // Initialize the new token instance
        // It is responsibility of the token to distribute supply to the msg.sender
        // so that we can update the token implementation with new rules for future tokens
        LivoToken(tokenClone).initialize(
            name, symbol, msg.sender, address(this), graduator, TOTAL_SUPPLY, baseBuyFeeBps, baseSellFeeBps
        );

        uint256 _creatorReservedSupply = TOTAL_SUPPLY * creatorReservedSupplyBasisPoints / BASIS_POINTS;

        // at creation all tokens are held by this contract
        tokenConfigs[tokenClone] = TokenConfig({
            bondingCurve: ILivoBondingCurve(bondingCurve),
            graduator: ILivoGraduator(graduator),
            creator: msg.sender,
            graduationEthFee: baseGraduationFee,
            ethForGraduationLiquidity: baseEthForGraduationLiquidity,
            creatorReservedSupply: _creatorReservedSupply,
            buyFeeBps: baseBuyFeeBps,
            sellFeeBps: baseSellFeeBps
        });

        // all other tokenState fields are correctly initialized to 0 or false
        tokenStates[tokenClone].circulatingSupply = _creatorReservedSupply;

        emit TokenCreated(tokenClone, msg.sender, name, symbol, bondingCurve, graduator, metadata);

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

        require(tokensToReceive <= _availableForPurchase(token), NotEnoughSupply());
        require(tokensToReceive >= minTokenAmount, SlippageExceeded());

        tokenState.ethCollected += ethForReserves;
        tokenState.circulatingSupply += tokensToReceive;
        treasuryEthFeesCollected += ethFee;

        IERC20(token).safeTransfer(msg.sender, tokensToReceive);

        emit LivoTokenBuy(token, msg.sender, msg.value, tokensToReceive, ethFee);
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
        require(ethForSeller >= minEthAmount, SlippageExceeded());
        require(_availableEthFromReserves(token) >= ethFromReserves, InsufficientETHReserves());

        tokenState.ethCollected -= ethFromReserves;
        tokenState.circulatingSupply -= tokenAmount;
        // review fee asymmetries 1% != 1% down, so 1% sell != 1% buy ... ?
        treasuryEthFeesCollected += ethFee;

        // funds transfers
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);
        _transferEth(msg.sender, ethForSeller);

        emit LivoTokenSell(token, msg.sender, tokenAmount, ethForSeller, ethFee);
    }

    function graduateToken(address tokenAddress) external {
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

        address uniPair = tokenConfig.graduator.graduateToken{value: ethForGraduation}(tokenAddress);

        emit TokenGraduated(tokenAddress, ethForGraduation, tokensForGraduation, uniPair);
    }

    //////////////////////////// view functions //////////////////////////

    function quoteBuy(address token, uint256 ethValue)
        external
        view
        returns (uint256 ethForPurchase, uint256 ethFee, uint256 tokensToReceive)
    {
        (ethForPurchase, ethFee, tokensToReceive) = _quoteBuy(token, ethValue);
        if (tokensToReceive > _availableForPurchase(token)) {
            revert NotEnoughSupply();
        }
    }

    function quoteSell(address token, uint256 tokenAmount)
        external
        view
        returns (uint256 ethFromSale, uint256 ethFee, uint256 ethForSeller)
    {
        (ethFromSale, ethFee, ethForSeller) = _quoteSell(token, tokenAmount);
        if (ethForSeller > _availableEthFromReserves(token)) {
            revert InsufficientETHReserves();
        }
    }

    /// @notice The available supply that can be purchased of a given token
    function getAvailableForPurchase(address token) external view returns (uint256) {
        return _availableForPurchase(token);
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
    function setLivoTokenImplementation(IERC20 newImplementation) public onlyOwner {
        require(address(newImplementation) != address(0), InvalidAddress());
        tokenImplementation = newImplementation;
        emit TokenImplementationUpdated(newImplementation);
    }

    /// @notice Updates the graduation threshold, which only affects new token deployments
    function setLiquidityForGraduation(uint256 ethAmount) public onlyOwner {
        baseEthForGraduationLiquidity = ethAmount;
        emit RequiredEthForGraduationLiquidityUpdated(ethAmount);
    }

    /// @notice Updates the graduation fee, which only affects new token deployments
    function setGraduationFee(uint256 ethAmount) public onlyOwner {
        baseGraduationFee = ethAmount;
        emit GraduationFeeUpdated(ethAmount);
    }

    /// @notice Updates the buy/sell fees, which only affects new token deployments
    function setTradingFees(uint16 buyFeeBps, uint16 sellFeeBps) public onlyOwner {
        require(buyFeeBps <= BASIS_POINTS, InvalidParameter(buyFeeBps));
        require(sellFeeBps <= BASIS_POINTS, InvalidParameter(sellFeeBps));
        baseBuyFeeBps = buyFeeBps;
        baseSellFeeBps = sellFeeBps;
        emit TradingFeesUpdated(buyFeeBps, sellFeeBps);
    }

    /// @notice Whitelists a bonding curve that can be chosen by future tokens
    function whitelistBondingCurve(address bondingCurve, bool whitelisted) public onlyOwner {
        whitelistedBondingCurves[bondingCurve] = whitelisted;
        emit BondingCurveWhitelisted(bondingCurve, whitelisted);
    }

    /// @dev blacklisted graduators will still be able to graduate the tokens that where created with them
    function whitelistGraduator(address graduator, bool whitelisted) public onlyOwner {
        // todo validation of the graduation manager?
        whitelistedGraduators[graduator] = whitelisted;
        emit GraduatorWhitelisted(graduator, whitelisted);
    }

    function setTreasuryAddress(address recipient) public onlyOwner {
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

    /// @dev The supply of a token that can be purchased
    /// @dev The reserved creator supply is only effective at graduation,
    /// and it is taken from the remaining tokens in this contract at graduation
    function _availableForPurchase(address token) internal view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    function _availableEthFromReserves(address token) internal view returns (uint256) {
        return tokenStates[token].ethCollected;
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
