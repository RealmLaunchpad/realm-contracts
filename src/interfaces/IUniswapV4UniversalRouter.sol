// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PathKey} from "lib/v4-periphery/src/libraries/PathKey.sol";

interface IUniversalRouter {
    /// @notice Executes encoded commands along with provided inputs. Reverts if deadline has expired.
    /// @param commands A set of concatenated commands, each 1 byte in length
    /// @param inputs An array of byte strings containing abi encoded inputs for each command
    /// @param deadline The deadline by which the transaction must be executed
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @title IV4RouterSwaps
/// @notice The V4 swap params of the universal router THIS PROTOCOL ACTUALLY TALKS TO, pinned here
///         rather than taken from `lib/v4-periphery`.
/// @dev Both Robinhood chains run stock universal-router v2.1.1, whose v4-periphery adds a per-hop
///      price floor (`minHopPriceX36`) that the version vendored in `lib/` predates. The params cross
///      into `execute` as an opaque `bytes` blob, so nothing type-checks the two sides against each
///      other: the router decodes with unchecked assembly and a stale layout reverts with EMPTY
///      returndata. Pinning the structs here — beside the `execute` they are encoded for — keeps the
///      wire format tied to the deployed router instead of to whatever `lib/` happens to hold.
/// @dev The stale 5-field layout failed ONLY on ERC20-quoted pools: the old encoding left the router
///      reading `currency0` as the `hookData` length, which is 0 for a native quote (harmless) and a
///      20-byte address for an ERC20 one (revert). That is why native pools kept working and this
///      surfaced with the ERC20-quote venue.
interface IV4RouterSwaps {
    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        /// @dev Minimum price for this hop, Q36. 0 disables it; `amountOutMinimum` is the real bound.
        uint256 minHopPriceX36;
        bytes hookData;
    }

    struct ExactInputParams {
        Currency currencyIn;
        PathKey[] path;
        /// @dev One floor per hop, so it MUST be `path.length` long — the router rejects any other
        ///      length with `InvalidHopPriceLength()`. Zero-filled: see the single-hop note above.
        uint256[] minHopPriceX36;
        uint128 amountIn;
        uint128 amountOutMinimum;
    }
}
