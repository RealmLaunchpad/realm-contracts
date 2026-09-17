// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PathKey} from "lib/v4-periphery/src/libraries/PathKey.sol";
import {UniversalRouterVenue} from "src/libraries/UniversalRouterVenue.sol";
import {IRealmKeepersRegistry} from "src/interfaces/IRealmKeepersRegistry.sol";

/// @title RealmTreasuryRouter
/// @notice The address every protocol contract pushes treasury native to (launchpad trading fees, graduation
///         fees, the LP fee router's treasury slice). Forwards 1/3 to `RealmVoting` — the slice the REALM
///         vote spends on the winning token — and the rest to the treasury multisig. Putting this proxy in
///         front of the multisig is what lets the treasury policy change later without touching the systems
///         that pay it.
/// @dev    UUPS proxy, stateless beyond owner + proxy slots + the conversion routes, like `SwapLpFeeRouter`:
///         the destinations and venue addresses are immutables of the implementation, so repointing any of
///         them is a new impl + `upgradeTo`.
contract RealmTreasuryRouter is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice The treasury multisig. Gets everything the voting contract does not.
    address public immutable TREASURY;
    /// @notice `RealmVoting`. Gets 1/3 of every deposit, earmarked for the round it arrives in.
    address public immutable VOTING;
    /// @notice Uniswap universal router `convert` swaps through.
    address public immutable UNIVERSAL_ROUTER;
    /// @notice Permit2, through which the universal router pulls the asset being converted.
    address public immutable PERMIT2;
    /// @notice `RealmKeepersRegistry`: the addresses allowed to call `convert`.
    address public immutable KEEPERS_REGISTRY;

    /// @notice The V4 path each ERC20 is sold along by `convert`, `asset -> ... -> native`, stored as
    ///         `abi.encode(PathKey[])`. Empty = not convertible. Owner-set, so the keeper picks WHEN and
    ///         HOW MUCH, never through which pools.
    mapping(address asset => bytes) public conversionRoute;

    /// @dev True while `convert` is swapping: the proceeds reach `receive` mid-swap and must not be routed
    ///      there, because `convert` measures them first.
    bool private transient _converting;

    /// @notice Emitted on every deposit. `votingShare` is 0 when the voting call failed (see `receive`).
    event TreasuryEthRouted(address indexed from, uint256 votingShare, uint256 treasuryShare);

    /// @notice Emitted when an ERC20 balance that accumulated here is forwarded to the multisig.
    event TreasuryAssetSwept(address indexed asset, uint256 amount);

    /// @notice Emitted when the owner sets the route `convert` sells `asset` along. `route` is
    ///         `abi.encode(PathKey[])`.
    event ConversionRouteSet(address indexed asset, bytes route);

    /// @notice Emitted when `amountIn` of `asset` was sold for `nativeOut`, both measured as balance
    ///         deltas. The native is then routed like any other deposit, so a `TreasuryEthRouted` with
    ///         `from` = this contract follows.
    event TreasuryAssetConverted(address indexed asset, uint256 amountIn, uint256 nativeOut);

    error TreasuryTransferFailed();
    error InvalidAddress();
    /// @notice Thrown when `sweep` / `setConversionRoute` is handed `address(0)`; native arrives through
    ///         `receive` and is routed on arrival, so there is never a native balance here to sweep.
    error InvalidAsset();
    /// @notice Thrown when a conversion route is empty or does not end in native, or `convert` is called
    ///         for an asset with no route.
    error InvalidRoute();
    /// @notice The caller is not on the keeper allowlist.
    error NotAKeeper();
    /// @notice The swap reverted or delivered less than `minOut`.
    error ConversionFailed();

    constructor(address treasury_, address voting_, address universalRouter_, address permit2_, address keepers_) {
        require(
            treasury_ != address(0) && voting_ != address(0) && universalRouter_ != address(0) && permit2_ != address(0)
                && keepers_ != address(0),
            InvalidAddress()
        );
        TREASURY = treasury_;
        VOTING = voting_;
        UNIVERSAL_ROUTER = universalRouter_;
        PERMIT2 = permit2_;
        KEEPERS_REGISTRY = keepers_;
        _disableInitializers();
    }

    /// @notice One-shot initializer for the proxy. Sets `msg.sender` as the initial owner.
    /// @dev Must be called atomically with proxy deployment (via `ERC1967Proxy`'s constructor init-data).
    function initialize() external initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @dev On the hot path of every trade: the launchpad and graduators require their treasury push to
    ///      succeed, so a voting contract that rejects native must not brick trading. Its share falls back
    ///      to the multisig; only the multisig rejecting native reverts, exactly as today.
    receive() external payable {
        if (_converting) return;
        _route(msg.sender, msg.value);
    }

    /// @notice Forwards this contract's whole balance of `asset` to the treasury multisig.
    /// @dev An ERC20 cannot be routed on arrival the way native is — there is no hook to run when one
    ///      lands — so a pool quoted in an ERC20 pays its treasury slice into this contract and it sits
    ///      here until someone calls this or `convert`. The whole balance goes to the MULTISIG: the REALM
    ///      vote spends native and only native, so splitting an arbitrary quote into it would hand the vote
    ///      a currency it cannot use.
    /// @dev Owner-gated, though the destination is an immutable and there is nothing for a caller to
    ///      gain: the treasury decides when its own balances move, and an ungated sweep is a stream of
    ///      transfers the multisig never asked for.
    function sweep(address asset) external onlyOwner {
        require(asset != address(0), InvalidAsset());
        uint256 amount = IERC20(asset).balanceOf(address(this));
        if (amount == 0) return;
        IERC20(asset).safeTransfer(TREASURY, amount);
        emit TreasuryAssetSwept(asset, amount);
    }

    /// @notice Sets the V4 path `convert` sells `asset` along. Replaceable at any time, so a pool that
    ///         dies costs a route update, not the balance.
    /// @dev Only the shape is checked (non-empty, ends in native); the pools are the owner's choice.
    function setConversionRoute(address asset, PathKey[] calldata path) external onlyOwner {
        require(asset != address(0), InvalidAsset());
        require(
            path.length != 0 && Currency.unwrap(path[path.length - 1].intermediateCurrency) == address(0),
            InvalidRoute()
        );
        bytes memory route = abi.encode(path);
        conversionRoute[asset] = route;
        emit ConversionRouteSet(asset, route);
    }

    /// @notice Sells `amountIn` of `asset` for native along its owner-set route and routes the proceeds like
    ///         any other deposit (1/3 voting, the rest to the multisig). Keeper-gated.
    /// @dev The keeper chooses the size and the floor, computed off-chain; the route is not theirs to
    ///      choose. Same trust model as the dividend conversions: the keeper gate plus `minOut`.
    /// @dev A partial fill leaves the unsold remainder here, still the treasury's, for the next call.
    /// @return nativeOut native received, measured as this contract's balance delta.
    function convert(address asset, uint256 amountIn, uint256 minOut) external returns (uint256 nativeOut) {
        require(IRealmKeepersRegistry(KEEPERS_REGISTRY).isKeeper(msg.sender), NotAKeeper());
        bytes memory route = conversionRoute[asset];
        require(route.length != 0, InvalidRoute());

        UniversalRouterVenue.ensureRouterPull(PERMIT2, UNIVERSAL_ROUTER, asset);
        uint256 assetBefore = IERC20(asset).balanceOf(address(this));
        uint256 nativeBefore = address(this).balance;
        _converting = true;
        bool ok = UniversalRouterVenue.swapAssetToNativeV4Path(
            UNIVERSAL_ROUTER, asset, abi.decode(route, (PathKey[])), amountIn, minOut
        );
        _converting = false;
        nativeOut = address(this).balance - nativeBefore;
        require(ok && nativeOut != 0 && nativeOut >= minOut, ConversionFailed());

        emit TreasuryAssetConverted(asset, assetBefore - IERC20(asset).balanceOf(address(this)), nativeOut);
        _route(address(this), nativeOut);
    }

    /// @dev The 1/3 voting split. See `receive`.
    function _route(address from, uint256 amount) private {
        uint256 votingShare = amount / 3;
        if (votingShare > 0) {
            (bool sent,) = VOTING.call{value: votingShare}("");
            if (!sent) votingShare = 0;
        }
        uint256 treasuryShare = amount - votingShare;
        (bool ok,) = TREASURY.call{value: treasuryShare}("");
        require(ok, TreasuryTransferFailed());
        emit TreasuryEthRouted(from, votingShare, treasuryShare);
    }

    /// @dev Reserved for future storage variables. Decrement when adding new storage.
    uint256[49] private __gap;
}
