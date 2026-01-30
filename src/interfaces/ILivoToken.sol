// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

interface ILivoToken is IERC20 {
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
