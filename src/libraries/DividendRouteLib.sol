// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Hop} from "src/interfaces/ILivoDividendSwapRegistry.sol";

/// @title DividendRouteLib
/// @notice The one wire format for a dividend payout asset's swap route, and the only place it is
///         decoded. A route travels frontend -> factory -> token -> registry as opaque `bytes`, so
///         every layer in between forwards it without knowing which venue it names.
///
/// @dev WHY ONE `bytes` FIELD AND NOT A STRUCT PER VENUE. A V4 route is a list of
///      `(currency, fee, tickSpacing, hooks)` hops; a V3 route is Uniswap's own packed
///      `token | fee | token` path; a V2 route is nothing at all, because the pair is fully implied by
///      its two currencies. Three shapes with nothing in common. Carrying them as three parallel
///      arrays through the creation payload would leave two of them empty on every token; carrying
///      them as one tagged blob costs one byte and keeps `EarningsAllocationMultiConfig` to a single
///      new field.
///
/// @dev THE EMPTY ROUTE IS NOT A MISSING ROUTE. It is the explicit choice of the permissionless V2
///      pair, which is what the registry measured on its own before routes existed. That makes the
///      common case free: a creator picking an asset with a deep V2 pair sends zero bytes.
library DividendRouteLib {
    /// @notice Venue tag, first byte of a non-empty route.
    /// @dev V2 has no tag because it has no route: the empty string IS the V2 selection. Numbered to
    ///      match the Uniswap version so a hex dump reads as itself.
    uint8 internal constant VENUE_V3 = 0x03;
    uint8 internal constant VENUE_V4 = 0x04;

    /// @notice The venue a route names, without decoding its body.
    /// @dev Returns 0 for the empty route (V2). An unrecognized tag is returned as-is so the caller
    ///      rejects it with its own error rather than this library guessing an intent.
    function venue(bytes memory route) internal pure returns (uint8) {
        if (route.length == 0) return 0;
        return uint8(route[0]);
    }

    /// @notice Everything a route says, decoded ONCE. Only the field its `venue` names is populated.
    /// @dev Exists so the conversion path does not decode the same immutable bytes twice: validation and
    ///      the swap itself both need the body, and they run back to back on the keeper's hot path.
    struct Decoded {
        uint8 venue;
        Hop[] hops;
        bytes path;
    }

    /// @notice Reads a route into the form both the eligibility check and the swap consume.
    function decode(bytes memory route) internal pure returns (Decoded memory d) {
        d.venue = venue(route);
        if (d.venue == VENUE_V4) d.hops = toV4Hops(route);
        else if (d.venue == VENUE_V3) d.path = toV3Path(route);
    }

    /// @notice The V4 hops a route carries. Reverts if the route is not a V4 route.
    /// @dev The body is `abi.encode(Hop[])` rather than a packed layout: `Hop` has an `int24` in the
    ///      middle, and hand-packing signed fields is exactly the kind of cleverness that produces a
    ///      route naming the wrong pool. The extra calldata is paid once, at creation.
    function toV4Hops(bytes memory route) internal pure returns (Hop[] memory hops) {
        // Strip the tag byte, then decode the rest as the array it was encoded as.
        hops = abi.decode(_body(route), (Hop[]));
    }

    /// @notice The V3 path a route carries, as the router's own `token | fee | token…` encoding.
    /// @dev Returned as the exact bytes the universal router consumes, so there is no translation step
    ///      at the call site and one- and two-hop paths are the same shape.
    function toV3Path(bytes memory route) internal pure returns (bytes memory path) {
        path = _body(route);
    }

    /// @dev The route minus its leading tag byte. `mcopy` rather than a per-byte Solidity loop: a route
    ///      is 190-320 bytes, and copying it a byte at a time (bounds-checked mload + mstore8 each) is
    ///      thousands of gas on a path that runs per conversion. Non-destructive on purpose — the caller
    ///      still holds `route` and the registry re-reads its tag.
    function _body(bytes memory route) private pure returns (bytes memory body) {
        uint256 len = route.length - 1;
        body = new bytes(len);
        assembly ("memory-safe") {
            mcopy(add(body, 0x20), add(route, 0x21), len)
        }
    }

    /// @notice Builds the wire format for a V4 route. Off-chain callers encode the same thing; this
    ///         exists so tests and scripts cannot drift from what the registry decodes.
    function encodeV4(Hop[] memory hops) internal pure returns (bytes memory) {
        return abi.encodePacked(VENUE_V4, abi.encode(hops));
    }

    /// @notice Builds the wire format for a V3 route from Uniswap's packed path.
    function encodeV3(bytes memory path) internal pure returns (bytes memory) {
        return abi.encodePacked(VENUE_V3, path);
    }
}
