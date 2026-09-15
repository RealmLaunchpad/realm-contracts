// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Minimal subset of the standard Pyth oracle interface, hand-written rather than vendored.
/// The name and signatures must match the deployed oracle contract, so they are kept verbatim.
interface IPyth {
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256 feeAmount);

    function updatePriceFeeds(bytes[] calldata updateData) external payable;

    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (Price memory price);

    function getPriceUnsafe(bytes32 id) external view returns (Price memory price);
}
