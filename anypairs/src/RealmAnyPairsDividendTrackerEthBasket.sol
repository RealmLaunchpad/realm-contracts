// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {RealmAnyPairsRouteLib} from "./RealmAnyPairsRouteLib.sol";

/// @dev Prefixed names avoid colliding with the file-level interfaces of the other trackers when both are imported.
interface IEBExttload {
    function exttload(bytes32 slot) external view returns (bytes32);
}

interface IEBV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface IEBV3Pool {
    function liquidity() external view returns (uint128);
}

interface IEBSwapRouter02 {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

interface IEBWETH9 {
    function deposit() external payable;
}

/**
 * @title RealmAnyPairsDividendTrackerEthBasket
 * @notice Holder rewards for a native-ETH-paired coin, claimable as a weighted basket of assets.
 * @dev Accrual, feed and push follow {RealmAnyPairsDividendTracker}: the hook calls `feed{value:}` and {process}
 *      pushes raw ETH, never swapping. Claims follow {RealmAnyPairsDividendTrackerBasket} with WETH as the quote:
 *      each non-WETH leg wraps its share and swaps it to the holder under a per-leg gas cap and the holder's
 *      min-out; a WETH leg is paid as native ETH. Claims refuse to run inside a V4 unlock.
 *      `_spend` runs right before the wrap inside the capped leg frame, so `reserve` and the native balance move
 *      together and a reentrant {feed} can only book value it actually brings.
 *      No `claim()` by design: the reflexive call must not accept any fill. Immutable, no owner, no drain.
 */
contract RealmAnyPairsDividendTrackerEthBasket {
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    uint256 internal constant MAGNITUDE = 2 ** 128;
    uint16 internal constant BPS = 10000;
    /// @dev Bounds the swaps in one claim on an immutable basket.
    uint256 internal constant MAX_LEGS = 10;
    /// @dev Gas forwarded to one leg's wrap+swap, so a griefed pool fails only its own leg. Sized for a single hop.
    uint256 internal constant LEG_GAS_CAP = 450_000;
    /// @dev Gas forwarded to one raw-ETH push.
    uint256 internal constant PUSH_GAS = 60_000;
    uint256 internal constant MAX_MIN_ELIGIBLE_MULTIPLE = 1e2;
    bytes32 internal constant V4_IS_UNLOCKED_SLOT = 0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23;

    address public immutable token;
    address public immutable feeder;
    /// @notice The chain's WETH9. Non-WETH legs swap from it; a WETH leg is paid as native ETH.
    address public immutable weth;
    address public immutable swapRouter;
    address public immutable v3Factory;
    address public immutable poolManager;
    /// @notice Immutable dust/overflow floor: gates reward booking and is the lowest settable {minEligible}.
    uint256 public immutable minEligibleFloor;
    uint256 public immutable legCount;
    uint256 public minEligible;

    mapping(uint256 => address) private _legAsset;
    mapping(uint256 => uint16) private _legBps;
    /// @dev Set only across this contract's own V4 unlock, so {unlockCallback} runs on nothing else.
    bool private transient _v4Swapping;

    uint256 public magnifiedRewardPerShare;
    uint256 public eligibleSupply;
    uint256 public totalDistributed;
    /// @dev Income buffered while eligible supply is below {minEligibleFloor}. Unrecoverable if supply never returns.
    uint256 public pending;
    /// @notice Native ETH already accounted for; any balance above it is unbooked income.
    uint256 public reserve;

    mapping(address => uint256) public trackedBalance;
    mapping(address => int256) internal magnifiedCorrections;
    mapping(address => uint256) public withdrawnRewards;
    mapping(address => bool) public excluded;

    address[] private _holders;
    mapping(address => uint256) private _holderIdx1;
    uint256 public lastProcessedIndex;

    uint256 private _entered = 1;

    event RewardsDistributed(uint256 amount, uint256 perShare);
    event RewardShortfall(uint256 reserve, uint256 balance);
    event ReserveUnderrun(uint256 reserve, uint256 amount);
    /// @notice `asset == address(0)` means native ETH (a push, a WETH leg, or a raw-ETH fallback).
    event RewardClaimed(address indexed account, address indexed asset, uint256 amount);
    event LegSwapFailed(address indexed account, address indexed asset, uint256 ethAmount);
    event LegPaymentFailed(address indexed account, address indexed asset, uint256 ethAmount);
    /// @notice The auto-push could not pay `account`; the accrual stays claimable.
    event PushPaymentFailed(address indexed account, uint256 amount);
    event MinEligibleSet(uint256 oldValue, uint256 newValue);

    error OnlyToken();
    error OnlySelf();
    error OnlyFeeder();
    error EthTransferFailed();
    error Reentrancy();
    error NothingToClaim();
    error ZeroRecipient();
    error BadBasket();
    error NoRouteFound();
    error BadMinOuts();
    error BadRoutes();
    error InsufficientGasForLeg();
    error LegMinOutUnmet();
    error RealizedBelowMinOut();
    /// @dev The router left some of this leg's WETH unspent (a partial fill against an exhausted pool).
    error PartialFill();
    error NotDuringSwap();
    error NotCreator();
    error MinEligibleBelowFloor();
    error MinEligibleTooHigh();

    modifier onlyToken() {
        if (msg.sender != token) {
            revert OnlyToken();
        }
        _;
    }
    modifier onlyFeeder() {
        if (msg.sender != feeder) {
            revert OnlyFeeder();
        }
        _;
    }
    modifier nonReentrant() {
        if (_entered == 2) {
            revert Reentrancy();
        }
        _entered = 2;
        _;
        _entered = 1;
    }

    struct Leg {
        address asset;
        uint16 bps;
    }

    struct Config {
        address token;
        address feeder;
        address weth;
        address swapRouter;
        address v3Factory; // required unless every leg is WETH
        address poolManager; // zero disables V4 lock gating
        uint256 minEligible;
        address[] excluded;
        Leg[] basket;
    }

    constructor(Config memory c) {
        if (c.weth == address(0)) {
            revert BadBasket();
        }
        token = c.token;
        feeder = c.feeder;
        weth = c.weth;
        swapRouter = c.swapRouter;
        v3Factory = c.v3Factory;
        poolManager = c.poolManager;
        uint256 me_ = c.minEligible == 0 ? 1 : c.minEligible;
        minEligibleFloor = me_;
        minEligible = me_;
        for (uint256 i; i < c.excluded.length; ++i) {
            excluded[c.excluded[i]] = true;
        }
        excluded[c.token] = true;
        excluded[address(this)] = true;
        excluded[address(0)] = true;
        excluded[c.feeder] = true;
        if (c.swapRouter != address(0)) {
            excluded[c.swapRouter] = true; // router dust must not accrue rewards
        }

        uint256 n = c.basket.length;
        if (n == 0 || n > MAX_LEGS) {
            revert BadBasket();
        }
        uint256 sumBps;
        for (uint256 i; i < n; ++i) {
            Leg memory leg = c.basket[i];
            if (leg.asset == address(0) || leg.bps == 0) {
                revert BadBasket();
            }
            sumBps += leg.bps;
            _legAsset[i] = leg.asset;
            _legBps[i] = leg.bps;
        }
        if (sumBps != BPS) {
            revert BadBasket();
        }
        legCount = n;
    }

    function basketLeg(uint256 i) external view returns (address asset, uint16 bps, bytes memory path) {
        asset = _legAsset[i];
        bps = _legBps[i];
        // The route a conversion would take right now (empty for the WETH leg or when none exists).
        if (asset != weth) {
            path = RealmAnyPairsRouteLib.encode(
                RealmAnyPairsRouteLib.best(
                    swapRouter == address(0) ? address(0) : v3Factory, poolManager, weth, true, asset
                ),
                asset
            );
        }
    }

    // ─────────────────────────── balance mirror (token-driven) ───────────────────────────

    function balanceSyncGas() external pure returns (uint256) {
        return 230_000;
    }

    function setBalance(address account, uint256 newBalance) external onlyToken {
        if (excluded[account]) {
            newBalance = 0;
        }
        _applyBalance(account, newBalance);
    }

    function _applyBalance(address account, uint256 newBalance) internal {
        uint256 old = trackedBalance[account];
        if (newBalance == old) {
            return;
        }
        if (newBalance > old) {
            uint256 add = newBalance - old;
            eligibleSupply += add;
            magnifiedCorrections[account] -= (magnifiedRewardPerShare * add).toInt256();
        } else {
            uint256 sub = old - newBalance;
            eligibleSupply -= sub;
            magnifiedCorrections[account] += (magnifiedRewardPerShare * sub).toInt256();
        }
        trackedBalance[account] = newBalance;
        uint256 idx1 = _holderIdx1[account];
        if (newBalance < minEligible) {
            if (idx1 != 0) {
                _removeHolder(account, idx1);
            }
        } else if (idx1 == 0) {
            _holders.push(account);
            _holderIdx1[account] = _holders.length;
        }
    }

    function syncBalance(address account) external nonReentrant {
        _syncBalance(account);
    }

    function syncBalances(address[] calldata accounts) external nonReentrant {
        for (uint256 i; i < accounts.length; ++i) {
            _syncBalance(accounts[i]);
        }
    }

    /// @dev Low-level staticcall so a failed or short return skips the repair. Uncapped because `token` is the
    /// immutable launcher-deployed coin.
    function _syncBalance(address account) internal {
        if (excluded[account]) {
            if (trackedBalance[account] != 0) {
                _applyBalance(account, 0);
            }
            return;
        }
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSelector(0x70a08231, account));
        if (!ok || ret.length < 32) {
            return;
        }
        uint256 real = abi.decode(ret, (uint256));
        if (real != trackedBalance[account]) {
            _applyBalance(account, real);
        }
    }

    function _removeHolder(address account, uint256 idx1) private {
        uint256 last = _holders.length;
        if (idx1 != last) {
            address moved = _holders[last - 1];
            _holders[idx1 - 1] = moved;
            _holderIdx1[moved] = idx1;
        }
        _holders.pop();
        _holderIdx1[account] = 0;
    }

    function holderCount() external view returns (uint256) {
        return _holders.length;
    }

    /// @notice Creator-only: set the auto-push eligibility floor, between {minEligibleFloor} and 100x it, and not
    /// above {eligibleSupply}. Affects only ring membership, never accrual.
    function setMinEligible(uint256 newMinEligible) external {
        if (msg.sender != _tokenCreator()) {
            revert NotCreator();
        }
        if (newMinEligible < minEligibleFloor) {
            revert MinEligibleBelowFloor();
        }
        if (newMinEligible > minEligibleFloor * MAX_MIN_ELIGIBLE_MULTIPLE) {
            revert MinEligibleTooHigh();
        }
        if (newMinEligible > eligibleSupply) {
            revert MinEligibleTooHigh();
        }
        emit MinEligibleSet(minEligible, newMinEligible);
        minEligible = newMinEligible;
    }

    function _tokenCreator() internal view returns (address c) {
        (bool hok, bytes memory hret) =
            feeder.staticcall{gas: 50_000}(abi.encodeWithSignature("creatorOfCoin(address)", token));
        if (hok && hret.length >= 32) {
            c = abi.decode(hret, (address));
            if (c == address(0)) {
                revert NotCreator();
            }
            return c;
        }
        (bool ok, bytes memory ret) = token.staticcall{gas: 20_000}(abi.encodeWithSelector(0x02d05d3f));
        if (!ok || ret.length < 32) {
            revert NotCreator();
        }
        c = abi.decode(ret, (address));
        if (c == address(0)) {
            revert NotCreator();
        }
    }

    function _v4LockHeld() internal view returns (bool) {
        address pm = poolManager;
        if (pm == address(0)) {
            return false;
        }
        return IEBExttload(pm).exttload(V4_IS_UNLOCKED_SLOT) != bytes32(0);
    }

    // ─────────────────────────── feeding ───────────────────────────

    function pokePending() external nonReentrant {
        if (pending != 0 && eligibleSupply >= minEligibleFloor) {
            uint256 p = pending;
            pending = 0;
            _book(p);
        }
    }

    function sync() public nonReentrant {
        _sync();
    }

    function _sync() internal {
        uint256 bal = address(this).balance;
        if (bal <= reserve) {
            if (bal < reserve) {
                emit RewardShortfall(reserve, bal);
            }
            return;
        }
        uint256 delta = bal - reserve;
        reserve = bal;
        _receive(delta);
    }

    function _spend(uint256 amount) internal {
        uint256 r = reserve;
        if (r >= amount) {
            reserve = r - amount;
            return;
        }
        emit ReserveUnderrun(r, amount);
        reserve = 0;
    }

    /// @notice The hook's native rewards entry; books the measured ETH increase.
    /// @dev Deliberately NOT nonReentrant: a guard would turn a reentrant feed during a payout into the hook's catch
    /// and lose the slice. Safe because every leg `_spend`s right before its wrap.
    function feed() external payable onlyFeeder {
        _sync();
    }

    function _receive(uint256 amount) internal {
        if (amount == 0) {
            return;
        }
        if (eligibleSupply < minEligibleFloor) {
            pending += amount;
            return;
        }
        if (pending != 0) {
            uint256 p = pending;
            pending = 0;
            _book(p);
        }
        _book(amount);
    }

    function _book(uint256 amount) internal {
        magnifiedRewardPerShare += (amount * MAGNITUDE) / eligibleSupply;
        totalDistributed += amount;
        emit RewardsDistributed(amount, magnifiedRewardPerShare);
    }

    function accumulativeOf(address account) public view returns (uint256) {
        int256 acc = (magnifiedRewardPerShare * trackedBalance[account]).toInt256() + magnifiedCorrections[account];
        return acc <= 0 ? 0 : uint256(acc) / MAGNITUDE;
    }

    function claimableOf(address account) public view returns (uint256) {
        return accumulativeOf(account) - withdrawnRewards[account];
    }

    // ─────────────────────────── auto-push (raw ETH) ───────────────────────────

    /// @notice Round-robin push of raw ETH; never swaps.
    /// @dev While the V4 lock is held only codeless holders are paid; others wait for a later pass or their own claim.
    function process(uint256 gasBudget) public nonReentrant returns (uint256 pushed) {
        uint256 n = _holders.length;
        if (n == 0) {
            return 0;
        }
        bool inLock = _v4LockHeld();
        uint256 idx = lastProcessedIndex;
        uint256 gasStart = gasleft();
        uint256 iterations;
        while (iterations < n) {
            if (gasleft() < PUSH_GAS + 120_000) {
                break;
            }
            uint256 len = _holders.length;
            if (len == 0) {
                break;
            }
            idx = idx + 1 < len ? idx + 1 : 0;
            address h = _holders[idx];
            uint256 amt = claimableOf(h);
            if (amt != 0 && (!inLock || h.code.length == 0)) {
                try this.pushReward(h, amt) {
                    unchecked {
                        ++pushed;
                    }
                } catch {
                    emit PushPaymentFailed(h, amt);
                }
            }
            unchecked {
                ++iterations;
            }
            if (gasStart - gasleft() > gasBudget) {
                break;
            }
        }
        lastProcessedIndex = idx;
    }

    function pushReward(address account, uint256 amount) external {
        if (msg.sender != address(this)) {
            revert OnlySelf();
        }
        withdrawnRewards[account] += amount;
        _spend(amount);
        (bool ok,) = payable(account).call{value: amount, gas: PUSH_GAS}("");
        if (!ok) {
            revert EthTransferFailed();
        }
        emit RewardClaimed(account, address(0), amount);
    }

    // ─────────────────────────── claim (basket) ───────────────────────────

    function claimAtAnyPrice() external returns (uint256 totalAmount) {
        uint256[] memory zero = new uint256[](legCount);
        return claimToWithMinOuts(msg.sender, zero);
    }

    function claimToAtAnyPrice(address to) external returns (uint256 totalAmount) {
        uint256[] memory zero = new uint256[](legCount);
        return claimToWithMinOuts(to, zero);
    }

    function claimWithMinOuts(uint256[] memory minOuts) external returns (uint256 totalAmount) {
        return claimToWithMinOuts(msg.sender, minOuts);
    }

    /// @notice Claim the caller's accrual as the basket, paid to `to`. `minOuts[i]` is in leg `i`'s asset units
    /// (ignored for the WETH leg). Refused inside a V4 unlock.
    /// @dev A failed leg with a non-zero floor reverts the claim ({LegMinOutUnmet}); with a zero floor it pays raw ETH.
    function claimToWithMinOuts(address to, uint256[] memory minOuts)
        public
        nonReentrant
        returns (uint256 totalAmount)
    {
        if (_v4LockHeld()) {
            revert NotDuringSwap();
        }
        _checkRecipient(to);
        return _claim(to, minOuts, new bytes[](legCount));
    }

    /// @notice Claim with a caller-supplied route per leg. An empty route is discovered on-chain; otherwise it is a
    /// 43-byte V3 path or an ABI-encoded V4 `PoolKey` (the only way to reach a hooked V4 pool).
    /// @dev Every supplied route is validated before anything is paid and may not route through {feeder}.
    function claimWithRoutes(uint256[] memory minOuts, bytes[] memory routes) external returns (uint256 totalAmount) {
        return claimToWithRoutes(msg.sender, minOuts, routes);
    }

    /// @notice {claimWithRoutes}, paid to `to`. A V4 route may be paired with WETH or native ETH.
    function claimToWithRoutes(address to, uint256[] memory minOuts, bytes[] memory routes)
        public
        nonReentrant
        returns (uint256 totalAmount)
    {
        if (_v4LockHeld()) {
            revert NotDuringSwap();
        }
        _checkRecipient(to);
        _requireRoutes(routes);
        return _claim(to, minOuts, routes);
    }

    /// @dev Shared claim body: debit the whole accrual, then pay each leg by weight (last leg takes the remainder).
    function _claim(address to, uint256[] memory minOuts, bytes[] memory routes)
        internal
        returns (uint256 totalAmount)
    {
        if (minOuts.length != legCount) {
            revert BadMinOuts();
        }
        if (routes.length != legCount) {
            revert BadRoutes();
        }
        _syncBalance(msg.sender);
        totalAmount = claimableOf(msg.sender);
        if (totalAmount == 0) {
            revert NothingToClaim();
        }
        withdrawnRewards[msg.sender] += totalAmount; // CEI: before any send/swap below
        uint256 n = legCount;
        uint256 distributed;
        for (uint256 i; i < n; ++i) {
            uint256 legAmt = i + 1 == n ? totalAmount - distributed : (totalAmount * _legBps[i]) / BPS;
            distributed += legAmt;
            if (legAmt == 0) {
                continue;
            }
            _payLeg(msg.sender, to, _legAsset[i], legAmt, minOuts[i], routes[i]);
        }
    }

    /// @dev Validates every supplied route up front, so a bad one fails the claim loudly.
    function _requireRoutes(bytes[] memory routes) internal view {
        if (routes.length != legCount) {
            revert BadRoutes();
        }
        for (uint256 i; i < routes.length; ++i) {
            if (routes[i].length == 0 || _legAsset[i] == weth) {
                continue;
            }
            RealmAnyPairsRouteLib.supplied(
                routes[i],
                swapRouter == address(0) ? address(0) : v3Factory,
                poolManager,
                weth,
                true,
                _legAsset[i],
                feeder
            );
        }
    }

    /// @dev Rejects recipients where a reward would be stranded or re-booked.
    function _checkRecipient(address to) internal view {
        if (
            to == address(0) || to == address(this) || to == token || to == weth || to == swapRouter || to == feeder
                || to == poolManager
        ) {
            revert ZeroRecipient();
        }
    }

    function _payLeg(address account, address to, address asset, uint256 ethAmt, uint256 minOut, bytes memory route)
        internal
    {
        if (asset == weth) {
            _payDirect(account, to, ethAmt); // "keep as ETH": no wrap, no swap, no price
            return;
        }
        if (gasleft() < LEG_GAS_CAP * 64 / 63 + 30_000) {
            revert InsufficientGasForLeg();
        }
        try this._executeSwap{gas: LEG_GAS_CAP}(to, asset, ethAmt, minOut, route) returns (uint256 out) {
            emit RewardClaimed(account, asset, out);
        } catch {
            if (minOut != 0) {
                revert LegMinOutUnmet();
            }
            emit LegSwapFailed(account, asset, ethAmt);
            _payDirect(account, to, ethAmt);
        }
    }

    /// @dev Self-only. Spend, wrap, swap, measure. Any revert unwinds the `_spend` and the wrap together.
    function _executeSwap(address to, address asset, uint256 ethAmt, uint256 minOut, bytes memory route)
        external
        returns (uint256 out)
    {
        if (msg.sender != address(this)) {
            revert OnlySelf();
        }
        _spend(ethAmt);
        // Caller's route if supplied, otherwise discovered now. V3 pools pair with WETH; V4 with WETH or native ETH.
        RealmAnyPairsRouteLib.Route memory r = route.length == 0
            ? RealmAnyPairsRouteLib.best(
                swapRouter == address(0) ? address(0) : v3Factory, poolManager, weth, true, asset
            )
            : RealmAnyPairsRouteLib.supplied(
                route, swapRouter == address(0) ? address(0) : v3Factory, poolManager, weth, true, asset, feeder
            );
        if (r.venue == RealmAnyPairsRouteLib.VENUE_NONE) {
            revert NoRouteFound();
        }
        uint256 before = IERC20(asset).balanceOf(to);
        if (r.venue == RealmAnyPairsRouteLib.VENUE_V3) {
            uint256 wethBefore = IERC20(weth).balanceOf(address(this));
            IEBWETH9(weth).deposit{value: ethAmt}();
            IERC20(weth).forceApprove(swapRouter, ethAmt);
            IEBSwapRouter02(swapRouter)
                .exactInput(
                    IEBSwapRouter02.ExactInputParams({
                        path: RealmAnyPairsRouteLib.v3Path(r, asset),
                        recipient: to,
                        amountIn: ethAmt,
                        amountOutMinimum: minOut
                    })
                );
            if (IERC20(weth).balanceOf(address(this)) > wethBefore) {
                revert PartialFill();
            }
            IERC20(weth).forceApprove(swapRouter, 0);
        } else {
            if (r.tokenIn == weth) {
                IEBWETH9(weth).deposit{value: ethAmt}();
            }
            _v4Swapping = true;
            IPoolManager(poolManager)
                .unlock(abi.encode(to, r.tokenIn, asset, r.fee, r.tickSpacing, r.hooks, ethAmt, minOut));
            _v4Swapping = false;
        }
        uint256 aft = IERC20(asset).balanceOf(to);
        out = aft > before ? aft - before : 0;
        if (out < minOut) {
            revert RealizedBelowMinOut();
        }
    }

    /// @notice PoolManager callback for a V4 leg swap started by {_executeSwap}; runs only inside this contract's own unlock.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != poolManager || !_v4Swapping) {
            revert OnlySelf();
        }
        (
            address to,
            address tokenIn,
            address asset,
            uint24 fee,
            int24 spacing,
            address hooks,
            uint256 amountIn,
            uint256 minOut
        ) = abi.decode(data, (address, address, address, uint24, int24, address, uint256, uint256));
        IPoolManager pm = IPoolManager(poolManager);
        uint256 out = RealmAnyPairsRouteLib.swapExactIn(
            pm, RealmAnyPairsRouteLib.poolKey(tokenIn, asset, fee, spacing, hooks), tokenIn, amountIn
        );
        if (out < minOut) {
            revert RealizedBelowMinOut();
        }
        RealmAnyPairsRouteLib.settleAndTake(pm, tokenIn, amountIn, asset, to, out);
        return "";
    }

    /// @dev Pays raw native ETH (a WETH leg or the zero-floor fallback). A reverting recipient re-credits the
    /// accrual instead of bricking the other legs.
    function _payDirect(address account, address to, uint256 ethAmt) internal {
        try this._transferDirect(to, ethAmt) {
            emit RewardClaimed(account, address(0), ethAmt);
        } catch {
            withdrawnRewards[account] -= ethAmt;
            emit LegPaymentFailed(account, address(0), ethAmt);
        }
    }

    /// @dev Self-only. Uncapped recipient gas: runs only on an out-of-lock self-claim, so contract wallets can receive.
    function _transferDirect(address to, uint256 ethAmt) external {
        if (msg.sender != address(this)) {
            revert OnlySelf();
        }
        _spend(ethAmt);
        (bool ok,) = payable(to).call{value: ethAmt}("");
        if (!ok) {
            revert EthTransferFailed();
        }
    }
}
