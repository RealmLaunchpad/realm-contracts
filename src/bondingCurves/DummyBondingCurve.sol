// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILivoBondingCurve} from "src/interfaces/ILivoBondingCurve.sol";

contract DummyBondingCurve is ILivoBondingCurve {
    function getTokensForEth(uint256 circulatingSupply, uint256 ethAmount) external pure returns (uint256) {
        // Linear price: price = circulatingSupply + 1
        // tokens = ethAmount / price = ethAmount / (circulatingSupply + 1)
        return ethAmount / (circulatingSupply + 1);
    }

    function getEthForTokens(uint256 circulatingSupply, uint256 tokenAmount) external pure returns (uint256) {
        // Linear price: price = circulatingSupply + 1
        // ethAmount = tokenAmount * price = tokenAmount * (circulatingSupply + 1)
        return tokenAmount * (circulatingSupply + 1);
    }
}
