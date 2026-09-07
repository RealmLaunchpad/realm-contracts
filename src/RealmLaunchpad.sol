// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {IRealmBondingCurve} from "src/interfaces/IRealmBondingCurve.sol";
import {IRealmGraduator} from "src/interfaces/IRealmGraduator.sol";
import {IRealmLaunchpad2} from "src/interfaces/IRealmLaunchpad2.sol";
import {TokenConfig, TokenState, TokenDataLib} from "src/types/tokenData.sol";

contract RealmLaunchpad is IRealmLaunchpad2, Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using TokenDataLib for TokenConfig;
    using TokenDataLib for TokenState;

    /// @notice Version of the Realm stack this contract belongs to
    string public constant VERSION = "2.0";

    /// @notice Authorized factories
    mapping(address factory => bool authorized) public whitelistedFactories;

    /// @notice Defensive per-trade cap on the pre-graduation fee (LP fee + tax)
    uint256 internal constant MAX_TRADING_FEE_BPS = 2_500; // 25%

    /// @notice 100% in basis points
    uint256 public constant BASIS_POINTS = 10_000;

    /// @notice Realm Treasury, receiver of the treasury share of trading fees and of graduation fees
    address public treasury;

    /// @notice Mapping of token address to its configuration
    mapping(address => TokenConfig) public tokenConfigs;

    /// @notice Mapping of token address to its state variables
    mapping(address => TokenState) public tokenStates;

    ///////////////////// Errors /////////////////////

    error InvalidAddress();
    error InvalidAmount();
    error ReceivingZeroAmount();
    error InvalidLaunchpadFee();
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
    event RealmTokenBuy(
        address indexed token, address indexed buyer, uint256 ethAmount, uint256 tokenAmount, uint256 ethFee
    );
    event RealmTokenSell(
        address indexed token, address indexed seller, uint256 tokenAmount, uint256 ethAmount, uint256 ethFee
    );
    /// @notice LP/trading fee split for a pre-graduation trade — creator share routed via the token's
    ///         `accrueFees`, treasury share pushed. Mirrors `LivoSwapHook.LpFeesAccrued` so pre- and
    ///         post-graduation fees aggregate identically.
    event LpFeesAccrued(address indexed token, uint256 creatorShare, uint256 treasuryShare);
    /// @notice Creator tax taken on a pre-graduation trade (100% to the creator via `accrueFees`).
    ///         Mirrors `LivoSwapHook.CreatorTaxesAccrued`. Emitted only when the tax is non-zero.
    event CreatorTaxesAccrued(address indexed token, uint256 amount);
    event TreasuryAddressUpdated(address newTreasury);
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
    /// @param _owner Address of the contract owner
    constructor(address _treasury, address _owner) Ownable(_owner) {
        // Set initial values directly (not via onlyOwner setters) to support CREATE2 deployment
        require(_treasury != address(0), InvalidAddress());
        treasury = _treasury;
        emit TreasuryAddressUpdated(_treasury);
    }

    /// @notice Registers a new token in the launchpad with its bonding curve, callable only by whitelisted factories
    function launchToken(address token, IRealmBondingCurve bondingCurve) external onlyWhitelistedFactory {
        // this check is important because bondingCurve!=address(0) is used as proxy for valid existing tokens within the Launchpad
        // the msg.sender is a trusted factory, which should have a valid bonding curve compliant with IBondingCurve
        require(address(bondingCurve) != address(0), InvalidAddress());

        // the token config (just the bonding curve) becomes immutable once set here. Pre-graduation
        // trading fees are no longer snapshotted here — they are read per-trade from the token itself.
        tokenConfigs[token] = TokenConfig({bondingCurve: bondingCurve});

        IRealmBondingCurve.GraduationConfig memory gradConfig = bondingCurve.getGraduationConfig();
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
        nonReentrant
        returns (uint256 receivedTokens)
    {
        TokenState storage tokenState = tokenStates[token];

        require(msg.value > 0, InvalidAmount());
        require(block.timestamp <= deadline, DeadlineExceeded());
        require(tokenConfigs[token].exists(), InvalidToken());
        require(tokenState.notGraduated(), AlreadyGraduated());

        // pre-graduation fee policy is read from the token itself and capped by the launchpad
        (uint16 totalFeeBps, uint16 lpFeeBps, uint16 treasuryShareBps) = _readLaunchpadFees(token, true);

        // this call to bonding curve reverts if exceeds graduation margins
        // The internal function also reverts with NotEnoughSupply if exceeding this contract token balance
        (uint256 ethForReserves, uint256 ethFee, uint256 tokensToReceive, bool canGraduate) =
            _quoteBuyTokensWithExactEth(token, msg.value, totalFeeBps);

        require(tokensToReceive > 0, ReceivingZeroAmount());
        require(tokensToReceive >= minTokenAmount, SlippageExceeded());

        tokenState.ethCollected += ethForReserves;
        tokenState.releasedSupply += tokensToReceive;

        // WARNING: fee-on-transfer / rebasing tokens are NOT supported and must never be launched here. The
        // launchpad assumes the buyer receives exactly `tokensToReceive`. A token that skims on transfer would
        // silently under-deliver (defeating the minTokenAmount slippage check above) and drift inventory.
        IERC20(token).safeTransfer(msg.sender, tokensToReceive);
        // split the fee: LP fee between treasury (push) and creator (accrueFees); tax (the remainder) fully to creator
        uint256 lpFee = (msg.value * lpFeeBps) / BASIS_POINTS;
        // tax = ethFee - lpFee
        _settleFee(token, lpFee, ethFee - lpFee, treasuryShareBps);

        // Fee breakdown (lpFee/tax/split) is intentionally NOT included here: it is emitted in the same tx
        // via LpFeesAccrued/CreatorTaxesAccrued, which mirror LivoSwapHook so the indexer aggregates pre- and
        // post-graduation fees through one code path.
        emit RealmTokenBuy(token, msg.sender, msg.value, tokensToReceive, ethFee);

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
        nonReentrant
        returns (uint256 receivedEth)
    {
        TokenState storage tokenState = tokenStates[token];

        require(tokenAmount > 0, InvalidAmount());
        require(block.timestamp <= deadline, DeadlineExceeded());
        require(tokenConfigs[token].exists(), InvalidToken());
        require(tokenState.notGraduated(), AlreadyGraduated());

        // pre-graduation fee policy is read from the token itself and capped by the launchpad
        (uint16 totalFeeBps, uint16 lpFeeBps, uint16 treasuryShareBps) = _readLaunchpadFees(token, false);

        // reverts with InsufficientEthReserves if seller would receive more than eth reserves allocated to the token
        // that scenario should never happen, it is an extra cautious measure
        (uint256 ethPulledFromReserves, uint256 ethFee, uint256 ethForSeller) =
            _quoteSellExactTokens(token, tokenAmount, totalFeeBps);

        require(ethForSeller >= minEthAmount, SlippageExceeded());
        // When minEthAmount==0, we assume that the seller accepts any kind of "reasonable" slippage
        // However, receiving eth in exchange for a non-zero amount of tokens would be unfair
        require(ethForSeller > 0, ReceivingZeroAmount());

        tokenState.ethCollected -= ethPulledFromReserves;
        tokenState.releasedSupply -= tokenAmount;

        // funds transfers
        // WARNING: fee-on-transfer / rebasing tokens are NOT supported and must never be launched here. The
        // launchpad pays ETH for the full `tokenAmount` but assumes it receives exactly that many tokens back.
        // A token that skims on transfer would silently leak launchpad inventory (eventually bricking buys and
        // graduation, where the launchpad's token balance no longer matches its ETH-side accounting).
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);

        // split the fee: LP fee between treasury (push) and creator (accrueFees); tax (the remainder) fully to creator
        uint256 lpFee = (ethPulledFromReserves * lpFeeBps) / BASIS_POINTS;
        // tax = ethFee - lpFee
        _settleFee(token, lpFee, ethFee - lpFee, treasuryShareBps);

        // Emitted after the fee events (LpFeesAccrued/CreatorTaxesAccrued in _settleFee) so the
        // pre-graduation event order matches buys and the post-graduation LivoSwapHook: fee events
        // first, trade event last. Fee breakdown is intentionally NOT included here (see buy).
        emit RealmTokenSell(token, msg.sender, tokenAmount, ethForSeller, ethFee);

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
    /// @return canGraduate True if this purchase would trigger graduation
    function quoteBuyTokensWithExactEth(address token, uint256 ethValue)
        external
        view
        returns (uint256 ethForPurchase, uint256 ethFee, uint256 tokensToReceive, bool canGraduate)
    {
        if (!tokenConfigs[token].exists()) revert InvalidToken();

        (uint16 totalFeeBps,,) = _readLaunchpadFees(token, true);
        // this reverts with NotEnoughSupply if attempting to purchase more than this contract's balance
        (ethForPurchase, ethFee, tokensToReceive, canGraduate) =
            _quoteBuyTokensWithExactEth(token, ethValue, totalFeeBps);
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

        (uint16 totalFeeBps,,) = _readLaunchpadFees(token, false);
        // reverts with InsufficientEthReserves if seller would receive more than eth reserves allocated to the token
        // that scenario should never happen, it is an extra cautious measure
        (ethPulledFromReserves, ethFee, ethForSeller) = _quoteSellExactTokens(token, tokenAmount, totalFeeBps);
    }

    /// @notice Quotes how much total ETH is needed to buy an exact amount of tokens
    /// @param token Address of the token to quote
    /// @param tokenAmount Amount of tokens to buy
    /// @return ethFee Fee amount in ETH
    /// @return ethForReserves ETH that goes into the reserves
    /// @return totalEthNeeded Total ETH to send (including fee)
    /// @return canGraduate True if this purchase would trigger graduation
    function quoteBuyExactTokens(address token, uint256 tokenAmount)
        external
        view
        returns (uint256 ethFee, uint256 ethForReserves, uint256 totalEthNeeded, bool canGraduate)
    {
        if (!tokenConfigs[token].exists()) revert InvalidToken();
        (uint16 totalFeeBps,,) = _readLaunchpadFees(token, true);
        (totalEthNeeded, ethFee, ethForReserves, canGraduate) = _quoteBuyExactTokens(token, tokenAmount, totalFeeBps);
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
        (uint16 totalFeeBps,,) = _readLaunchpadFees(token, false);
        (ethPulledFromReserves, ethFee, tokensRequired) = _quoteSellTokensForExactEth(token, ethAmount, totalFeeBps);
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
        IRealmToken(token).proposeNewOwner(newTokenOwner);
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

        address graduator = IRealmToken(tokenAddress).graduator();

        // Transfer ALL tokens to graduator
        token.safeTransfer(graduator, tokenBalance);

        // Graduator handles: burning, fees, compensation, liquidity
        // IMPORTANT: for v2 taxable tokens, transfer should happen before marking the token as graduated, so that the graduator is not taxed at graduation
        IRealmGraduator(graduator).graduateToken{value: ethCollected}(tokenAddress, tokenBalance);

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

    /// @notice Routes a trading fee for accounting parity with the post-graduation `LivoSwapHook`:
    ///         the LP fee is split between treasury (pushed) and creator, while the tax goes entirely
    ///         to the creator. Emits `LpFeesAccrued` (and `CreatorTaxesAccrued` when the tax is non-zero).
    /// @dev Must be called after all state changes (CEI). Trade entry points are also nonReentrant,
    ///      which is what makes the `accrueFees` hop to a creator-controlled receiver safe.
    function _settleFee(address token, uint256 lpFee, uint256 tax, uint16 treasuryShareBps) internal {
        if (lpFee == 0 && tax == 0) return;
        uint256 treasuryShare = (lpFee * treasuryShareBps) / BASIS_POINTS;
        uint256 creatorShare = lpFee - treasuryShare;
        uint256 creatorTotal = creatorShare + tax;

        emit LpFeesAccrued(token, creatorShare, treasuryShare);
        if (tax > 0) emit CreatorTaxesAccrued(token, tax);

        _transferEth(treasury, treasuryShare, true);
        if (creatorTotal > 0) IRealmToken(token).accrueFees{value: creatorTotal}();
    }

    //////////////////////// INTERNAL VIEW FUNCTIONS //////////////////////////

    /// @notice Reads the token's pre-graduation fee policy for a trade and enforces the launchpad caps.
    /// @dev The fee rates and the treasury/creator split are owned by the token; the launchpad only
    ///      bounds them defensively: the total fee (LP fee + tax) must be `<= MAX_TRADING_FEE_BPS` and
    ///      `treasuryShareBps <= BASIS_POINTS`.
    /// @return totalFeeBps Sum of the LP fee and the tax — the amount deducted from the trade.
    /// @return lpFeeBps The LP-fee component, split treasury/creator by `treasuryShareBps`.
    /// @return treasuryShareBps Share of the LP fee routed to the treasury.
    function _readLaunchpadFees(address token, bool isBuy)
        internal
        view
        returns (uint16 totalFeeBps, uint16 lpFeeBps, uint16 treasuryShareBps)
    {
        IRealmToken.LaunchpadFees memory fees = IRealmToken(token)
            .getLaunchpadFees(
                IRealmToken.LaunchpadTrade({
                    isBuy: isBuy,
                    ethReserves: tokenStates[token].ethCollected,
                    releasedSupply: tokenStates[token].releasedSupply
                })
            );
        uint256 total = uint256(fees.lpFeeBps) + fees.taxBps;
        require(total <= MAX_TRADING_FEE_BPS, InvalidLaunchpadFee());
        require(fees.treasuryShareBps <= BASIS_POINTS, InvalidLaunchpadFee());
        return (uint16(total), fees.lpFeeBps, fees.treasuryShareBps);
    }

    /// @notice Returns the maximum ETH a user can spend on a token without exceeding graduation limits
    function _maxEthToSpend(address token) internal view returns (uint256 ethBuy) {
        (uint16 totalFeeBps,,) = _readLaunchpadFees(token, true);
        uint256 remainingReserves = tokenConfigs[token].bondingCurve.maxEthReserves() - tokenStates[token].ethCollected;

        // apply inverse fees
        ethBuy = (remainingReserves * BASIS_POINTS) / (BASIS_POINTS - totalFeeBps);
    }

    /// @notice Computes the buy quote: ETH split, fee, tokens received, and graduation eligibility
    function _quoteBuyTokensWithExactEth(address token, uint256 ethValue, uint16 buyFeeBps)
        internal
        view
        returns (uint256 ethForPurchase, uint256 ethFee, uint256 tokensToReceive, bool canGraduate)
    {
        // it is ok that these fees round in favor of the user (1 wei less fee on every purchase)
        ethFee = (ethValue * buyFeeBps) / BASIS_POINTS;
        ethForPurchase = ethValue - ethFee;

        (tokensToReceive, canGraduate) =
            tokenConfigs[token].bondingCurve.buyTokensWithExactEth(tokenStates[token].ethCollected, ethForPurchase);

        if (tokensToReceive > _availableTokens(token)) revert NotEnoughSupply();

        return (ethForPurchase, ethFee, tokensToReceive, canGraduate);
    }

    /// @notice Computes the sell quote: ETH pulled from reserves, fee, and ETH for the seller
    function _quoteSellExactTokens(address token, uint256 tokenAmount, uint16 sellFeeBps)
        internal
        view
        returns (uint256 ethPulledFromReserves, uint256 ethFee, uint256 ethForSeller)
    {
        ethPulledFromReserves =
            tokenConfigs[token].bondingCurve.sellExactTokens(tokenStates[token].ethCollected, tokenAmount);

        // it is ok that these fees round in favor of the user (1 wei less fee on every sale)
        ethFee = (ethPulledFromReserves * sellFeeBps) / BASIS_POINTS;
        ethForSeller = ethPulledFromReserves - ethFee;

        if (ethPulledFromReserves > _availableEthFromReserves(token)) revert InsufficientEthReserves();

        return (ethPulledFromReserves, ethFee, ethForSeller);
    }

    /// @notice Computes the inverse buy quote: total ETH needed to buy exact tokens
    function _quoteBuyExactTokens(address token, uint256 tokenAmount, uint16 buyFeeBps)
        internal
        view
        returns (uint256 totalEthNeeded, uint256 ethFee, uint256 ethForReserves, bool canGraduate)
    {
        (ethForReserves, canGraduate) =
            tokenConfigs[token].bondingCurve.buyExactTokens(tokenStates[token].ethCollected, tokenAmount);

        // Inverse fee: ethForReserves = totalEthNeeded * (BASIS_POINTS - buyFeeBps) / BASIS_POINTS
        // So totalEthNeeded = ceil(ethForReserves * BASIS_POINTS / (BASIS_POINTS - buyFeeBps))
        uint256 denom = BASIS_POINTS - buyFeeBps;
        totalEthNeeded = (ethForReserves * BASIS_POINTS + denom - 1) / denom;
        ethFee = totalEthNeeded - ethForReserves;

        if (tokenAmount > _availableTokens(token)) revert NotEnoughSupply();
    }

    /// @notice Computes the inverse sell quote: tokens needed to receive exact ETH
    function _quoteSellTokensForExactEth(address token, uint256 ethAmount, uint16 sellFeeBps)
        internal
        view
        returns (uint256 ethPulledFromReserves, uint256 ethFee, uint256 tokensRequired)
    {
        // ethAmount = ethPulledFromReserves * (BASIS_POINTS - sellFeeBps) / BASIS_POINTS
        // So ethPulledFromReserves = ceil(ethAmount * BASIS_POINTS / (BASIS_POINTS - sellFeeBps))
        uint256 denom = BASIS_POINTS - sellFeeBps;
        ethPulledFromReserves = (ethAmount * BASIS_POINTS + denom - 1) / denom;
        ethFee = ethPulledFromReserves - ethAmount;

        tokensRequired = tokenConfigs[token].bondingCurve
            .sellTokensForExactEth(tokenStates[token].ethCollected, ethPulledFromReserves);

        if (ethPulledFromReserves > _availableEthFromReserves(token)) revert InsufficientEthReserves();
    }

    /// @dev The supply of a token that can be purchased
    function _availableTokens(address token) internal view returns (uint256) {
        return IRealmToken(token).balanceOf(address(this));
    }

    /// @notice Returns the ETH reserves currently allocated to a token
    function _availableEthFromReserves(address token) internal view returns (uint256) {
        return tokenStates[token].ethCollected;
    }

    function _onlyWhitelistedFactory() internal view {
        require(whitelistedFactories[msg.sender], UnauthorizedFactory());
    }
}
