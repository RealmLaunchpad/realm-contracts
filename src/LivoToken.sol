// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract LivoToken is ERC20 {
    uint256 public constant BASIS_POINTS = 10_000;

    /// @notice LivoLaunchpad address
    address public launchpad;

    /// review if we need this
    address public creator;

    /// @notice The only graduator allowed to graduate this token
    address public graduator;

    /// @notice Addresses exempt from fees (only affecting post-graduation trades)
    mapping(address => bool) public feeExempt;

    /// @notice Sets which pools/pairs are considered for trading fees
    mapping(address => bool) public automatedMarketMakerPairs;

    /// @dev only to prevent re-initialization
    bool internal _initialized;
    /// @notice Token name and symbol
    string private _tokenName;
    /// @notice Token symbol
    string private _tokenSymbol;

    /// @notice buy/sell fees in basis points (100 bps = 1%)
    uint16 public buyFeeBps;
    uint16 public sellFeeBps;

    //////////////////////// Events //////////////////////

    /// @notice Emitted when a fee exemption is set
    event FeeExemptSet(address indexed account, bool exempt);
    event MarketMakerPairAdded(address indexed pair);

    //////////////////////// Errors //////////////////////

    error OnlyGraduatorAllowed();
    error AlreadyInitialized();

    constructor() ERC20("", "") {}

    function initialize(
        string memory _name,
        string memory _symbol,
        address _creator,
        address _launchpad,
        address _graduator,
        uint256 _totalSupply,
        uint256 _buyFeeBps,
        uint256 _sellFeeBps
    ) external {
        require(!_initialized, AlreadyInitialized());
        _initialized = true;

        _tokenName = _name;
        _tokenSymbol = _symbol;
        creator = _creator;
        launchpad = _launchpad;
        graduator = _graduator;
        buyFeeBps = uint16(_buyFeeBps);
        sellFeeBps = uint16(_sellFeeBps);

        // all supply goes to the launchpad, where it can be traded according to the bonding curve
        _setFeeExempt(_launchpad, true);
        _setFeeExempt(_graduator, true);

        // all is minted back to the launchpad
        _mint(_launchpad, _totalSupply);
    }

    //////////////////////// restricted access functions ////////////////////////

    function setAutomatedMarketMakerPair(address pair) external {
        require(msg.sender == graduator, OnlyGraduatorAllowed());

        automatedMarketMakerPairs[pair] = true;
        emit MarketMakerPairAdded(pair);
    }

    //////////////////////// view functions ////////////////////////

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

    function _update(address from, address to, uint256 amount) internal override {
        require(from != to, "Can NOT send to same address");

        if (feeExempt[from] || feeExempt[to]) {
            // if the sender or receiver is fee exempt, transfer without fees
            super._update(from, to, amount);
            return;
        }

        uint256 fee = 0;
        if (automatedMarketMakerPairs[to]) {
            fee = (amount * sellFeeBps) / BASIS_POINTS;
        } else if (automatedMarketMakerPairs[from]) {
            fee = (amount * buyFeeBps) / BASIS_POINTS;
        }

        // burn the fees
        if (fee > 0) {
            _update(from, address(0xdead), fee);
        }

        // amountAfterFee = amount if fee is 0
        uint256 amountAfterFee = amount - fee;

        super._update(from, to, amountAfterFee);
    }
}
