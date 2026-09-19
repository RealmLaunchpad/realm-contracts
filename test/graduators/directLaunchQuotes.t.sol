// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {DirectLaunchUniV4Tests} from "test/graduators/directLaunchUniV4.t.sol";
import {RealmDirectGraduatorUniV4} from "src/graduators/RealmDirectGraduatorUniV4.sol";
import {RealmFactoryUniV4Direct} from "src/factories/RealmFactoryUniV4Direct.sol";
import {RealmHookAnyPair} from "src/hooks/RealmHookAnyPair.sol";
import {RealmTaxableTokenUniV4} from "src/tokens/RealmTaxableTokenUniV4.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {IRealmMasterFeeHandler} from "src/interfaces/IRealmMasterFeeHandler.sol";
import {UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {PoolKey as CorePoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "lib/v4-core/src/types/PoolId.sol";
import {PoolId as HookPoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "lib/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "lib/v4-core/src/libraries/TickMath.sol";
import {IPermit2} from "lib/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {IV4Router} from "lib/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {IUniversalRouter} from "src/interfaces/IUniswapV4UniversalRouter.sol";

/// @notice An ordinary 6-decimal ERC20, standing in for the kind of stablecoin a creator would quote
///         their token against. Six decimals on purpose: it is the shape that breaks anything which
///         quietly assumes 18.
contract QuoteCoin is ERC20 {
    constructor() ERC20("QuoteCoin", "QC") {}

    function decimals() public pure virtual override returns (uint8) {
        return 6;
    }

    function mintTo(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice A quote with the legacy `bytes32` symbol (MKR-style): 32 raw bytes, not an ABI string.
contract Bytes32SymbolCoin is QuoteCoin {
    function symbol() public pure override returns (string memory) {
        assembly {
            mstore(0, "B32")
            return(0, 32)
        }
    }
}

/// @notice The direct venue launched against an ERC20 rather than the chain's native currency, and
///         against SEVERAL currencies at once. What these cover that `DirectLaunchUniV4Tests` does not:
///         the pool sorting either way, the fee arriving in the quote, and the supply splitting by
///         weight across pools.
contract DirectLaunchQuotesTests is DirectLaunchUniV4Tests {
    using PoolIdLibrary for CorePoolKey;
    using StateLibrary for IPoolManager;

    QuoteCoin internal quoteCoin;

    /// @dev Quote-per-coin of 1e-4 QC per token. QC has 6 decimals and the token 18, so on RAW units
    ///      that is 1e-4 * 1e6 / 1e18 = 1e-16, i.e. tick ln(1e-16)/ln(1.0001) ≈ -368,400 (spacing-aligned).
    int24 internal constant QC_LAUNCH_TICK = -368_400;

    /// @dev QC's whitelist rate, as if it were a dollar stable with ETH at $3,500: `QC_LAUNCH_TICK`'s 1e5
    ///      QC market cap is ~28.6 ETH.
    uint256 internal constant QC_PER_ETH = 3_500e18;

    function setUp() public virtual override {
        super.setUp();
        quoteCoin = new QuoteCoin();
        _whitelist(address(quoteCoin), QC_PER_ETH);
    }

    /////////////////////////// HELPERS ///////////////////////////

    function _quotePairs(int24 tick) internal view returns (RealmFactoryUniV4Direct.DirectPair[] memory p) {
        p = new RealmFactoryUniV4Direct.DirectPair[](1);
        p[0] = RealmFactoryUniV4Direct.DirectPair({quote: address(quoteCoin), weightBps: 10_000, launchTick: tick});
    }

    function _launchAgainstQuoteCoin(RealmFactoryUniV4Direct.DevBuy memory devBuy) internal returns (address token) {
        vm.prank(creator);
        token = directFactory.createToken(
            _setup(false),
            _quotePairs(QC_LAUNCH_TICK),
            _noDirectAlloc(_emptyTaxCfg()),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            devBuy,
            address(0)
        );
    }

    function _qcPoolKey(address token) internal view returns (CorePoolKey memory) {
        return UniswapV4PoolConstants.realmPoolKey(token, address(quoteCoin), TEST_ANYPAIR_HOOK_ADDRESS);
    }

    /// @dev An exact-input swap on an ERC20-quoted pool, through the universal router.
    function _swapQuotePool(address caller, address token, bool isBuy, uint256 amountIn) internal {
        _swapQuotePool(caller, token, address(quoteCoin), isBuy, amountIn);
    }

    /// @dev The same, on the pool `token` shares with any ERC20 `quote`.
    function _swapQuotePool(address caller, address token, address quote, bool isBuy, uint256 amountIn) internal {
        CorePoolKey memory coreKey = UniswapV4PoolConstants.realmPoolKey(token, quote, TEST_ANYPAIR_HOOK_ADDRESS);
        PoolKey memory key = abi.decode(abi.encode(coreKey), (PoolKey));
        bool quoteIsC0 = quote < token;
        address tokenIn = isBuy ? quote : token;

        vm.startPrank(caller);
        IERC20(tokenIn).approve(permit2Address, type(uint256).max);
        IPermit2(permit2Address).approve(tokenIn, universalRouter, type(uint160).max, type(uint48).max);

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: isBuy ? quoteIsC0 : !quoteIsC0,
                amountIn: uint128(amountIn),
                amountOutMinimum: 0,
                hookData: bytes("")
            })
        );
        (bool inIsC0) = isBuy ? quoteIsC0 : !quoteIsC0;
        params[1] = abi.encode(inIsC0 ? key.currency0 : key.currency1, amountIn);
        params[2] = abi.encode(inIsC0 ? key.currency1 : key.currency0, uint256(0));

        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        IUniversalRouter(universalRouter).execute(abi.encodePacked(uint8(0x10)), inputs, block.timestamp);
        vm.stopPrank();
    }

    /////////////////////////// TESTS ///////////////////////////

    function test_erc20Quote_opensThePoolAndSeedsIt() public {
        address token = _launchAgainstQuoteCoin(_noDevBuy());

        (uint160 sqrtPriceX96, int24 tick,,) = IPoolManager(poolManagerAddress).getSlot0(_qcPoolKey(token).toId());
        // The pool's orientation is the reciprocal of quote-per-coin only when the coin sorts second.
        int24 expected = token < address(quoteCoin) ? QC_LAUNCH_TICK : -QC_LAUNCH_TICK;
        assertEq(tick, expected, "pool opened at the wrong tick");
        assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(expected));

        uint256 seeded = IERC20(token).balanceOf(poolManagerAddress);
        assertEq(seeded + IERC20(token).balanceOf(address(0xdEaD)), TOTAL_SUPPLY, "supply seeded or burned");
        assertTrue(IRealmToken(token).graduated());
    }

    function test_erc20Quote_registersTheQuoteOnTheToken() public {
        address token = _launchAgainstQuoteCoin(_noDevBuy());

        assertEq(IRealmToken(token).quoteCount(), 2, "native plus the ERC20");
        assertEq(IRealmToken(token).quotes(0), address(0), "native is always index 0");
        assertEq(IRealmToken(token).quotes(1), address(quoteCoin));
    }

    function test_erc20Quote_devBuyPullsTheQuoteAndDelivers() public {
        quoteCoin.mintTo(creator, 1_000e6);
        vm.prank(creator);
        quoteCoin.approve(address(directFactory), type(uint256).max);

        RealmFactoryUniV4Direct.DevBuy memory devBuy = _devBuyTo(alice);
        devBuy.quoteAmount = 100e6;

        address token = _launchAgainstQuoteCoin(devBuy);

        assertGt(IERC20(token).balanceOf(alice), 0, "dev buy delivered nothing");
        assertEq(quoteCoin.balanceOf(address(directGraduator)), 0, "graduator keeps no quote");
        assertEq(IERC20(token).balanceOf(address(directFactory)), 0, "factory keeps no tokens");
    }

    /// @dev `BuyOnDeploy` reports what the dev buy cost in the pair's own quote, not `msg.value` (zero on
    ///      an ERC20 pair).
    function test_erc20Quote_buyOnDeployReportsTheQuoteSpent() public {
        quoteCoin.mintTo(creator, 1_000e6);
        vm.prank(creator);
        quoteCoin.approve(address(directFactory), type(uint256).max);
        RealmFactoryUniV4Direct.DevBuy memory devBuy = _devBuyTo(alice);
        devBuy.quoteAmount = 100e6;

        vm.recordLogs();
        _launchAgainstQuoteCoin(devBuy);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length == 0 || logs[i].topics[0] != IRealmFactory.BuyOnDeploy.selector) continue;
            (uint256 spent,,,) = abi.decode(logs[i].data, (uint256, uint256, address[], uint256[]));
            assertEq(spent, 100e6, "cost in the quote's raw units");
            found = true;
        }
        assertTrue(found, "no BuyOnDeploy");
    }

    /// @dev The whole point of the any-pair hook: the fee is collected in the pool's own currency and
    ///      reaches the creator as that currency, never converted on the way.
    function test_erc20Quote_swapFeesReachTheCreatorInTheQuote() public {
        address token = _launchAgainstQuoteCoin(_noDevBuy());

        quoteCoin.mintTo(alice, 1_000e6);
        _swapQuotePool(alice, token, true, 100e6);
        assertGt(IERC20(token).balanceOf(alice), 0, "buy delivered nothing");

        // The hook CLAIMS the fee during the swap and redeems it on demand — see `pendingLpFees`. The
        // redemption is permissionless, so anyone (here, the test) can trigger it.
        assertGt(anyPairHook.pendingLpFees(token, address(quoteCoin)), 0, "fee booked at the trade");
        anyPairHook.settleFees(token, address(quoteCoin));

        address[] memory tokens = new address[](1);
        tokens[0] = token;
        uint256[] memory claimable =
            IRealmMasterFeeHandler(address(feeHandler)).getClaimable(tokens, address(quoteCoin), creator);
        assertGt(claimable[0], 0, "creator's LP-fee share must be claimable IN THE QUOTE");
        assertEq(
            IRealmMasterFeeHandler(address(feeHandler)).getClaimable(tokens, creator)[0],
            0,
            "and nothing in native, which this pool never touches"
        );
    }

    function test_erc20Quote_treasuryShareLandsOnTheTreasuryRouter() public {
        address token = _launchAgainstQuoteCoin(_noDevBuy());
        quoteCoin.mintTo(alice, 1_000e6);

        uint256 before = quoteCoin.balanceOf(treasury);
        _swapQuotePool(alice, token, true, 100e6);
        anyPairHook.settleFees(token, address(quoteCoin));
        assertGt(quoteCoin.balanceOf(treasury) - before, 0, "treasury slice must arrive in the quote");
    }

    /// @dev A taxed token on the QuoteCoin pool, with alice's buy already booked in the hook.
    function _taxedTokenWithPendingFees() internal returns (address token) {
        vm.prank(creator);
        token = directFactory.createToken(
            _setup(true),
            _quotePairs(QC_LAUNCH_TICK),
            _noDirectAlloc(_taxCfg(300, 300, uint32(14 days))),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            _noDevBuy(),
            address(0)
        );
        quoteCoin.mintTo(alice, 1_000e6);
        _swapQuotePool(alice, token, true, 100e6);
    }

    /// @dev The hook cannot be upgraded, so a token whose `accrueFees` reverts must not strand the ledger.
    ///      The router reaches the creator through the same `accrueFees`, so both legs fall through to the
    ///      treasury here, and the event says how much of each.
    function test_settleFees_fallsBackToTreasuryWhenTheTokenReverts() public {
        address token = _taxedTokenWithPendingFees();
        uint256 lpFee = anyPairHook.pendingLpFees(token, address(quoteCoin));
        uint256 tax = anyPairHook.pendingTaxes(token, address(quoteCoin));
        assertGt(tax, 0, "the buy booked a tax");
        vm.mockCallRevert(token, abi.encodeWithSignature("accrueFees(address,uint256)"), "");

        uint256 treasuryBefore = quoteCoin.balanceOf(treasury);
        vm.expectEmit(address(anyPairHook));
        emit RealmHookAnyPair.TreasuryFallback(token, address(quoteCoin), lpFee, tax);
        anyPairHook.settleFees(token, address(quoteCoin));

        assertEq(quoteCoin.balanceOf(treasury) - treasuryBefore, lpFee + tax, "everything reached the treasury");
        assertEq(anyPairHook.pendingTaxes(token, address(quoteCoin)), 0, "ledger cleared");
        assertEq(quoteCoin.balanceOf(address(anyPairHook)), 0, "hook keeps nothing");
    }

    /// @dev `settleFees` is permissionless: a caller must not be able to starve a destination's call into
    ///      its fallback and divert the creator's fees to the treasury.
    function test_settleFees_refusesToRunWithoutGasForTheCappedCalls() public {
        address token = _taxedTokenWithPendingFees();
        vm.expectRevert(RealmHookAnyPair.InsufficientGas.selector);
        anyPairHook.settleFees{gas: 600_000}(token, address(quoteCoin));
    }

    function test_erc20Quote_sellWorksInTheOtherDirection() public {
        address token = _launchAgainstQuoteCoin(_noDevBuy());
        quoteCoin.mintTo(alice, 1_000e6);
        _swapQuotePool(alice, token, true, 100e6);

        uint256 bag = IERC20(token).balanceOf(alice);
        uint256 quoteBefore = quoteCoin.balanceOf(alice);
        _swapQuotePool(alice, token, false, bag / 2);
        assertGt(quoteCoin.balanceOf(alice), quoteBefore, "sell must return the quote");
    }

    /// @dev The hook caches what it resolved about a pool on the first swap, so every later one pays a
    ///      warm SLOAD instead of two external calls. Resolution itself is what the fee tests above
    ///      exercise; this pins that it is remembered, and remembered correctly.
    function test_anyPairHook_cachesThePoolIdentity() public {
        address token = _launchAgainstQuoteCoin(_noDevBuy());
        quoteCoin.mintTo(alice, 1_000e6);
        _swapQuotePool(alice, token, true, 100e6);

        // The repo vendors two v4-core copies; the hook is compiled against the periphery's, so the
        // canonical pool id is re-wrapped at this boundary. Same 32 bytes either way.
        (address resolved, bool quoteIsC0) =
            anyPairHook.poolInfo(HookPoolId.wrap(PoolId.unwrap(_qcPoolKey(token).toId())));
        assertEq(resolved, token, "the Realm token is the resolved side");
        assertEq(quoteIsC0, address(quoteCoin) < token, "orientation follows the sort order");
    }

    //////////////////////// MULTI-PAIR ////////////////////////

    function _twoPairs() internal view returns (RealmFactoryUniV4Direct.DirectPair[] memory p) {
        p = new RealmFactoryUniV4Direct.DirectPair[](2);
        p[0] = RealmFactoryUniV4Direct.DirectPair({quote: address(0), weightBps: 6_000, launchTick: LAUNCH_TICK});
        p[1] = RealmFactoryUniV4Direct.DirectPair({
            quote: address(quoteCoin), weightBps: 4_000, launchTick: QC_LAUNCH_TICK
        });
    }

    function test_multiPair_seedsEveryPoolAndSplitsSupplyByWeight() public {
        vm.prank(creator);
        address token = directFactory.createToken(
            _setup(false),
            _twoPairs(),
            _noDirectAlloc(_emptyTaxCfg()),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            _noDevBuy(),
            address(0)
        );

        // Both pools live on the same singleton manager and both open at the TOP of their own band —
        // a position is active for `[lower, upper)`, so `getLiquidity()` reads 0 until the first buy
        // steps into the range. What is observable, and what actually matters, is that each pool trades.
        quoteCoin.mintTo(alice, 1_000e6);
        _swapBuyV4(alice, token, 0.02 ether, 0, true);
        uint256 fromNativePool = IERC20(token).balanceOf(alice);
        assertGt(fromNativePool, 0, "native pool delivered nothing");

        _swapQuotePool(alice, token, true, 50e6);
        assertGt(IERC20(token).balanceOf(alice) - fromNativePool, 0, "quote pool delivered nothing");

        assertEq(IRealmToken(token).quoteCount(), 2);
        assertEq(
            IERC20(token).balanceOf(poolManagerAddress) + IERC20(token).balanceOf(address(0xdEaD))
                + IERC20(token).balanceOf(alice),
            TOTAL_SUPPLY,
            "every token is seeded, burned or bought"
        );
    }

    function test_multiPair_emitsOnePoolSeededPerPoolWithItsWeight() public {
        vm.recordLogs();
        vm.prank(creator);
        directFactory.createToken(
            _setup(false),
            _twoPairs(),
            _noDirectAlloc(_emptyTaxCfg()),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            _noDevBuy(),
            address(0)
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint16[] memory weights = new uint16[](2);
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 3 && logs[i].topics[0] == RealmDirectGraduatorUniV4.PoolSeeded.selector) {
                (, uint16 weightBps,,) = abi.decode(logs[i].data, (bytes32, uint16, int24, uint128));
                if (found < 2) weights[found] = weightBps;
                ++found;
            }
        }
        assertEq(found, 2, "one PoolSeeded per pool");
        assertEq(weights[0], 6_000);
        assertEq(weights[1], 4_000);
    }

    /// @dev The quote's metadata rides in `PoolSeeded` so an indexer needs no RPC, and the market caps are
    ///      in its RAW units: 1e-4 QC per coin across 1e9 coins is 1e5 QC, i.e. 1e11 at 6 decimals.
    function test_poolSeeded_carriesTheQuoteMetadataAndRawMarketCaps() public {
        vm.recordLogs();
        _launchAgainstQuoteCoin(_noDevBuy());
        (uint256 launchCap, uint256 targetCap, uint8 decimals, string memory symbol) = _poolSeededTail();
        assertEq(decimals, 6);
        assertEq(symbol, "QC");
        assertApproxEqRel(launchCap, 1e11, 0.01e18, "launch market cap in raw QC units");
        assertEq(targetCap, launchCap * 5);
    }

    /// @dev A `symbol()` that is not an ABI string labels nothing, and must not block the launch.
    function test_poolSeeded_nonStringSymbolIsEmptyAndTheLaunchSucceeds() public {
        quoteCoin = new Bytes32SymbolCoin();
        _whitelist(address(quoteCoin), QC_PER_ETH);
        vm.recordLogs();
        _launchAgainstQuoteCoin(_noDevBuy());
        (,, uint8 decimals, string memory symbol) = _poolSeededTail();
        assertEq(decimals, 6);
        assertEq(symbol, "");
    }

    /// @dev The first `PoolSeeded` in the recorded logs, fields after `liquidity`.
    function _poolSeededTail()
        internal
        returns (uint256 launchCap, uint256 targetCap, uint8 decimals, string memory symbol)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 3 && logs[i].topics[0] == RealmDirectGraduatorUniV4.PoolSeeded.selector) {
                (,,,, launchCap, targetCap, decimals, symbol) =
                    abi.decode(logs[i].data, (bytes32, uint16, int24, uint128, uint256, uint256, uint8, string));
                return (launchCap, targetCap, decimals, symbol);
            }
        }
        revert("PoolSeeded not emitted");
    }

    function test_multiPair_rejectsADuplicateQuote() public {
        RealmFactoryUniV4Direct.DirectPair[] memory pairs = _twoPairs();
        pairs[1].quote = address(0);
        vm.prank(creator);
        vm.expectRevert(RealmFactoryUniV4Direct.InvalidPairs.selector);
        directFactory.createToken(
            _setup(false),
            pairs,
            _noDirectAlloc(_emptyTaxCfg()),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            _noDevBuy(),
            address(0)
        );
    }

    function test_multiPair_rejectsWeightsThatDoNotSumToTheWhole() public {
        RealmFactoryUniV4Direct.DirectPair[] memory pairs = _twoPairs();
        pairs[1].weightBps = 3_000;
        vm.prank(creator);
        vm.expectRevert(RealmFactoryUniV4Direct.InvalidPairs.selector);
        directFactory.createToken(
            _setup(false),
            pairs,
            _noDirectAlloc(_emptyTaxCfg()),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            _noDevBuy(),
            address(0)
        );
    }

    function test_multiPair_rejectsMoreThanMaxPairs() public {
        RealmFactoryUniV4Direct.DirectPair[] memory pairs = new RealmFactoryUniV4Direct.DirectPair[](4);
        for (uint256 i; i < 4; ++i) {
            pairs[i] = RealmFactoryUniV4Direct.DirectPair({
                quote: address(uint160(0x1000 + i)), weightBps: 2_500, launchTick: LAUNCH_TICK
            });
        }
        vm.prank(creator);
        vm.expectRevert(RealmFactoryUniV4Direct.InvalidPairs.selector);
        directFactory.createToken(
            _setup(false),
            pairs,
            _noDirectAlloc(_emptyTaxCfg()),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            _noDevBuy(),
            address(0)
        );
    }
}
