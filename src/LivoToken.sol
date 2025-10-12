// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract LivoToken is ERC20 {
    /// @notice The only graduator allowed to graduate this token
    address public graduator;

    /// @notice Whether the token has graduated already or not
    bool public graduated;

    /// @notice Uniswap pair. Token transfers to this address are blocked before graduation
    address public pair;

    /// @notice Token name
    string private _tokenName;

    /// @notice Token symbol
    string private _tokenSymbol;

    //////////////////////// Events //////////////////////

    event FeeExemptSet(address indexed account, bool exempt);
    event Graduated();

    //////////////////////// Errors //////////////////////

    error OnlyGraduatorAllowed();
    error AlreadyInitialized();
    error TranferToPairBeforeGraduationNotAllowed();
    error CannotSelfTransfer();
    error InvalidGraduator();

    //////////////////////////////////////////////////////

    /// @notice Creates a new LivoToken instance which will be used as implementation for clones
    /// @dev Token name and symbol are set during initialization, not in constructor
    constructor() ERC20("", "") {}

    /// @notice Initializes the token clone with its parameters
    /// @param name_ The token name
    /// @param symbol_ The token symbol
    /// @param graduator_ Address of the graduator contract
    /// @param pair_ Address of the Uniswap pair
    /// @param supplyReceiver_ Address receiving the total supply of tokens
    /// @param totalSupply_ Total supply to mint
    function initialize(
        string memory name_,
        string memory symbol_,
        address graduator_,
        address pair_,
        address supplyReceiver_,
        uint256 totalSupply_
    ) external {
        require(graduator_ != address(0), InvalidGraduator());
        require(graduator == address(0), AlreadyInitialized());

        _tokenName = name_;
        _tokenSymbol = symbol_;
        graduator = graduator_;
        pair = pair_;

        // all is minted back to the launchpad
        _mint(supplyReceiver_, totalSupply_);
    }

    //////////////////////// restricted access functions ////////////////////////

    /// @notice Marks the token as graduated, which unlocks transfers to the pair
    /// @dev Can only be called by the pre-set graduator contract
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

        // this ensures tokens don't arrive to the pair before graduation
        // to avoid exploits/DOS related to liquidity addition at graduation
        if ((!graduated) && (to == pair)) {
            revert TranferToPairBeforeGraduationNotAllowed();
        }

        super._update(from, to, amount);
    }
}
