// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {ILivoBondingCurve} from "src/interfaces/ILivoBondingCurve.sol";
import {ILivoGraduator} from "src/interfaces/ILivoGraduator.sol";
import {ILivoLaunchpad} from "src/interfaces/ILivoLaunchpad.sol";
import {TokenConfig, TokenState, TokenDataLib} from "src/types/tokenData.sol";

contract LivoLaunchpad is ILivoLaunchpad, Ownable2Step {
    using SafeERC20 for IERC20;
    using TokenDataLib for TokenConfig;
    using TokenDataLib for TokenState;

    /// @notice Authorized factories
    mapping(address factory => bool authorized) public whitelistedFactories;

    /// @notice Max allowed trading fees in basis points
    uint256 internal constant MAX_TRADING_FEE_BPS = 500; // 5%

    /// @notice 100% in basis points
    uint256 public constant BASIS_POINTS = 10_000;

    /// @notice Livo Treasury, receiver of all trading/graduation fees
    address public treasury;

    /// @notice Trading fees (buys) in basis points (100 bps = 1%). Updates to these only affect future tokens
    uint16 public baseBuyFeeBps;

    /// @notice Trading fees (sells) in basis points (100 bps = 1%). Updates to these only affect future tokens
    uint16 public baseSellFeeBps;

    /// @notice Mapping of token address to its configuration
    mapping(address => TokenConfig) public tokenConfigs;

    /// @notice Mapping of token address to its state variables
    mapping(address => TokenState) public tokenStates;

    ///////////////////// Errors /////////////////////

    error InvalidAddress();
    error InvalidAmount();
    error ReceivingZeroAmount();
    error InvalidParameter(uint256 parameter);
    error InvalidToken();
    error NotEnoughSupply();
    error AlreadyGraduated();
    error InsufficientEthReserves();
    error EthTransferFailed();
    error DeadlineExceeded();
    error SlippageExceeded();
    error AlreadyConfigured();
    error UnauthorizedFactory();

    ///////////////////// Events /////////////////////

    event TokenLaunched(address indexed token, uint256 graduationThreshold, uint256 maxExcessOverThreshold);
    event TokenGraduated(address indexed token, uint256 ethCollected, uint256 tokensForGraduation);
    event LivoTokenBuy(
        address indexed token, address indexed buyer, uint256 ethAmount, uint256 tokenAmount, uint256 ethFee
    );
    event LivoTokenSell(
        address indexed token, address indexed seller, uint256 tokenAmount, uint256 ethAmount, uint256 ethFee
    );
    event TreasuryAddressUpdated(address newTreasury);
    event TradingFeesUpdated(uint16 buyFeeBps, uint16 sellFeeBps);
    event CommunityTakeOver(address indexed token, address newOwner);
    event FactoryWhitelisted(address indexed factory);
    event FactoryBlacklisted(address indexed factory);

    ////////////////// MODIFIERS ///////////////////////

    modifier onlyWhitelistedFactory() {
        _onlyWhitelistedFactory();
        _;
    }

    /////////////////////////////////////////////////

    /// @param _treasury Address of the treasury to receive fees
    constructor(address _treasury) Ownable(msg.sender) {
        // Set initial values and emit events for off-chain indexers
        setTreasuryAddress(_treasury);
        // buy/sell fees at 1%
        setTradingFees(100, 100);
    }

    /// @notice Registers a new token in the launchpad with its bonding curve, callable only by whitelisted factories
    function launchToken(address token, ILivoBondingCurve bondingCurve) external onlyWhitelistedFactory {
        // this check is important because bondingCurve!=address(0) is used as proxy for valid existing tokens within the Launchpad
        // the msg.sender is a trusted factory, which should have a valid bonding curve compliant with IBondingCurve
        require(address(bondingCurve) != address(0), InvalidAddress());

        // these token configs become immutable once set here
        tokenConfigs[token] =
            TokenConfig({bondingCurve: bondingCurve, buyFeeBps: baseBuyFeeBps, sellFeeBps: baseSellFeeBps});

        ILivoBondingCurve.GraduationConfig memory gradConfig = bondingCurve.getGraduationConfig();
        emit TokenLaunched(token, gradConfig.ethGraduationThreshold, gradConfig.maxExcessOverThreshold);
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
        TokenState storage tokenState = tokenStates[token];

        require(msg.value > 0, InvalidAmount());
        require(block.timestamp <= deadline, DeadlineExceeded());
        require(tokenConfigs[token].exists(), InvalidToken());
        require(tokenState.notGraduated(), AlreadyGraduated());

        // this call to bonding curve reverts if exceeds graduation margins
        // The internal function also reverts with NotEnoughSupply if exceeding this contract token balance
        (uint256 ethForReserves, uint256 ethFee, uint256 tokensToReceive, bool canGraduate) =
            _quoteBuyTokensWithExactEth(token, msg.value);

        require(tokensToReceive > 0, ReceivingZeroAmount());
        require(tokensToReceive >= minTokenAmount, SlippageExceeded());

        tokenState.ethCollected += ethForReserves;
        tokenState.releasedSupply += tokensToReceive;

        IERC20(token).safeTransfer(msg.sender, tokensToReceive);
        _transferEth(treasury, ethFee, true);

        emit LivoTokenBuy(token, msg.sender, msg.value, tokensToReceive, ethFee);

        // if the graduation criteria is met, graduation happens automatically
        if (canGraduate) {
            _graduateToken(token, tokenState);
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

        require(tokenAmount > 0, InvalidAmount());
        require(block.timestamp <= deadline, DeadlineExceeded());
        require(tokenConfig.exists(), InvalidToken());
        require(tokenState.notGraduated(), AlreadyGraduated());

        // reverts with InsufficientEthReserves if seller would receive more than eth reserves allocated to the token
        // that scenario should never happen, it is an extra cautious measure
        (uint256 ethPulledFromReserves, uint256 ethFee, uint256 ethForSeller) =
            _quoteSellExactTokens(token, tokenAmount);

        require(ethForSeller >= minEthAmount, SlippageExceeded());
        // When minEthAmount==0, we assume that the seller accepts any kind of "reasonable" slippage
        // However, receiving eth in exchange for a non-zero amount of tokens would be unfair
        require(ethForSeller > 0, ReceivingZeroAmount());

        tokenState.ethCollected -= ethPulledFromReserves;
        tokenState.releasedSupply -= tokenAmount;

        emit LivoTokenSell(token, msg.sender, tokenAmount, ethForSeller, ethFee);

        // funds transfers
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);

        _transferEth(treasury, ethFee, true);
        _transferEth(msg.sender, ethForSeller, true);

        return ethForSeller;
    }

    //////////////////////////// view functions //////////////////////////

    /// @notice Quotes the result of buying tokens with exact ETH amount
    /// @param token Address of the token to quote
    /// @param ethValue Amount of ETH to spend
    /// @return ethForPurchase Amount of ETH used effectively for purchase (after fees)
    /// @return ethFee Fee amount in ETH
    /// @return tokensToReceive Amount of tokens that would be received
    function quoteBuyTokensWithExactEth(address token, uint256 ethValue)
        external
        view
        returns (uint256 ethForPurchase, uint256 ethFee, uint256 tokensToReceive)
    {
        if (!tokenConfigs[token].exists()) revert InvalidToken();

        // this reverts with NotEnoughSupply if attempting to purchase more than this contract's balance
        (ethForPurchase, ethFee, tokensToReceive,) = _quoteBuyTokensWithExactEth(token, ethValue);
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

        // reverts with InsufficientEthReserves if seller would receive more than eth reserves allocated to the token
        // that scenario should never happen, it is an extra cautious measure
        (ethPulledFromReserves, ethFee, ethForSeller) = _quoteSellExactTokens(token, tokenAmount);
    }

    /// @notice Quotes how much total ETH is needed to buy an exact amount of tokens
    /// @param token Address of the token to quote
    /// @param tokenAmount Amount of tokens to buy
    /// @return totalEthNeeded Total ETH to send (including fee)
    /// @return ethFee Fee amount in ETH
    /// @return ethForReserves ETH that goes into the reserves
    /// @return canGraduate Whether this buy reaches the graduation threshold
    function quoteBuyExactTokens(address token, uint256 tokenAmount)
        external
        view
        returns (uint256 totalEthNeeded, uint256 ethFee, uint256 ethForReserves, bool canGraduate)
    {
        if (!tokenConfigs[token].exists()) revert InvalidToken();
        (totalEthNeeded, ethFee, ethForReserves, canGraduate) = _quoteBuyExactTokens(token, tokenAmount);
    }

    /// @notice Quotes how many tokens must be sold to receive an exact amount of ETH
    /// @param token Address of the token to quote
    /// @param ethAmount Amount of ETH the seller wants to receive
    /// @return ethPulledFromReserves Amount of ETH pulled from reserves (before fee)
    /// @return ethFee Fee amount in ETH
    /// @return tokensRequired Amount of tokens that must be sold
    function quoteSellTokensForExactEth(address token, uint256 ethAmount)
        external
        view
        returns (uint256 ethPulledFromReserves, uint256 ethFee, uint256 tokensRequired)
    {
        if (!tokenConfigs[token].exists()) revert InvalidToken();
        (ethPulledFromReserves, ethFee, tokensRequired) = _quoteSellTokensForExactEth(token, ethAmount);
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

    //////////////////////////// Admin functions //////////////////////////

    /// @notice Whitelist a Factory allowed to launch tokens here
    function whitelistFactory(address factory) external onlyOwner {
        require(factory != address(0), InvalidAddress());
        require(!whitelistedFactories[factory], AlreadyConfigured());
        whitelistedFactories[factory] = true;
        emit FactoryWhitelisted(factory);
    }

    /// @notice blacklist a Factory not allowed to launch tokens here anymore
    function blacklistFactory(address factory) external onlyOwner {
        require(factory != address(0), InvalidAddress());
        require(whitelistedFactories[factory], UnauthorizedFactory());
        whitelistedFactories[factory] = false;
        emit FactoryBlacklisted(factory);
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

    /// @notice Updates the treasury address
    /// @param recipient The new treasury address
    function setTreasuryAddress(address recipient) public onlyOwner {
        require(recipient != address(0), InvalidAddress());
        treasury = recipient;
        emit TreasuryAddressUpdated(recipient);
    }

    /// @notice If a token is abandoned by original creators and the community wants to step in,
    ///         the contract admins can propose a new owner without needing to be the current owner.
    ///         The proposed address must still call acceptTokenOwnership() to complete the transfer.
    /// @dev A malicious team can potentially take over any token, but that would undermine the community trust so the incentives are little.
    /// @param token The address of the token
    /// @param newTokenOwner The address of the proposed new tokenOwner (must not be address(0))
    function communityTakeOver(address token, address newTokenOwner) external onlyOwner {
        // address(0) is allowed, to cancel an existing proposed owner
        ILivoToken(token).proposeNewOwner(newTokenOwner);
        emit CommunityTakeOver(token, newTokenOwner);
    }

    //////////////////////////// Internal functions //////////////////////////

    /// @dev This function assumes that the graduation criteria is met
    /// @dev It also assumes that the token hasn't been graduated yet
    function _graduateToken(address tokenAddress, TokenState storage tokenState) internal {
        IERC20 token = IERC20(tokenAddress);
        tokenState.graduated = true;

        uint256 ethCollected = tokenState.ethCollected;
        uint256 tokenBalance = _availableTokens(tokenAddress);

        // Update state - all resources transferred to graduator
        tokenState.ethCollected = 0;
        tokenState.releasedSupply += tokenBalance;

        address graduator = ILivoToken(tokenAddress).graduator();

        // Transfer ALL tokens to graduator
        token.safeTransfer(graduator, tokenBalance);

        // Graduator handles: burning, fees, compensation, liquidity
        ILivoGraduator(graduator).graduateToken{value: ethCollected}(tokenAddress, tokenBalance);

        emit TokenGraduated(tokenAddress, ethCollected, tokenBalance);
    }

    /// @notice Transfers ETH to a recipient, optionally reverting on failure
    function _transferEth(address recipient, uint256 amount, bool requireSuccess) internal returns (bool) {
        if (amount == 0) return true;
        // note: this call happens always after all state changes in all callers of this function to protect against re-entrancy
        (bool success,) = recipient.call{value: amount}("");
        require(!requireSuccess || success, EthTransferFailed());

        return success;
    }

    //////////////////////// INTERNAL VIEW FUNCTIONS //////////////////////////

    /// @notice Returns the maximum ETH a user can spend on a token without exceeding graduation limits
    function _maxEthToSpend(address token) internal view returns (uint256 ethBuy) {
        uint256 remainingReserves = tokenConfigs[token].maxEthReserves() - tokenStates[token].ethCollected;

        // apply inverse fees
        ethBuy = (remainingReserves * BASIS_POINTS) / (BASIS_POINTS - tokenConfigs[token].buyFeeBps);
    }

    /// @notice Computes the buy quote: ETH split, fee, tokens received, and graduation eligibility
    function _quoteBuyTokensWithExactEth(address token, uint256 ethValue)
        internal
        view
        returns (uint256 ethForPurchase, uint256 ethFee, uint256 tokensToReceive, bool canGraduate)
    {
        TokenConfig storage tokenConfig = tokenConfigs[token];

        // it is ok that these fees round in favor of the user (1 wei less fee on every purchase)
        ethFee = (ethValue * tokenConfig.buyFeeBps) / BASIS_POINTS;
        ethForPurchase = ethValue - ethFee;

        (tokensToReceive, canGraduate) =
            tokenConfig.bondingCurve.buyTokensWithExactEth(tokenStates[token].ethCollected, ethForPurchase);

        if (tokensToReceive > _availableTokens(token)) revert NotEnoughSupply();

        return (ethForPurchase, ethFee, tokensToReceive, canGraduate);
    }

    /// @notice Computes the sell quote: ETH pulled from reserves, fee, and ETH for the seller
    function _quoteSellExactTokens(address token, uint256 tokenAmount)
        internal
        view
        returns (uint256 ethPulledFromReserves, uint256 ethFee, uint256 ethForSeller)
    {
        TokenConfig storage tokenConfig = tokenConfigs[token];

        ethPulledFromReserves = tokenConfig.bondingCurve.sellExactTokens(tokenStates[token].ethCollected, tokenAmount);

        // it is ok that these fees round in favor of the user (1 wei less fee on every sale)
        ethFee = (ethPulledFromReserves * tokenConfig.sellFeeBps) / BASIS_POINTS;
        ethForSeller = ethPulledFromReserves - ethFee;

        if (ethPulledFromReserves > _availableEthFromReserves(token)) revert InsufficientEthReserves();

        return (ethPulledFromReserves, ethFee, ethForSeller);
    }

    /// @notice Computes the inverse buy quote: total ETH needed to buy exact tokens
    function _quoteBuyExactTokens(address token, uint256 tokenAmount)
        internal
        view
        returns (uint256 totalEthNeeded, uint256 ethFee, uint256 ethForReserves, bool canGraduate)
    {
        TokenConfig storage tokenConfig = tokenConfigs[token];

        (ethForReserves, canGraduate) =
            tokenConfig.bondingCurve.buyExactTokens(tokenStates[token].ethCollected, tokenAmount);

        // Inverse fee: ethForReserves = totalEthNeeded * (BASIS_POINTS - buyFeeBps) / BASIS_POINTS
        // So totalEthNeeded = ceil(ethForReserves * BASIS_POINTS / (BASIS_POINTS - buyFeeBps))
        uint256 denom = BASIS_POINTS - tokenConfig.buyFeeBps;
        totalEthNeeded = (ethForReserves * BASIS_POINTS + denom - 1) / denom;
        ethFee = totalEthNeeded - ethForReserves;

        if (tokenAmount > _availableTokens(token)) revert NotEnoughSupply();
    }

    /// @notice Computes the inverse sell quote: tokens needed to receive exact ETH
    function _quoteSellTokensForExactEth(address token, uint256 ethAmount)
        internal
        view
        returns (uint256 ethPulledFromReserves, uint256 ethFee, uint256 tokensRequired)
    {
        TokenConfig storage tokenConfig = tokenConfigs[token];

        // ethAmount = ethPulledFromReserves * (BASIS_POINTS - sellFeeBps) / BASIS_POINTS
        // So ethPulledFromReserves = ceil(ethAmount * BASIS_POINTS / (BASIS_POINTS - sellFeeBps))
        uint256 denom = BASIS_POINTS - tokenConfig.sellFeeBps;
        ethPulledFromReserves = (ethAmount * BASIS_POINTS + denom - 1) / denom;
        ethFee = ethPulledFromReserves - ethAmount;

        tokensRequired =
            tokenConfig.bondingCurve.sellTokensForExactEth(tokenStates[token].ethCollected, ethPulledFromReserves);

        if (ethPulledFromReserves > _availableEthFromReserves(token)) revert InsufficientEthReserves();
    }

    /// @dev The supply of a token that can be purchased
    function _availableTokens(address token) internal view returns (uint256) {
        return ILivoToken(token).balanceOf(address(this));
    }

    /// @notice Returns the ETH reserves currently allocated to a token
    function _availableEthFromReserves(address token) internal view returns (uint256) {
        return tokenStates[token].ethCollected;
    }

    function _onlyWhitelistedFactory() internal view {
        require(whitelistedFactories[msg.sender], UnauthorizedFactory());
    }
}
