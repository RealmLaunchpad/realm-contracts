// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

interface ILivoToken is IERC20 {
    /// @notice Tax configuration for a token
    struct TaxConfig {
        uint16 buyTaxBps; // Buy tax in basis points (max 500 = 5%)
        uint16 sellTaxBps; // Sell tax in basis points (max 500 = 5%)
        uint40 taxDurationSeconds; // Duration after graduation during which taxes apply
        uint40 graduationTimestamp; // Timestamp when token graduated (0 if not graduated)
        address taxRecipient; // Address receiving tax payments (token owner)
    }

    ////////////////// STATE CHANGING FUNCTIONS ////////////////////

    function markGraduated() external;

    /// @notice Allows the current owner or whitelisted address to propose a new owner
    function proposeNewOwner(address newOwner) external;

    /// @notice Allows the proposed owner to accept the ownership
    function acceptTokenOwnership() external;

    ////////////////// VIEW FUNCTIONS ////////////////////

    /// @notice Returns the tax configuration for this token
    /// @return config The complete tax configuration
    function getTaxConfig() external view returns (TaxConfig memory config);

    /// @notice Contract in charge of handling the graduation process
    /// @dev Must implement ILivoGraduator interface
    function graduator() external view returns (address);

    /// @notice Returns true if already graduated
    function graduated() external view returns (bool);

    /// @notice Address where liquidity is deployed after graduation
    function pair() external view returns (address);

    /// @notice The contract where fees will deposited
    /// @dev Must implement ILivoFeeHandler interface
    function feeHandler() external view returns (address);

    /// @notice The address-key to assign the fees within the feeHandler contract
    /// @dev we use bytes32 to have future flexibility. Addresses could be converted to bytes32 as well for basic address keys
    function feeReceiverKey() external view returns (bytes32);

    /// @notice Owner of the token. The creator unless communityTakeOver takes place
    function owner() external view returns (address);

    /// @notice Address who can accept ownership of the token
    /// @dev It can be address(0) if no owner is proposed
    function proposedOwner() external view returns (address);
}
