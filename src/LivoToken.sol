// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract LivoToken is ERC20 {
    uint256 public constant BASIS_POINTS = 10_000;

    /// @notice LivoLaunchpad address
    address public launchpad;

    /// @notice The only graduator allowed to graduate this token
    address public graduator;

    /// @notice Wether the token has graduated already or not
    bool public graduated;

    /// @notice Uniswap pair. Token transfers to this address are blocked before graduation
    address public pair;

    /// @dev only to prevent re-initialization
    bool internal _initialized;
    /// @notice Token name and symbol
    string private _tokenName;
    /// @notice Token symbol
    string private _tokenSymbol;

    //////////////////////// Events //////////////////////

    /// @notice Emitted when a fee exemption is set
    event FeeExemptSet(address indexed account, bool exempt);
    event Graduated();

    //////////////////////// Errors //////////////////////

    error OnlyGraduatorAllowed();
    error AlreadyInitialized();
    error TranferToPairBeforeGraduationNotAllowed();
    error CannotSelfTransfer();

    constructor() ERC20("", "") {}

    function initialize(
        string memory name_,
        string memory symbol_,
        address launchpad_,
        address graduator_,
        address pair_,
        uint256 totalSupply_
    ) external {
        require(!_initialized, AlreadyInitialized());
        _initialized = true;

        _tokenName = name_;
        _tokenSymbol = symbol_;
        launchpad = launchpad_;
        graduator = graduator_;
        pair = pair_;

        // all is minted back to the launchpad
        _mint(launchpad_, totalSupply_);
    }

    //////////////////////// restricted access functions ////////////////////////

    function markGraduated() external {
        require(msg.sender == graduator, OnlyGraduatorAllowed());

        graduated = true;
        emit Graduated();
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

    function _update(address from, address to, uint256 amount) internal override {
        require(from != to, CannotSelfTransfer());

        // cache to save gas
        address pair_ = pair;

        // this ensures tokens don't arrive to the pair before graduation
        // to avoid exploits/DOS related to liquidity addition at graduation
        if ((!graduated) && (to == pair_)) {
            revert TranferToPairBeforeGraduationNotAllowed();
        }

        super._update(from, to, amount);
    }
}
