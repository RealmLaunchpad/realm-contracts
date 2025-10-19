// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import {LivoToken} from "src/LivoToken.sol";
import {ILivoBondingCurve} from "src/interfaces/ILivoBondingCurve.sol";
import {ILivoGraduator} from "src/interfaces/ILivoGraduator.sol";
import {TokenConfig, TokenState, TokenDataLib} from "src/types/tokenData.sol";

contract LivoLaunchpad is Ownable2Step {
    using SafeERC20 for IERC20;
    using TokenDataLib for TokenConfig;
    using TokenDataLib for TokenState;

    /// @notice Max allowed trading fees in basis points
    uint256 internal constant MAX_TRADING_FEE_BPS = 500; // 5%

    /// @notice 100% in basis points
    uint256 public constant BASIS_POINTS = 10_000;

    /// @notice The total supply of all deployed tokens
    /// @dev 1 billion tokens with 18 decimals
    uint256 private constant TOTAL_SUPPLY = 1_000_000_000e18; // 1B tokens

    /// @notice Supply reserved to the token creator, but only transferred at token graduation
    uint256 public constant CREATOR_RESERVED_SUPPLY = 10_000_000e18;

    /// @notice The base graduation fee in ETH, paid at graduation to the treasury (in wei)
    uint256 public baseGraduationFee;

    /// @notice Total fees collected by the treasury (in wei)
    uint256 public treasuryEthFeesCollected;

    /// @notice Livo Treasury, receiver of all trading/graduation fees
    address public treasury;

    /// @notice Trading fees (buys) in basis points (100 bps = 1%). Updates to these only affect future tokens
    uint16 public baseBuyFeeBps;

    /// @notice Trading fees (sells) in basis points (100 bps = 1%). Updates to these only affect future tokens
    uint16 public baseSellFeeBps;

    /// @notice Whitelisted sets of (implementation, bonding curve, graduator)
    mapping(address implementation => mapping(address curve => mapping(address graduator => bool whitelisted))) public whitelistedComponents;

    /// @notice Mapping of token address to its configuration
    mapping(address => TokenConfig) public tokenConfigs;

    /// @notice Mapping of token address to its state variables
    mapping(address => TokenState) public tokenStates;

    ///////////////////// Errors /////////////////////

    error WhitelistAlreadySet();
    error NotWhitelistedComponents();
    error InvalidNameOrSymbol();
    error InvalidAmount();
    error ReceivingZeroAmount();
    error InvalidParameter(uint256 parameter);
    error InvalidToken();
    error NotEnoughSupply();
    error AlreadyGraduated();
    error InsufficientETHReserves();
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
        address implementation,
        address bondingCurve,
        address graduator
    );
    event TokenGraduated(address indexed token, uint256 ethCollected, uint256 tokensForGraduation);
    event LivoTokenBuy(
        address indexed token, address indexed buyer, uint256 ethAmount, uint256 tokenAmount, uint256 ethFee
    );
    event LivoTokenSell(
        address indexed token, address indexed seller, uint256 tokenAmount, uint256 ethAmount, uint256 ethFee
    );
    event TreasuryFeesCollected(address indexed treasury, uint256 amount);
    event TreasuryAddressUpdated(address newTreasury);
    event TradingFeesUpdated(uint16 buyFeeBps, uint16 sellFeeBps);
    event GraduationFeeUpdated(uint256 newGraduationFee);
    event ComponentsSetWhitelisted(address implementation, address bondingCurve, address graduator, bool whitelisted);

    /////////////////////////////////////////////////

    /// @param _treasury Address of the treasury to receive fees
    constructor(address _treasury) Ownable(msg.sender) {
        // Set initial values and emit events for off-chain indexers
        setTreasuryAddress(_treasury);

        setGraduationFee(0.5 ether);
        // buy/sell fees at 1%
        setTradingFees(100, 100);
    }

    /// @notice Creates a token with bonding curve and graduator with 1B total supply held by launchpad initially.
    /// @dev Selected bonding curve and graduator must be a whitelisted pair
    /// @param name The name of the token
    /// @param symbol The symbol of the token (max 32 characters)
    /// @param implementation Token implementation contract
    /// @param bondingCurve Address of the bonding curve contract
    /// @param graduator Address of the graduator contract
    /// @param salt Salt for deterministic deployment, avoiding (to some extent) tokenCreation DOS.
    /// @return token The address of the newly created token
    function createToken(
        string calldata name,
        string calldata symbol,
	address implementation,
        address bondingCurve,
        address graduator,
        bytes32 salt
    ) external returns (address token) {
        require(bytes(name).length > 0 && bytes(symbol).length > 0, InvalidNameOrSymbol());
        require(bytes(symbol).length <= 32, InvalidNameOrSymbol());
        require(whitelistedComponents[implementation][bondingCurve][graduator], NotWhitelistedComponents());

        bytes32 salt_ = keccak256(abi.encodePacked(msg.sender, block.timestamp, symbol, salt));
        // minimal proxy pattern to deploy a new LivoToken instance
        // Deploying the contracts with new() costs 3-4 times more gas than cloning
        // trading will be a bit more expensive, as variables cannot be immutable
        token = Clones.cloneDeterministic(tokenImplementation, salt_);

        // This event needs to be emitted before the tokens are minted so that the indexer starts tracking this token address first
        emit TokenCreated(token, msg.sender, name, symbol, implementation, bondingCurve, graduator);

        (uint256 graduationThreshold, uint256 maxExcessOverThreshold) = ILivoBondingCurve(bondingCurve).getGraduationSettings();

        // at creation all tokens are held by this contract
        tokenConfigs[token] = TokenConfig({
            bondingCurve: ILivoBondingCurve(bondingCurve),
            graduator: ILivoGraduator(graduator),
            creator: msg.sender,
            ethGraduationThreshold: graduationThreshold,
            maxExcessOverThreshold: maxExcessOverThreshold,
            creatorReservedSupply: CREATOR_RESERVED_SUPPLY,
            graduationEthFee: baseGraduationFee,
            buyFeeBps: baseBuyFeeBps,
            sellFeeBps: baseSellFeeBps
        });

        // Creates the Uniswap Pair or whatever other initialization is necessary
        // in the case of univ4, the pair will be the address of the pool manager,
        // to which tokens cannot be transferred until graduation
        address pair = ILivoGraduator(graduator).initializePair(token);

        LivoToken(token).initialize(
            name,
            symbol,
            graduator, // graduator address
            pair, // uniswap pair
            address(this), // supply receiver, all tokens are held by the launchpad initially
            TOTAL_SUPPLY
        );

        return token;
    }

    /// @notice Buys tokens with exact ETH amount
    /// @dev The user sends ETH via msg.value and receives tokens based on the bonding curve price
    /// @dev 1% fee deducted from ETH amount.
    /// @dev Slippage control is done with minTokenAmount.
    /// @dev Purchases can trigger graduation if threshold reached
    /// @dev Cannot buy a token that has already graduated (use uniswap instead)
    /// @param token Address of the token to buy
    /// @param minTokenAmount Minimum amount of tokens to receive (slippage protection)
    /// @param deadline Unix timestamp after which transaction will revert
    /// @return receivedTokens Amount of tokens received
    function buyTokensWithExactEth(address token, uint256 minTokenAmount, uint256 deadline)
        external
        payable
        returns (uint256 receivedTokens)
    {
        TokenConfig storage tokenConfig = tokenConfigs[token];
        TokenState storage tokenState = tokenStates[token];

        require(msg.value > 0, InvalidAmount());
        require(tokenConfig.exists(), InvalidToken());
        require(tokenState.notGraduated(), AlreadyGraduated());
        require(block.timestamp <= deadline, DeadlineExceeded());

        (uint256 ethForReserves, uint256 ethFee, uint256 tokensToReceive) = _quoteBuyWithExactEth(token, msg.value);

        require(tokensToReceive >= minTokenAmount, SlippageExceeded());
        require(tokensToReceive <= _availableTokensForPurchase(token), NotEnoughSupply());
        require(
            tokenState.ethCollected + ethForReserves <= tokenConfig.maxEthReserves(),
            PurchaseExceedsLimitPostGraduation()
        );

        treasuryEthFeesCollected += ethFee;
        tokenState.ethCollected += ethForReserves;
        tokenState.releasedSupply += tokensToReceive;

        IERC20(token).safeTransfer(msg.sender, tokensToReceive);

        emit LivoTokenBuy(token, msg.sender, msg.value, tokensToReceive, ethFee);

        // if the graduation criteria is met, graduation happens automatically
        if (tokenState.ethCollected >= tokenConfig.ethGraduationThreshold) {
            _graduateToken(token, tokenState, tokenConfig);
        }

        return tokensToReceive;
    }

    /// @notice Sells an exact amount of tokens back and receives ETH based on the bonding curve price.
    /// @dev 1% fee deducted from ETH received.
    /// @dev Slippage control is done with minEthAmount (min eth willing to receive).
    /// @dev Cannot sell tokens that have been graduated (use uniswap instead)
    /// @dev Even if minEthAmount==0, receiving 0 eth is not allowed and the transaction reverts
    /// @param token Address of the token to sell
    /// @param tokenAmount Amount of tokens to sell
    /// @param minEthAmount Minimum amount of ETH to receive (slippage protection)
    /// @param deadline Unix timestamp after which transaction will revert
    /// @return receivedEth Amount of ETH received
    function sellExactTokens(address token, uint256 tokenAmount, uint256 minEthAmount, uint256 deadline)
        external
        returns (uint256 receivedEth)
    {
        TokenConfig storage tokenConfig = tokenConfigs[token];
        TokenState storage tokenState = tokenStates[token];

        require(tokenConfig.exists(), InvalidToken());
        require(tokenState.notGraduated(), AlreadyGraduated());
        require(tokenAmount > 0, InvalidAmount());
        require(block.timestamp <= deadline, DeadlineExceeded());

        (uint256 ethPulledFromReserves, uint256 ethFee, uint256 ethForSeller) =
            _quoteSellExactTokens(token, tokenAmount);

        require(ethForSeller >= minEthAmount, SlippageExceeded());
        // When minEthAmount==0, we assume that the seller accepts any kind of "reasonable" slippage
        // However, receiving eth in exchange for a non-zero amount of tokens would be unfair
        require(ethForSeller > 0, ReceivingZeroAmount());
        // Hopefully this scenario never happens
        require(_availableEthFromReserves(token) >= ethPulledFromReserves, InsufficientETHReserves());

        tokenState.ethCollected -= ethPulledFromReserves;
        tokenState.releasedSupply -= tokenAmount;
        treasuryEthFeesCollected += ethFee;

        // funds transfers
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);
        _transferEth(msg.sender, ethForSeller);

        emit LivoTokenSell(token, msg.sender, tokenAmount, ethForSeller, ethFee);

        return ethForSeller;
    }

    //////////////////////////// view functions //////////////////////////

    /// @notice Quotes the result of buying tokens with exact ETH amount
    /// @param token Address of the token to quote
    /// @param ethValue Amount of ETH to spend
    /// @return ethForPurchase Amount of ETH used effectively for purchase (after fees)
    /// @return ethFee Fee amount in ETH
    /// @return tokensToReceive Amount of tokens that would be received
    function quoteBuyWithExactEth(address token, uint256 ethValue)
        external
        view
        returns (uint256 ethForPurchase, uint256 ethFee, uint256 tokensToReceive)
    {
        if (!tokenConfigs[token].exists()) revert InvalidToken();
        if (ethValue > _maxEthToSpend(token)) revert PurchaseExceedsLimitPostGraduation();

        (ethForPurchase, ethFee, tokensToReceive) = _quoteBuyWithExactEth(token, ethValue);

        if (tokensToReceive > _availableTokensForPurchase(token)) revert NotEnoughSupply();
    }

    /// @notice Quotes the result of selling exact amount of tokens
    /// @param token Address of the token to quote
    /// @param tokenAmount Amount of tokens to sell
    /// @return ethPulledFromReserves Amount of ETH pulled from the reserves before fees are applied
    /// @return ethFee Fee amount in ETH
    /// @return ethForSeller Amount of ETH the seller would receive
    function quoteSellExactTokens(address token, uint256 tokenAmount)
        external
        view
        returns (uint256 ethPulledFromReserves, uint256 ethFee, uint256 ethForSeller)
    {
        if (!tokenConfigs[token].exists()) revert InvalidToken();

        (ethPulledFromReserves, ethFee, ethForSeller) = _quoteSellExactTokens(token, tokenAmount);

        if (ethPulledFromReserves > _availableEthFromReserves(token)) revert InsufficientETHReserves();
    }

    /// @notice Returns the maximum amount of ETH that can be spent on a given token
    /// @dev This avoids going above the excess limit above graduation threshold
    function getMaxEthToSpend(address token) external view returns (uint256) {
        return _maxEthToSpend(token);
    }

    /// @notice Returns relevant state variables of a token defined in TokenState struct
    /// @param token Address of the token
    /// @return The TokenState
    function getTokenState(address token) external view returns (TokenState memory) {
        return tokenStates[token];
    }

    /// @notice Returns the configuration of a token
    /// @param token Address of the token
    /// @return The token configuration
    function getTokenConfig(address token) external view returns (TokenConfig memory) {
        return tokenConfigs[token];
    }

    /// @notice Returns the creator of a token
    /// @param token The address of the token
    /// @return The address of the token creator
    function getTokenCreator(address token) external view returns (address) {
        TokenConfig storage config = tokenConfigs[token];
        if (!config.exists()) revert InvalidToken();
        return config.creator;
    }

    //////////////////////////// Admin functions //////////////////////////

    /// @notice Updates the graduation fee, which only affects new token deployments
    /// @param ethAmount The new graduation fee in wei
    function setGraduationFee(uint256 ethAmount) public onlyOwner {
        baseGraduationFee = ethAmount;
        emit GraduationFeeUpdated(ethAmount);
    }

    /// @notice Updates the buy/sell fees, which only affects new token deployments
    /// @param buyFeeBps The buy fee in basis points (100 = 1%)
    /// @param sellFeeBps The sell fee in basis points (100 = 1%)
    function setTradingFees(uint16 buyFeeBps, uint16 sellFeeBps) public onlyOwner {
        require(buyFeeBps <= MAX_TRADING_FEE_BPS, InvalidParameter(buyFeeBps));
        require(sellFeeBps <= MAX_TRADING_FEE_BPS, InvalidParameter(sellFeeBps));
        baseBuyFeeBps = buyFeeBps;
        baseSellFeeBps = sellFeeBps;
        emit TradingFeesUpdated(buyFeeBps, sellFeeBps);
    }

    /// @notice Whitelist a combination of bonding curve and graduator
    /// @dev A combination of bonding curve & graduator can only be used if they are both whitelisted as a pair
    /// @param implementation Token implementation address
    /// @param bondingCurve Address of the bonding curve contract
    /// @param graduator Address of the graduator contract
    /// @param whitelisted True to whitelist combination, false to remove from whitelist
    function whitelistCurveAndGraduator(address implementation, address bondingCurve, address graduator, bool whitelisted) external onlyOwner {
        if (whitelistedComponents[implementation][bondingCurve][graduator] == whitelisted) revert WhitelistAlreadySet();

        whitelistedComponents[implementation][bondingCurve][graduator] = whitelisted;

        emit ComponentsSetWhitelisted(implementation, bondingCurve, graduator, whitelisted);
    }

    /// @notice Updates the treasury address
    /// @param recipient The new treasury address
    function setTreasuryAddress(address recipient) public onlyOwner {
        treasury = recipient;
        emit TreasuryAddressUpdated(recipient);
    }

    /// @notice Collects accumulated treasury fees and transfers them to the treasury
    /// @dev No access control, as the receiver of the fees is the treasury itself
    function collectTreasuryFees() external {
        uint256 amount = treasuryEthFeesCollected;
        if (amount == 0) return;

        treasuryEthFeesCollected = 0;

        _transferEth(treasury, amount);

        emit TreasuryFeesCollected(treasury, amount);
    }

    //////////////////////////// Internal functions //////////////////////////

    /// @dev This function assumes that the graduation criteria is met
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
        // The effect is that the last buyer will be at an immediate small win.
        // The larger the last purchase, the larger the price difference from the bonding curve to the univ2 pool
        // But I think that simply encourages graduation, so I don't see a big problem
        // The larger the buy, the larger the instant profit of the last purchase
        token.safeTransfer(tokenConfig.creator, tokensForCreator);
        token.safeTransfer(address(tokenConfig.graduator), tokensForGraduation);

        // pass here the tokensForGraduation to avoid deflation attack in the graduator
        tokenConfig.graduator.graduateToken{value: ethForGraduation}(tokenAddress, tokensForGraduation);

        emit TokenGraduated(tokenAddress, ethForGraduation, tokensForGraduation);
    }

    function _transferEth(address recipient, uint256 amount) internal {
        if (amount == 0) return;
        // note: this call happens always after all state changes in all callers of this function to protect against re-entrancy
        (bool success,) = recipient.call{value: amount}("");
        require(success, EthTransferFailed());
    }

    //////////////////////// INTERNAL VIEW FUNCTIONS //////////////////////////

    function _maxEthToSpend(address token) internal view returns (uint256 ethBuy) {
        uint256 remainingReserves = tokenConfigs[token].maxEthReserves() - tokenStates[token].ethCollected;

        // apply inverse fees
        ethBuy = (remainingReserves * BASIS_POINTS) / (BASIS_POINTS - tokenConfigs[token].buyFeeBps);
    }

    function _quoteBuyWithExactEth(address token, uint256 ethValue)
        internal
        view
        returns (uint256 ethForPurchase, uint256 ethFee, uint256 tokensToReceive)
    {
        TokenConfig storage tokenConfig = tokenConfigs[token];

        // it is ok that these fees round in favor of the user (1 wei less fee on every purchase)
        ethFee = (ethValue * tokenConfig.buyFeeBps) / BASIS_POINTS;
        ethForPurchase = ethValue - ethFee;

        tokensToReceive =
            tokenConfig.bondingCurve.buyTokensWithExactEth(tokenStates[token].ethCollected, ethForPurchase);

        return (ethForPurchase, ethFee, tokensToReceive);
    }

    function _quoteSellExactTokens(address token, uint256 tokenAmount)
        internal
        view
        returns (uint256 ethFromSale, uint256 ethFee, uint256 ethForSeller)
    {
        TokenConfig storage tokenConfig = tokenConfigs[token];

        ethFromSale = tokenConfig.bondingCurve.sellExactTokens(tokenStates[token].ethCollected, tokenAmount);

        // it is ok that these fees round in favor of the user (1 wei less fee on every sale)
        ethFee = (ethFromSale * tokenConfig.sellFeeBps) / BASIS_POINTS;
        ethForSeller = ethFromSale - ethFee;

        return (ethFromSale, ethFee, ethForSeller);
    }

    /// @dev The supply of a token that can be purchased
    /// @dev The reserved creator supply is only effective at graduation,
    /// and it is taken from the remaining tokens in this contract at graduation
    function _availableTokensForPurchase(address token) internal view returns (uint256) {
        // This is equivalent to:  return IERC20(token).balanceOf(address(this)) - CREATOR_RESERVED_SUPPLY;
        // But the below formulation is more gas efficient as it avoids an external call
        return TOTAL_SUPPLY - tokenStates[token].releasedSupply - CREATOR_RESERVED_SUPPLY;
    }

    function _availableEthFromReserves(address token) internal view returns (uint256) {
        return tokenStates[token].ethCollected;
    }
}
