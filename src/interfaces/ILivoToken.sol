// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

interface ILivoToken is IERC20 {
    function initialize(
        string memory _name,
        string memory _symbol,
        address _creator,
        address _launchpad,
        address _graduator,
        address _pair,
        uint256 _totalSupply,
        uint256 _buyFeeBps,
        uint256 _sellFeeBps
    ) external;

    function markGraduated() external;

    function creator() external view returns (address);
}
