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

    /// @notice Uniswap V2 Router contract
    /// @dev Handles routing and execution of V2 swaps
    address public constant UNIV2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

    /// @notice Uniswap V2 Factory contract
    /// @dev Creates and manages V2 pair contracts
    address public constant UNIV2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;

    /// @notice Dead address used for burning LP tokens
    /// @dev Standard burn address that works on all chains
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;
}

/// @title Deployment Address Constants for Sepolia Testnet
/// @notice Centralized constants for protocol infrastructure addresses on Sepolia Testnet
/// @dev TODO: Update these addresses with actual Sepolia deployments
library DeploymentAddressesSepolia {
    /// @notice Uniswap V4 Pool Manager contract
    address public constant UNIV4_POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;

    /// @notice Uniswap V4 Position Manager contract
    address public constant UNIV4_POSITION_MANAGER = 0xf969Aee60879C54bAAed9F3eD26147Db216Fd664;

    /// @notice Uniswap V4 Universal Router contract
    address public constant UNIV4_UNIVERSAL_ROUTER = 0xf70536B3bcC1bD1a972dc186A2cf84cC6da6Be5D;

    /// @notice Permit2 contract
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @notice Wrapped Ether (WETH) token contract
    address public constant WETH = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9; // this is WETH deployed by uniswap for uniswap tests

    /// @notice Uniswap V2 Router contract
    address public constant UNIV2_ROUTER = 0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008;

    /// @notice Uniswap V2 Factory contract
    /// @dev TODO: Sepolia V2 Factory address not documented - can be queried from router.factory()
    address public constant UNIV2_FACTORY = address(0); // TODO: Get from router.factory() or Sepolia docs

    /// @notice Dead address used for burning LP tokens
    /// @dev Standard burn address that works on all chains
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;
}
