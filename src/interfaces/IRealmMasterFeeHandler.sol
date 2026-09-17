// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRealmClaims} from "src/interfaces/IRealmClaims.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {PathKey} from "lib/v4-periphery/src/libraries/PathKey.sol";

/// @notice Unified singleton fee handler supporting single and multi-receiver tokens, with optional
///         synchronous ETH forwarding (direct fees) per receiver. Replaces both `RealmFeeHandler`
///         (single-receiver) and `RealmFeeSplitter` (multi-receiver clone) in the new token family.
interface IRealmMasterFeeHandler is IRealmClaims {
    ////////////////// Errors //////////////////

    error AlreadyRegistered();
    error NotRegistered();
    error Unauthorized();
    error InvalidFeeShares();
    error InvalidShares();
    error TooManyDirectReceivers();
    error TooManyFeeReceivers();
    /// @notice Thrown when an ERC20 entry point is handed `address(0)`, which is the native sentinel
    ///         and belongs on the payable overload instead.
    error InvalidAsset();
    /// @notice Thrown when a token has already been paid in `MAX_FEE_ASSETS` distinct ERC20s. Only
    ///         the token itself can add one, so this bounds the `setShares` snapshot loop without being
    ///         reachable by anyone else.
    error TooManyFeeAssets();
    /// @notice Thrown by `claimAsNative` when the swap reverted, filled only partially, or delivered less
    ///         than `minOut`.
    error NativeConversionFailed();

    ////////////////// Events //////////////////

    /// @notice Emitted on every NATIVE `depositFees` call, before any direct forward attempt.
    event CreatorFeesDeposited(address indexed token, uint256 amount);

    /// @notice The ERC20 counterpart of `CreatorFeesDeposited`, emitted when a token pays its fees in
    ///         the currency its pool is quoted in. A separate event rather than a widened one so every
    ///         existing indexer handler for the native path keeps working untouched.
    /// @dev `amount` is what ACTUALLY arrived, not what was requested — a fee-on-transfer quote
    ///      delivers less, and the split is computed on the smaller number.
    event CreatorAssetFeesDeposited(address indexed token, address indexed asset, uint256 amount);

    /// @notice The ERC20 counterpart of `IRealmClaims.CreatorClaimed`: a receiver was paid in `asset`,
    ///         either by a successful direct forward or by claiming. Same reasoning as
    ///         `CreatorAssetFeesDeposited` for why it is a separate event.
    event CreatorAssetClaimed(address indexed token, address indexed asset, address indexed account, uint256 amount);

    /// @notice Emitted by `claimAsNative` after its per-token `CreatorAssetClaimed` events: `amountIn` of
    ///         `asset` (their sum) was sold and `nativeOut` paid to `account` instead. A payout, not new
    ///         earnings — the fees were already accounted in `asset`.
    event CreatorAssetConvertedToNative(
        address indexed account, address indexed asset, uint256 amountIn, uint256 nativeOut
    );

    /// @notice Emitted when shares are (re)configured via `registerToken` or `setShares`. `token`
    ///         distinguishes per-token configs since this is a singleton handler.
    event SharesUpdated(address indexed token, address[] recipients, uint256[] sharesBps);

    /// @notice Emitted for each address that becomes a direct receiver — at `registerToken` for
    ///         every direct entry in the init payload, and from `setShares` for every address that
    ///         was not direct beforehand and is direct in the new payload.
    event DirectReceiverRegistered(address indexed token, address indexed receiver);

    /// @notice Emitted from `setShares` for each address that was direct beforehand and is no
    ///         longer direct in the new payload (demoted to claimable or removed entirely). Any
    ///         failed-forward residue in pending claims is preserved and recoverable via `claim()`.
    event DirectReceiverRemoved(address indexed token, address indexed receiver);

    ////////////////// Functions //////////////////

    /// @notice Deposits ETH fees for `token`. Routes to the appropriate single or multi-receiver
    ///         path based on the token's registered config. Direct receivers are forwarded
    ///         synchronously; forward failures silently fall back to pending-claim accounting so
    ///         swap and graduation hot paths cannot be DoS'd.
    /// @dev `CreatorFeesDeposited` is emitted before any forward attempt for non-zero deposits;
    ///      zero-value calls are no-ops and emit nothing.
    function depositFees(address token) external payable;

    /// @notice Deposits ERC20 fees for `token`, in whichever currency its pool is quoted in. Callable
    ///         ONLY by the token itself — see the implementation for why the native overload above can
    ///         be permissionless and this one cannot.
    function depositFees(address token, address asset, uint256 amount) external;

    /// @notice Registers initial fee-receiver config for a newly-deployed token. One-shot per
    ///         token. Callable only by the token itself; the token address is inferred from
    ///         `msg.sender`.
    function registerToken(IRealmFactory.FeeShare[] calldata feeShares) external;

    /// @notice Replaces the fee-receiver config for `token`. Callable only by the admin or the
    ///         token's current non-zero owner. Snapshots claimable accrual into pending before
    ///         overwriting so no ETH is lost on transitions. The direct-receiver set is fully mutable.
    function setShares(address token, IRealmFactory.FeeShare[] calldata feeShares) external;

    ////////////////// Views //////////////////

    /// @notice Returns all current recipients and their BPS shares for `token`.
    function getRecipients(address token) external view returns (address[] memory, uint256[] memory);

    /// @notice Returns the current direct-receiver addresses for `token`.
    function getDirectReceivers(address token) external view returns (address[] memory);

    /// @notice Returns whether `account` is currently a direct receiver for `token`.
    function isDirectReceiver(address token, address account) external view returns (bool);

    /// @notice Every asset `token` may hold fees in: native (`address(0)`) first, always, then every ERC20
    ///         it has been paid in.
    function assetsOf(address token) external view returns (address[] memory);

    /// @notice Claims accumulated fees for `msg.sender` in one ERC20 `asset` across the given tokens.
    function claim(address[] calldata tokens, address asset) external;

    /// @notice Claims `msg.sender`'s fees in `asset` across `tokens` and pays them out as native, sold
    ///         along `path` (`asset -> ... -> native`) with a floor of `minOut`.
    function claimAsNative(address[] calldata tokens, address asset, PathKey[] calldata path, uint256 minOut)
        external
        returns (uint256 nativeOut);

    /// @notice Returns the pending claimable `asset` fees for `account` across the given tokens.
    function getClaimable(address[] calldata tokens, address asset, address account)
        external
        view
        returns (uint256[] memory);
}
