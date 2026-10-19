// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {Ownable, Ownable2Step} from "lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";

import {RealmEtfAssets, IEtfV3Pool} from "src/etf/RealmEtfAssets.sol";

/// @title RealmEtf
/// @notice An ETF: an ERC20 share over a set of `RealmEtfAssets`-listed assets. Deposit USDG and it
///         is swapped into every asset; redeem shares and a pro-rata slice of every asset is sold back to
///         USDG. The creator (owner) is the only one who rebalances, adds or removes assets.
///
/// @dev PRO-RATA, ORACLE-FREE MINTING. A deposit buys each asset, and mints `supply x` the SMALLEST
///      fraction it added to any holding. Prices only decide how the USDG is split across assets (spot,
///      from each asset's route pool), so a wrong or manipulated price costs the depositor efficiency,
///      never the other holders: any surplus of the other assets stays in the vault. A redemption takes the
///      same fraction of every holding, so it needs no price at all.
///
/// @dev SEMI-ERC4626 + ERC-5143. `deposit`/`redeem` follow ERC-4626, with ERC-5143 overloads that add a
///      slippage floor. `mint`/`withdraw` are unsupported (`maxMint`/`maxWithdraw` are 0): an exact USDG
///      out cannot be hit pro-rata across pools with different slippage. `totalAssets` and the previews
///      value holdings at their route pools' SPOT prices, before swap fees and price impact: estimates,
///      not the exact amounts ERC-4626 asks of previews.
///
/// @dev REBALANCES TRUST THE CREATOR. The creator picks `minOut`; nothing on chain bounds the price. A
///      creator can push a pool around their own rebalance and keep the difference.
///
/// @dev TWO CALL CONTEXTS. Called directly, each V4 swap unlocks the pool manager itself. Called while the
///      pool manager is already unlocked (by `RealmEtfHook` inside a swap on the shares/USDG pool, or by
///      any router mid-unlock), V4 swaps run inline and settle their own deltas before returning. V3
///      swaps are direct pool calls either way.
contract RealmEtf is ERC20, Ownable2Step, ReentrancyGuardTransient, IERC4626, IUnlockCallback {
    using SafeERC20 for IERC20;
    using TransientStateLibrary for IPoolManager;

    /// @notice Most assets an ETF may hold. Every deposit and redemption swaps through each one.
    uint256 public constant MAX_ASSETS = 10;

    /// @notice Shares minted to `DEAD` at seeding, so supply never returns to a size rounding can exploit.
    uint256 public constant DEAD_SHARES = 1e15;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 private constant BPS = 10_000;

    /// @notice The factory that deployed and seeded this ETF.
    address public immutable FACTORY;

    /// @notice The hook of the ETF's shares/USDG pool, the only caller of `redeemOnCredit`.
    address public immutable HOOK;

    /// @notice Where the ETF's assets and their USDG routes are listed.
    RealmEtfAssets public immutable REGISTRY;

    /// @notice The pool manager V4 routes swap on.
    IPoolManager public immutable POOL_MANAGER;

    /// @notice The deposit asset (ERC-4626 `asset()`).
    address public immutable USDG;

    uint8 private immutable _usdgDecimals;

    address[] internal _assets;

    /// @dev The V3 pool a swap is in flight on, the only caller its callback accepts.
    address private transient _v3Pool;

    event Seeded(address indexed receiver, uint256 assets, uint256 shares);
    event Rebalanced(address indexed sellAsset, uint256 sold, address indexed buyAsset, uint256 bought);
    event AssetAdded(address indexed asset);
    event AssetRemoved(address indexed asset);
    event RedeemedInKind(address indexed owner, address indexed receiver, uint256 shares);
    /// @notice An in-kind transfer failed (a paused or blacklisting token); the amount stays in the vault.
    event InKindTransferFailed(address indexed asset, uint256 amount);

    error OnlyFactory();
    error AlreadySeeded();
    error InvalidAssets();
    error InvalidWeights();
    error AssetNotListed();
    error AssetNotHeld();
    error TooManyAssets();
    error ZeroAmount();
    error Slippage();
    error NotSupported();
    error Unauthorized();

    constructor(
        string memory name_,
        string memory symbol_,
        address creator,
        RealmEtfAssets registry,
        address hook,
        address[] memory assets_
    ) ERC20(name_, symbol_) Ownable(creator) {
        FACTORY = msg.sender;
        HOOK = hook;
        REGISTRY = registry;
        POOL_MANAGER = registry.POOL_MANAGER();
        USDG = registry.USDG();
        _usdgDecimals = IERC20Metadata(USDG).decimals();

        require(assets_.length != 0 && assets_.length <= MAX_ASSETS, InvalidAssets());
        for (uint256 i; i < assets_.length; ++i) {
            require(registry.isListed(assets_[i]), AssetNotListed());
            for (uint256 j; j < i; ++j) {
                require(assets_[j] != assets_[i], InvalidAssets());
            }
            _assets.push(assets_[i]);
        }
    }

    //////////////////////// seeding //////////////////////

    /// @notice First deposit, split by `weightsBps` (no holdings to go pro-rata on yet). One share per
    ///         whole USDG; `DEAD_SHARES` of them go to `DEAD`. Factory only, once.
    /// @dev The factory has already sent `assets` USDG here.
    function seed(uint256 assets, uint16[] calldata weightsBps, address receiver, uint256 minShares)
        external
        nonReentrant
        returns (uint256 shares)
    {
        require(msg.sender == FACTORY, OnlyFactory());
        require(totalSupply() == 0, AlreadySeeded());
        uint256 n = _assets.length;
        require(weightsBps.length == n, InvalidWeights());

        uint256 sum;
        uint256 spent;
        for (uint256 i; i < n; ++i) {
            require(weightsBps[i] != 0, InvalidWeights());
            sum += weightsBps[i];
            uint256 amountIn = i == n - 1 ? assets - spent : assets * weightsBps[i] / BPS;
            spent += amountIn;
            require(_swap(_assets[i], true, amountIn) != 0, ZeroAmount());
        }
        require(sum == BPS, InvalidWeights());

        uint256 total = assets * 10 ** (decimals() - _usdgDecimals);
        require(total > DEAD_SHARES, ZeroAmount());
        shares = total - DEAD_SHARES;
        require(shares >= minShares, Slippage());
        _mint(DEAD, DEAD_SHARES);
        _mint(receiver, shares);
        emit Seeded(receiver, assets, shares);
    }

    //////////////////////// ERC-4626 / ERC-5143 //////////////////////

    /// @notice Shares in circulation. Excludes the shares locked in the pool manager behind `HOOK`'s claims:
    ///         those were sold through the pool and already paid out (`redeemOnCredit`), so they are burned
    ///         in all but name. Balances therefore sum to more than this.
    function totalSupply() public view override(ERC20, IERC20) returns (uint256) {
        return super.totalSupply() - POOL_MANAGER.balanceOf(HOOK, uint256(uint160(address(this))));
    }

    function asset() external view returns (address) {
        return USDG;
    }

    /// @notice Holdings valued in USDG at their route pools' spot prices. An estimate: selling them would
    ///         pay swap fees and price impact.
    function totalAssets() public view returns (uint256 total) {
        for (uint256 i; i < _assets.length; ++i) {
            address a = _assets[i];
            total += REGISTRY.usdgValueOf(a, IERC20(a).balanceOf(address(this)));
        }
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return Math.mulDiv(assets, totalSupply(), totalAssets());
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return Math.mulDiv(shares, totalAssets(), totalSupply());
    }

    function maxDeposit(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    /// @notice Estimate only (see `totalAssets`).
    function previewDeposit(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256) {
        return _deposit(assets, receiver, 0);
    }

    /// @notice ERC-5143: `deposit` that reverts below `minShares`.
    function deposit(uint256 assets, address receiver, uint256 minShares) external returns (uint256) {
        return _deposit(assets, receiver, minShares);
    }

    function maxMint(address) external pure returns (uint256) {
        return 0;
    }

    function previewMint(uint256) external pure returns (uint256) {
        revert NotSupported();
    }

    function mint(uint256, address) external pure returns (uint256) {
        revert NotSupported();
    }

    function maxWithdraw(address) external pure returns (uint256) {
        return 0;
    }

    function previewWithdraw(uint256) external pure returns (uint256) {
        revert NotSupported();
    }

    function withdraw(uint256, address, address) external pure returns (uint256) {
        revert NotSupported();
    }

    function maxRedeem(address owner_) external view returns (uint256) {
        return balanceOf(owner_);
    }

    /// @notice Estimate only (see `totalAssets`).
    function previewRedeem(uint256 shares) external view returns (uint256) {
        return convertToAssets(shares);
    }

    function redeem(uint256 shares, address receiver, address owner_) external returns (uint256) {
        return _redeem(shares, receiver, owner_, 0);
    }

    /// @notice ERC-5143: `redeem` that reverts below `minAssets`.
    function redeem(uint256 shares, address receiver, address owner_, uint256 minAssets) external returns (uint256) {
        return _redeem(shares, receiver, owner_, minAssets);
    }

    /// @notice `HOOK` only: pays `receiver` the USDG for `shares` the hook does not hold yet. A sell through the
    ///         pool settles its shares after the swap, so the hook is paid out first and then claims the
    ///         incoming shares in the pool manager, which takes them out of `totalSupply` for good. The
    ///         pool manager guarantees they arrive: the whole transaction reverts otherwise.
    function redeemOnCredit(uint256 shares, address receiver) external nonReentrant returns (uint256 assets) {
        require(msg.sender == HOOK, Unauthorized());
        require(shares != 0, ZeroAmount());
        assets = _sellSlice(shares, totalSupply(), receiver, 0);
        emit Withdraw(msg.sender, receiver, msg.sender, assets, shares);
    }

    /// @notice The exit that needs no pool: burns `shares` and sends their pro-rata slice of every asset.
    ///         An asset whose transfer fails (paused, blacklisted) is skipped and its slice stays in the vault.
    function redeemInKind(uint256 shares, address receiver, address owner_)
        external
        nonReentrant
        returns (uint256[] memory amounts)
    {
        require(shares != 0, ZeroAmount());
        if (msg.sender != owner_) _spendAllowance(owner_, msg.sender, shares);
        uint256 supply = totalSupply();
        _burn(owner_, shares);
        uint256 n = _assets.length;
        amounts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            IERC20 a = IERC20(_assets[i]);
            uint256 amount = Math.mulDiv(a.balanceOf(address(this)), shares, supply);
            if (SafeERC20.trySafeTransfer(a, receiver, amount)) amounts[i] = amount;
            else emit InKindTransferFailed(address(a), amount);
        }
        emit RedeemedInKind(owner_, receiver, shares);
    }

    //////////////////////// creator //////////////////////

    /// @notice Sells `sellAmount` of a held asset (`type(uint256).max`: all of it) and buys `buyAsset`
    ///         with the proceeds, through USDG. Buying an asset not yet held adds it; selling all of one
    ///         removes it. Reverts if fewer than `minOut` of `buyAsset` are bought.
    function rebalance(address sellAsset, uint256 sellAmount, address buyAsset, uint256 minOut)
        external
        onlyOwner
        nonReentrant
        returns (uint256 bought)
    {
        uint256 sellIndex = _indexOf(sellAsset);
        require(sellIndex != type(uint256).max, AssetNotHeld());
        require(buyAsset != sellAsset && REGISTRY.isListed(buyAsset), AssetNotListed());
        uint256 balance = IERC20(sellAsset).balanceOf(address(this));
        if (sellAmount > balance) sellAmount = balance;
        require(sellAmount != 0, ZeroAmount());

        if (sellAmount == balance) {
            _assets[sellIndex] = _assets[_assets.length - 1];
            _assets.pop();
            emit AssetRemoved(sellAsset);
        }
        if (_indexOf(buyAsset) == type(uint256).max) {
            require(_assets.length < MAX_ASSETS, TooManyAssets());
            _assets.push(buyAsset);
            emit AssetAdded(buyAsset);
        }

        uint256 usdg = _swap(sellAsset, false, sellAmount);
        uint256 before = IERC20(buyAsset).balanceOf(address(this));
        _swap(buyAsset, true, usdg);
        bought = IERC20(buyAsset).balanceOf(address(this)) - before;
        require(bought >= minOut, Slippage());
        emit Rebalanced(sellAsset, sellAmount, buyAsset, bought);
    }

    /// @notice The assets currently held.
    function getAssets() external view returns (address[] memory) {
        return _assets;
    }

    //////////////////////// swap callbacks //////////////////////

    /// @dev A V4 swap started by `_swap` outside an unlock.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(POOL_MANAGER), Unauthorized());
        (PoolKey memory key, address tokenIn, uint256 amountIn) = abi.decode(data, (PoolKey, address, uint256));
        return abi.encode(_swapV4(key, tokenIn, amountIn));
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        require(msg.sender == _v3Pool && msg.sender != address(0), Unauthorized());
        IERC20(abi.decode(data, (address)))
            .safeTransfer(msg.sender, uint256(amount0Delta > 0 ? amount0Delta : amount1Delta));
    }

    //////////////////////// internals //////////////////////

    function _deposit(uint256 assets, address receiver, uint256 minShares)
        internal
        nonReentrant
        returns (uint256 shares)
    {
        require(assets != 0, ZeroAmount());
        IERC20(USDG).safeTransferFrom(msg.sender, address(this), assets);

        uint256 n = _assets.length;
        uint256 supply = totalSupply();
        uint256[] memory balances = new uint256[](n);
        uint256[] memory values = new uint256[](n);
        uint256 totalValue;
        for (uint256 i; i < n; ++i) {
            balances[i] = IERC20(_assets[i]).balanceOf(address(this));
            values[i] = REGISTRY.usdgValueOf(_assets[i], balances[i]);
            totalValue += values[i];
        }

        shares = type(uint256).max;
        uint256 spent;
        for (uint256 i; i < n; ++i) {
            uint256 amountIn = i == n - 1 ? assets - spent : Math.mulDiv(assets, values[i], totalValue);
            spent += amountIn;
            // ponytail: a slice that rounds to 0 USDG is skipped, not bought; its asset is dust next to the deposit.
            if (amountIn == 0) continue;
            _swap(_assets[i], true, amountIn);
            uint256 added = IERC20(_assets[i]).balanceOf(address(this)) - balances[i];
            shares = Math.min(shares, Math.mulDiv(supply, added, balances[i]));
        }
        require(shares != 0 && shares != type(uint256).max, ZeroAmount());
        require(shares >= minShares, Slippage());
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function _redeem(uint256 shares, address receiver, address owner_, uint256 minAssets)
        internal
        nonReentrant
        returns (uint256 assets)
    {
        require(shares != 0, ZeroAmount());
        if (msg.sender != owner_) _spendAllowance(owner_, msg.sender, shares);
        uint256 supply = totalSupply();
        _burn(owner_, shares);
        assets = _sellSlice(shares, supply, receiver, minAssets);
        emit Withdraw(msg.sender, receiver, owner_, assets, shares);
    }

    /// @dev Sells `shares / supply` of every holding into USDG and pays it to `receiver`.
    function _sellSlice(uint256 shares, uint256 supply, address receiver, uint256 minAssets)
        internal
        returns (uint256 assets)
    {
        for (uint256 i; i < _assets.length; ++i) {
            address a = _assets[i];
            assets += _swap(a, false, Math.mulDiv(IERC20(a).balanceOf(address(this)), shares, supply));
        }
        require(assets >= minAssets, Slippage());
        IERC20(USDG).safeTransfer(receiver, assets);
    }

    /// @dev Swaps `amountIn` USDG into `asset_` (`buy`) or `asset_` into USDG, through its registry route.
    function _swap(address asset_, bool buy, uint256 amountIn) internal returns (uint256 amountOut) {
        if (amountIn == 0) return 0;
        RealmEtfAssets.Route memory route = REGISTRY.routeOf(asset_);
        address tokenIn = buy ? USDG : asset_;
        if (route.venue == RealmEtfAssets.Venue.V3) return _swapV3(route.pool, tokenIn, amountIn);
        if (POOL_MANAGER.isUnlocked()) return _swapV4(route.key, tokenIn, amountIn);
        return abi.decode(POOL_MANAGER.unlock(abi.encode(route.key, tokenIn, amountIn)), (uint256));
    }

    /// @dev Exact-input swap on a V4 pool inside an unlock, settled before returning.
    function _swapV4(PoolKey memory key, address tokenIn, uint256 amountIn) internal returns (uint256 amountOut) {
        bool zeroForOne = Currency.unwrap(key.currency0) == tokenIn;
        BalanceDelta delta = POOL_MANAGER.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        (int128 paid, int128 received) =
            zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        (Currency cIn, Currency cOut) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        POOL_MANAGER.sync(cIn);
        IERC20(tokenIn).safeTransfer(address(POOL_MANAGER), uint256(uint128(-paid)));
        POOL_MANAGER.settle();
        amountOut = uint256(uint128(received));
        POOL_MANAGER.take(cOut, address(this), amountOut);
    }

    function _swapV3(address pool, address tokenIn, uint256 amountIn) internal returns (uint256) {
        bool zeroForOne = tokenIn == IEtfV3Pool(pool).token0();
        _v3Pool = pool;
        (int256 amount0, int256 amount1) = IEtfV3Pool(pool)
            .swap(
                address(this),
                zeroForOne,
                int256(amountIn),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
                abi.encode(tokenIn)
            );
        _v3Pool = address(0);
        return uint256(-(zeroForOne ? amount1 : amount0));
    }

    function _indexOf(address asset_) internal view returns (uint256) {
        for (uint256 i; i < _assets.length; ++i) {
            if (_assets[i] == asset_) return i;
        }
        return type(uint256).max;
    }
}
