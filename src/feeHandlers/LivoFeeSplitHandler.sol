// // SPDX-License-Identifier: MIT
// pragma solidity 0.8.28;

// import {ILivoFeeHandler} from "src/interfaces/ILivoFeeHandler.sol";

// // todo library for Split operations like:
// // - validate split
// // - pending claims per share holder

// /// @notice A fee handler that splits fees between multiple receivers based on predefined shares.
// contract LivoFeeSplitHandler is ILivoFeeHandler {
//     uint256 public constant MAX_N_RECEIVERS = 10;

//     error TooManyReceivers();

//     struct Split {
//         /// @notice owner of the split, who can modify shares
//         address owner;
//         /// @notice Addresses receiving the split
//         address[] receivers;
//         /// @notice Shares in basis points (100 bps = 1%). Must add up exactly to 10000 (100%)
//         uint16[] shareBps;
//         /// @notice Deposited eth per share (shares are in BPS)
//         uint256 ethPerShare;
//         /// @notice claimed balance per shareholder
//         mapping(address => uint256) claimed;
//     }

//     mapping(bytes32 key => Split split) splits;

//     function createSplit(bytes32 key, address splitOwner, address[] memory receivers, uint16[] memory shareBps)
//         external {
//         // todo onlyLaunchpad? or who can create the splits?
//         // question should the split be automatically generated or passed?
//         // todo the key cannot be the owner, because the splitOwner could create multiple splits

//         // saves a Split objet in the splits mapping
//     }

//     function modifySplit(bytes32 key, address[] memory receivers, uint16[] memory shareBps) external {
//         // todo check msg.sender == split.owner
//         // _validateSplit
//         // save new split
//     }

//     /// @notice Deposits msg.value into `receiver` balance
//     function depositFees(address receiver) external payable {
//         // todo convert receiver -> key
//         // ... todo

//         emit FeesDeposited(receiver, msg.value);
//     }

//     /// @notice Claims accumulated ETH fees for msg.sender
//     function claim() external {
//         // ... todo

//         emit FeesClaimed(msg.sender, claimable);

//         (bool success,) = msg.sender.call{value: claimable}("");
//         require(success, EthTransferFailed());
//     }

//     /////////////////// view ////////////////////////

//     /// @notice Returns the pending ETH fees for `account`
//     function getClaimable(address account) public view returns (uint256) {
//         // ... todo this would be claimable per account per split ... we can't comply with the interface
//     }

//     /////////////////// view ////////////////////////

//     /// @dev makes sure the split is not ill-formed
//     /// @dev checks for repeated addresses and that the sum of shares adds up to 100%
//     function _validateSplit(Split memory split) internal {
//         uint256 sharesSum;
//         uint256 nReceivers = split.receivers.length;

//         // todo finish this function

//         if (nReceivers > MAX_N_RECEIVERS) revert TooManyReceivers();

//         for (uint256 i = 0; i < nReceivers; i++) {
//             sharesSum += split.shareBps[i];
//         }
//     }
// }
