// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Deployment Address Constants for Ethereum Mainnet
/// @notice Centralized constants for protocol infrastructure addresses on Ethereum Mainnet
/// @dev These addresses are network-specific and must be updated for other chains
library DeploymentAddressesMainnet {
    /// @notice Uniswap V4 Pool Manager contract
    /// @dev Core contract managing all V4 pools and their lifecycle
    address public constant UNIV4_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    /// @notice Uniswap V4 Position Manager contract
    /// @dev Manages liquidity positions for V4 pools
    address public constant UNIV4_POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;

    /// @notice Uniswap V4 Universal Router contract
    /// @dev Handles routing and execution of V4 swaps
    address public constant UNIV4_UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;

    /// @notice Permit2 contract
    /// @dev Token approval contract used across multiple protocols
    /// @dev Note: Permit2 may be deployed at the same address on multiple chains
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @notice Wrapped Ether (WETH) token contract
    /// @dev Official WETH contract for Ethereum Mainnet
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
}

/// @title Deployment Address Constants for Sepolia Testnet
/// @notice Centralized constants for protocol infrastructure addresses on Sepolia Testnet
/// @dev TODO: Update these addresses with actual Sepolia deployments
library DeploymentAddressesSepolia {
    /// @notice Uniswap V4 Pool Manager contract
    address public constant UNIV4_POOL_MANAGER = 0x00b036b58a818b1bc34d502d3fe730db729e62ac;

    /// @notice Uniswap V4 Position Manager contract
    address public constant UNIV4_POSITION_MANAGER = 0xf969aee60879c54baaed9f3ed26147db216fd664;

    /// @notice Uniswap V4 Universal Router contract
    address public constant UNIV4_UNIVERSAL_ROUTER = 0xf70536b3bcc1bd1a972dc186a2cf84cc6da6be5d;

    /// @notice Permit2 contract
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @notice Wrapped Ether (WETH) token contract
    address public constant WETH = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9; // this is WETH deployed by uniswap for uniswap tests
}
