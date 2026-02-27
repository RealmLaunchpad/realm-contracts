// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {ILivoBondingCurve} from "src/interfaces/ILivoBondingCurve.sol";
import {ILivoGraduator} from "src/interfaces/ILivoGraduator.sol";
import {ILivoLaunchpad} from "src/interfaces/ILivoLaunchpad.sol";
import {FactoryWhitelisting} from "src/FactoryWhitelisting.sol";
import {TokenConfig, TokenState, TokenDataLib} from "src/types/tokenData.sol";

contract LivoLaunchpad is ILivoLaunchpad, Ownable2Step, FactoryWhitelisting {
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

    /// @notice Total fees collected by the treasury (in wei)
    uint256 public treasuryEthFeesCollected;

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
    error InvalidTokenSupply();

    ///////////////////// Events /////////////////////

    event TokenCreated(
        address indexed token,
        address indexed tokenOwner,
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

    /////////////////////////////////////////////////

    /// @param _treasury Address of the treasury to receive fees
    constructor(address _treasury) Ownable(msg.sender) {
        // Set initial values and emit events for off-chain indexers
        setTreasuryAddress(_treasury);
        // buy/sell fees at 1%
        setTradingFees(100, 100);
    }

    function launchToken(address token, ILivoBondingCurve bondingCurve) external onlyWhitelistedFactory {
        require(IERC20(token).totalSupply() == TOTAL_SUPPLY, InvalidTokenSupply());
        // this check is important because bondingCurve!=address(0) is used as proxy for valid existing tokens within the Launchpad
        require(address(bondingCurve) != address(0), InvalidAddress());

        tokenConfigs[token] = TokenConfig({
            bondingCurve: bondingCurve,
            buyFeeBps: baseBuyFeeBps,
            sellFeeBps: baseSellFeeBps
        });

        // todo finish implement
        // todo consider emitting event
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
        if (tokenState.ethCollected >= tokenConfig.bondingCurve.ethGraduationThreshold()) {
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
        _transferEth(msg.sender, ethForSeller, true);

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

    /// @notice Returns the owner of a token
    /// @param token The address of the token
    /// @return The address of the token owner
    function getTokenOwner(address token) external view returns (address) {
        // reverts on purpose because other parts of the system rely on the veracity of this output
        if (!tokenConfigs[token].exists()) revert InvalidToken();
        return ILivoToken(token).owner();
    }

    //////////////////////////// Admin functions //////////////////////////

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

    /// @notice Collects accumulated treasury fees and transfers them to the treasury
    /// @dev No access control, as the receiver of the fees is the treasury itself
    function collectTreasuryFees() external {
        uint256 amount = treasuryEthFeesCollected;
        if (amount == 0) return;

        treasuryEthFeesCollected = 0;

        _transferEth(treasury, amount, true);

        emit TreasuryFeesCollected(treasury, amount);
    }

    /// @notice If a token is abandoned by original creators and the community wants to step in,
    ///         the contract admins can propose a new owner without needing to be the current owner.
    ///         The proposed address must still call acceptTokenOwnership() to complete the transfer.
    /// @dev A malicious team can potentially take over any token, but that would undermine the community trust so the incentives are little.
    /// @param token The address of the token
    /// @param newTokenOwner The address of the proposed new tokenOwner (must not be address(0))
    function communityTakeOver(address token, address newTokenOwner) external onlyOwner {
        // todo redirect this to updating owneship in the token
        // todo implement tests
    }

    //////////////////////////// Internal functions //////////////////////////

    /// @dev This function assumes that the graduation criteria is met
    /// @dev It also assumes that the token hasn't been graduated yet
    function _graduateToken(address tokenAddress, TokenState storage tokenState) internal {
        IERC20 token = IERC20(tokenAddress);
        tokenState.graduated = true;

        uint256 ethCollected = tokenState.ethCollected;
        uint256 tokenBalance = token.balanceOf(address(this));

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

    function _transferEth(address recipient, uint256 amount, bool requireSuccess) internal returns (bool) {
        if (amount == 0) return true;
        // note: this call happens always after all state changes in all callers of this function to protect against re-entrancy
        (bool success,) = recipient.call{value: amount}("");
        require(!requireSuccess || success, EthTransferFailed());

        return success;
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
    function _availableTokensForPurchase(address token) internal view returns (uint256) {
        // This is equivalent to: return IERC20(token).balanceOf(address(this));
        // But the below formulation is more gas efficient as it avoids an external call
        return TOTAL_SUPPLY - tokenStates[token].releasedSupply;
    }

    function _availableEthFromReserves(address token) internal view returns (uint256) {
        return tokenStates[token].ethCollected;
    }
}
