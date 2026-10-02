// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Burnable} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Burnable.sol";

import {ISwapLpFeeRouter} from "src/interfaces/ISwapLpFeeRouter.sol";
import {ISwapLpFeeRouterTokenFees} from "src/interfaces/ISwapLpFeeRouterTokenFees.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {IRealmTaxableToken} from "src/interfaces/IRealmTaxableToken.sol";
import {IRealmSwapper} from "src/interfaces/IRealmSwapper.sol";
import {IRealmKeepersRegistry} from "src/interfaces/IRealmKeepersRegistry.sol";

/// @title SwapLpFeeRouter
/// @notice UUPS-upgradeable router that splits LP fees between the protocol treasury and the per-token
///         creator share with a flat 30/70 split (a future implementation may carve out a
///         liquidity-reinvestment slice). Its depositors are `RealmLpLocker` (the native pool fees of the
///         protocol-owned positions) and, on older tokens, the hooks.
/// @dev    Fees a pool collected in the Realm TOKEN (sells pay the pool fee in their input) cannot be
///         split as they are: they wait in `pendingTokenFees` until a keeper sells them for the quote
///         (`convertTokenFees`) and the proceeds take the usual split, or burns them (`burnTokenFees`).
/// @dev    The split, the treasury, the swapper and the keepers registry are baked into the
///         implementation's bytecode, so changing any is done by deploying a new implementation and
///         calling `upgradeTo` on the proxy. Its only storage is `pendingTokenFees`.
contract SwapLpFeeRouter is
    ISwapLpFeeRouter,
    ISwapLpFeeRouterTokenFees,
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    /// @notice Basis points denominator (10000 = 100%).
    uint256 internal constant BASIS_POINTS = 10_000;

    /// @notice Treasury share of every routed LP fee (bps): 30 treasury / 70 creator.
    uint16 public constant TREASURY_BPS = 3_000;

    /// @notice Treasury address that receives the treasury slice on every routing. Baked into the
    ///         implementation as an immutable so each routing avoids the external
    ///         `LAUNCHPAD.treasury()` lookup. If the treasury changes, deploy a new router
    ///         implementation with the new value and `upgradeTo` it.
    address public immutable TREASURY;

    /// @notice The `RealmSwapper` proxy that sells pending token-side fees for their quote.
    /// @dev Constructor-set like `TREASURY`, not a `DeploymentAddresses` constant: phase 0 deploys this
    ///      router together with the swapper and the keepers registry, before their constants exist.
    address public immutable REALM_SWAPPER;

    /// @notice The `RealmKeepersRegistry` gating `convertTokenFees`, as it gates the tokens' conversions.
    address public immutable KEEPERS_REGISTRY;

    /// @inheritdoc ISwapLpFeeRouterTokenFees
    /// @dev Slot 0 of this contract's own storage, carved out of the head of `__gap` (now 49): OZ v5 keeps
    ///      `Ownable`/`Initializable` in namespaced slots, so the gap started at slot 0 and was all zero.
    mapping(address token => mapping(address quote => uint256)) public pendingTokenFees;

    /// @notice Emitted on every successful routing.
    /// @param token          The token whose LP fees were routed.
    /// @param creatorShare   The portion forwarded to the creator via `token.accrueFees`.
    /// @param treasuryShare  The portion sent to the treasury.
    /// @param liquidityShare The portion (re)deployed as additional liquidity. Hardcoded to zero
    ///                       in this implementation; future implementations may populate it when
    ///                       a liquidity-reinvestment path is wired in. The field is included
    ///                       from day one so indexers and the off-chain ABI stay stable.
    event LpFeesRouted(address indexed token, uint256 creatorShare, uint256 treasuryShare, uint256 liquidityShare);

    /// @notice The ERC20 counterpart of `LpFeesRouted`, for a pool quoted in something other than the
    ///         chain's native currency. A separate event rather than a widened one so every existing
    ///         indexer handler for the native path keeps working untouched.
    /// @param asset The quote currency the fee was collected and split in.
    event LpAssetFeesRouted(
        address indexed token,
        address indexed asset,
        uint256 creatorShare,
        uint256 treasuryShare,
        uint256 liquidityShare
    );

    error TreasuryTransferFailed();
    error InvalidTreasury();
    /// @notice Thrown when the ERC20 entry point is handed `address(0)`, which is the native sentinel
    ///         and belongs on the payable overload instead.
    error InvalidAsset();
    error NothingToConvert();
    /// @notice Native from anyone but the swapper, the only native this contract expects unprompted.
    error UnexpectedNative();
    error NotAKeeper();

    /// @notice Sets up the implementation's immutables. The implementation itself is not meant to
    ///         be used directly — `_disableInitializers()` locks its proxy storage so only proxies
    ///         pointing to this implementation can be initialized.
    /// @dev    Immutables are read from the implementation's bytecode through delegatecall, so they
    ///         work transparently behind the UUPS proxy. To change the treasury, deploy a new impl
    ///         with a different constructor arg and call `upgradeTo` on the proxy.
    constructor(address treasury_, address swapper_, address keepersRegistry_) {
        require(treasury_ != address(0), InvalidTreasury());
        TREASURY = treasury_;
        REALM_SWAPPER = swapper_;
        KEEPERS_REGISTRY = keepersRegistry_;
        _disableInitializers();
    }

    /// @notice One-shot initializer for the proxy. Sets `msg.sender` as the initial owner.
    /// @dev Must be called atomically with proxy deployment (via `ERC1967Proxy`'s constructor
    ///      init-data) so no one else can front-run ownership.
    function initialize() external initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
    }

    /// @dev UUPS upgrade gate: only the owner can swap the implementation.
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @notice The native proceeds of a `convertTokenFees` sale, delivered by the swapper.
    receive() external payable {
        require(msg.sender == REALM_SWAPPER, UnexpectedNative());
    }

    /// @inheritdoc ISwapLpFeeRouter
    /// @dev Reverts on treasury transfer failure so the calling hook can apply its own fallback.
    /// @dev `ethSwapAmount` / `tokenSwapAmount` are accepted for ABI stability but unused: the split
    ///      is flat, no longer marketcap-tiered.
    /// @dev SECURITY NOTE: this entrypoint is intentionally permissionless. Any external caller can
    ///      route fees by sending ETH along with an arbitrary `token`. This is acceptable because the
    ///      caller is splitting their own ETH (no protocol funds at risk). Do NOT add protocol logic
    ///      elsewhere that assumes routings only originate from the hook.
    function depositLpFees(address token, uint256, uint256) external payable override {
        _splitNative(token, msg.value);
    }

    /// @dev The native split of `amount`, already held here.
    function _splitNative(address token, uint256 amount) private {
        if (amount == 0) return;

        uint256 treasuryShare = (amount * TREASURY_BPS) / BASIS_POINTS;
        uint256 creatorShare = amount - treasuryShare;
        // Liquidity-reinvestment slice is reserved for a future implementation.
        uint256 liquidityShare = 0;

        emit LpFeesRouted(token, creatorShare, treasuryShare, liquidityShare);

        if (treasuryShare > 0) {
            (bool ok,) = TREASURY.call{value: treasuryShare}("");
            require(ok, TreasuryTransferFailed());
        }
        if (creatorShare > 0) {
            // Forwards to the master fee handler via the token's own `accrueFees`. The token is
            // pre-approved as a recipient there and routes to the configured creator/fee receivers.
            IRealmToken(token).accrueFees{value: creatorShare}();
        }
    }

    /// @inheritdoc ISwapLpFeeRouter
    /// @dev The ERC20 twin of the payable overload above, for a pool quoted in something other than the
    ///      chain's native currency. Same flat split, same destinations, same revert-on-failure contract
    ///      so the hook's own fallback still governs.
    /// @dev PULLS rather than receiving: an ERC20 has no `receive()`, so the caller approves this
    ///      contract for `amount` and the transfer happens here. That also makes the amount actually
    ///      moved the amount this contract splits, which is what a fee-on-transfer quote requires.
    /// @dev The treasury slice is a plain transfer, NOT a call: `RealmTreasuryRouter` has no ERC20 hook
    ///      to route it on arrival, so it accumulates there until someone calls its `sweep(asset)`.
    ///      Voting stays native-only by design, so that sweep sends the whole balance to the multisig.
    function depositLpFees(address token, address asset, uint256 amount, uint256, uint256) external override {
        require(asset != address(0), InvalidAsset());
        if (amount == 0) return;

        IERC20 quote = IERC20(asset);
        uint256 balanceBefore = quote.balanceOf(address(this));
        quote.safeTransferFrom(msg.sender, address(this), amount);
        _splitAsset(token, asset, quote.balanceOf(address(this)) - balanceBefore);
    }

    /// @dev The ERC20 split of `received` of `asset`, already held here.
    function _splitAsset(address token, address asset, uint256 received) private {
        if (received == 0) return;
        IERC20 quote = IERC20(asset);

        uint256 treasuryShare = (received * TREASURY_BPS) / BASIS_POINTS;
        uint256 creatorShare = received - treasuryShare;

        emit LpAssetFeesRouted(token, asset, creatorShare, treasuryShare, 0);

        if (treasuryShare > 0) quote.safeTransfer(TREASURY, treasuryShare);
        if (creatorShare > 0) {
            // The token pulls, exactly as this contract just did, so the approval is sized to this call
            // and consumed by it. Routed through the TOKEN rather than straight to the fee handler
            // because the token is what carves the earnings-allocation slices out of the creator share.
            quote.forceApprove(token, creatorShare);
            IRealmTaxableToken(payable(token)).accrueFees(asset, creatorShare);
        }
    }

    /// @inheritdoc ISwapLpFeeRouterTokenFees
    /// @dev Measured as a balance delta, so the bucket only ever holds what actually arrived.
    function depositTokenFees(address token, address quote, uint256 amount) external {
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        pendingTokenFees[token][quote] += IERC20(token).balanceOf(address(this)) - balanceBefore;
    }

    /// @inheritdoc ISwapLpFeeRouterTokenFees
    /// @dev The bucket is cleared before the sale, so a reentering token finds nothing to sell twice. The
    ///      swapper sells all of it or reverts, which restores the bucket with the rest of the state.
    ///      `quoteOut` is net of the swapper's keeper cut on a native quote.
    function convertTokenFees(address token, address quote, uint256 minOut) external returns (uint256 quoteOut) {
        // Fails closed on a codeless registry: a high-level call expecting a return value reverts.
        require(IRealmKeepersRegistry(KEEPERS_REGISTRY).isKeeper(msg.sender), NotAKeeper());
        uint256 tokenIn = pendingTokenFees[token][quote];
        require(tokenIn != 0, NothingToConvert());
        pendingTokenFees[token][quote] = 0;

        IERC20(token).forceApprove(REALM_SWAPPER, tokenIn);
        // ERC20: split what arrived, not what the swapper reports, so a fee-on-transfer quote cannot
        // overdraw the split.
        uint256 balanceBefore = quote == address(0) ? 0 : IERC20(quote).balanceOf(address(this));
        quoteOut = IRealmSwapper(REALM_SWAPPER).sellToken(token, quote, tokenIn, minOut, address(this));
        if (quote != address(0)) quoteOut = IERC20(quote).balanceOf(address(this)) - balanceBefore;
        emit LpTokenFeesConverted(token, quote, tokenIn, quoteOut);

        if (quote == address(0)) _splitNative(token, quoteOut);
        else _splitAsset(token, quote, quoteOut);
    }

    /// @inheritdoc ISwapLpFeeRouterTokenFees
    /// @dev Every Realm token inherits `ERC20Burnable`, so this reduces `totalSupply`.
    function burnTokenFees(address token, address quote) external returns (uint256 amount) {
        require(IRealmKeepersRegistry(KEEPERS_REGISTRY).isKeeper(msg.sender), NotAKeeper());
        amount = pendingTokenFees[token][quote];
        require(amount != 0, NothingToConvert());
        pendingTokenFees[token][quote] = 0;

        ERC20Burnable(token).burn(amount);
        emit LpTokenFeesBurned(token, quote, amount);
    }

    /// @dev Reserved for future storage variables. Decrement when adding new storage to keep the
    ///      proxy's slot layout stable across upgrades. Never reorder existing storage.
    uint256[49] private __gap;
}
