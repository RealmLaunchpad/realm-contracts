// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILivoBondingCurve} from "src/interfaces/ILivoBondingCurve.sol";

interface ILivoLaunchpad {
    function treasury() external view returns (address);
    function getTokenOwner(address token) external view returns (address);
    function launchToken(address token, ILivoBondingCurve curve) external;
}
