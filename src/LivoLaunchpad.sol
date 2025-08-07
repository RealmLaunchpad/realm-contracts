// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import "src/LivoToken.sol";
import "src/interfaces/ILivoBondingCurve.sol";
import "src/interfaces/ILivoGraduator.sol";
import {TokenData, TokenDataLib} from "src/types/tokenData.sol";

contract LivoLaunchpad is Ownable {
    using TokenDataLib for TokenData;
    using SafeERC20 for IERC20;

    uint256 public constant BASIS_POINTS = 10_000; // 100% in basis points

    // question consider if this should be immutable or not
    /// @notice LivoToken ERC20 implementation address
    IERC20 public tokenImplementation;

    /// @notice The amount of ETH held in a token balance that is required for graduation
    uint256 public graduationThreshold = 20 ether;

    /// @notice Creator fee in basis points (100 bps = 1%).
    uint256 public graduationFee = 0.1 ether;

    /// @notice Total fees collected by the treasury
    uint256 public treasuryEthFeesCollected;

    /// @notice Livo Treasury, receiver of all trading/graduation fees
    address public treasury;

    /// @notice Trading fees in basis points (100 bps = 1%). Updates to these only affect future tokens
    uint16 public baseBuyFeeBps = 100; // 1%
    uint16 public baseSellFeeBps = 100; // 1%
    /// @notice Each trade has fees, that fee is split between the creator and the treasury. This is the share for the creator
    uint16 public creatorFeeShareBps;

    /// @notice Mapping of token address to its data
    mapping(address => TokenData) public tokens;

    /// @notice Which Bonding Curve addresses can be selected at token creation
    mapping(address => bool) public whitelistedBondingCurves;

    /// @notice Which Graduator addresses can be selected at token creation
    mapping(address => bool) public whitelistedGraduators;

    /// @notice the total supply of tokens forever
    uint256 private constant TOTAL_SUPPLY = 1_000_000e18; // 1M tokens

    // todo update this. So far dummy for compilation
    uint256 private constant BONDING_CURVE_SUPPLY = 1_000_000e18; // 1M tokens for bonding curve

    ///////////////////// Errors /////////////////////

    error InvalidBondingCurve();
    error InvalidGraduator();
    error InvalidNameOrSymbol();
    error InvalidAmount();
    error InvalidParameter(uint256 parameter);
    error InvalidAddress();
    error InvalidToken();
    error CannotBeTraded();
    error NotEnoughSupply();
    error AlreadyGraduated();
    error InsufficientETHReserves();
    error GraduationCriteriaNotMet();
    error EthTransferFailed();
    error DeadlineExceeded();
    error SlippageExceeded();

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
        require(whitelistedBondingCurves[bondingCurve], InvalidBondingCurve());
        require(whitelistedGraduators[graduator], InvalidGraduator());

        address creator = msg.sender;

        // minimal proxy pattern to deploy a new LivoToken instance
        address tokenClone = Clones.clone(address(tokenImplementation));
        // Initialize the new token instance
        // It is responsibility of the token to distribute supply to the creator
        // so that we can update the token implementation with new rules for future tokens
        LivoToken(tokenClone).initialize(name, symbol, creator, address(this), TOTAL_SUPPLY);

        // at creation all tokens are held by this contract
        tokens[tokenClone] = TokenData({
            bondingCurve: ILivoBondingCurve(bondingCurve),
            graduator: graduator,
            creator: creator,
            ethCollected: 0,
            creatorFeesCollected: 0,
            // question would it make sense to make the calculations based on the balanceOf this address at all times?
            circulatingSupply: TOTAL_SUPPLY - IERC20(tokenClone).balanceOf(address(this)),
            buyFeeBps: baseBuyFeeBps,
            sellFeeBps: baseSellFeeBps,
            creatorFeeBps: creatorFeeShareBps,
            graduated: false
        });

        emit TokenCreated(tokenClone, creator, name, symbol, bondingCurve, metadata);

        return tokenClone;
    }

    function buyToken(address token, uint256 minTokenAmount, uint256 deadline) external payable {
        TokenData storage tokenData = tokens[token];

        require(msg.value > 0, InvalidAmount());
        require(tokenData.exists(), InvalidToken());
        require(tokenData.notGraduated(), AlreadyGraduated());
        require(block.timestamp <= deadline, DeadlineExceeded());

        // this applies the trading fees
        (uint256 ethForReserves, uint256 ethFee, uint256 tokensToReceive) = quoteBuy(token, msg.value);

        require(tokensToReceive >= IERC20(token).balanceOf(address(this)), NotEnoughSupply());
        require(tokensToReceive >= minTokenAmount, SlippageExceeded());

        uint256 creatorFee = (ethFee * tokenData.creatorFeeBps) / BASIS_POINTS;

        tokenData.creatorFeesCollected += creatorFee;
        treasuryEthFeesCollected += ethFee - creatorFee;
        tokenData.ethCollected += ethForReserves;

        IERC20(token).safeTransfer(msg.sender, tokensToReceive);

        emit LivoTokenPurchased(token, msg.sender, msg.value, tokensToReceive, ethFee);
    }

    function sellToken(address token, uint256 tokenAmount, uint256 minEthAmount, uint256 deadline) external {
        TokenData storage tokenData = tokens[token];

        require(tokenData.exists(), InvalidToken());
        require(tokenData.notGraduated(), AlreadyGraduated());
        require(tokenAmount > 0, InvalidAmount());
        require(block.timestamp <= deadline, DeadlineExceeded());

        (uint256 ethFromSale, uint256 ethFee, uint256 ethForSeller) = quoteSell(token, tokenAmount);

        // This is to prevent where a bonding curve steals from other curves or treasury
        // Hopefully this scenario never happens
        require(ethFromSale <= tokenData.ethCollected, InsufficientETHReserves());
        require(ethForSeller >= minEthAmount, SlippageExceeded());

        tokenData.ethCollected -= ethFromSale;

        uint256 creatorFee = (ethFee * tokenData.creatorFeeBps) / BASIS_POINTS;

        tokenData.creatorFeesCollected += creatorFee;
        treasuryEthFeesCollected += ethFee - creatorFee;

        emit LivoTokenSold(token, msg.sender, tokenAmount, ethForSeller, ethFee);

        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);
        // review potential reentrancies
        (bool success,) = payable(msg.sender).call{value: ethForSeller}("");
        require(success, EthTransferFailed());
    }

    function graduateToken(address token) external payable {
        TokenData storage tokenData = tokens[token];

        require(tokenData.notGraduated(), AlreadyGraduated());
        require(meetsGraduationCriteria(token), GraduationCriteriaNotMet());

        tokenData.graduated = true;

        // review if token donations can mess up this
        uint256 ethCollected = tokenData.ethCollected;

        uint256 ethForGraduation = ethCollected - graduationFee;
        uint256 tokensForGraduation = IERC20(token).balanceOf(address(this));

        treasuryEthFeesCollected += graduationFee;

        ILivoGraduator graduator = ILivoGraduator(tokenData.graduator);
        IERC20(token).safeTransfer(address(graduator), tokensForGraduation);
        graduator.graduateToken{value: ethForGraduation}(token);

        emit TokenGraduated(token, ethForGraduation, tokensForGraduation);
    }

    //////////////////////////// view functions //////////////////////////

    function quoteBuy(address token, uint256 ethValue)
        external
        view
        returns (uint256 ethForPurchase, uint256 ethFee, uint256 tokensToReceive)
    {
        TokenData storage tokenData = tokens[token];

        ethFee = (ethValue * tokenData.buyFeeBps) / BASIS_POINTS;
        ethForPurchase = ethValue - ethFee;

        tokensToReceive = tokenData.bondingCurve.getTokensForEth(tokenData.circulatingSupply, ethForPurchase);
        return (ethForPurchase, ethFee, tokensToReceive);
    }

    function quoteSell(address token, uint256 tokenAmount)
        external
        view
        returns (uint256 ethFromSale, uint256 ethFee, uint256 ethForSeller)
    {
        TokenData storage tokenData = tokens[token];

        ethFromSale = tokenData.bondingCurve.getEthForTokens(tokenData.circulatingSupply, tokenAmount);
        ethFee = (ethFromSale * tokenData.sellFeeBps) / BASIS_POINTS;
        ethForSeller = ethFromSale - ethFee;

        return (ethFromSale, ethFee, ethForSeller);
    }

    function getBuyPrice(address token, uint256 ethAmount) external view returns (uint256) {
        TokenData storage tokenData = tokens[token];
        require(tokenData.creator != address(0), "LivoLaunchpad: Token not found");

        // review this bonding curve interface
        uint256 fee = (ethAmount * tokenData.buyFeeBps) / BASIS_POINTS;
        uint256 ethForTokens = ethAmount - fee;

        return tokenData.bondingCurve.getTokensForEth(tokenData.circulatingSupply, ethForTokens);
    }

    function getSellPrice(address token, uint256 tokenAmount) external view returns (uint256) {
        TokenData storage tokenData = tokens[token];
        require(tokenData.creator != address(0), "LivoLaunchpad: Token not found");

        uint256 ethToReceive = tokenData.bondingCurve.getEthForTokens(tokenData.circulatingSupply, tokenAmount);

        uint256 fee = (ethToReceive * tokenData.sellFeeBps) / BASIS_POINTS;
        return ethToReceive - fee;
    }

    function meetsGraduationCriteria(address token) public view returns (bool) {
        TokenData storage tokenData = tokens[token];
        // the graduation fee is taken from the eth collected by the curve, so the final liquidity is the graduation threshold
        return (tokenData.ethCollected >= graduationThreshold + graduationFee) && !tokenData.graduated;
    }

    function getEthCollectedByToken(address token) external view returns (uint256) {
        return tokens[token].ethCollected;
    }

    //////////////////////////// Admin functions //////////////////////////

    function setLivoTokenImplementation(IERC20 newImplementation) external onlyOwner {
        require(address(newImplementation) != address(0), InvalidAddress());
        tokenImplementation = newImplementation;
        emit TokenImplementationUpdated(newImplementation);
    }

    // Owner functions
    function setGraduationThreshold(uint256 ethAmount) external onlyOwner {
        graduationThreshold = ethAmount;
        emit GraduationThresholdUpdated(ethAmount);
    }

    function setTreasuryAddress(address recipient) external onlyOwner {
        treasury = recipient;
        emit TreasuryAddressUpdated(recipient);
    }

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

    function setTradingFees(uint16 buyFeeBps, uint16 sellFeeBps) external onlyOwner {
        require(buyFeeBps <= BASIS_POINTS, InvalidParameter(buyFeeBps));
        require(sellFeeBps <= BASIS_POINTS, InvalidParameter(sellFeeBps));
        baseBuyFeeBps = buyFeeBps;
        baseSellFeeBps = sellFeeBps;
        emit TradingFeesUpdated(buyFeeBps, sellFeeBps);
    }

    function collectTreasuryFees() external onlyOwner {
        uint256 amount = treasuryEthFeesCollected;
        if (amount == 0) return;

        (bool success,) = treasury.call{value: amount}("");
        require(success, EthTransferFailed());
        treasuryEthFeesCollected = 0;

        emit TreasuryFeesCollected(treasury, amount);
    }
}
