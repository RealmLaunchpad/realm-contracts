// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "lib/openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {ILivoFeeSplitter} from "src/interfaces/ILivoFeeSplitter.sol";
import {ILivoFeeHandler} from "src/interfaces/ILivoFeeHandler.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";

contract LivoFeeSplitter is ILivoFeeSplitter, Initializable, ReentrancyGuard {
    uint256 internal constant BPS_TOTAL = 10_000;

    address public feeHandler;
    address public token;
    address[] public recipients;
    uint256[] public sharesBps;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address feeHandler_,
        address token_,
        address[] calldata recipients_,
        uint256[] calldata sharesBps_
    ) external initializer {
        feeHandler = feeHandler_;
        token = token_;
        _setShares(recipients_, sharesBps_);
    }

    function setShares(address[] calldata recipients_, uint256[] calldata sharesBps_) external {
        require(msg.sender == ILivoToken(token).owner(), Unauthorized());
        _setShares(recipients_, sharesBps_);
    }

    function distribute(address[] calldata tokens) external nonReentrant {
        ILivoFeeHandler(feeHandler).claim(tokens);

        uint256 balance = address(this).balance;
        if (balance == 0) return;

        uint256 nRecipients = recipients.length;
        uint256 distributed;

        for (uint256 i = 0; i < nRecipients - 1; i++) {
            uint256 amount = (balance * sharesBps[i]) / BPS_TOTAL;
            distributed += amount;
            _transferEth(recipients[i], amount);
            emit FeesDistributed(recipients[i], amount);
        }

        // last recipient gets remainder (rounding dust)
        uint256 remainder = balance - distributed;
        _transferEth(recipients[nRecipients - 1], remainder);
        emit FeesDistributed(recipients[nRecipients - 1], remainder);
    }

    receive() external payable {}

    function getRecipients() external view returns (address[] memory, uint256[] memory) {
        return (recipients, sharesBps);
    }

    function _setShares(address[] calldata recipients_, uint256[] calldata sharesBps_) internal {
        uint256 len = recipients_.length;
        require(len > 0 && len == sharesBps_.length, InvalidRecipients());

        uint256 total;
        for (uint256 i = 0; i < len; i++) {
            require(recipients_[i] != address(0), InvalidRecipients());
            require(sharesBps_[i] > 0, InvalidShares());
            total += sharesBps_[i];
        }
        require(total == BPS_TOTAL, InvalidShares());

        recipients = recipients_;
        sharesBps = sharesBps_;

        emit SharesUpdated(recipients_, sharesBps_);
    }

    function _transferEth(address recipient, uint256 amount) internal {
        if (amount == 0) return;
        (bool success,) = recipient.call{value: amount}("");
        require(success);
    }
}
