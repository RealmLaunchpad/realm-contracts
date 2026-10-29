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
import {SafeCast} from "lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";

import {RealmEtfAssets, IEtfV3Pool, IEtfV2Pair} from "src/etf/RealmEtfAssets.sol";
import {KeeperGated} from "src/tokens/KeeperGated.sol";

/// @title RealmEtf
/// @notice An ETF: an ERC20 share over a set of `RealmEtfAssets`-listed assets. Deposit USDG and it
///         is swapped into every asset; redeem shares and a pro-rata slice of every asset is sold back to
///         USDG. The creator (owner) proposes rebalances within the ETF's immutable `MODE`; a keeper executes them.
///
/// @dev PRO-RATA, ORACLE-FREE MINTING. A deposit buys each asset, and mints `supply x` the SMALLEST
///      fraction it added to any holding. Prices only decide how the USDG is split across assets (spot,
///      from each asset's route pool), so a wrong or manipulated price costs the depositor efficiency,
///      never the other holders: any surplus of the other assets stays in the vault. Every holding is
///      bought, with at least `MIN_SLICE`, so even one priced at ~0 bounds the shares. A redemption takes
///      the same fraction of every holding, so it needs no price at all.
///
/// @dev SEMI-ERC4626 + ERC-5143. `deposit`/`mint`/`redeem` follow ERC-4626, with ERC-5143 overloads that add a
///      slippage bound. `mint` buys each holding's exact pro-rata growth with exact-output swaps. `withdraw` is
///      unsupported (`maxWithdraw` is 0): an exact USDG out cannot be hit pro-rata across pools with different
///      slippage. `totalAssets` and the previews value holdings at their route pools' SPOT prices, before swap
///      fees and price impact: estimates, not the exact amounts ERC-4626 asks of previews.
///
/// @dev REBALANCES ARE INTENTS. The creator queues proposals (sell `sellBps` of one holding, buy another, no
///      `minOut`) and may cancel any pending one; a keeper executes them in order later with no floor, at a time
///      the creator cannot know, so a flash-loaned price push around it is impossible. Partial fills still revert.
///      `MODE` bounds what may be bought.
///
/// @dev SUNSET ASSETS (`REGISTRY.isSunset`) are dead to every path but `redeemInKind`: not bought, sold, valued
///      or rebalanced, and left out of the shares a deposit mints. Their balance stays for in-kind exits, shared
///      by every share, new ones included (`RealmEtfAssets.sunset`).
///
/// @dev EXIT FEE. Every exit (`redeem`, a sell through `RealmEtfHook`, `redeemInKind`) hands `EXIT_FEE_BPS` of
///      the shares to the creator (`owner()`) and redeems only the rest, so NAV per share is unchanged. None
///      while ownership is renounced.
///
/// @dev TWO CALL CONTEXTS. Called directly, each V4 swap unlocks the pool manager itself. Called while the
///      pool manager is already unlocked (by `RealmEtfHook` inside a swap on the shares/USDG pool, or by
///      any router mid-unlock), V4 swaps run inline and settle their own deltas before returning. V2 and V3
///      swaps are direct pool calls either way.
contract RealmEtf is ERC20, Ownable2Step, ReentrancyGuardTransient, IERC4626, IUnlockCallback, KeeperGated {
    using SafeERC20 for IERC20;
    using TransientStateLibrary for IPoolManager;

    /// @notice Most live assets an ETF may hold. Every deposit and redemption swaps through each one; sunset
    ///         assets are never swapped, so they do not count.
    uint256 public constant MAX_ASSETS = 10;

    /// @notice Shares minted to `DEAD` at seeding, so supply never returns to a size rounding can exploit.
    uint256 public constant DEAD_SHARES = 1e15;

    /// @notice Least raw USDG a deposit spends on each holding (0.001 USDG), so a holding whose fair slice
    ///         rounds to 0 is still bought and still bounds the shares. A deposit must cover it for every
    ///         holding.
    uint256 public constant MIN_SLICE = 1_000;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @notice Share of every exit's shares paid to the creator instead of being redeemed (0.05%).
    uint256 public constant EXIT_FEE_BPS = 5;

    uint256 private constant BPS = 10_000;

    /// @notice What the creator may change. `FIXED`: nothing. `REBALANCE`: rebalance among the original assets
    ///         only. `FLEXIBLE`: rebalance into any listed asset.
    enum Mode {
        FIXED,
        REBALANCE,
        FLEXIBLE
    }

    /// @notice A proposed rebalance: sell `sellBps` of the `sellAsset` holding (at execution) for `buyAsset`.
    struct RebalanceIntent {
        address sellAsset;
        uint16 sellBps;
        address buyAsset;
    }

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

    /// @notice What rebalances may do, fixed at creation.
    Mode public immutable MODE;

    /// @notice USDG's decimals: seeding mints one 18-decimal share per whole USDG.
    uint8 private immutable _usdgDecimals;

    /// @notice The assets held, sunset ones included, in `getAssets()` order. At most `MAX_ASSETS` live ones.
    address[] internal _assets;

    /// @notice The assets the ETF was created with: all a `REBALANCE` ETF may ever buy.
    mapping(address asset => bool) public isOriginal;

    /// @notice The creator's proposed rebalances by id, for a keeper to execute in id order. `sellBps == 0`:
    ///         executed, cancelled or never proposed.
    mapping(uint256 id => RebalanceIntent) public rebalances;

    /// @notice The id the next proposal gets.
    uint256 public nextRebalanceId;

    /// @notice The oldest pending rebalance, the only one a keeper may execute. `nextRebalanceId`: none pending.
    uint256 public rebalanceHead;

    /// @dev The V3 pool a swap is in flight on, the only caller its callback accepts, once.
    address private transient _v3Pool;

    /// @dev The token that swap pays in. The callback pays this one, never a token the pool names in `data`.
    address private transient _v3TokenIn;

    /// @dev Most the in-flight V3 swap's callback may take: the exact input, or unbounded for an exact output
    ///      (only `mint` swaps those, paid by the minter, bounded by their approval and `maxAssets`). The registry is upgradeable,
    ///      so a route's "pool" is not trusted to ask only what it is owed.
    uint256 private transient _v3MaxIn;

    /// @dev Who pays the USDG of `mint`'s swaps (pulled per swap); zero: the ETF pays from its balance.
    address private transient _payer;

    event Seeded(address indexed receiver, uint256 assets, uint256 shares);
    event RebalanceProposed(uint256 indexed id, address indexed sellAsset, uint16 sellBps, address indexed buyAsset);
    event RebalanceCancelled(uint256 indexed id);
    event Rebalanced(
        uint256 indexed id, address indexed sellAsset, uint256 sold, address indexed buyAsset, uint256 bought
    );
    /// @notice USDG found in the ETF outside a deposit was spent on the live holdings, minting no shares.
    event Reinvested(uint256 assets);
    event AssetAdded(address indexed asset);
    event AssetRemoved(address indexed asset);
    event RedeemedInKind(address indexed owner, address indexed receiver, uint256 shares);
    /// @notice The redeemer forfeited `asset` (`skipMask`); `amount` stays in the vault for the other holders.
    event InKindForfeited(address indexed asset, uint256 amount);
    /// @notice An exit paid `shares` (of the shares it gave up) to `creator` instead of redeeming them.
    event ExitFeeCharged(address indexed creator, uint256 shares);
    /// @notice The ETF's state after every action that changes holdings or supply, emitted last. `assets` is
    ///         `getAssets()` (sunset ones included), `balances` their raw balances, `usdgValues` their spot USDG
    ///         value (`REGISTRY.usdgValueOf`, 0 for sunset assets), so they sum to `totalAssets`.
    /// @dev Through `RealmEtfHook`, `totalSupply` is the supply once the shares-pool swap settles, but for the
    ///      JIT rounding dust (`docs/etf-jit-math.md`, ~1e-16 of a share): a sell already excludes the sold
    ///      shares, which the hook locks only after the ETF returns, but not the dust the core keeps in
    ///      circulation; an exact-output buy still counts the hook's unused share buffer (at most
    ///      `SHARES_BUFFER` + 1 per 2^40 bought), locked right after. Every later `NavUpdated` reads the
    ///      settled supply.
    event NavUpdated(
        uint256 totalAssets, uint256 totalSupply, address[] assets, uint256[] balances, uint256[] usdgValues
    );

    error OnlyFactory();
    error AlreadySeeded();
    error InvalidAssets();
    error InvalidWeights();
    error AssetNotListed();
    error AssetNotHeld();
    error TooManyAssets();
    error ZeroAmount();
    error Slippage();
    /// @notice A route pool could not take the whole input of a swap.
    error InsufficientLiquidity();
    error NotSupported();
    error Unauthorized();
    /// @notice A `REBALANCE` ETF may only buy the assets it was created with.
    error NotOriginalAsset();
    error NoPendingRebalance();
    /// @notice An older rebalance is still pending: they execute in id order.
    error RebalanceOutOfOrder();

    constructor(
        string memory name_,
        string memory symbol_,
        address creator,
        RealmEtfAssets registry,
        address hook,
        Mode mode,
        address[] memory assets_
    ) ERC20(name_, symbol_) Ownable(creator) {
        FACTORY = msg.sender;
        HOOK = hook;
        REGISTRY = registry;
        POOL_MANAGER = registry.POOL_MANAGER();
        USDG = registry.USDG();
        _usdgDecimals = IERC20Metadata(USDG).decimals();
        MODE = mode;

        require(assets_.length != 0 && assets_.length <= MAX_ASSETS, InvalidAssets());
        for (uint256 i; i < assets_.length; ++i) {
            require(registry.isListed(assets_[i]) && !registry.isSunset(assets_[i]), AssetNotListed());
            for (uint256 j; j < i; ++j) {
                require(assets_[j] != assets_[i], InvalidAssets());
            }
            _assets.push(assets_[i]);
            isOriginal[assets_[i]] = true;
        }
    }

    //////////////////////// seeding //////////////////////

    /// @notice First deposit, split by `weightsBps` (no holdings to go pro-rata on yet). One share per
    ///         whole USDG; `DEAD_SHARES` of them go to `DEAD`. Factory only, once. Reverts if any asset's buy
    ///         gets less than its `minAmountsOut` entry (same order as `getAssets()`): the share count is fixed,
    ///         so the amounts bought are what slippage cuts.
    /// @dev The factory has already sent `assets` USDG here.
    function seed(uint256 assets, uint16[] calldata weightsBps, address receiver, uint256[] calldata minAmountsOut)
        external
        nonReentrant
        returns (uint256 shares)
    {
        require(msg.sender == FACTORY, OnlyFactory());
        require(totalSupply() == 0, AlreadySeeded());
        uint256 n = _assets.length;
        require(weightsBps.length == n && minAmountsOut.length == n, InvalidWeights());

        uint256 sum;
        uint256 spent;
        for (uint256 i; i < n; ++i) {
            require(weightsBps[i] != 0, InvalidWeights());
            sum += weightsBps[i];
            uint256 amountIn = i == n - 1 ? assets - spent : assets * weightsBps[i] / BPS;
            spent += amountIn;
            uint256 bought = _swap(_assets[i], true, amountIn);
            require(bought != 0, ZeroAmount());
            require(bought >= minAmountsOut[i], Slippage());
        }
        require(sum == BPS, InvalidWeights());

        uint256 total = assets * 10 ** (decimals() - _usdgDecimals);
        require(total > DEAD_SHARES, ZeroAmount());
        shares = total - DEAD_SHARES;
        _mint(DEAD, DEAD_SHARES);
        _mint(receiver, shares);
        emit Seeded(receiver, assets, shares);
        _emitNav(totalSupply());
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

    /// @notice Live (not sunset) holdings valued in USDG at their route pools' spot prices. An estimate:
    ///         selling them would pay swap fees and price impact.
    function totalAssets() public view returns (uint256 total) {
        for (uint256 i; i < _assets.length; ++i) {
            total += REGISTRY.usdgValueOf(_assets[i], _balanceOrZero(_assets[i]));
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
        return type(uint256).max;
    }

    /// @notice Estimate only: the spot value of the exact amounts `mint` buys (see `totalAssets`), before
    ///         swap fees and price impact, so the real cost is higher.
    function previewMint(uint256 shares) external view returns (uint256 assets) {
        uint256 supply = totalSupply();
        // Sunset assets value at 0, as `mint` does not buy them.
        for (uint256 i; i < _assets.length; ++i) {
            address a = _assets[i];
            uint256 out = Math.mulDiv(shares, _balanceOrZero(a), supply, Math.Rounding.Ceil);
            assets += REGISTRY.usdgValueOf(a, out);
        }
    }

    function mint(uint256 shares, address receiver) external returns (uint256) {
        return _mintExact(shares, receiver, type(uint256).max);
    }

    /// @notice ERC-5143: `mint` that reverts above `maxAssets`.
    function mint(uint256 shares, address receiver, uint256 maxAssets) external returns (uint256) {
        return _mintExact(shares, receiver, maxAssets);
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

    /// @notice Estimate only (see `totalAssets`). Net of the exit fee.
    function previewRedeem(uint256 shares) external view returns (uint256) {
        (, uint256 fee) = _exitFee(shares);
        return convertToAssets(shares - fee);
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
        uint256 supply = totalSupply();
        // The hook locks all `shares`, so the fee is minted: the supply still drops by exactly what is sold.
        (address creator, uint256 fee) = _exitFee(shares);
        if (fee != 0) {
            _mint(creator, fee);
            emit ExitFeeCharged(creator, fee);
        }
        assets = _sellSlice(shares - fee, supply, receiver, 0);
        emit Withdraw(msg.sender, receiver, msg.sender, assets, shares);
        // The sold shares still count until the hook locks them, after this returns.
        _emitNav(totalSupply() - shares);
    }

    /// @notice The exit that needs no pool: burns `shares` and sends their pro-rata slice of every asset,
    ///         sunset ones included. Reverts if any transfer fails (a paused or blacklisting token).
    function redeemInKind(uint256 shares, address receiver, address owner_) external returns (uint256[] memory) {
        return _redeemInKind(shares, receiver, owner_, 0);
    }

    /// @notice `redeemInKind` that FORFEITS the assets whose `getAssets()` index bit is set in `skipMask`: their
    ///         slice is not sent and stays in the vault for the remaining holders. The way out past a token that
    ///         cannot be transferred; check `getAssets()` first, a rebalance can reorder it.
    function redeemInKind(uint256 shares, address receiver, address owner_, uint256 skipMask)
        external
        returns (uint256[] memory)
    {
        return _redeemInKind(shares, receiver, owner_, skipMask);
    }

    //////////////////////// rebalances //////////////////////

    /// @notice Creator only: queues selling `sellBps` (of 10,000) of the `sellAsset` holding, as it stands at
    ///         execution, for `buyAsset`, through USDG. `sellAsset` need only be held by then, so a proposal may
    ///         sell what an earlier one buys. Keepers execute the queue in id order.
    function proposeRebalance(address sellAsset, uint16 sellBps, address buyAsset)
        external
        onlyOwner
        returns (uint256 id)
    {
        require(sellBps != 0 && sellBps <= BPS, InvalidWeights());
        _checkRebalance(sellAsset, buyAsset);
        id = nextRebalanceId++;
        rebalances[id] = RebalanceIntent(sellAsset, sellBps, buyAsset);
        emit RebalanceProposed(id, sellAsset, sellBps, buyAsset);
    }

    /// @notice Creator only: drops pending proposal `id`.
    function cancelRebalance(uint256 id) external onlyOwner {
        require(rebalances[id].sellBps != 0, NoPendingRebalance());
        delete rebalances[id];
        emit RebalanceCancelled(id);
        _advanceRebalanceHead();
    }

    /// @notice Keepers only: executes pending proposal `id`, which must be the oldest (`rebalanceHead`), with no
    ///         `minOut` (when to call, and whether the price impact is acceptable, is keeper policy). Proposals
    ///         never change, so the id binds the intent the keeper vetted. Buying an asset not yet held adds it;
    ///         selling all of one removes it. Reverts if nothing of `buyAsset` is bought: a held asset with a zero
    ///         balance would make every deposit divide by zero.
    function executeRebalance(uint256 id) external nonReentrant returns (uint256 bought) {
        _requireKeeper();
        RebalanceIntent memory intent = rebalances[id];
        require(intent.sellBps != 0, NoPendingRebalance());
        require(id == rebalanceHead, RebalanceOutOfOrder());
        delete rebalances[id];
        _advanceRebalanceHead();
        (address sellAsset, address buyAsset) = (intent.sellAsset, intent.buyAsset);
        uint256 sellIndex = _checkRebalance(sellAsset, buyAsset);
        require(sellIndex != type(uint256).max, AssetNotHeld());
        uint256 balance = IERC20(sellAsset).balanceOf(address(this));
        uint256 sellAmount = Math.mulDiv(balance, intent.sellBps, BPS);
        require(sellAmount != 0, ZeroAmount());

        if (sellAmount == balance) {
            _assets[sellIndex] = _assets[_assets.length - 1];
            _assets.pop();
            emit AssetRemoved(sellAsset);
        }
        if (_indexOf(buyAsset) == type(uint256).max) {
            require(_liveAssets().length < MAX_ASSETS, TooManyAssets());
            _assets.push(buyAsset);
            emit AssetAdded(buyAsset);
        }

        uint256 usdg = _swap(sellAsset, false, sellAmount);
        uint256 before = IERC20(buyAsset).balanceOf(address(this));
        _swap(buyAsset, true, usdg);
        bought = IERC20(buyAsset).balanceOf(address(this)) - before;
        require(bought != 0, ZeroAmount());
        emit Rebalanced(id, sellAsset, sellAmount, buyAsset, bought);
        _emitNav(totalSupply());
    }

    /// @notice Keepers only: spends all USDG in the ETF (cash payouts, airdrops: whatever arrived outside a
    ///         deposit) on the live holdings, split by value, minting no shares, so it accrues to holders.
    /// @dev Keeper-gated for the reason rebalances are: it trades the holders' USDG with no floor, so a public
    ///      caller could push a pool, reinvest into it and unwind in one transaction. No minimum amount: no
    ///      shares are minted, so a holding whose slice rounds to 0 is simply not bought.
    function reinvest() external nonReentrant returns (uint256 assets) {
        _requireKeeper();
        assets = IERC20(USDG).balanceOf(address(this));
        _buyProRata(_liveAssets(), assets, 0);
        emit Reinvested(assets);
        _emitNav(totalSupply());
    }

    /// @notice The assets currently held.
    function getAssets() external view returns (address[] memory) {
        return _assets;
    }

    //////////////////////// swap callbacks //////////////////////

    /// @dev A V4 swap started by `_swap` outside an unlock.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(POOL_MANAGER), Unauthorized());
        (PoolKey memory key, address tokenIn, int256 amountSpecified) = abi.decode(data, (PoolKey, address, int256));
        (uint256 amountIn, uint256 amountOut) = _swapV4(key, tokenIn, amountSpecified);
        return abi.encode(amountIn, amountOut);
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        require(msg.sender == _v3Pool, Unauthorized());
        _v3Pool = address(0);
        uint256 owed = uint256(amount0Delta > 0 ? amount0Delta : amount1Delta);
        require(owed <= _v3MaxIn, Unauthorized());
        _pay(_v3TokenIn, msg.sender, owed);
    }

    //////////////////////// internals //////////////////////

    function _deposit(uint256 assets, address receiver, uint256 minShares)
        internal
        nonReentrant
        returns (uint256 shares)
    {
        address[] memory live = _liveAssets();
        require(assets >= live.length * MIN_SLICE, ZeroAmount());
        IERC20(USDG).safeTransferFrom(msg.sender, address(this), assets);

        uint256 supply = totalSupply();
        // Each holding gets MIN_SLICE plus its value share of the rest. A holding skipped for a 0 slice would
        // come free to the depositor, and its price can be pushed to ~0 within the transaction; bought at
        // that price instead, it is paid for in kind by whoever crashed it. Honest dust costs MIN_SLICE.
        uint256[] memory balances = _buyProRata(live, assets, MIN_SLICE);
        shares = type(uint256).max;
        for (uint256 i; i < live.length; ++i) {
            uint256 added = IERC20(live[i]).balanceOf(address(this)) - balances[i];
            shares = Math.min(shares, Math.mulDiv(supply, added, balances[i]));
        }
        require(shares != 0 && shares != type(uint256).max, ZeroAmount());
        require(shares >= minShares, Slippage());
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
        _emitNav(totalSupply());
    }

    /// @dev Buys `ceil(shares * balance / supply)` of every live holding with exact-output swaps paid by the
    ///      caller, so each grows by at least the fraction of supply minted. The USDG paid is the sum.
    function _mintExact(uint256 shares, address receiver, uint256 maxAssets)
        internal
        nonReentrant
        returns (uint256 assets)
    {
        require(shares != 0, ZeroAmount());
        // Every asset sunset: nothing to buy, so the shares cost 0 USDG and redeem the sunset balances in
        // kind. Accepted, the sunset leak of docs/etf-design-decisions.md: sunset is for tokens that no
        // longer move, and one that does was the owner's call. The ETF is also a whitelisted launch quote,
        // so free shares can buy out its token/ETF pools: also accepted, the owner's call too.
        address[] memory live = _liveAssets();
        uint256 supply = totalSupply();
        _payer = msg.sender;
        for (uint256 i; i < live.length; ++i) {
            uint256 out = Math.mulDiv(shares, IERC20(live[i]).balanceOf(address(this)), supply, Math.Rounding.Ceil);
            // Checked cast: a plain `int256(out)` wraps an `out` >= 2^255 into a tiny exact INPUT, which
            // would mint `shares` for a few raw USDG.
            (uint256 paid,) = _trade(live[i], true, SafeCast.toInt256(out));
            assets += paid;
        }
        _payer = address(0);
        require(assets <= maxAssets, Slippage());
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
        _emitNav(totalSupply());
    }

    function _redeem(uint256 shares, address receiver, address owner_, uint256 minAssets)
        internal
        nonReentrant
        returns (uint256 assets)
    {
        require(shares != 0, ZeroAmount());
        if (msg.sender != owner_) _spendAllowance(owner_, msg.sender, shares);
        uint256 supply = totalSupply();
        uint256 net = _burnNetOfExitFee(owner_, shares);
        assets = _sellSlice(net, supply, receiver, minAssets);
        emit Withdraw(msg.sender, receiver, owner_, assets, shares);
        _emitNav(totalSupply());
    }

    function _redeemInKind(uint256 shares, address receiver, address owner_, uint256 skipMask)
        internal
        nonReentrant
        returns (uint256[] memory amounts)
    {
        require(shares != 0, ZeroAmount());
        if (msg.sender != owner_) _spendAllowance(owner_, msg.sender, shares);
        uint256 supply = totalSupply();
        uint256 net = _burnNetOfExitFee(owner_, shares);
        uint256 n = _assets.length;
        amounts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            IERC20 a = IERC20(_assets[i]);
            if ((skipMask >> i) & 1 == 1) {
                // A forfeited token may be dead: its balance is read without reverting.
                emit InKindForfeited(address(a), Math.mulDiv(_balanceOrZero(address(a)), net, supply));
            } else {
                uint256 amount = Math.mulDiv(a.balanceOf(address(this)), net, supply);
                a.safeTransfer(receiver, amount);
                amounts[i] = amount;
            }
        }
        emit RedeemedInKind(owner_, receiver, shares);
        _emitNav(totalSupply());
    }

    /// @dev The exit fee on `shares` and who gets it: none while ownership is renounced.
    function _exitFee(uint256 shares) internal view returns (address creator, uint256 fee) {
        creator = owner();
        if (creator != address(0)) fee = shares * EXIT_FEE_BPS / BPS;
    }

    /// @dev Moves the exit fee from `owner_` to the creator and burns the rest, which it returns.
    function _burnNetOfExitFee(address owner_, uint256 shares) internal returns (uint256 net) {
        (address creator, uint256 fee) = _exitFee(shares);
        if (fee != 0) {
            _transfer(owner_, creator, fee);
            emit ExitFeeCharged(creator, fee);
        }
        net = shares - fee;
        _burn(owner_, net);
    }

    /// @dev Sells `shares / supply` of every live holding into USDG and pays it to `receiver`.
    function _sellSlice(uint256 shares, uint256 supply, address receiver, uint256 minAssets)
        internal
        returns (uint256 assets)
    {
        address[] memory live = _liveAssets();
        for (uint256 i; i < live.length; ++i) {
            address a = live[i];
            assets += _swap(a, false, Math.mulDiv(IERC20(a).balanceOf(address(this)), shares, supply));
        }
        require(assets >= minAssets, Slippage());
        IERC20(USDG).safeTransfer(receiver, assets);
    }

    /// @dev Splits `assets` USDG over `live`: `minSlice` each plus its value share of the rest, and buys.
    ///      Returns the balances before.
    function _buyProRata(address[] memory live, uint256 assets, uint256 minSlice)
        internal
        returns (uint256[] memory balances)
    {
        uint256 n = live.length;
        balances = new uint256[](n);
        uint256[] memory values = new uint256[](n);
        uint256 totalValue;
        for (uint256 i; i < n; ++i) {
            balances[i] = IERC20(live[i]).balanceOf(address(this));
            values[i] = REGISTRY.usdgValueOf(live[i], balances[i]);
            totalValue += values[i];
        }
        uint256 budget = assets - n * minSlice;
        uint256 spent;
        for (uint256 i; i < n; ++i) {
            // Every holding valued at 0 (dust at prices that round it down): split evenly.
            uint256 share = totalValue == 0 ? budget / n : Math.mulDiv(budget, values[i], totalValue);
            uint256 amountIn = i == n - 1 ? assets - spent : minSlice + share;
            spent += amountIn;
            _swap(live[i], true, amountIn);
        }
    }

    /// @dev Exact-input swap of `amountIn` USDG into `asset_` (`buy`) or `asset_` into USDG.
    function _swap(address asset_, bool buy, uint256 amountIn) internal returns (uint256 amountOut) {
        if (amountIn == 0) return 0;
        (, amountOut) = _trade(asset_, buy, -SafeCast.toInt256(amountIn));
    }

    /// @dev Swaps USDG into `asset_` (`buy`) or `asset_` into USDG through its registry route. `amountSpecified`
    ///      follows V4: negative is an exact input, positive an exact output. Reverts unless the pool fills it
    ///      whole: a partial fill (no price limit) would leave the rest of an input in the vault, uncounted, or
    ///      buy less than `mint` needs.
    function _trade(address asset_, bool buy, int256 amountSpecified)
        internal
        returns (uint256 amountIn, uint256 amountOut)
    {
        RealmEtfAssets.Route memory route = REGISTRY.routeOf(asset_);
        address tokenIn = buy ? USDG : asset_;
        // V2 and V3 sort a pool's two tokens by address.
        bool zeroForOne = buy == (USDG < asset_);
        if (route.venue == RealmEtfAssets.Venue.V3) {
            (amountIn, amountOut) = _swapV3(route.pool, tokenIn, zeroForOne, amountSpecified);
        } else if (route.venue == RealmEtfAssets.Venue.V2) {
            (amountIn, amountOut) = _swapV2(route.pool, tokenIn, zeroForOne, amountSpecified);
        } else if (POOL_MANAGER.isUnlocked()) {
            (amountIn, amountOut) = _swapV4(route.key, tokenIn, amountSpecified);
        } else {
            (amountIn, amountOut) =
                abi.decode(POOL_MANAGER.unlock(abi.encode(route.key, tokenIn, amountSpecified)), (uint256, uint256));
        }
        require(
            amountSpecified < 0 ? amountIn == uint256(-amountSpecified) : amountOut == uint256(amountSpecified),
            InsufficientLiquidity()
        );
    }

    /// @dev Swap on a V4 pool inside an unlock, settled before returning.
    function _swapV4(PoolKey memory key, address tokenIn, int256 amountSpecified)
        internal
        returns (uint256 amountIn, uint256 amountOut)
    {
        bool zeroForOne = Currency.unwrap(key.currency0) == tokenIn;
        BalanceDelta delta = POOL_MANAGER.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        (int128 paid, int128 received) =
            zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        (Currency cIn, Currency cOut) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        amountIn = uint256(uint128(-paid));
        amountOut = uint256(uint128(received));
        POOL_MANAGER.sync(cIn);
        _pay(tokenIn, address(POOL_MANAGER), amountIn);
        POOL_MANAGER.settle();
        POOL_MANAGER.take(cOut, address(this), amountOut);
    }

    function _swapV3(address pool, address tokenIn, bool zeroForOne, int256 amountSpecified)
        internal
        returns (uint256 amountIn, uint256 amountOut)
    {
        (_v3Pool, _v3TokenIn) = (pool, tokenIn);
        _v3MaxIn = amountSpecified < 0 ? uint256(-amountSpecified) : type(uint256).max;
        // V3's sign is the opposite of V4's: positive is an exact input.
        (int256 amount0, int256 amount1) = IEtfV3Pool(pool)
            .swap(
                address(this),
                zeroForOne,
                -amountSpecified,
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
                ""
            );
        _v3Pool = address(0);
        (int256 paid, int256 received) = zeroForOne ? (amount0, amount1) : (amount1, amount0);
        return (uint256(paid), uint256(-received));
    }

    /// @dev Amounts from the reserves with Uniswap V2's 0.3% fee, as its router computes them.
    function _swapV2(address pair, address tokenIn, bool zeroForOne, int256 amountSpecified)
        internal
        returns (uint256 amountIn, uint256 amountOut)
    {
        (uint256 r0, uint256 r1,) = IEtfV2Pair(pair).getReserves();
        (uint256 rIn, uint256 rOut) = zeroForOne ? (r0, r1) : (r1, r0);
        if (amountSpecified < 0) {
            amountIn = uint256(-amountSpecified);
            amountOut = amountIn * 997 * rOut / (rIn * 1000 + amountIn * 997);
        } else {
            amountOut = uint256(amountSpecified);
            require(amountOut < rOut, InsufficientLiquidity());
            amountIn = rIn * amountOut * 1000 / ((rOut - amountOut) * 997) + 1;
        }
        _pay(tokenIn, pair, amountIn);
        // The pair rejects a zero-out swap; a dust input that buys nothing is left to it, as V3's fee would take it.
        if (amountOut != 0) {
            IEtfV2Pair(pair).swap(zeroForOne ? 0 : amountOut, zeroForOne ? amountOut : 0, address(this), "");
        }
    }

    /// @dev Pays a swap's input: pulled from `_payer` during `mint`, from the ETF's balance otherwise.
    function _pay(address token, address to, uint256 amount) internal {
        if (_payer == address(0)) IERC20(token).safeTransfer(to, amount);
        else IERC20(token).safeTransferFrom(_payer, to, amount);
    }

    /// @dev Emits `NavUpdated` with `supply` as the share supply. Values like `totalAssets` (sunset: 0).
    function _emitNav(uint256 supply) private {
        address[] memory assets_ = _assets;
        uint256 n = assets_.length;
        uint256[] memory balances = new uint256[](n);
        uint256[] memory values = new uint256[](n);
        uint256 total;
        for (uint256 i; i < n; ++i) {
            balances[i] = _balanceOrZero(assets_[i]);
            values[i] = REGISTRY.usdgValueOf(assets_[i], balances[i]);
            total += values[i];
        }
        emit NavUpdated(total, supply, assets_, balances, values);
    }

    /// @dev The ETF's balance of `asset`, 0 if the call fails: a dead sunset token (reverting, or no code) must not
    ///      brick the NAV and preview reads every path runs. Swaps and transfers read balances strictly.
    function _balanceOrZero(address asset_) private view returns (uint256) {
        (bool ok, bytes memory data) = asset_.staticcall(abi.encodeCall(IERC20.balanceOf, (address(this))));
        return ok && data.length >= 32 ? abi.decode(data, (uint256)) : 0;
    }

    /// @dev The held assets that are not sunset.
    function _liveAssets() internal view returns (address[] memory live) {
        uint256 n = _assets.length;
        live = new address[](n);
        uint256 count;
        for (uint256 i; i < n; ++i) {
            if (!REGISTRY.isSunset(_assets[i])) live[count++] = _assets[i];
        }
        assembly {
            mstore(live, count)
        }
    }

    /// @dev Moves `rebalanceHead` past executed and cancelled proposals. A creator who cancels many queued
    ///      behind a pending one makes the keeper's next execution skip them all (one SLOAD each).
    function _advanceRebalanceHead() private {
        uint256 head = rebalanceHead;
        uint256 next = nextRebalanceId;
        while (head < next && rebalances[head].sellBps == 0) {
            ++head;
        }
        rebalanceHead = head;
    }

    /// @dev The rebalance checks, run at proposal and again at execution. Returns `sellAsset`'s index, `max` if
    ///      not held (allowed at proposal: an earlier proposal may buy it).
    function _checkRebalance(address sellAsset, address buyAsset) internal view returns (uint256 sellIndex) {
        require(MODE != Mode.FIXED, NotSupported());
        sellIndex = _indexOf(sellAsset);
        require(
            buyAsset != sellAsset && REGISTRY.isListed(buyAsset) && !REGISTRY.isSunset(buyAsset)
                && !REGISTRY.isSunset(sellAsset),
            AssetNotListed()
        );
        require(MODE == Mode.FLEXIBLE || isOriginal[buyAsset], NotOriginalAsset());
    }

    function _indexOf(address asset_) internal view returns (uint256) {
        for (uint256 i; i < _assets.length; ++i) {
            if (_assets[i] == asset_) return i;
        }
        return type(uint256).max;
    }
}
