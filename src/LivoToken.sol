// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract LivoToken is ERC20 {
    /// @notice LivoLaunchpad factory address
    address public factory;

    /// review if we need this
    address public creator;

    /// @notice Addresses exempt from fees (only affecting post-graduation trades)
    mapping(address => bool) public feeExempt;

    /// @dev only to prevent re-initialization
    bool internal _initialized;
    /// @notice Token name and symbol
    string private _tokenName;
    /// @notice Token symbol
    string private _tokenSymbol;

    /// @notice Emitted when a fee exemption is set
    event FeeExemptSet(address indexed account, bool exempt);

    constructor() ERC20("", "") {}

    function initialize(
        string memory _name,
        string memory _symbol,
        address _creator,
        address _factory,
        uint256 _totalSupply
    ) external {
        require(!_initialized, "LivoToken: Already initialized");
        _initialized = true;

        // all supply goes to the factory, where it can be traded according to the bonding curve
        _setFeeExempt(_factory, true);

        // 1% of total supply to the creator
        uint256 creatorSupply = _totalSupply / 100;
        _mint(_creator, creatorSupply);
        _mint(_factory, _totalSupply - creatorSupply);

        _tokenName = _name;
        _tokenSymbol = _symbol;
        creator = _creator;
        factory = _factory;
    }

    /// @dev ERC20 interface compliance
    function name() public view override returns (string memory) {
        return _tokenName;
    }

    /// @dev ERC20 interface compliance
    function symbol() public view override returns (string memory) {
        return _tokenSymbol;
    }

    //////////////////////// internal functions ////////////////////////

    function _setFeeExempt(address account, bool exempt) internal {
        feeExempt[account] = exempt;
        emit FeeExemptSet(account, exempt);
    }

    // todo update buy/sell fees logic (burned?)
}
