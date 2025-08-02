// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract LivoToken is ERC20, Ownable {
    address public creator;
    address public factory;
    
    bool public antiBotEnabled;
    uint256 public buyFeeBps;
    uint256 public sellFeeBps;
    bool private initialized;
    
    string private _tokenName;
    string private _tokenSymbol;
    
    mapping(address => bool) public feeExempt;
    
    modifier onlyFactory() {
        require(msg.sender == factory, "LivoToken: Only factory can call");
        _;
    }
    
    constructor() ERC20("", "") Ownable(msg.sender) {}
    
    function initialize(
        string memory _name,
        string memory _symbol,
        address _creator,
        address _factory,
        uint256 _totalSupply
    ) external {
        require(!initialized, "LivoToken: Already initialized");
        initialized = true;
        
        _tokenName = _name;
        _tokenSymbol = _symbol;
        creator = _creator;
        factory = _factory;
        _transferOwnership(_factory);
        
        _mint(_factory, _totalSupply);
        
        feeExempt[_factory] = true;
        feeExempt[_creator] = true;
    }
    
    function name() public view override returns (string memory) {
        return _tokenName;
    }
    
    function symbol() public view override returns (string memory) {
        return _tokenSymbol;
    }
    
    function setAntiBotProtection(bool enabled) external onlyFactory {
        antiBotEnabled = enabled;
    }
    
    function setBuyFee(uint256 basisPoints) external onlyFactory {
        require(basisPoints <= 10000, "LivoToken: Fee too high");
        buyFeeBps = basisPoints;
    }
    
    function setSellFee(uint256 basisPoints) external onlyFactory {
        require(basisPoints <= 10000, "LivoToken: Fee too high");
        sellFeeBps = basisPoints;
    }
    
    function setFeeExempt(address account, bool exempt) external onlyFactory {
        feeExempt[account] = exempt;
    }
    
    function _update(address from, address to, uint256 value) internal override {
        if (antiBotEnabled && from != address(0) && to != address(0)) {
            require(!_isContract(to) || feeExempt[to], "LivoToken: Contract interactions blocked");
        }
        
        super._update(from, to, value);
    }
    
    function _isContract(address account) internal view returns (bool) {
        return account.code.length > 0;
    }
}