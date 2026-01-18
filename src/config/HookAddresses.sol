// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Hook Address Constants
/// @notice Centralized constants for precomputed hook addresses used across the system
/// @dev These addresses are precomputed to meet Uniswap V4 hook permission requirements
library HookAddresses {
    /// @notice Precomputed LivoSwapHook address for Uniswap V4
    /// @dev Required permissions: AFTER_SWAP_FLAG (0x04) | AFTER_SWAP_RETURNS_DELTA_FLAG (0x40) | BEFORE_SWAP_FLAG (0x44)
    /// @dev Hook address must have these flags encoded in its address per UniV4 requirements
    address payable public constant LIVO_SWAP_HOOK = payable(0x75BDB48EFe32d231cC24c38c9A27a925d91a80C4);
}
