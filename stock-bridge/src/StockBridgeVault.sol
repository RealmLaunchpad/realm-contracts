// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {StockBridgeShare} from "./StockBridgeShare.sol";
import {ISwapRouter02, IWETH} from "./interfaces/ISwapRouter02.sol";

/// @title StockBridgeVault
/// @notice Pooled vault whose shares track a stock position
/// Deposits and redemptions are denominated in `depositToken`, a USD stablecoin, so share accounting
/// is in stable USD terms. Native ETH is also accepted (`mintWithETH`) and can be paid out
/// (`redeemToETH`); those legs swap ETH<->depositToken through Uniswap V3 SwapRouter02 at the edge,
/// leaving the core stablecoin-denominated.
///
/// Trust model: the controller is an off-chain operator that holds the real position and reports
/// share/payout amounts. The contract bounds what that trust can cost:
///   - Deposits are escrowed here, not handed to the controller, until confirmMint.
///   - Redemption payouts are pulled FROM the controller only at confirm time.
///   - Every confirmation's implied share price is bounded vs the last (`maxPriceDeviationBps`).
///   - The ETH-payout slippage floor (`minEthOut`) is set BY THE USER at redeemToETH time, not by the
///     controller, so the controller cannot both fund and un-bound the stablecoin->ETH conversion.
///   - The ETH send never bricks: on failure the payout is re-wrapped and credited as claimable WETH
///     (`claimWeth`), so a contract-user that rejects ETH cannot grief the controller or the pool.
///
contract StockBridgeVault is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    struct PendingMint {
        address user;
        uint256 depositAmount;
        uint256 expiry;
    }

    struct PendingRedeem {
        address user;
        uint256 shareAmount;
        uint256 expiry;
        bool wantsEth; // true if redeemed via redeemToETH -> paid in native ETH
        uint256 minEthOut; // user-supplied slippage floor for the depositToken->ETH swap (wantsEth only)
    }

    IERC20 public depositToken; // USD stablecoin
    StockBridgeShare public share;

    /// @dev Uniswap V3 SwapRouter02 + WETH, for the ETH<->depositToken edge swaps only.
    ISwapRouter02 public swapRouter;
    address public weth;
    /// @dev WETH/depositToken pool fee tier to route through. Owner-settable to follow liquidity
    /// migration. Set in initialize() — inline defaults do NOT apply through a proxy.
    uint24 public swapPoolFee;

    /// @dev The operator wallet. Owner-updatable. A centralization point; see header.
    address public controller;

    uint256 public requestTimeout;

    /// @dev Set once the first confirmation records a price; before that the deviation band has
    /// nothing to compare against and is skipped. Using an explicit flag (not `lastPrice != 0`)
    /// means a degenerate implied-price-of-0 can never silently re-disable the band.
    bool public priceBootstrapped;
    uint256 public lastPricePerShareE18;
    uint256 public maxPriceDeviationBps;

    /// @dev Minimum DEPOSIT value in depositToken units. Gates mint / mintWithETH ONLY — below this,
    /// the off-chain bridge and venue-deposit minimums cannot process the amount. It deliberately does
    /// NOT gate redeem: a holder can always exit their full balance, with only truly-unconfirmable dust
    /// blocked by the separate confirmability guard in _createRedeem. Defaults to 0 (no floor); the
    /// owner sets the real value post-deploy via setMinDeposit.
    uint256 public minDeposit;

    uint256 public nextRequestId;
    mapping(uint256 => PendingMint) public pendingMints;
    mapping(uint256 => PendingRedeem) public pendingRedeems;
    mapping(uint256 => bool) public redeemReclaimAuthorized;
    /// @dev Claimable WETH credited when an ETH payout couldn't be PUSHED to the user (user rejects ETH).
    mapping(address => uint256) public wethOwed;
    /// @dev Claimable depositToken credited when an ETH redeem's swap couldn't meet the user's
    /// minEthOut floor (settle the value rather than brick the request — see confirmRedeem).
    mapping(address => uint256) public depositOwed;

    event ControllerSet(address controller);
    event MaxPriceDeviationSet(uint256 bps);
    event MinDepositSet(uint256 amount);
    event SwapPoolFeeSet(uint24 fee);
    event MintRequested(uint256 indexed requestId, address indexed user, uint256 depositAmount);
    event MintConfirmed(uint256 indexed requestId, address indexed user, uint256 sharesOut);
    event RedeemRequested(uint256 indexed requestId, address indexed user, uint256 shareAmount);
    event RedeemConfirmed(uint256 indexed requestId, address indexed user, uint256 payoutAmount, uint256 ethOut);
    event MintReclaimed(uint256 indexed requestId, address indexed user, uint256 depositAmount);
    event RedeemReclaimed(uint256 indexed requestId, address indexed user, uint256 shareAmount);
    event RedeemReclaimAuthorized(uint256 indexed requestId);
    event WethCredited(address indexed user, uint256 amount);
    event WethClaimed(address indexed user, uint256 amount);
    event DepositCredited(address indexed user, uint256 amount);
    event DepositClaimed(address indexed user, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error NotController();
    error UnknownRequest();
    error NotYourRequest();
    error NotYetExpired();
    error NotAuthorized();
    error AlreadyAuthorized();
    error PriceDeviationTooHigh(uint256 impliedPriceE18, uint256 lastPriceE18);
    error NotWeth();
    error TooHigh();
    error NothingOwed();
    error BelowMinimum();
    error DustRedeem();

    modifier onlyController() {
        if (msg.sender != controller) revert NotController();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers(); // lock the implementation; only the proxy is initializable
    }

    function initialize(
        address _depositToken,
        address _controller,
        uint256 _requestTimeout,
        address _swapRouter,
        address _weth,
        address _owner
    ) external initializer {
        if (
            _depositToken == address(0) || _controller == address(0) || _swapRouter == address(0)
                || _weth == address(0)
        ) revert ZeroAddress();
        if (_requestTimeout == 0) revert ZeroAmount(); // a 0 timeout makes requests reclaimable next block
        __Ownable_init(_owner);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        depositToken = IERC20(_depositToken);
        share = new StockBridgeShare(address(this)); // owned by the proxy, so it survives upgrades
        controller = _controller;
        requestTimeout = _requestTimeout;
        swapRouter = ISwapRouter02(_swapRouter);
        weth = _weth;
        swapPoolFee = 500; // inline defaults don't apply through a proxy — set here
        maxPriceDeviationBps = 1000;
        emit ControllerSet(_controller);
    }

    /// @dev UUPS upgrade authorization — owner-only.
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @dev Only WETH may send ETH here (from withdraw() on the redeem-to-ETH path). ETH on
    /// mintWithETH arrives as that payable function's msg.value, not through receive.
    receive() external payable {
        if (msg.sender != weth) revert NotWeth();
    }

    function setController(address _controller) external onlyOwner {
        if (_controller == address(0)) revert ZeroAddress();
        controller = _controller;
        emit ControllerSet(_controller);
    }

    /// @notice Set the confirmation price band, in bps. Must be in (0, 50%]: a 0% band would freeze
    /// confirmations to an exact price and, via the redeem confirmability guard, reject any non-exact
    /// redeem.
    function setMaxPriceDeviationBps(uint256 bps) external onlyOwner {
        if (bps == 0 || bps > 5000) revert TooHigh();
        maxPriceDeviationBps = bps;
        emit MaxPriceDeviationSet(bps);
    }

    /// @notice Set the minimum DEPOSIT value, in depositToken units. Gates mint / mintWithETH only;
    /// see `minDeposit`. Set too high it blocks new deposits, but that is owner-recoverable and cannot
    /// touch existing funds, so no on-chain cap (which would be decimals-fragile) is imposed.
    function setMinDeposit(uint256 amount) external onlyOwner {
        minDeposit = amount;
        emit MinDepositSet(amount);
    }

    function setSwapPoolFee(uint24 fee) external onlyOwner {
        swapPoolFee = fee;
        emit SwapPoolFeeSet(fee);
    }

    // ─────────────────────────────── Mint ───────────────────────────────

    /// @notice Deposit `depositToken` directly.
    function mint(uint256 amount) external nonReentrant returns (uint256 requestId) {
        if (amount == 0) revert ZeroAmount();
        if (amount < minDeposit) revert BelowMinimum();
        depositToken.safeTransferFrom(msg.sender, address(this), amount);
        return _createMint(msg.sender, amount);
    }

    /// @notice Deposit native ETH, swapped to `depositToken` in-transaction, then treated like a
    /// normal deposit.
    /// @param minDepositOut the caller's OWN slippage floor for the ETH->depositToken swap.
    /// @dev An unconfirmed ETH deposit is refunded as depositToken (the swapped amount) via
    /// reclaimExpiredMint, not as the original ETH.
    function mintWithETH(uint256 minDepositOut) external payable nonReentrant returns (uint256 requestId) {
        if (msg.value == 0) revert ZeroAmount();
        uint256 depositOut = swapRouter.exactInputSingle{value: msg.value}(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: weth,
                tokenOut: address(depositToken),
                fee: swapPoolFee,
                recipient: address(this),
                amountIn: msg.value,
                amountOutMinimum: minDepositOut,
                sqrtPriceLimitX96: 0
            })
        );
        if (depositOut == 0) revert ZeroAmount();
        if (depositOut < minDeposit) revert BelowMinimum();
        return _createMint(msg.sender, depositOut);
    }

    function _createMint(address user, uint256 amount) internal returns (uint256 requestId) {
        requestId = nextRequestId++;
        pendingMints[requestId] =
            PendingMint({user: user, depositAmount: amount, expiry: block.timestamp + requestTimeout});
        emit MintRequested(requestId, user, amount);
    }

    /// @notice Controller confirms a mint after sizing the real position. Mints shares, then forwards
    /// the escrowed deposit to the controller to fund that position.
    function confirmMint(uint256 requestId, uint256 sharesOut) external onlyController nonReentrant {
        PendingMint memory p = pendingMints[requestId];
        if (p.user == address(0)) revert UnknownRequest();
        if (sharesOut == 0) revert ZeroAmount();
        delete pendingMints[requestId];

        _checkAndUpdatePrice(p.depositAmount, sharesOut);

        share.mint(p.user, sharesOut);
        depositToken.safeTransfer(controller, p.depositAmount);
        emit MintConfirmed(requestId, p.user, sharesOut);
    }

    // ─────────────────────────────── Redeem ───────────────────────────────

    /// @notice Burn shares to redeem for `depositToken`.
    function redeem(uint256 shareAmount) external nonReentrant returns (uint256 requestId) {
        return _createRedeem(shareAmount, false, 0);
    }

    /// @notice Burn shares to redeem for native ETH.
    /// @param minEthOut YOUR slippage floor for the depositToken->ETH conversion that happens at
    /// confirm time. If the payout would convert to less ETH than this, confirm settles the value as
    /// claimable depositToken instead. Set it from a live quote — this is what stops the controller
    /// from choosing its own (zero) floor and sandwiching the swap.
    function redeemToETH(uint256 shareAmount, uint256 minEthOut) external nonReentrant returns (uint256 requestId) {
        return _createRedeem(shareAmount, true, minEthOut);
    }

    function _createRedeem(uint256 shareAmount, bool wantsEth, uint256 minEthOut)
        internal
        returns (uint256 requestId)
    {
        if (shareAmount == 0) revert ZeroAmount();
        // Fail closed on redeems confirmRedeem could NEVER finalize — this is NOT a deposit floor. The
        // fair payout is this redeem's share of the pool at the last price; paying it runs through
        // _checkAndUpdatePrice, which reverts on a zero implied price or one outside the band. If the
        // fair payout itself cannot clear that, the request would strand, so it is rejected here BEFORE
        // shares are burned. The check mirrors the confirm-time band check for the FAIR FLOORED payout:
        // guard-passes <=> confirmRedeem(id, fairPayout) succeeds (identical mulDiv floors + band). It
        // errs safe: a redeem it rejects could in principle still confirm at a rounded-UP payout, but
        // only for value below the smallest payout unit. Before the first mint bootstraps a price there
        // are no shares to burn, so the check is skipped.
        if (priceBootstrapped) {
            uint256 fairPayout = Math.mulDiv(shareAmount, lastPricePerShareE18, 1e18);
            // impliedPrice floors to 0 whenever fairPayout * 1e18 < shareAmount (implies unconfirmable).
            uint256 impliedPrice = Math.mulDiv(fairPayout, 1e18, shareAmount);
            uint256 last = lastPricePerShareE18;
            uint256 diff = impliedPrice > last ? impliedPrice - last : last - impliedPrice;
            if (impliedPrice == 0 || diff * 10_000 > last * maxPriceDeviationBps) revert DustRedeem();
        }
        share.burn(msg.sender, shareAmount);

        requestId = nextRequestId++;
        pendingRedeems[requestId] = PendingRedeem({
            user: msg.sender,
            shareAmount: shareAmount,
            expiry: block.timestamp + requestTimeout,
            wantsEth: wantsEth,
            minEthOut: minEthOut
        });
        emit RedeemRequested(requestId, msg.sender, shareAmount);
    }

    /// @notice Controller confirms a redeem after closing that slice of the position. Pulls
    /// `payoutAmount` depositToken from the controller. A plain redeem forwards it to the user; an ETH
    /// redeem swaps it to ETH (bounded by the USER's stored minEthOut) and pushes native ETH, with a
    /// WETH-credit fallback if the push fails, so it can never brick.
    function confirmRedeem(uint256 requestId, uint256 payoutAmount) external onlyController nonReentrant {
        PendingRedeem memory p = pendingRedeems[requestId];
        if (p.user == address(0)) revert UnknownRequest();
        delete pendingRedeems[requestId];
        delete redeemReclaimAuthorized[requestId]; // never leave a stale authorization

        _checkAndUpdatePrice(payoutAmount, p.shareAmount);

        uint256 ethOut = 0;
        if (p.wantsEth) {
            depositToken.safeTransferFrom(controller, address(this), payoutAmount);
            depositToken.forceApprove(address(swapRouter), payoutAmount);
            // ONLY the swap is inside try/catch: if it cannot meet the user's minEthOut floor it reverts
            // and the value is settled as claimable depositToken. The post-swap ETH handling below is
            // OUTSIDE the try on purpose — a failure there (e.g. a nonstandard WETH) must revert the
            // whole tx, never be miscaught as a "swap failure" and mis-settled while the vault actually
            // holds WETH.
            bool swapped;
            uint256 wethOut;
            try swapRouter.exactInputSingle(
                ISwapRouter02.ExactInputSingleParams({
                    tokenIn: address(depositToken),
                    tokenOut: weth,
                    fee: swapPoolFee,
                    recipient: address(this),
                    amountIn: payoutAmount,
                    amountOutMinimum: p.minEthOut,
                    sqrtPriceLimitX96: 0
                })
            ) returns (uint256 _wethOut) {
                wethOut = _wethOut;
                swapped = true;
            } catch {
                // Unmeetable floor -> settle the full value as claimable depositToken rather than brick
                // the request (a brick would be clearable only via a spammable owner attestation). The
                // anti-sandwich property is preserved: an honest ETH fill still cannot go below the floor.
                depositToken.forceApprove(address(swapRouter), 0);
                depositOwed[p.user] += payoutAmount;
                emit DepositCredited(p.user, payoutAmount);
            }
            if (swapped) {
                IWETH(weth).withdraw(wethOut);
                (bool ok,) = p.user.call{value: wethOut}("");
                if (ok) {
                    ethOut = wethOut; // delivered as native ETH
                } else {
                    // User rejects raw ETH -> re-wrap and credit claimable WETH. Never brick.
                    IWETH(weth).deposit{value: wethOut}();
                    wethOwed[p.user] += wethOut;
                    emit WethCredited(p.user, wethOut);
                }
            }
        } else {
            depositToken.safeTransferFrom(controller, p.user, payoutAmount);
        }
        emit RedeemConfirmed(requestId, p.user, payoutAmount, ethOut);
    }

    /// @notice Claim WETH credited to you when an ETH payout couldn't be pushed (e.g. your contract
    /// rejects raw ETH). A plain ERC20 transfer, so this cannot be blocked.
    function claimWeth() external nonReentrant {
        uint256 amt = wethOwed[msg.sender];
        if (amt == 0) revert NothingOwed();
        wethOwed[msg.sender] = 0;
        IERC20(weth).safeTransfer(msg.sender, amt);
        emit WethClaimed(msg.sender, amt);
    }

    /// @notice Claim depositToken credited to you when an ETH redeem's swap couldn't meet your
    /// minEthOut floor.
    function claimDeposit() external nonReentrant {
        uint256 amt = depositOwed[msg.sender];
        if (amt == 0) revert NothingOwed();
        depositOwed[msg.sender] = 0;
        depositToken.safeTransfer(msg.sender, amt);
        emit DepositClaimed(msg.sender, amt);
    }

    // ─────────────────────── Reclaim (stuck-request recovery) ───────────────────────

    /// @notice Recover a mint deposit the controller never confirmed. Safe unconditionally — this
    /// contract still holds the escrowed deposit. ETH deposits refund as depositToken (see mintWithETH).
    function reclaimExpiredMint(uint256 requestId) external nonReentrant {
        PendingMint memory p = pendingMints[requestId];
        if (p.user == address(0)) revert UnknownRequest();
        if (msg.sender != p.user) revert NotYourRequest();
        if (block.timestamp <= p.expiry) revert NotYetExpired();

        delete pendingMints[requestId];
        depositToken.safeTransfer(p.user, p.depositAmount);
        emit MintReclaimed(requestId, p.user, p.depositAmount);
    }

    /// @dev The vault cannot distinguish "controller never processed this redeem" (safe to re-mint)
    /// from "controller already closed the position off-chain, only the on-chain confirm got stuck"
    /// (unsafe), so re-minting is gated behind an explicit owner attestation.
    function authorizeRedeemReclaim(uint256 requestId) external onlyOwner {
        if (pendingRedeems[requestId].user == address(0)) revert UnknownRequest();
        if (redeemReclaimAuthorized[requestId]) revert AlreadyAuthorized();
        redeemReclaimAuthorized[requestId] = true;
        emit RedeemReclaimAuthorized(requestId);
    }

    /// @notice Re-mints the burned shares (both redeem kinds). Requires expiry AND owner attestation.
    function reclaimExpiredRedeem(uint256 requestId) external nonReentrant {
        PendingRedeem memory p = pendingRedeems[requestId];
        if (p.user == address(0)) revert UnknownRequest();
        if (msg.sender != p.user) revert NotYourRequest();
        if (block.timestamp <= p.expiry) revert NotYetExpired();
        if (!redeemReclaimAuthorized[requestId]) revert NotAuthorized();

        delete pendingRedeems[requestId];
        delete redeemReclaimAuthorized[requestId];
        share.mint(p.user, p.shareAmount);
        emit RedeemReclaimed(requestId, p.user, p.shareAmount);
    }

    /// @dev Bounds a confirmation's implied price against the last, either direction. Skipped only on
    /// the very first confirmation (`priceBootstrapped == false`). Rejects a zero implied price so the
    /// band can never be silently re-disabled.
    function _checkAndUpdatePrice(uint256 valueAmount, uint256 shareAmount) internal {
        uint256 impliedPriceE18 = Math.mulDiv(valueAmount, 1e18, shareAmount);
        if (impliedPriceE18 == 0) revert ZeroAmount();
        if (priceBootstrapped) {
            uint256 last = lastPricePerShareE18;
            uint256 diff = impliedPriceE18 > last ? impliedPriceE18 - last : last - impliedPriceE18;
            if (diff * 10_000 > last * maxPriceDeviationBps) {
                revert PriceDeviationTooHigh(impliedPriceE18, last);
            }
        }
        lastPricePerShareE18 = impliedPriceE18;
        priceBootstrapped = true;
    }

    /// @dev Reserved storage for future upgrades. Not strictly required — this is the leaf contract and
    /// all upgradeable parents use ERC-7201 namespaced storage, so nothing can shift these slots. Kept
    /// as a defensive convention. UPGRADE RULE: add new state variables IMMEDIATELY BEFORE this gap and
    /// decrement its size by the slots used — never append after it.
    uint256[50] private __gap;
}
