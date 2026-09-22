// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title GraduationFeeConstants
/// @notice Per-chain graduation fee amounts, in the native unit (18-dec wei-scale).
/// @dev The V2 graduator references these via a local alias so the `chain-arc-*` recipe can
///      import-swap this file for `GraduationFeeConstantsArc` (native = USDC), exactly like the
///      taxable tokens swap `DeploymentAddresses`. Ethereum/Robinhood values (native = ETH) below.
library GraduationFeeConstants {
    /// @notice Total graduation fee (creator compensation + treasury fee [+ triggerer, V2 only]).
    uint256 internal constant GRADUATION_FEE = 0.25 ether;

    /// @notice Native compensation paid to `tx.origin` for triggering V2 graduation (offsets the gas
    ///         of the lazy pair deploy inside `graduateToken()`).
    uint256 internal constant TRIGGERER_GRADUATION_COMPENSATION = 0.005 ether;

    /// @notice Build-vs-target guard, called from the V2 graduator constructor so EVERY graduator
    ///         deployment is checked automatically (any script, a raw `cast` deploy, or a test) — the
    ///         graduator bakes this whole lib at compile time. This is the ETH-priced lib, so it must NOT land on an ARC
    ///         (native = USDC) chain. Deny-list keeps it future-proof for new ETH-family chains.
    /// @dev ARC chain-ids (native = USDC): testnet 5042002, mainnet 5042. See [[arc-chain-facts]].
    function assertDeployableOn(uint256 chainId) internal pure {
        require(
            chainId != 5042002 && chainId != 5042,
            "GraduationFeeConstants: ETH-priced graduator on an ARC chain -- run `just chain-arc-testnet` && rebuild"
        );
    }
}
