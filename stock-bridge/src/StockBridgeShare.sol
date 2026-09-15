// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Pooled-share receipt for StockBridgeVault: 1 share is a proportional claim on the vault's
/// backing. Mint and burn are restricted to the paired vault.
contract StockBridgeShare is ERC20 {
    address public immutable vault;

    error NotVault();

    // Name and symbol are placeholders — set the real stock's ticker before deployment.
    constructor(address _vault) ERC20("Bridged Stock Share", "sbSTOCK") {
        vault = _vault;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    function mint(address to, uint256 amount) external onlyVault {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyVault {
        _burn(from, amount);
    }
}
