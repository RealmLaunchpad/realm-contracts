// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The multi-asset dividend state getter every taxable token exposes.
/// @dev Declared here rather than imported so a test can read one field off a token without pulling in
///      the whole concrete token type.
interface IDividendAssetsView {
    function dividendAssets(uint256 index)
        external
        view
        returns (
            uint128 rewardPerTokenStored,
            uint40 periodFinish,
            uint40 lastUpdate,
            uint40 lastProcessBlock,
            uint8 precisionExp,
            address token,
            uint96 rate,
            uint128 owed,
            uint88 pendingNative,
            uint40 failedConversionBlock
        );
}

/// @notice Asset `index`'s stream slope. Replaces the `dividendRate()` getter the token dropped to stay
///         inside EIP-170 — the field is still there, it just has to be read off the struct.
function divRate(address token, uint256 index) view returns (uint96 rate) {
    (,,,,,, rate,,,) = IDividendAssetsView(token).dividendAssets(index);
}

/// @notice When asset `index`'s accumulator was last advanced.
function divLastUpdate(address token, uint256 index) view returns (uint40 lastUpdate) {
    (,, lastUpdate,,,,,,,) = IDividendAssetsView(token).dividendAssets(index);
}
