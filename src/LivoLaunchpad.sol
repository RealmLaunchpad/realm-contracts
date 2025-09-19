// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import {LivoToken} from "src/LivoToken.sol";
import {ILivoBondingCurve} from "src/interfaces/ILivoBondingCurve.sol";
import {ILivoGraduator} from "src/interfaces/ILivoGraduator.sol";
import {TokenConfig, TokenState, TokenDataLib} from "src/types/tokenData.sol";

contract LivoLaunchpad is Ownable {
    using SafeERC20 for IERC20;
    using TokenDataLib for TokenConfig;
    using TokenDataLib for TokenState;

    /// 100% in basis points
    uint256 public constant BASIS_POINTS = 10_000;

    /// @notice the total supply of all deployed tokens
    uint256 private constant TOTAL_SUPPLY = 1_000_000_000e18; // 1B tokens

    /// @notice Supply reserved to the token creator, but only transferred at token graduation
    uint256 public constant CREATOR_RESERVED_SUPPLY = 10_000_000e18;

    /// @notice The max amount of ether in reserves of a token after crossing the graduation threshold
    uint256 public constant MAX_THRESHOLD_EXCEESS = 0.5 ether;

    /// @notice LivoToken ERC20 implementation address
    IERC20 public tokenImplementation;

    /// @notice Eth reserves accumulated by a token to meet graduation criteria. Includes the graduation fees
    uint256 public baseEthGraduationThreshold;

    /// @notice The base graduation fee in ETH, paid at graduation to the treasury
    uint256 public baseGraduationFee;

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

    ///////////////////// Errors /////////////////////

    error InvalidBondingCurve();
    error InvalidGraduator();
    error InvalidNameOrSymbol();
    error InvalidAmount();
    error InvalidParameter(uint256 parameter);
    error InvalidToken();
    error NotEnoughSupply();
    error AlreadyGraduated();
    error InsufficientETHReserves();
    error GraduationCriteriaNotMet();
    error EthTransferFailed();
    error DeadlineExceeded();
    error SlippageExceeded();
    error PurchaseExceedsLimitPostGraduation();

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
    event TokenGraduated(address indexed token, uint256 ethCollected, uint256 tokensForGraduation);
    event LivoTokenBuy(
        address indexed token, address indexed buyer, uint256 ethAmount, uint256 tokenAmount, uint256 ethFee
    );
    event LivoTokenSell(
        address indexed token, address indexed seller, uint256 tokenAmount, uint256 ethAmount, uint256 ethFee
    );
    event TreasuryFeesCollected(address indexed treasury, uint256 amount);
    event TokenImplementationUpdated(address newImplementation);
    event EthGraduationThresholdUpdated(uint256 newThreshold);
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

        // This arbitrarily exact price ensures that if graduation happens exactly at this value,
        // the price in the uniswap pool after graduation matches the price of the bonding curve
        setEthGraduationThreshold(7956000000000052224); // 7.956 ether
        setGraduationFee(0.5 ether);
        // buy/sell fees at 1%
        setTradingFees(100, 100);
    }

    struct TmpTokenMeta {
        address token;
        string name;
        string symbol;
        string metadata;
        address bondingCurve;
        address graduator;
        uint16 buyFeesBps;
        uint16 sellFeesBps;
    }

    function createToken(
        string calldata name,
        string calldata symbol,
        string calldata metadata,
        address bondingCurve,
        address graduator
    ) external returns (address) {
        require(bytes(name).length > 0 && bytes(symbol).length > 0, InvalidNameOrSymbol());
        require(bytes(symbol).length <= 32, InvalidNameOrSymbol());

        require(whitelistedBondingCurves[bondingCurve], InvalidBondingCurve());
        require(whitelistedGraduators[graduator], InvalidGraduator());

        // minimal proxy pattern to deploy a new LivoToken instance
        // Deploying the contracts with new() costs 3-4 times more gas than cloning
        // trading will be a bit more expensive, as variables cannot be immutable
        address tokenClone = Clones.clone(address(tokenImplementation));

        TmpTokenMeta memory tmpTokenMeta = TmpTokenMeta({
            token: tokenClone,
            name: name,
            symbol: symbol,
            metadata: metadata,
            bondingCurve: bondingCurve,
            graduator: graduator,
            buyFeesBps: baseBuyFeeBps,
            sellFeesBps: baseSellFeeBps
        });

        // This event needs to be emitted before the tokens are minted so that the indexer starts tracking this token address first
        emit TokenCreated(tokenClone, msg.sender, name, symbol, bondingCurve, graduator, metadata);

        // initialize token config, pair and token state
        // forced to do this weird thing due to stack-too-deep errors
        _initializers(tmpTokenMeta);

        return tokenClone;
    }

    /// @dev slippage control is done with minTokenAmount (min tokens willing to buy)
    function buyTokensWithExactEth(address token, uint256 minTokenAmount, uint256 deadline) external payable {
        TokenConfig storage tokenConfig = tokenConfigs[token];
        TokenState storage tokenState = tokenStates[token];

        require(msg.value > 0, InvalidAmount());
        require(tokenConfig.exists(), InvalidToken());
        require(tokenState.notGraduated(), AlreadyGraduated());
        require(block.timestamp <= deadline, DeadlineExceeded());
        // fees are ignored in this check. If fees were accounted, the limit should be higher,
        // which would expand the price diff between bounding curve and uniswap
        require(
            tokenState.ethCollected + msg.value < tokenConfig.ethGraduationThreshold + MAX_THRESHOLD_EXCEESS,
            PurchaseExceedsLimitPostGraduation()
        );

        (uint256 ethForReserves, uint256 ethFee, uint256 tokensToReceive) = _quoteBuyWithExactEth(token, msg.value);

        require(tokensToReceive <= _availableForPurchase(token), NotEnoughSupply());
        require(tokensToReceive >= minTokenAmount, SlippageExceeded());

        require(ethForReserves + ethFee == msg.value, "reserves + fee should match msg.value");
        treasuryEthFeesCollected += ethFee;
        tokenState.ethCollected += ethForReserves;
        tokenState.releasedSupply += tokensToReceive;

        IERC20(token).safeTransfer(msg.sender, tokensToReceive);

        emit LivoTokenBuy(token, msg.sender, msg.value, tokensToReceive, ethFee);

        if (_meetsGraduationCriteria(tokenState, tokenConfig)) {
            _graduateToken(token, tokenState, tokenConfig);
        }
    }

    /// @dev slippage control is done with minEthAmount (min eth willing to receive)
    function sellExactTokens(address token, uint256 tokenAmount, uint256 minEthAmount, uint256 deadline) external {
        TokenConfig storage tokenConfig = tokenConfigs[token];
        TokenState storage tokenState = tokenStates[token];

        require(tokenConfig.exists(), InvalidToken());
        require(tokenState.notGraduated(), AlreadyGraduated());
        require(tokenAmount > 0, InvalidAmount());
        require(block.timestamp <= deadline, DeadlineExceeded());

        (uint256 ethFromReserves, uint256 ethFee, uint256 ethForSeller) = _quoteSellExactTokens(token, tokenAmount);

        // Hopefully this scenario never happens
        require(ethForSeller >= minEthAmount, SlippageExceeded());
        require(_availableEthFromReserves(token) >= ethFromReserves, InsufficientETHReserves());

        tokenState.ethCollected -= ethFromReserves;
        tokenState.releasedSupply -= tokenAmount;
        treasuryEthFeesCollected += ethFee;

        // funds transfers
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);
        _transferEth(msg.sender, ethForSeller);

        emit LivoTokenSell(token, msg.sender, tokenAmount, ethForSeller, ethFee);
    }

    //////////////////////////// view functions //////////////////////////

    function quoteBuyWithExactEth(address token, uint256 ethValue)
        external
        view
        returns (uint256 ethForPurchase, uint256 ethFee, uint256 tokensToReceive)
    {
        (ethForPurchase, ethFee, tokensToReceive) = _quoteBuyWithExactEth(token, ethValue);

        if (ethForPurchase > _maxEthToSpend(token)) revert PurchaseExceedsLimitPostGraduation();
        if (tokensToReceive > _availableForPurchase(token)) revert NotEnoughSupply();
    }

    function quoteSellExactTokens(address token, uint256 tokenAmount)
        external
        view
        returns (uint256 ethFromSale, uint256 ethFee, uint256 ethForSeller)
    {
        (ethFromSale, ethFee, ethForSeller) = _quoteSellExactTokens(token, tokenAmount);

        if (ethForSeller > _availableEthFromReserves(token)) revert InsufficientETHReserves();
    }

    /// @notice Returns the maximum amount of ETH that can be spent on a given token
    /// @dev This avoids going above the excess limit above graduation threshold
    function getMaxEthToSpend(address token) external view returns (uint256) {
        return _maxEthToSpend(token);
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
        tokenImplementation = newImplementation;
        emit TokenImplementationUpdated(address(newImplementation));
    }

    /// @notice Updates the graduation threshold, which only affects new token deployments
    function setEthGraduationThreshold(uint256 ethThreshold) public onlyOwner {
        baseEthGraduationThreshold = ethThreshold;
        emit EthGraduationThresholdUpdated(ethThreshold);
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
    function whitelistBondingCurve(address bondingCurve, bool whitelisted) external onlyOwner {
        whitelistedBondingCurves[bondingCurve] = whitelisted;
        emit BondingCurveWhitelisted(bondingCurve, whitelisted);
    }

    /// @dev blacklisted graduators will still be able to graduate the tokens that where created with them
    function whitelistGraduator(address graduator, bool whitelisted) external onlyOwner {
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

    function _initializers(TmpTokenMeta memory tmpTokenMeta) internal {
        // at creation all tokens are held by this contract
        tokenConfigs[tmpTokenMeta.token] = TokenConfig({
            bondingCurve: ILivoBondingCurve(tmpTokenMeta.bondingCurve),
            graduator: ILivoGraduator(tmpTokenMeta.graduator),
            creator: msg.sender,
            graduationEthFee: baseGraduationFee,
            ethGraduationThreshold: baseEthGraduationThreshold,
            creatorReservedSupply: CREATOR_RESERVED_SUPPLY,
            buyFeeBps: tmpTokenMeta.buyFeesBps,
            sellFeeBps: tmpTokenMeta.sellFeesBps
        });

        // Creates the Uniswap Pair or whatever other initialization is necessary
        address pair = ILivoGraduator(tmpTokenMeta.graduator).initializePair(tmpTokenMeta.token);

        // Initialize the new token instance
        // It is responsibility of the token to distribute supply to the msg.sender
        // so that we can update the token implementation with new rules for future tokens
        LivoToken(tmpTokenMeta.token).initialize(
            tmpTokenMeta.name,
            tmpTokenMeta.symbol,
            address(this), // launchpad
            tmpTokenMeta.graduator, // graduator address
            pair, // uniswap pair
            TOTAL_SUPPLY,
            tmpTokenMeta.buyFeesBps,
            tmpTokenMeta.sellFeesBps
        );
    }

    /// @dev This function assumes that the graduation criteria have been met
    /// @dev It also assumes that the token hasn't been graduated yet
    function _graduateToken(address tokenAddress, TokenState storage tokenState, TokenConfig storage tokenConfig)
        internal
    {
        IERC20 token = IERC20(tokenAddress);

        tokenState.graduated = true;

        uint256 ethCollected = tokenState.ethCollected;
        uint256 ethForGraduation = ethCollected - tokenConfig.graduationEthFee;
        treasuryEthFeesCollected += tokenConfig.graduationEthFee;

        uint256 tokensForCreator = tokenConfig.creatorReservedSupply;
        uint256 tokensForGraduation = token.balanceOf(address(this)) - tokensForCreator;

        // update token state
        tokenState.ethCollected = 0;
        tokenState.releasedSupply += tokensForCreator + tokensForGraduation;

        // If the last purchase is a large one, the resulting price in the pool will be higher
        // I don't see a security risk in this.
        // The effect is that the last buyer will be at an immediate win.
        // The larger the last purchase, the larger the price difference from the bonding curve to the univ2 pool
        // But I think that simply encourages graduation, so I don't see a big problem
        // The larger the buy, the larger the instant profit of the last purchase
        // @audit can the last buyer exploit this somehow?

        token.safeTransfer(tokenConfig.creator, tokensForCreator);
        token.safeTransfer(address(tokenConfig.graduator), tokensForGraduation);

        tokenConfig.graduator.graduateToken{value: ethForGraduation}(tokenAddress);

        emit TokenGraduated(tokenAddress, ethForGraduation, tokensForGraduation);
    }

    function _transferEth(address recipient, uint256 amount) internal {
        if (amount == 0) return;
        // @audit beware of potential reentrancies. Make sure this call is always done at the end of all transactions
        (bool success,) = recipient.call{value: amount}("");
        require(success, EthTransferFailed());
    }

    //////////////////////// INTERNAL VIEW FUNCTIONS //////////////////////////

    function _maxEthToSpend(address token) internal view returns (uint256) {
        return tokenConfigs[token].ethGraduationThreshold + MAX_THRESHOLD_EXCEESS - tokenStates[token].ethCollected;
    }

    function _quoteBuyWithExactEth(address token, uint256 ethValue)
        internal
        view
        returns (uint256 ethForPurchase, uint256 ethFee, uint256 tokensToReceive)
    {
        TokenConfig storage tokenConfig = tokenConfigs[token];

        ethFee = (ethValue * tokenConfig.buyFeeBps) / BASIS_POINTS;
        ethForPurchase = ethValue - ethFee;

        tokensToReceive = tokenConfig.bondingCurve.buyTokensWithExactEth(
            tokenStates[token].tokenReserves(), tokenStates[token].ethCollected, ethForPurchase
        );

        return (ethForPurchase, ethFee, tokensToReceive);
    }

    function _quoteSellExactTokens(address token, uint256 tokenAmount)
        internal
        view
        returns (uint256 ethFromSale, uint256 ethFee, uint256 ethForSeller)
    {
        TokenConfig storage tokenConfig = tokenConfigs[token];

        ethFromSale = tokenConfig.bondingCurve.sellExactTokens(
            tokenStates[token].tokenReserves(), tokenStates[token].ethCollected, tokenAmount
        );

        ethFee = (ethFromSale * tokenConfig.sellFeeBps) / BASIS_POINTS;
        ethForSeller = ethFromSale - ethFee;

        return (ethFromSale, ethFee, ethForSeller);
    }

    function _meetsGraduationCriteria(TokenState storage state, TokenConfig storage config)
        internal
        view
        returns (bool)
    {
        return (state.ethCollected >= config.ethGraduationThreshold);
    }

    /// @dev The supply of a token that can be purchased
    /// @dev The reserved creator supply is only effective at graduation,
    /// and it is taken from the remaining tokens in this contract at graduation
    function _availableForPurchase(address token) internal view returns (uint256) {
        // This is equivalent to:  return IERC20(token).balanceOf(address(this)) - CREATOR_RESERVED_SUPPLY;
        // But this implementation is more gas efficient as it avoids an external call
        return TOTAL_SUPPLY - tokenStates[token].releasedSupply - CREATOR_RESERVED_SUPPLY;
    }

    function _availableEthFromReserves(address token) internal view returns (uint256) {
        return tokenStates[token].ethCollected;
    }
}
