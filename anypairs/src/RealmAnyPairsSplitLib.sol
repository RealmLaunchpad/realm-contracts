// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Lets a DELEGATECALLed library function read the hook's own PoolManager via a self-call
/// (`address(this)` is the hook there).
interface IHookPoolManager {
    function poolManager() external view returns (address);
}

interface IHookConvert {
    function convertToWeth(address recipient, address token, bytes memory path, uint256 amount, uint256 minOut)
        external
        returns (uint256 out);
}

interface ISwapRouter02Lib {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/// @title RealmAnyPairsSplitLib
/// @notice Cold-path helpers (split storage, quote-path validation, WETH conversion, claims) extracted from
/// the tax hook to keep its runtime size down. None of them is on the swap path.
/// @dev Functions are `external`, so they live in a separately deployed library reached by DELEGATECALL:
/// `address(this)` is the hook and `msg.sender` is the hook's caller. The library address is linked into
/// the hook's bytecode, so it must be deployed before the hook's CREATE2 salt is mined; redeploying it
/// invalidates the salt.
library RealmAnyPairsSplitLib {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;

    /// @dev Ceiling on split recipients; bounds {store} and the hook's per-swap payout loop.
    uint256 internal constant MAX_SPLIT_RECIPIENTS = 20;

    /// @dev One creator-fee split entry, shared by the hook and this library.
    struct Split {
        address to;
        uint16 bps;
    }

    error BadSplit();
    error BadSplitLength();
    error BadQuotePath();
    error NothingAccrued();
    error QuoteIsWeth();
    /// @dev A native-ETH payout (`token == address(0)`) failed. Redeclared on the hook so its ABI decodes it.
    error EthTransferFailed();
    /// @dev A {claimTo} destination that would destroy or donate the payout (zero, the hook, the PoolManager).
    /// Redeclared on the hook so its ABI decodes it.
    error BadClaimDestination();

    /// @dev Mirrors the hook's event; emitted under DELEGATECALL, so the log address is the hook.
    event Claimed(address indexed recipient, address indexed token, uint256 amount);

    /// @dev Gas cap forwarded to the conversion swap, and the minimum gasleft before attempting it. Kept in
    /// step with the hook, which aliases these.
    uint256 internal constant CONVERT_GAS_CAP = 2_000_000;
    uint256 internal constant CONVERT_GAS_FLOOR = 2_120_000;

    /// @notice Replace a pool's creator-fee split. Empty clears it (fees go wholly to the creator).
    /// @dev Takes the hook's storage array directly (storage pointers can cross an external library boundary).
    function store(Split[] storage arr, address[] calldata recipients, uint16[] calldata bps, address poolManager)
        external
    {
        if (recipients.length != bps.length || recipients.length > MAX_SPLIT_RECIPIENTS) {
            revert BadSplitLength();
        }
        // `delete` is unavailable on a storage pointer, so clear by popping (bounded by MAX_SPLIT_RECIPIENTS).
        while (arr.length != 0) {
            arr.pop();
        }
        if (recipients.length == 0) {
            return;
        }
        uint256 sum;
        for (uint256 i; i < recipients.length; i++) {
            // Rejected: zero; the hook itself (a self-push succeeds and strands the funds forever); the
            // PoolManager (funds there are unattributed and swept by the next settler). The hook's
            // `_storeSplit` adds further refusals.
            if (
                recipients[i] == address(0) || recipients[i] == address(this) || recipients[i] == poolManager
                    || bps[i] == 0
            ) {
                revert BadSplit();
            }
            sum += bps[i];
            arr.push(Split({to: recipients[i], bps: bps[i]}));
        }
        if (sum != BPS) {
            revert BadSplit();
        }
    }

    /// @notice Validate a V3 multi-hop path that must start at `quote` and end at `weth`.
    /// @dev Also checks structure (20 bytes + N * 23-byte hops) so a malformed path is rejected at config
    /// time rather than silently failing at claim time.
    function requireQuotePath(address quote, address weth, bytes calldata path) external pure {
        if (quote == weth || weth == address(0)) {
            revert QuoteIsWeth();
        }
        if (
            path.length < 43 || address(bytes20(path[0:20])) != quote
                || address(bytes20(path[path.length - 20:])) != weth || (path.length - 43) % 23 != 0
        ) {
            revert BadQuotePath();
        }
    }

    /// @notice The approve -> exactInput -> approve-reset sequence behind the hook's `convertToWeth`.
    /// @dev Runs under DELEGATECALL, spending the hook's own quote balance. `minOut` reverts a bad fill so
    /// `claim` falls back to paying the raw quote.
    function swapToWeth(
        address recipient,
        address token,
        bytes memory path,
        uint256 amount,
        uint256 minOut,
        address swapRouter,
        address weth
    ) external returns (uint256 out) {
        IERC20(token).forceApprove(swapRouter, amount);
        // Report the recipient's actual balance delta, not the router's self-reported amountOut.
        uint256 before = IERC20(weth).balanceOf(recipient);
        ISwapRouter02Lib(swapRouter)
            .exactInput(
                ISwapRouter02Lib.ExactInputParams({
                    path: path, recipient: recipient, amountIn: amount, amountOutMinimum: minOut
                })
            );
        // Saturating: a recipient that forwards WETH onward must not make a successful swap revert.
        uint256 aft = IERC20(weth).balanceOf(recipient);
        out = aft > before ? aft - before : 0;
        IERC20(token).forceApprove(swapRouter, 0);
    }

    /// @dev The trailing 20-byte address of a memory V3 path (its final token).
    function _lastAddress(bytes memory path) private pure returns (address addr) {
        uint256 len = path.length;
        assembly {
            addr := shr(96, mload(add(add(path, 0x20), sub(len, 20))))
        }
    }

    /// @notice The body of the pair hook's `claim` / `claimTo`.
    /// @dev DELEGATECALLed: `msg.sender` is the claimer (the ledger key), and `address(this)` is the hook, so
    /// `convertToWeth` below is a real external call that can be gas-capped and caught.
    /// @param to where the value goes. Only a destination; the entry debited is always `owed[msg.sender][token]`.
    function claimTo(
        mapping(address => mapping(address => uint256)) storage owed,
        mapping(address => bytes) storage quoteToWethPath,
        address token,
        uint256 minWethOut,
        address to,
        address weth,
        address swapRouter
    ) external returns (uint256 amountPaid, address tokenPaid) {
        // Reject destinations that would destroy (zero, the hook) or donate (the PoolManager) the payout.
        // The PoolManager is read from the hook; if that read fails, only the other two checks apply.
        if (to == address(0) || to == address(this)) {
            revert BadClaimDestination();
        }
        (bool pmOk, bytes memory pmRet) =
            address(this).staticcall(abi.encodeWithSelector(IHookPoolManager.poolManager.selector));
        if (pmOk && pmRet.length >= 32 && address(uint160(uint256(bytes32(pmRet)))) == to) {
            revert BadClaimDestination();
        }

        uint256 amount = owed[msg.sender][token];
        if (amount == 0) {
            revert NothingAccrued();
        }
        owed[msg.sender][token] = 0;

        // Native quote: send ETH directly. Reverts on failure (rather than falling back) so the zeroed
        // ledger entry is restored; a recipient that cannot receive ETH should name another `to`.
        if (token == address(0)) {
            (bool sent,) = payable(to).call{value: amount}("");
            if (!sent) {
                revert EthTransferFailed();
            }
            emit Claimed(msg.sender, address(0), amount);
            return (amount, address(0));
        }

        bytes memory path = quoteToWethPath[token];
        // `weth` can be repointed without revalidating stored paths; a path that no longer ends at the
        // current `weth` is treated as unconfigured (pay raw quote) instead of paying a mislabeled asset.
        bool pathTargetsCurrentWeth = weth != address(0) && path.length >= 43 && _lastAddress(path) == weth;
        // Gas-capped swap with a floor check first, so enough gas always remains for the raw-quote fallback.
        if (pathTargetsCurrentWeth && swapRouter != address(0) && token != weth && gasleft() >= CONVERT_GAS_FLOOR) {
            try IHookConvert(address(this)).convertToWeth{gas: CONVERT_GAS_CAP}(
                to, token, path, amount, minWethOut
            ) returns (
                uint256 out
            ) {
                emit Claimed(msg.sender, weth, out);
                return (out, weth);
            } catch {
                // Fall through to paying the raw quote, including on a `minWethOut` failure: no fill means
                // no value loss, and `tokenPaid` tells the caller which asset arrived.
            }
        }
        // Report what actually arrived (fee-on-transfer quotes deliver less), saturating. The ledger debit
        // stays the full `amount`.
        uint256 before = IERC20(token).balanceOf(to);
        IERC20(token).safeTransfer(to, amount);
        uint256 aft = IERC20(token).balanceOf(to);
        uint256 delivered = aft > before ? aft - before : 0;
        emit Claimed(msg.sender, token, delivered);
        return (delivered, token);
    }
}
