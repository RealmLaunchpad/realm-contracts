// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "lib/openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {ILivoFeeSplitter} from "src/interfaces/ILivoFeeSplitter.sol";
import {ILivoFeeHandler} from "src/interfaces/ILivoFeeHandler.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";

/// @notice Splits ETH fees received from a `LivoFeeHandler` among multiple recipients according to configurable BPS shares.
/// @dev Uses a cumulative `ethPerBps` accumulator pattern to track each recipient's claimable amount without iterating over all recipients on every deposit.
contract LivoFeeSplitter is ILivoFeeSplitter, Initializable, ReentrancyGuard {
    uint256 internal constant BPS_TOTAL = 10_000;
    uint256 internal constant PRECISION = 1e18;

    address internal univ4FeeHandler;
    address public token;
    address[] public recipients;
    uint256[] public sharesBps;

    /// @notice Cumulative ETH earned per basis point of share, scaled by `PRECISION`.
    uint256 public ethPerBps;

    /// @notice BPS share assigned to each recipient.
    mapping(address => uint256) public sharesBpsOf;

    /// @notice Snapshot of `ethPerBps` at the time of the recipient's last claim or share update.
    mapping(address => uint256) public claimedPerBps;

    /// @notice Residual claimable ETH carried over after a share update for a recipient.
    mapping(address => uint256) public pendingClaims;

    /// @dev Tracks ETH already accounted for in `ethPerBps` so new deposits can be detected via `address(this).balance - totalAccounted`.
    uint256 internal totalAccounted;

    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the splitter with a UniV4 fee handler, token, and initial share configuration.
    /// @param univ4FeeHandler_ Address of the UniV4 `LivoFeeHandler` this splitter claims from.
    /// @param token_ Address of the `LivoToken` whose fees are being split.
    /// @param recipients_ Initial fee recipients.
    /// @param sharesBps_ BPS shares for each recipient (must sum to 10 000).
    function initialize(
        address univ4FeeHandler_,
        address token_,
        address[] calldata recipients_,
        uint256[] calldata sharesBps_
    ) external initializer {
        univ4FeeHandler = univ4FeeHandler_;
        token = token_;
        _setShares(recipients_, sharesBps_);
    }

    /// @notice Updates the recipient list and their shares. Only callable by the token owner.
    /// @dev Snapshots each current recipient's claimable balance into `pendingClaims` before overwriting shares.
    /// @param recipients_ New fee recipients.
    /// @param sharesBps_ New BPS shares (must sum to 10 000).
    function setShares(address[] calldata recipients_, uint256[] calldata sharesBps_) external {
        require(msg.sender == ILivoToken(token).owner(), Unauthorized());

        // claims from the underlying and accrues balance
        _claimFromSource();

        uint256 len = recipients.length;
        for (uint256 i = 0; i < len; i++) {
            address r = recipients[i];
            pendingClaims[r] = _getClaimableFromAccrued(r);
            claimedPerBps[r] = ethPerBps;
        }

        _setShares(recipients_, sharesBps_);
    }

    /// @notice Returns the address that should own LP position NFTs (delegates to upstream handler)
    function liquidityPositionOwner() external view returns (address) {
        return ILivoFeeHandler(univ4FeeHandler).liquidityPositionOwner();
    }

    /// @notice Accepts ETH fees and accrues them for shareholders.
    function depositFees(address, address) external payable {
        _accrueBalance();
    }

    /// @notice Claims all accrued ETH fees for `msg.sender` and transfers them.
    /// @dev The tokens parameter is ignored; the splitter knows its single token.
    function claim(address[] calldata) external nonReentrant {
        // claim from the source first to have an updated balance state
        _claimFromSource();

        // claimable is now updated with the latest accrued balance
        uint256 claimable = _getClaimableFromAccrued(msg.sender);
        if (claimable == 0) return;

        claimedPerBps[msg.sender] = ethPerBps;
        // this slot is already warm, so not worth optimizing to only clear if non zero
        pendingClaims[msg.sender] = 0;

        totalAccounted -= claimable;

        (bool success,) = msg.sender.call{value: claimable}("");
        require(success);

        emit FeesClaimed(msg.sender, claimable);
    }

    /// @notice Accepts ETH deposits (e.g. from the fee handler).
    receive() external payable {}

    /// @notice Returns the claimable ETH for `account` across the given tokens.
    /// @dev Only returns non-zero for entries matching this splitter's token.
    /// @param tokens The token addresses to query.
    /// @param account The address to query.
    /// @return amounts Array of claimable amounts per token.
    function getClaimable(address[] calldata tokens, address account) external view returns (uint256[] memory amounts) {
        uint256 len = tokens.length;
        amounts = new uint256[](len);

        uint256 claimableForToken = _getFullClaimable(account);

        for (uint256 i = 0; i < len; i++) {
            if (tokens[i] == token) {
                amounts[i] = claimableForToken;
            }
        }
    }

    /// @dev Returns the total claimable ETH for `account`, including any unaccrued ETH in the contract and upstream pending fees.
    function _getFullClaimable(address account) internal view returns (uint256) {
        uint256 fromAccrued = _getClaimableFromAccrued(account);

        uint256 unaccounted = address(this).balance - totalAccounted;
        uint256[] memory upstream = ILivoFeeHandler(univ4FeeHandler).getClaimable(_tokens(), address(this));

        // from Accrued is already given by shareholder, but the others need to be split still
        return fromAccrued + ((unaccounted + upstream[0]) * sharesBpsOf[account]) / BPS_TOTAL;
    }

    /// @notice Returns all current recipients and their BPS shares.
    function getRecipients() external view returns (address[] memory, uint256[] memory) {
        return (recipients, sharesBps);
    }

    /// @dev Returns the claimable ETH for `account` based on already-accrued balances only (excludes pending in fee handler).
    function _getClaimableFromAccrued(address account) internal view returns (uint256) {
        return ((ethPerBps - claimedPerBps[account]) * sharesBpsOf[account]) / PRECISION + pendingClaims[account];
    }

    /// @dev Overwrites the recipient list and shares. Clears old mappings, validates inputs, and sets new state.
    function _setShares(address[] calldata recipients_, uint256[] calldata sharesBps_) internal {
        uint256 oldLen = recipients.length;
        for (uint256 i = 0; i < oldLen; i++) {
            delete sharesBpsOf[recipients[i]];
        }

        uint256 len = recipients_.length;
        require(len > 0 && len == sharesBps_.length, InvalidRecipients());

        // duplicate address would break accounting and eth would be unrecoverable from this splitter contract
        // this check costs only 500-700 gas, which is quite an affordable one-time payment against losing funds
        _requireNoDuplicates(recipients_);

        uint256 total;
        for (uint256 i = 0; i < len; i++) {
            require(recipients_[i] != address(0), InvalidRecipients());
            require(sharesBps_[i] > 0, InvalidShares());
            total += sharesBps_[i];
        }
        require(total == BPS_TOTAL, InvalidShares());

        recipients = recipients_;
        sharesBps = sharesBps_;

        for (uint256 i = 0; i < len; i++) {
            sharesBpsOf[recipients_[i]] = sharesBps_[i];
            claimedPerBps[recipients_[i]] = ethPerBps;
        }

        emit SharesUpdated(recipients_, sharesBps_);
    }

    /// @dev Claims pending fees from the underlying fee handler, then accrues the new ETH.
    function _claimFromSource() internal {
        ILivoFeeHandler(univ4FeeHandler).claim(_tokens());
        _accrueBalance();
    }

    /// @dev Returns a single-element array containing this splitter's token address.
    function _tokens() internal view returns (address[] memory tokens) {
        tokens = new address[](1);
        tokens[0] = token;
    }

    /// @dev Accounts for any new ETH that has arrived since the last accrual by updating `ethPerBps`.
    function _accrueBalance() internal {
        uint256 newEth = address(this).balance - totalAccounted;
        if (newEth == 0) return;

        totalAccounted += newEth;
        // negligible precision loss
        ethPerBps += (newEth * PRECISION) / BPS_TOTAL;

        emit FeesAccrued(newEth);
    }

    function _requireNoDuplicates(address[] calldata addresses) internal pure {
        uint256 len = addresses.length;
        for (uint256 i = 0; i < len; i++) {
            for (uint256 j = i + 1; j < len; j++) {
                require(addresses[i] != addresses[j], InvalidRecipients());
            }
        }
    }
}
