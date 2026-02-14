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

    /// @notice Returns the tax configuration for this token
    /// @return config The complete tax configuration
    function getTaxConfig() external view returns (TaxConfig memory config);

    function initialize(
        string memory name_,
        string memory symbol_,
        address graduator_,
        address pair_,
        address launchpad_,
        uint256 totalSupply_,
        bytes memory tokenCalldata
    ) external;

    function markGraduated() external;

    function graduator() external view returns (address);

    function graduated() external view returns (bool);

    function pair() external view returns (address);
}
