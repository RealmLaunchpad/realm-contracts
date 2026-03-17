// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "lib/openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {ILivoGraduator} from "src/interfaces/ILivoGraduator.sol";
import {ILivoFeeHandler} from "src/interfaces/ILivoFeeHandler.sol";
import {ILivoFeeSplitter} from "src/interfaces/ILivoFeeSplitter.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";

contract LivoToken is ERC20, ILivoToken, Initializable {
    /// @notice all Livo tokens have same supply
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    /// @notice Owner of the token. The creator unless communityTakeOver takes place
    address public owner;

    /// @notice Address who can accept ownership of the token
    /// @dev It can be address(0) if no owner is proposed
    address public proposedOwner;

    /// @notice The only graduator allowed to graduate this token
    address public graduator;

    /// @notice Whether the token has graduated already or not
    bool public graduated;

    /// @notice Uniswap pair. Token transfers to this address are blocked before graduation
    address public pair;

    /// @notice Launchpad address
    LivoLaunchpad public launchpad;

    /// @notice Contract handling fees for this token
    address public feeHandler;

    /// @notice Address that receives fees within the fee handler
    address public feeReceiver;

    /// @notice Token name
    string internal _tokenName;

    /// @notice Token symbol
    string internal _tokenSymbol;

    //////////////////////// Errors //////////////////////

    error OnlyGraduatorAllowed();
    error TransferToPairBeforeGraduationNotAllowed();
    error CannotSelfTransfer();
    error InvalidGraduator();
    error Unauthorized();
    error InvalidFeeReceiver();

    //////////////////////////////////////////////////////

    /// @notice Creates a new LivoToken instance which will be used as implementation for clones
    /// @dev Token name and symbol are set during initialization, not in constructor
    constructor() ERC20("", "") {
        _disableInitializers();
    }

    /// @notice Initializes the token clone with its parameters
    /// @param params Shared token initialization parameters
    function initialize(ILivoToken.InitializeParams memory params) external virtual initializer {
        require(params.graduator != address(0), InvalidGraduator());

        _tokenName = params.name;
        _tokenSymbol = params.symbol;
        graduator = params.graduator;
        owner = params.tokenOwner;
        pair = ILivoGraduator(params.graduator).initialize(address(this));
        feeHandler = params.feeHandler;
        feeReceiver = params.feeReceiver;

        // all is minted back to the launchpad
        // question should the launchpad check it owns the full supply? or should we leave that open?
        _mint(params.launchpad, TOTAL_SUPPLY);

        launchpad = LivoLaunchpad(params.launchpad);
    }

    //////////////////////// restricted access functions ////////////////////////

    /// @notice Marks the token as graduated, which unlocks transfers to the pair
    /// @dev Can only be called by the pre-set graduator contract
    function markGraduated() external virtual {
        require(msg.sender == graduator, OnlyGraduatorAllowed());

        graduated = true;
        emit Graduated();
    }

    /// @notice Proposes a new owner for a token. Only callable by the current tokenOwner.
    ///         Pass address(0) as newOwner to cancel a pending proposal.
    /// @dev Also callable by the launchpad for communityTakeOvers. Effectively called by admins.
    function proposeNewOwner(address newOwner) external {
        address _owner = owner;
        require(msg.sender == _owner || msg.sender == address(launchpad), Unauthorized());

        proposedOwner = newOwner;

        emit NewOwnerProposed(_owner, newOwner, msg.sender);
    }

    /// @notice Accepts token ownership. Only callable by the address proposed as new owner.
    function acceptTokenOwnership() external {
        require(msg.sender == proposedOwner, Unauthorized());

        owner = msg.sender;
        delete proposedOwner;

        emit OwnershipTransferred(msg.sender);
    }

    /// @notice Updates the fee receiver address, only callable by the token owner
    function setFeeReceiver(address newFeeReceiver) external {
        require(msg.sender == owner, Unauthorized());
        require(newFeeReceiver != address(0), InvalidFeeReceiver());

        feeReceiver = newFeeReceiver;

        emit FeeReceiverUpdated(newFeeReceiver);
    }

    //////////////////////// fee accrual ////////////////////////

    /// @notice Routes ETH fees to the fee handler for the token's fee receiver
    function accrueFees() external payable {
        ILivoFeeHandler(feeHandler).depositFees{value: msg.value}(address(this), feeReceiver);
    }

    //////////////////////// view functions ////////////////////////

    /// @notice Returns the underlying fee receiver addresses and their share in basis points
    function getFeeReceivers() external view returns (address[] memory, uint256[] memory) {
        address feeReceiver_ = feeReceiver;
        if (feeReceiver_.code.length > 0) {
            try ILivoFeeSplitter(feeReceiver_).getRecipients() returns (
                address[] memory recipients, uint256[] memory sharesBps
            ) {
                return (recipients, sharesBps);
            } catch {}
        }
        // fallback to direct fee receiver with 100% share if the fee receiver is not a fee splitter
        address[] memory result = new address[](1);
        result[0] = feeReceiver_;
        uint256[] memory shares = new uint256[](1);
        shares[0] = 10_000;
        return (result, shares);
    }

    /// @notice Default tax config returning no taxes. Overridden by taxable token implementations.
    function getTaxConfig() external view virtual returns (ILivoToken.TaxConfig memory config) {}

    /// @dev ERC20 interface compliance
    function name() public view override returns (string memory) {
        return _tokenName;
    }

    /// @dev ERC20 interface compliance
    function symbol() public view override returns (string memory) {
        return _tokenSymbol;
    }

    /// @dev Launchpad is pre-approved
    function allowance(address owner_, address spender) public view override(ERC20, IERC20) returns (uint256) {
        if (spender == address(launchpad)) return type(uint256).max;
        return super.allowance(owner_, spender);
    }

    //////////////////////// internal functions ////////////////////////

    function _update(address from, address to, uint256 amount) internal virtual override {
        // this ensures tokens don't arrive to the pair before graduation
        // to avoid exploits/DOS related to liquidity addition at graduation
        if ((!graduated) && (to == pair)) {
            revert TransferToPairBeforeGraduationNotAllowed();
        }

        super._update(from, to, amount);
    }

    function _spendAllowance(address owner_, address spender, uint256 value) internal override {
        // skips allowance logic if the spender is the launchpad to pre-approve launchpad forever
        if (spender == address(launchpad)) return;

        super._spendAllowance(owner_, spender, value);
    }
}
