// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./LivoToken.sol";
import "./interfaces/ILivoBondingCurve.sol";
import "./interfaces/ILivoGraduationManager.sol";

contract LivoLaunchpad is Ownable, ReentrancyGuard {
    struct TokenData {
        address bondingCurve;
        address creator;
        uint256 bondingCurveSupply;
        uint256 ethCollected;
        uint96 tradingFeeBps;
        uint96 creatorFeeBps;
        bool graduated;
    }
    
    address public immutable tokenImplementation;
    
    uint256 public graduationThreshold = 20 ether;
    uint96 public tradingFeeBps = 100; // 1%
    uint256 public graduationFee = 0.1 ether;
    uint96 public creatorFeeBps = 5000; // 50%
    address public treasury;
    ILivoGraduationManager public graduationManager;
    
    mapping(address => TokenData) public tokens;
    mapping(address => bool) public whitelistedBondingCurves;
    mapping(address => bool) public whitelistedGraduationManagers;
    
    uint256 private constant TOTAL_SUPPLY = 1_000_000_000 * 10**18; // 1B tokens
    uint256 private constant BONDING_CURVE_SUPPLY = 800_000_000 * 10**18; // 800M tokens for bonding curve
    
    event TokenCreated(
        address indexed token,
        address indexed creator,
        string name,
        string symbol,
        address bondingCurve,
        string metadata
    );
    
    event TokenPurchased(
        address indexed token,
        address indexed buyer,
        uint256 ethAmount,
        uint256 tokenAmount,
        uint256 fee
    );
    
    event TokenSold(
        address indexed token,
        address indexed seller,
        uint256 tokenAmount,
        uint256 ethAmount,
        uint256 fee
    );
    
    event TokenGraduated(
        address indexed token,
        uint256 ethCollected,
        uint256 tokensRemaining
    );
    
    constructor(address _treasury) Ownable(msg.sender) {
        treasury = _treasury;
        tokenImplementation = address(new LivoToken());
    }
    
    function createToken(
        string calldata name,
        string calldata symbol,
        string calldata metadata,
        address bondingCurve
    ) external payable nonReentrant returns (address) {
        require(whitelistedBondingCurves[bondingCurve], "LivoLaunchpad: Invalid bonding curve");
        require(bytes(name).length > 0 && bytes(symbol).length > 0, "LivoLaunchpad: Invalid name or symbol");
        
        address tokenClone = Clones.clone(tokenImplementation);
        
        LivoToken(tokenClone).initialize(name, symbol, msg.sender, address(this), TOTAL_SUPPLY);
        
        tokens[tokenClone] = TokenData({
            bondingCurve: bondingCurve,
            creator: msg.sender,
            bondingCurveSupply: BONDING_CURVE_SUPPLY,
            ethCollected: 0,
            tradingFeeBps: tradingFeeBps,
            creatorFeeBps: creatorFeeBps,
            graduated: false
        });
        
        emit TokenCreated(tokenClone, msg.sender, name, symbol, bondingCurve, metadata);
        
        return tokenClone;
    }
    
    function buyToken(address token) external payable nonReentrant {
        require(msg.value > 0, "LivoLaunchpad: ETH amount must be greater than 0");
        TokenData storage tokenData = tokens[token];
        require(tokenData.creator != address(0), "LivoLaunchpad: Token not found");
        require(!tokenData.graduated, "LivoLaunchpad: Token already graduated");
        
        uint256 fee = (msg.value * tokenData.tradingFeeBps) / 10000;
        uint256 ethForTokens = msg.value - fee;
        
        uint256 tokensToReceive = ILivoBondingCurve(tokenData.bondingCurve).getTokensForEth(
            ethForTokens,
            BONDING_CURVE_SUPPLY - tokenData.bondingCurveSupply,
            tokenData.ethCollected
        );
        
        require(tokensToReceive <= tokenData.bondingCurveSupply, "LivoLaunchpad: Insufficient token supply");
        
        tokenData.bondingCurveSupply -= tokensToReceive;
        tokenData.ethCollected += ethForTokens;
        
        LivoToken(token).transfer(msg.sender, tokensToReceive);
        
        uint256 creatorFee = (fee * tokenData.creatorFeeBps) / 10000;
        uint256 treasuryFee = fee - creatorFee;
        
        if (creatorFee > 0) {
            payable(tokenData.creator).transfer(creatorFee);
        }
        if (treasuryFee > 0) {
            payable(treasury).transfer(treasuryFee);
        }
        
        emit TokenPurchased(token, msg.sender, msg.value, tokensToReceive, fee);
    }
    
    function sellToken(address token, uint256 tokenAmount) external nonReentrant {
        require(tokenAmount > 0, "LivoLaunchpad: Token amount must be greater than 0");
        TokenData storage tokenData = tokens[token];
        require(tokenData.creator != address(0), "LivoLaunchpad: Token not found");
        require(!tokenData.graduated, "LivoLaunchpad: Token already graduated");
        
        LivoToken(token).transferFrom(msg.sender, address(this), tokenAmount);
        
        uint256 ethToReceive = ILivoBondingCurve(tokenData.bondingCurve).getEthForTokens(
            tokenAmount,
            BONDING_CURVE_SUPPLY - tokenData.bondingCurveSupply,
            tokenData.ethCollected
        );
        
        require(ethToReceive <= tokenData.ethCollected, "LivoLaunchpad: Insufficient ETH reserves");
        
        uint256 fee = (ethToReceive * tokenData.tradingFeeBps) / 10000;
        uint256 ethAfterFee = ethToReceive - fee;
        
        tokenData.bondingCurveSupply += tokenAmount;
        tokenData.ethCollected -= ethToReceive;
        
        payable(msg.sender).transfer(ethAfterFee);
        
        uint256 creatorFee = (fee * tokenData.creatorFeeBps) / 10000;
        uint256 treasuryFee = fee - creatorFee;
        
        if (creatorFee > 0) {
            payable(tokenData.creator).transfer(creatorFee);
        }
        if (treasuryFee > 0) {
            payable(treasury).transfer(treasuryFee);
        }
        
        emit TokenSold(token, msg.sender, tokenAmount, ethAfterFee, fee);
    }
    
    function graduateToken(address token) external payable nonReentrant {
        require(msg.value >= graduationFee, "LivoLaunchpad: Insufficient graduation fee");
        require(checkGraduationEligibility(token), "LivoLaunchpad: Token not eligible for graduation");
        
        TokenData storage tokenData = tokens[token];
        require(!tokenData.graduated, "LivoLaunchpad: Token already graduated");
        
        tokenData.graduated = true;
        
        uint256 ethCollected = tokenData.ethCollected;
        uint256 tokensRemaining = tokenData.bondingCurveSupply;
        
        LivoToken(token).transfer(address(graduationManager), tokensRemaining);
        
        payable(treasury).transfer(graduationFee);
        if (msg.value > graduationFee) {
            payable(msg.sender).transfer(msg.value - graduationFee);
        }
        
        graduationManager.graduateToken{value: ethCollected}(token);
        
        emit TokenGraduated(token, ethCollected, tokensRemaining);
    }
    
    function checkGraduationEligibility(address token) public view returns (bool) {
        TokenData storage tokenData = tokens[token];
        return tokenData.ethCollected >= graduationThreshold && !tokenData.graduated;
    }
    
    function isGraduated(address token) external view returns (bool) {
        return tokens[token].graduated;
    }
    
    function getBuyPrice(address token, uint256 ethAmount) external view returns (uint256) {
        TokenData storage tokenData = tokens[token];
        require(tokenData.creator != address(0), "LivoLaunchpad: Token not found");
        
        uint256 fee = (ethAmount * tokenData.tradingFeeBps) / 10000;
        uint256 ethForTokens = ethAmount - fee;
        
        return ILivoBondingCurve(tokenData.bondingCurve).getTokensForEth(
            ethForTokens,
            BONDING_CURVE_SUPPLY - tokenData.bondingCurveSupply,
            tokenData.ethCollected
        );
    }
    
    function getSellPrice(address token, uint256 tokenAmount) external view returns (uint256) {
        TokenData storage tokenData = tokens[token];
        require(tokenData.creator != address(0), "LivoLaunchpad: Token not found");
        
        uint256 ethToReceive = ILivoBondingCurve(tokenData.bondingCurve).getEthForTokens(
            tokenAmount,
            BONDING_CURVE_SUPPLY - tokenData.bondingCurveSupply,
            tokenData.ethCollected
        );
        
        uint256 fee = (ethToReceive * tokenData.tradingFeeBps) / 10000;
        return ethToReceive - fee;
    }
    
    function getEthCollectedByToken(address token) external view returns (uint256) {
        return tokens[token].ethCollected;
    }
    
    // Owner functions
    function setGraduationThreshold(uint256 ethAmount) external onlyOwner {
        graduationThreshold = ethAmount;
    }
    
    function setFeeRecipient(address recipient) external onlyOwner {
        treasury = recipient;
    }
    
    function setCreatorFeeShare(uint256 basisPoints) external onlyOwner {
        require(basisPoints <= 10000, "LivoLaunchpad: Invalid basis points");
        creatorFeeBps = uint96(basisPoints);
    }
    
    function setGraduationManager(address manager) external onlyOwner {
        require(whitelistedGraduationManagers[manager], "LivoLaunchpad: Invalid graduation manager");
        graduationManager = ILivoGraduationManager(manager);
    }
    
    function whitelistBondingCurve(address bondingCurve, bool whitelisted) external onlyOwner {
        whitelistedBondingCurves[bondingCurve] = whitelisted;
    }
    
    function whitelistGraduationManager(address manager, bool whitelisted) external onlyOwner {
        whitelistedGraduationManagers[manager] = whitelisted;
    }
}