// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILivoFeeHandler} from "src/interfaces/ILivoFeeHandler.sol";
import {ILivoLaunchpad} from "src/interfaces/ILivoLaunchpad.sol";

contract LivoFeeBaseHandler is ILivoFeeHandler {
    mapping(address token => mapping(address account => uint256 amount)) pendingClaims;
    uint256 public treasuryPendingFees;

    address public immutable LIVO_LAUNCHPAD;

    constructor(address _launchpad) {
        LIVO_LAUNCHPAD = _launchpad;
    }

    function depositFees(address token, address feeReceiver) external payable {
        pendingClaims[token][feeReceiver] += msg.value;
        emit FeesDeposited(token, feeReceiver, msg.value);
    }

    function depositTreasuryFees() external payable {
        treasuryPendingFees += msg.value;
    }

    /// @notice Claims accumulated ETH fees for msg.sender from the provided `tokens`
    /// @dev claiming per token is less gas efficient than bulk claiming all tokens together in one balance.
    ///         However, if we'd do that, we would be forcing users to claim from all tokens at once, even from the ones they don't endorse
    function claim(address[] calldata tokens) external virtual {
        uint256 claimable;
        uint256 nTokens = tokens.length;

        for (uint256 i = 0; i < nTokens; i++) {
            address token = tokens[i];
            uint256 tokenClaimable = pendingClaims[token][msg.sender];
            if (tokenClaimable == 0) continue;

            claimable += tokenClaimable;
            delete pendingClaims[token][msg.sender];

            emit CreatorClaimed(token, msg.sender, tokenClaimable);
        }

        if (claimable == 0) return;

        _transferEth(msg.sender, claimable);
    }

    /// @notice Claims the pending treasury LP fees to the treasury address
    /// @dev Callable by anyone since funds always go to treasury
    function treasuryClaim() public {
        uint256 pending = treasuryPendingFees;

        if (pending > 0) {
            address treasury = ILivoLaunchpad(LIVO_LAUNCHPAD).treasury();
            treasuryPendingFees = 0;
            _transferEth(treasury, pending);
        }

        emit TreasuryFeesClaimed(pending);
    }

    /// @dev This doesn't include non-accrued LP fees that are sitting in the LP position
    function getClaimable(address[] calldata tokens, address account)
        external
        view
        virtual
        returns (uint256[] memory claimable)
    {
        uint256 nTokens = tokens.length;
        claimable = new uint256[](nTokens);
        for (uint256 i = 0; i < nTokens; i++) {
            claimable[i] = pendingClaims[tokens[i]][account];
        }
    }

    function _transferEth(address recipient, uint256 amount) internal {
        if (amount == 0) return;
        (bool success,) = recipient.call{value: amount}("");
        require(success, EthTransferFailed());
    }
}
