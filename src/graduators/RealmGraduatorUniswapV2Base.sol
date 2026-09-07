// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRealmGraduator} from "src/interfaces/IRealmGraduator.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {IUniswapV2Router} from "src/interfaces/IUniswapV2Router.sol";
import {IUniswapV2Factory} from "src/interfaces/IUniswapV2Factory.sol";
import {IRealmLaunchpad} from "src/interfaces/IRealmLaunchpad.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV2Pair} from "src/interfaces/IUniswapV2Pair.sol";

/// @title RealmGraduatorUniswapV2Base
/// @notice Shared Uniswap V2 graduation logic. The ETH-family and ARC (native = USDC) graduators are
///         SEPARATE deployable contracts, not one import-swapped file, because their difference is
///         behavioral, not just constants: ETH wraps native into WETH via `addLiquidityETH`, while ARC
///         pairs `<token, USDC-ERC20>` via two-ERC20 `addLiquidity` with an 18↔6-decimal conversion.
///         Everything that does NOT differ (fee split, pair prediction, price-matched liquidity,
///         cleanup) lives here; the venue + fee specifics are `virtual` hooks each subclass fills in.
/// @dev Abstract: never deployed directly. See `RealmGraduatorUniswapV2` (ETH) and
///      `RealmGraduatorUniswapV2Arc` (ARC).
abstract contract RealmGraduatorUniswapV2Base is IRealmGraduator {
    using SafeERC20 for IRealmToken;

    /// @notice Graduation native fee (creator compensation + treasury fee). Value from `_graduationFee()`.
    uint256 public immutable GRADUATION_ETH_FEE;

    /// @notice Native compensation paid to token creator at graduation (half of the fee)
    /// @dev this is part of the GRADUATION_ETH_FEE
    uint256 public immutable CREATOR_GRADUATION_COMPENSATION;

    /// @notice Native compensation paid to `tx.origin` for triggering graduation, to offset the
    ///         extra gas spent deploying the UniswapV2 pair lazily inside `graduateToken()`.
    uint256 public immutable TRIGGERER_GRADUATION_COMPENSATION;

    /// @notice Where LP tokens are sent at graduation, effectively locking the liquidity
    address internal constant DEAD_ADDRESS = address(0xdEaD);

    /// @notice Address of the RealmLaunchpad contract
    address public immutable REALM_LAUNCHPAD;

    /// @notice Uniswap V2 router contract
    IUniswapV2Router internal immutable UNISWAP_ROUTER;

    /// @notice Uniswap V2 factory contract
    IUniswapV2Factory internal immutable UNISWAP_FACTORY;

    /// @notice V2 quote token every graduated pair is paired against. ETH-family: the router's WETH.
    ///         ARC (native = USDC, no WETH): the 6-dec USDC ERC-20 — provided by `_pairToken()`.
    address internal immutable PAIR_TOKEN;

    /// @notice Init code hash of the Uniswap V2 pair contract used by the configured factory.
    ///         Required to predict the CREATE2 pair address without deploying the pair upfront.
    /// @dev Per-chain value: must match `keccak256(type(<factory's pair>).creationCode)` exactly.
    ///      Mainnet (stock UniswapV2 factory) is `0x96e8ac42...`. The Sepolia factory wired in
    ///      `DeploymentAddressesEthereumSepolia` is a fork with different pair bytecode, so its hash
    ///      differs from mainnet — see `DeploymentAddressesEthereumSepolia.UNIV2_PAIR_INIT_CODE_HASH`.
    ///      Wrong value here ⇒ `pair` is set to a non-existent CREATE2 address, taxes silently
    ///      stop accruing because the real pair is not recognized as the pair.
    bytes32 internal immutable PAIR_INIT_CODE_HASH;
    //////////////////////// EVENTS ////////////////////////

    event SweepedRemainingEth(address graduatedToken, uint256 amount);

    //////////////////////// ERRORS ////////////////////////

    error NotEnoughEthForGraduation();
    error EtherTransferFailed();

    /////////////////////// VENUE + FEE HOOKS ///////////////////////

    /// @dev Build-vs-target guard: reverts if this graduator's baked fees/venue don't match `chainId`.
    function _assertDeployableOn(uint256 chainId) internal pure virtual;

    /// @dev Total graduation fee, in native 18-dec (chain-specific constant).
    function _graduationFee() internal pure virtual returns (uint256);

    /// @dev Triggerer compensation, in native 18-dec (chain-specific constant).
    function _triggererCompensation() internal pure virtual returns (uint256);

    /// @dev Quote token to pair against. ETH: `router.WETH()`. ARC: the 6-dec USDC ERC-20.
    function _pairToken(IUniswapV2Router router) internal pure virtual returns (address);

    /// @dev Multiplier from the pool's quote-reserve units to native 18-dec. 1 on ETH; 1e12 on ARC.
    function _quoteToNativeScale() internal pure virtual returns (uint256);

    /// @dev Adds `tokenAmount` + `nativeValue` (18-dec) of liquidity to the venue. Returns the native
    ///      amount used in 18-dec on both chains. ETH: `addLiquidityETH`. ARC: two-ERC20 `addLiquidity`.
    function _supplyLiquidity(address token, address quote, uint256 tokenAmount, uint256 nativeValue, address to)
        internal
        virtual
        returns (uint256 amountToken, uint256 amountNative, uint256 liquidity);

    ////////////////////////////////////////////////////////

    /// @notice Initializes the Uniswap V2 graduator
    /// @param _uniswapRouter Address of the Uniswap V2 router
    /// @param _launchpad Address of the RealmLaunchpad contract
    /// @param _pairInitCodeHash keccak256 of the pair contract creation code used by the configured factory
    constructor(address _uniswapRouter, address _launchpad, bytes32 _pairInitCodeHash) {
        // Refuse graduator bytecode built with the wrong chain's baked fee/venue — fires on ANY deploy
        // path (script, raw cast, test). Virtual dispatch resolves to the concrete subclass's chain.
        _assertDeployableOn(block.chainid);

        REALM_LAUNCHPAD = _launchpad;
        UNISWAP_ROUTER = IUniswapV2Router(_uniswapRouter);

        PAIR_TOKEN = _pairToken(IUniswapV2Router(_uniswapRouter));
        UNISWAP_FACTORY = IUniswapV2Factory(IUniswapV2Router(_uniswapRouter).factory());
        PAIR_INIT_CODE_HASH = _pairInitCodeHash;

        uint256 fee = _graduationFee();
        GRADUATION_ETH_FEE = fee;
        CREATOR_GRADUATION_COMPENSATION = fee / 2;
        TRIGGERER_GRADUATION_COMPENSATION = _triggererCompensation();
    }

    /// @notice Returns the deterministic CREATE2 address that the Uniswap V2 pair for `<token, PAIR_TOKEN>` will have.
    /// @dev Pure prediction; pair contract is deployed lazily at graduation. Token's transfer gate keys off this address.
    /// @param tokenAddress Address of the token
    /// @return pair Address of the (future or existing) Uniswap V2 pair
    function initialize(address tokenAddress) external override returns (address pair) {
        pair = _pairFor(tokenAddress);
        emit PairInitialized(tokenAddress, pair);
    }

    /// @dev Standard UniswapV2Library-style CREATE2 prediction for the `<token, PAIR_TOKEN>` pair.
    function _pairFor(address tokenAddress) internal view returns (address pair) {
        (address token0, address token1) =
            tokenAddress < PAIR_TOKEN ? (tokenAddress, PAIR_TOKEN) : (PAIR_TOKEN, tokenAddress);
        // forge-lint: disable-next-line(unsafe-typecast)
        pair = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            address(UNISWAP_FACTORY),
                            keccak256(abi.encodePacked(token0, token1)),
                            PAIR_INIT_CODE_HASH
                        )
                    )
                )
            )
        );
    }

    /// @notice Graduates a token by adding liquidity to Uniswap V2
    /// @param tokenAddress Address of the token to graduate
    function graduateToken(address tokenAddress, uint256 tokenAmount) external payable override {
        require(msg.sender == REALM_LAUNCHPAD, OnlyLaunchpadAllowed());
        IRealmToken token = IRealmToken(tokenAddress);
        require(tokenAmount > 0, NoTokensToGraduate());
        require(msg.value > 0, NoETHToGraduate());

        // 1. Handle fee split and payments
        uint256 ethForLiquidity = _handleGraduationFees(tokenAddress);

        // 2. Mark graduated and add liquidity
        // Pair was not deployed at token creation (only its CREATE2 address was reserved).
        // Deploy it now if nobody else has yet — `createPair` is permissionless on UniV2 so an
        // outside actor may have front-run us; in that case `getPair` returns the pre-existing pair
        // and we use it directly.
        address pair = UNISWAP_FACTORY.getPair(tokenAddress, PAIR_TOKEN);
        if (pair == address(0)) {
            pair = UNISWAP_FACTORY.createPair(tokenAddress, PAIR_TOKEN);
        }
        // this opens the gate of transferring tokens to the uniswap pair
        token.markGraduated();

        uint256 tokensForLiquidity = tokenAmount;
        token.safeIncreaseAllowance(address(UNISWAP_ROUTER), tokensForLiquidity);

        uint256 ethReserve = _syncedEthReserves(pair, tokenAddress);

        uint256 amountToken;
        uint256 amountEth;
        uint256 liquidity;
        if (ethReserve == 0) {
            (amountToken, amountEth, liquidity) =
                _naiveLiquidityAddition(tokenAddress, tokensForLiquidity, ethForLiquidity);
        } else {
            (amountToken, amountEth, liquidity) =
                _addLiquidityWithPriceMatching(tokenAddress, ethReserve, tokensForLiquidity, ethForLiquidity, pair);
        }

        _cleanup(tokenAddress);
        emit TokenGraduated(tokenAddress, amountToken, amountEth, liquidity);
    }

    /// @dev Reads the actual eth reserves after syncing
    function _syncedEthReserves(address pair, address tokenAddress) internal returns (uint256 ethReserve) {
        IUniswapV2Pair pairContract = IUniswapV2Pair(pair);
        pairContract.sync();

        (uint112 reserve0, uint112 reserve1,) = pairContract.getReserves();

        // Determine which reserve corresponds to which token
        address token0 = pairContract.token0();

        // Normalize the quote reserve to native 18-dec so the price-matching math below stays in one
        // unit. Scale is 1 on ETH (18-dec WETH); 1e12 on ARC (6-dec USDC quote).
        uint256 rawQuoteReserve = token0 == tokenAddress ? reserve1 : reserve0;
        ethReserve = rawQuoteReserve * _quoteToNativeScale();
    }

    /// @dev Adds liquidity trying to match the intended price (derived from the ratio of eth/tokens for graduation)
    /// @dev The number one priority is that liquidity addition doesn't revert
    /// @dev The number two priority is that the resulting price in the pool is GREATER than the last price given by the launchpad before graduation
    function _addLiquidityWithPriceMatching(
        address tokenAddress,
        uint256 ethReserve,
        uint256 tokenBalance,
        uint256 ethValue,
        address pair
    ) internal returns (uint256 amountToken, uint256 amountEth, uint256 liquidity) {
        // Calculate tokens needed to match target price
        uint256 tokensToTransfer = (tokenBalance * ethReserve) / (ethValue + ethReserve);

        // Note: tokensToTransfer is always < tokenBalance due to (ethReserve < ethValue + ethReserve)
        IRealmToken(tokenAddress).safeTransfer(pair, tokensToTransfer);
        IUniswapV2Pair(pair).sync();

        // Add remaining tokens and native value as liquidity via the per-chain venue (WETH path on
        // ETH; two-ERC20 `<token, USDC>` on ARC). `amountEth` returns in native 18-dec on both.
        uint256 remainingTokens = tokenBalance - tokensToTransfer;
        (amountToken, amountEth, liquidity) =
            _supplyLiquidity(tokenAddress, PAIR_TOKEN, remainingTokens, ethValue, DEAD_ADDRESS);
        // the tokens sent as sync also count as liquidity added ofc
        amountToken += tokensToTransfer;
    }

    /// @dev This blindly adds the liquidity, accepting any LPs, so accepting whatever price ratio is in the pair already
    function _naiveLiquidityAddition(address tokenAddress, uint256 tokenBalance, uint256 ethValue)
        internal
        returns (uint256 amountToken, uint256 amountEth, uint256 liquidity)
    {
        (amountToken, amountEth, liquidity) =
            _supplyLiquidity(tokenAddress, PAIR_TOKEN, tokenBalance, ethValue, DEAD_ADDRESS);
    }

    function _handleGraduationFees(address tokenAddress) internal returns (uint256 ethForLiquidity) {
        require(msg.value > GRADUATION_ETH_FEE, NotEnoughEthForGraduation());

        ethForLiquidity = msg.value - GRADUATION_ETH_FEE;
        uint256 treasuryShare = GRADUATION_ETH_FEE - CREATOR_GRADUATION_COMPENSATION - TRIGGERER_GRADUATION_COMPENSATION;

        // Creator share routed through token -> feeHandler -> feeReceiver
        emit CreatorGraduationFeeCollected(tokenAddress, CREATOR_GRADUATION_COMPENSATION);
        IRealmToken(tokenAddress).accrueFees{value: CREATOR_GRADUATION_COMPENSATION}();

        // Best-effort triggerer compensation. If `tx.origin` cannot receive ETH the amount
        // stays in the contract and is swept to the treasury by `_cleanup()`.
        // slither-disable-next-line tx-origin,unchecked-low-level,arbitrary-send-eth
        (bool triggererPaid,) = tx.origin.call{value: TRIGGERER_GRADUATION_COMPENSATION}("");
        triggererPaid; // intentionally ignored: failure path is handled by `_cleanup()`

        // Treasury share sent directly
        address treasury = IRealmLaunchpad(REALM_LAUNCHPAD).treasury();
        (bool success,) = treasury.call{value: treasuryShare}("");
        require(success, EtherTransferFailed());
        emit TreasuryGraduationFeeCollected(tokenAddress, treasuryShare);
    }

    function _cleanup(address tokenAddress) internal {
        uint256 remainingTokenBalance = IRealmToken(tokenAddress).balanceOf(address(this));
        // burn any remaining tokens
        if (remainingTokenBalance > 0) {
            IRealmToken(tokenAddress).safeTransfer(DEAD_ADDRESS, remainingTokenBalance);
        }

        // send any remaining ETH to the owner (launchpad)
        uint256 remainingEth = address(this).balance;
        if (remainingEth > 0) {
            address treasury = IRealmLaunchpad(REALM_LAUNCHPAD).treasury();
            (bool success,) = treasury.call{value: remainingEth}("");
            require(success, EtherTransferFailed());

            // for transparency, to be able to detect if some graduation went completely wrong
            emit SweepedRemainingEth(tokenAddress, remainingEth);
        }
    }
}
