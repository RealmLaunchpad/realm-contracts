// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// this line below is swapped per target chain at deploy time (the addresses are compile-time
/// constants baked into bytecode): DeploymentAddressesEthereumSepolia, DeploymentAddressesRobinhood*,
/// or DeploymentAddressesArc{Mainnet,Testnet}.
import {DeploymentAddressesEthereumMainnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";

/// @title DividendDistribution
/// @notice Trustless holder dividends for a Realm token: UP TO THREE payout assets, paid out of
///         post-graduation earnings, streamed continuously so no caller can time their way into a share.
///
/// @dev THE RULE, and the reason everything else is small:
///
///          You earn in proportion to `balance x time`, from a stream that never stops.
///
///      Every distribution funds a linear stream over `DIVIDEND_DRIP_DURATION` and each holder accrues
///      against a global `rewardPerTokenStored` accumulator that only advances with the clock. A flash
///      loan spans zero seconds, so it accrues exactly zero — not by an age gate, a snapshot, a minimum
///      or a trusted ticker, but because its integrand is zero. There is no distribution INSTANT left to
///      sandwich: money arrives as a slope, not as a drop.
///
/// @dev ⚠️ THE ONE ORDERING RULE THE WHOLE DESIGN RESTS ON. `_onDividendTransfer` must run BEFORE the
///      balances move, and it must advance the accumulator BEFORE it settles either account. The
///      accumulator divides the elapsed interval by the eligible supply read at that moment; settle
///      after the mutation and an attacker can shrink the denominator inside their own transaction and
///      harvest a real elapsed interval at an inflated rate — atomically, with no time exposure. Settle
///      first and both halves are worthless: their buy books at a zero balance, and their
///      denominator-shrinking transfer books the pending interval at the full supply before shrinking
///      anything.
///      With several payout assets that rule applies to EVERY one of them on every transfer: the hook
///      loops the whole configured set, so no asset is ever left un-settled across a balance change.
///
/// @dev NO ROUNDS, NO PHASES, NO WINDOWS. Funding is idempotent in the only sense that matters — a
///      distribution arriving mid-stream folds the undelivered remainder into a fresh full-length
///      window and changes the SLOPE. It never reverts for being early, never has to wait for a
///      previous stream to drain, and never leaves money in a state that has to be rolled over.
///
/// @dev ONE TO THREE ASSETS PER TOKEN, chosen at creation and permanent — never rewritten, by anyone,
///      for any reason. Each is native (`address(0)`), the token itself (`DIVIDEND_SELF_TOKEN`, and only
///      when it is the ONLY asset), or any ERC20 the registry can reach. There is no whitelist and no
///      per-asset approval — what makes an ERC20 eligible is the liquidity `DIVIDEND_SWAP_REGISTRY`
///      measures at creation, nothing else.
///
/// @dev EACH ASSET IS ITS OWN, INDEPENDENT MACHINE. `dividendWeightsBps` splits the dividends slice of
///      earnings between them at accrual time, and from that point on nothing is shared: each has its
///      own native buffer, its own `DIVIDEND_THRESHOLD` to cross, its own conversion, its own stream and
///      slope, its own accumulator, its own per-account checkpoint, its own per-block funding cooldown
///      and its own treasury-sweep proof. A 20/80 split therefore converts the 20% asset roughly four
///      times less often, in roughly the same-sized distributions — which is the point: the threshold
///      exists so a conversion is worth its gas, and a weight is not a reason to relax it.
///      The ONLY things the assets share are the eligible supply (a property of the token, not of a
///      payout), the activation instant, and the reentrancy lock.
///
/// @dev A CONVERSION THAT CAN NEVER HAPPEN IS THE TREASURY'S PROBLEM, NOT THE TOKEN'S. If a payout
///      pool dies, the buffered native cannot be converted and would otherwise sit owed to holders
///      forever. Rather than rewrite the asset and write off what holders had already accrued — paying
///      an old-asset debt out of a new-asset balance at a 1:1 unit ratio between two assets that may
///      not even share decimals — the unconvertible buffer goes to `DIVIDEND_TREASURY`, and Realm makes
///      holders whole off-chain if it is ever worth doing. Nothing on-chain is written off: the stream,
///      the accumulator and every accrual survive untouched. This is a backstop for a case that should
///      not occur — a token whose payout asset has no liquidity has, by then, no activity either.
///
/// @dev ⚠️ ACCEPTED, AND THE ONE GAP THE SWEEP DOES NOT COVER: it moves UNCONVERTED native only. Once
///      the native has been swapped, the asset sits in this contract and nothing can ever take it out
///      again — `_sweepableAsset` subtracts `committedDividends`, so `rescueTokens` cannot reach it
///      either, which is deliberate (that subtraction is what stops an owner draining holders' pot). So
///      a payout asset that becomes permanently undeliverable AFTER a conversion — it blacklists this
///      token, or pauses transfers for good — strands whatever had already been bought. There is no
///      second escape hatch for that, and adding one would mean an owner-reachable path into a live
///      dividend pot, which is a worse trade than the case it insures against.
///      This used to have a much more likely cause: an accumulator scaled to 18 decimals truncated every
///      increment to zero for a low-decimal payout asset, so USDC-style tokens streamed nothing while
///      `owed` kept counting it, and the whole pot ended up here. That is fixed — the scale is now
///      derived from each asset's own decimals (see `DivAsset.precisionExp`) — and what is left is the
///      genuinely exotic case above.
///
/// @dev NO HOLDER SET. The contract never enumerates holders. `processDividends(index, minOut, address[])`
///      takes the push list from the caller and reads each amount out of that holder's own accrued
///      balance, so the call is idempotent and unforgeable: a duplicate pays 0, a wrong address pays 0,
///      and an omitted holder loses NOTHING — their accrual simply keeps sitting there until the next
///      batch, or until they call `claimDividends()` themselves. That is what lets a keeper push only
///      to holders above whatever threshold it likes.
///
/// @dev THE HOT PATH IS THE WHOLE COST, and it is zero per asset while that asset is not streaming.
///      Between an asset's streams `lastUpdate == periodFinish`, so its accumulator cannot move, and an
///      account whose `rewardPerTokenPaid` already equals it is skipped without a write. A transfer only
///      pays for storage on the assets whose accumulator has actually advanced since that account last
///      moved. Excluded addresses — crucially the `pair`, counterparty of every trade — are never
///      settled at all, so a buy or a sell touches ONE account slot per asset, not two. The eligible
///      supply is computed at most ONCE per transfer however many assets advance, and only if one does.
///      A single-asset token therefore pays what it always did, plus the loop.
///
/// @dev Asset-agnostic: a payout may be native, the token itself, or a third ERC20, and the accounting
///      never knows the difference.
abstract contract DividendDistribution {
    /// @notice Hard ceiling on payout assets per token. A FIXED bound, not a policy knob: the transfer
    ///         hook loops the set on every balance change, so it has to be small, known at compile time
    ///         and impossible to grow after creation. Three is what the product asked for.
    uint256 public constant MAX_DIVIDEND_ASSETS = 3;

    /// @notice Minimum accrued native amount an asset's buffer must hold before it may fund that asset's
    ///         stream. Per asset, never aggregate — see the independence note on the contract docstring.
    ///         Bypassed only once the asset has gone `STALE_DIVIDEND_WINDOW` without a distribution, so
    ///         a sub-threshold residual on a dead token is not stranded in the buffer forever.
    uint256 public constant DIVIDEND_THRESHOLD = DeploymentAddresses.DIVIDEND_THRESHOLD;

    /// @notice Max native a token may convert in ONE distribution, per asset. Deliberately the SAME
    ///         constant `processBurn` and `processLiquidity` cap with, for the same reason and on the
    ///         same scale — roughly 3-11% of a graduated pool across the liquidity tiers.
    /// @dev WHAT THIS DOES AND DOES NOT BOUND. It caps the loss PER BLOCK PER ASSET, and nothing else.
    ///      It does NOT bound the FRACTION of a conversion a sandwich can take: the cost of pushing a
    ///      constant-product price arbitrarily far and back is the pool fee paid twice — about 0.6% of
    ///      the pool's native reserve — and that cost does not grow with how far the price is pushed,
    ///      while the prize is the whole spend. Against any pool short of very deep, a caller who picks
    ///      their own zero floor keeps almost all of it. That is why `processDividends` is keeper-gated
    ///      (see `RealmKeepersRegistry`) and why this cap is a second line, not the first.
    /// @dev ⚠️ ACCEPTED: a token's AGGREGATE per-block conversion exposure is this times the number of
    ///      configured assets, because the cooldown is per asset (three different pools, three different
    ///      manipulations, no shared cost). Keeper-gating is what actually bounds it.
    /// @dev Necessarily >= `DIVIDEND_THRESHOLD`: a cap below the floor would leave an asset that
    ///      qualifies to distribute unable to convert what qualified it. The remainder above the cap
    ///      stays buffered and funds a later stream, so nothing is stranded.
    uint256 public constant MAX_DIVIDEND_PER_CONVERSION = DeploymentAddresses.MAX_EARNINGS_PER_PROCESS;

    /// @notice How long each distribution takes to stream out. Every funding restarts a full window of
    ///         this length for THAT asset, folding whatever the previous one had left to deliver into
    ///         the new slope.
    /// @dev NOT the anti-flash-loan mechanism, and deliberately SMALL. A borrowed balance exists for
    ///      zero seconds and therefore integrates to zero regardless of the length — what rules the
    ///      flash loan out is the accumulator and the settle-before-mutate ordering, not this constant.
    ///      What the length actually buys is dilution of a ONE-BLOCK hold: 15 minutes prices a 12-second
    ///      block at ~1.3% of whatever the stream still has to deliver, against a round-trip cost of two
    ///      taxes plus two pool fees. The ABSOLUTE size of that capture is bounded by
    ///      `MAX_DIVIDEND_PER_CONVERSION` and the per-block funding cooldown, which cap how large a
    ///      slope can be built, and that bound is what makes the timed hold uneconomic — not the window.
    ///      Sizing it in days would rule out fast payout cadences for a proportionally small gain.
    /// @dev It is a smoothing window, not an eligibility gate: nothing about it can make a call revert,
    ///      and a holder is never "too new" for it. Arriving mid-stream simply earns from the moment of
    ///      arrival.
    uint256 public constant DIVIDEND_DRIP_DURATION = 15 minutes;

    /// @notice Time without a distribution after which an ASSET is treated as DEAD. Two things unlock
    ///         there, both last resorts: funding below `DIVIDEND_THRESHOLD`, so a residual that can no
    ///         longer grow is not stranded in the buffer forever, and the treasury sweep of a buffer no
    ///         swap can convert (see `DividendDistributionLogic._fundDividends`, which also records what
    ///         that second use does and does not prove).
    /// @dev Anchored on that asset's own `periodFinish`, which every distribution pushes forward, so an
    ///      asset that is merely quiet never comes near this and the threshold keeps behaving exactly as
    ///      it does today. Only an asset nobody is converting ages into it — which, with weights, one
    ///      asset of a set can do while its siblings stay healthy.
    uint256 public constant STALE_DIVIDEND_WINDOW = 30 days;

    /// @notice Gas stipend for a native payout inside a KEEPER BATCH. Bounded so one holder with an
    ///         expensive (or reverting) `receive()` cannot brick or grief the rest of the batch; a plain
    ///         `receive()` and the common smart-account fallbacks fit comfortably.
    /// @dev Per-chain, because what a holder's wallet costs to pay is a property of the chain's wallet
    ///      population and not of this protocol — a future chain can raise it without a code change.
    /// @dev This is a batch-throughput knob, NOT an eligibility gate. A holder whose fallback needs more
    ///      than this is skipped by the batch but can still be paid in full through `claimDividends()`,
    ///      which forwards all remaining gas because it has no batch to protect and the caller is
    ///      spending their own gas. Their accrual is untouched by the skip, so nothing is lost.
    uint256 public constant NATIVE_PAYOUT_GAS = DeploymentAddresses.NATIVE_PAYOUT_GAS;

    /// @notice Gas stipend for an ERC20 payout inside a KEEPER BATCH. Same job as `NATIVE_PAYOUT_GAS`,
    ///         deliberately far larger: the payout asset is the creator's choice and the registry vets its
    ///         liquidity, never its behaviour, so a token whose `transfer` burns unbounded gas would
    ///         otherwise take down every batch AND every `claimDividends()` instead of returning `false`.
    /// @dev Sized to be unreachable by any honest token — a cold-slot transfer costs tens of thousands,
    ///      a hook-heavy one a few hundred — so this is a bomb bound, not an eligibility gate. As with the
    ///      native leg, a holder the batch skips is still payable in full through `claimDividends()`.
    /// @dev Not per-chain: this bounds a contract's own code, which is the same everywhere, unlike the
    ///      wallet population `NATIVE_PAYOUT_GAS` is sized against.
    uint256 public constant ASSET_PAYOUT_GAS = 500_000;

    /// @notice Decimal exponent every payout asset's fixed-point scale is measured against:
    ///         `precisionExp = DIVIDEND_PRECISION_DECIMALS - asset decimals`.
    /// @dev 36 rather than 18 because 18 is not a scale, it is a scale that happens to suit an
    ///      18-decimal asset. The accumulator's granularity is `supply / 10**exp` asset units, and with a
    ///      fixed 1e27 supply an exponent of 18 makes one accumulator step worth 1e9 asset units — 1000
    ///      USDC. A 0.2 ETH distribution buys less than that, so EVERY increment truncated to zero and a
    ///      6-decimal payout delivered nothing at all while `owed` kept counting it. Measuring the
    ///      exponent from the asset's own decimals makes the granularity `1e-18` of ONE whole unit of
    ///      the payout asset whatever its decimals are, which is what the design always assumed.
    uint256 internal constant DIVIDEND_PRECISION_DECIMALS = 36;

    /// @notice Eligible supply below which a stream PAUSES. One whole token, against a fixed total
    ///         supply of 1e27.
    /// @dev Two jobs, one line. It is the division guard — eligible supply reaches zero on a token whose
    ///      holders have all sold back into the pool — and it is the bound that keeps
    ///      `rewardPerTokenStored` inside its `uint128`: the accumulator's growth is
    ///      `payout * 10**exp / supply`, so a floor on the denominator is a ceiling on the accumulator.
    ///      With `exp = 36 - decimals` that ceiling is `total distributed, in WHOLE units, times 1e18`,
    ///      i.e. 3.4e20 whole units of the payout asset over the token's life — the same bound for a
    ///      6-decimal asset as for an 18-decimal one, and out of reach for both.
    /// @dev The paused interval's clock still advances (see `_syncDividend`), and the stream's finish
    ///      line moves out by the same span. Freezing the clock instead would bank the skipped seconds
    ///      and hand the whole lot to whoever bought in first once supply recovered — a just-in-time
    ///      capture window, which is the one thing this design exists to not have. Advancing the clock
    ///      WITHOUT extending the window was the other wrong answer: `owed` already counted the whole
    ///      distribution, so the skipped value would stay reserved and reach nobody, ever.
    uint256 internal constant MIN_DIVIDEND_SUPPLY = 1e18;

    /// @dev Denominator for `dividendWeightsBps`. Declared here rather than reached for from
    ///      `EarningsAllocation`, which this contract does not inherit.
    uint256 internal constant DIVIDEND_BPS_TOTAL = 10_000;

    /// @notice Pass this as a payout asset to mean "the token itself". A creator configuring a token
    ///         cannot name its own address — it does not exist yet at the point the configuration is
    ///         written — so the sentinel is resolved to `address(this)` during initialization.
    /// @dev Only legal on a SINGLE-asset token: the Uniswap-V2 shape of this payout is carved in token
    ///      space, out of the tax tokens, and removes itself from the ETH split's denominator — which is
    ///      a whole-slice operation with no meaningful per-asset fraction. See `_initializeDividends`.
    address public constant DIVIDEND_SELF_TOKEN = address(type(uint160).max);

    /// @notice The registry that decides whether a third payout asset is eligible, and that performs
    ///         the native -> asset conversion when a distribution funds a stream. Uniswap V2 by
    ///         default, plus the curated Uniswap V4 routes it holds for assets that only exist there.
    /// @dev A PROXY, deliberately reached through a compile-time constant rather than a stored address:
    ///      tokens are unpatchable clones, so this is the only seam through which an eligibility rule or
    ///      a swap route can be fixed for tokens that are ALREADY live. Nothing about the asset choice
    ///      is curated behind it for the V2 path — see `IRealmDividendSwapRegistry`.
    /// @dev Exposed so an off-chain keeper can price its slippage floor against the exact pools the swap
    ///      will cross (`registry.pairFor`, or `registry.routeOf` when the asset has a V4 route), which
    ///      is what `minOut` has to be computed from.
    address public constant DIVIDEND_SWAP_REGISTRY = DeploymentAddresses.DIVIDEND_SWAP_REGISTRY;

    /// @notice Where a buffer the registry cannot convert AT ANY PRICE ends up. A safety net, not a fee:
    ///         it only ever receives native that no holder could otherwise have been paid out of, and
    ///         reaching it requires a zero-floor swap to have failed outright.
    /// @dev A compile-time constant for the same reason the registry is one — a clone cannot be patched,
    ///      so the escape hatch cannot be a stored address someone could repoint.
    address public constant DIVIDEND_TREASURY = DeploymentAddresses.REALM_TREASURY;

    /// @notice One payout asset's entire machine. THREE SLOTS, packed so the transfer hot path reads
    ///         the first one alone unless that asset's stream is actually running.
    /// @dev Slot 0 (`rewardPerTokenStored` + the three clocks + `precisionExp` = 256 bits exactly) is
    ///      the hot slot: the "has anything accrued since the last sync?" test and the settle arithmetic
    ///      both live entirely inside it. Slot 1 (`token` + `rate`) is only touched when the accumulator
    ///      actually advances or a payout is made, and slot 2 (the ledger and the buffer) only
    ///      out-of-band. That is what keeps a single-asset token at the cost it had before this struct
    ///      existed: one SLOAD when idle, two when advancing.
    /// @dev `failedConversionBlock` is a `uint40` here where it used to need a full word of its own: the
    ///      old reason was that the compiler would otherwise pack it into the head of the tax slot that
    ///      followed and evict `graduationTimestamp` from it. Inside a struct array it cannot leak into
    ///      a neighbouring variable's slot, so that reason is gone.
    /// @dev `owed` is `uint128` (3.4e38 units) rather than the old `uint160`: it counts payout-asset
    ///      units this token still has to deliver, which is bounded by everything it has ever streamed,
    ///      and the accumulator's own documented ceiling is orders of magnitude below this.
    struct DivAsset {
        // --- slot 0: the hot slot ---
        /// @dev Payout per unit of eligible supply, accumulated over this asset's life, scaled by
        ///      `10 ** precisionExp`. Monotonic: it only ever advances with the clock.
        uint128 rewardPerTokenStored;
        /// @dev When this asset's current stream runs dry. Also its staleness anchor, and its "dividends
        ///      are active" flag: 0 until the token graduates.
        uint40 periodFinish;
        /// @dev When `rewardPerTokenStored` was last advanced, clamped to `periodFinish` (a stream
        ///      cannot accrue past its own end).
        uint40 lastUpdate;
        /// @dev Block of the last call that actually moved this asset's buffer — a funded conversion or
        ///      a treasury sweep. Gates the FUNDING leg of `processDividends` to once per block, per
        ///      asset.
        uint40 lastProcessBlock;
        /// @dev `rewardPerTokenStored`'s fixed-point scale, as a power of ten:
        ///      `DIVIDEND_PRECISION_DECIMALS - payout asset decimals`, written once at creation. Storage
        ///      rather than a constant because the right scale depends on the payout asset, and the
        ///      asset is the creator's choice — see `DIVIDEND_PRECISION_DECIMALS`.
        uint8 precisionExp;
        // --- slot 1 ---
        /// @dev The payout asset. `address(0)` = native, `address(this)` = the token itself, anything
        ///      else = a third ERC20 bought through `DIVIDEND_SWAP_REGISTRY`. Written ONCE, at creation,
        ///      and never again — a pool that dies is handled by sweeping the unconvertible buffer to
        ///      `DIVIDEND_TREASURY`, not by repointing the payout.
        address token;
        /// @dev Current stream slope, in payout-asset units per second.
        uint96 rate;
        // --- slot 2: out-of-band only ---
        /// @dev Payout-asset units this token owes holders for this asset: everything streamed into the
        ///      accumulator, minus everything actually delivered. THE single source of truth for "how
        ///      much of this balance is not ours", read through `committedDividends`.
        uint128 owed;
        /// @dev Native earnings accrued to THIS asset so far, awaiting a distribution.
        ///      ~309M units of the chain's native currency. The width matters because "native" is not
        ///      ETH everywhere: on ARC it is USDC-denominated, where a narrower field would cap the
        ///      buffer at a dollar figure a token could conceivably reach.
        uint88 pendingNative;
        /// @dev Block in which a zero-floor conversion of this asset was last seen to return nothing,
        ///      i.e. the first half of the treasury sweep's proof that the pool is really gone. 0 = no
        ///      failure on record.
        ///      The PERSISTENCE MARKER. "The pool produced nothing at any price" is a snapshot, and a
        ///      snapshot is manufacturable — and far more cheaply than emptying the pool, because the
        ///      registry also refuses whenever depth merely dips under its threshold. One sell is enough
        ///      to cause the failure and one buy to undo it. Requiring the same failure in a LATER block
        ///      forces the griefer to hold that position across a block boundary, twice, per slice
        ///      swept. A genuinely dead pool just needs one extra call.
        uint40 failedConversionBlock;
    }

    /// @notice Per-account, per-asset dividend state. One slot each, and the only per-account storage
    ///         the feature has.
    /// @dev `rewardPerTokenPaid` is the accumulator value this account was last settled at; `rewards` is
    ///      what it has banked and not yet been paid.
    /// @dev `rewards` is `uint120` (1.3e36 payout-asset units) because it shares the slot. It bounds a
    ///      SINGLE holder's UNCLAIMED accrual for ONE asset, which cannot exceed everything the token
    ///      has ever distributed in it; for any asset the registry accepts that is orders of magnitude
    ///      out of reach.
    struct Acct {
        uint128 rewardPerTokenPaid;
        uint120 rewards;
    }

    /// @notice The configured payout assets. Entries at or beyond `_dividendAssetCount()` are unused
    ///         and must never be read — a zeroed entry is indistinguishable from a native payout that
    ///         has not graduated yet.
    /// @dev `public`, and MEASURED to be the cheap option: the compiler's getter returns the ten fields
    ///      as a flat tuple, and a hand-written `dividendAsset(uint256) returns (DivAsset memory)` costs
    ///      the clone ~280 bytes MORE than it (the struct encodes to the same tuple either way, and the
    ///      memory copy is extra). On a contract this close to EIP-170 that is worth stating: do not
    ///      "optimise" this into an internal variable plus a wrapper.
    DivAsset[MAX_DIVIDEND_ASSETS] public dividendAssets;

    /// @notice Per-account accumulator checkpoint + banked payout, one entry per configured asset.
    ///         See `Acct`.
    /// @dev `internal` with NO getter, unlike `dividendAssets` above: the raw checkpoint is an
    ///      implementation detail, and the only question anyone asks of it — what is this holder owed
    ///      right now — is answered exactly by `previewDividend(holder, i)`, which also folds in the
    ///      drip since the last sync. A getter for the two raw fields would cost the clone bytecode to
    ///      return a number every reader would then have to correct.
    mapping(address account => Acct[MAX_DIVIDEND_ASSETS]) internal dividendAccounts;

    /// @notice How the dividends slice of earnings is split between the configured assets, in bps of
    ///         that slice. Sums to `DIVIDEND_BPS_TOTAL` across the configured entries; every configured
    ///         entry is non-zero.
    /// @dev Its own slot, off the transfer hot path: it is read only when earnings are routed, which is
    ///      the V2 swap-back and the V4 fee-router call, never a plain transfer.
    uint16[MAX_DIVIDEND_ASSETS] public dividendWeightsBps;

    /// @dev Reentrancy guard for every dividend entry point that makes an external call: the payouts,
    ///      which send to arbitrary addresses, and the funding, which swaps through the venue. One lock
    ///      covers all assets because they are not independent HERE — they share this contract's balance,
    ///      and a funding reentered mid-swap would fund a second stream off a buffer the outer call is
    ///      about to spend. Transient, so it costs no SSTORE and is independent of any guard the concrete
    ///      token already uses.
    bool private transient dividendLocked;

    /// @dev Taken once per external call rather than once per holder, so a large batch pays for a single
    ///      transient write instead of one per address.
    modifier nonReentrantDividends() {
        require(!dividendLocked, DividendReentrancy());
        dividendLocked = true;
        _;
        dividendLocked = false;
    }

    //////////////////////// Events //////////////////////

    /// @notice Emitted once at creation for a token configured with a non-zero dividends allocation,
    ///         carrying the FIRST payout asset. Kept unchanged, and kept emitted, so indexers written
    ///         against the single-asset shape keep working; `DividendAssetInitialized` is the complete
    ///         description of the configuration.
    event DividendsInitialized(address dividendToken);

    /// @notice Emitted once per configured payout asset at creation: which slot it occupies, what it is,
    ///         and what share of the dividends slice it takes.
    event DividendAssetInitialized(uint256 indexed index, address asset, uint16 weightBps);

    /// @notice Dividends went live: the accumulators start running and the staleness clocks start here.
    ///         Emitted once, at graduation, for all configured assets at once.
    event DividendsActivated();

    /// @notice A distribution funded one asset's stream. `nativeIn` is the native buffer consumed (0 for
    ///         the V2 token-space payout), `assetOut` what it bought. `rate` and `periodFinish` describe
    ///         that asset's stream AFTER the fold-in, which is the authoritative slope from this block on.
    event DividendsFunded(
        address indexed asset, uint256 nativeIn, uint256 assetOut, uint256 rate, uint256 periodFinish
    );

    /// @notice One holder, one asset, one payout of everything they had accrued in it at that moment.
    event DividendPaid(address indexed holder, address indexed asset, uint256 amount);

    /// @notice A fundable buffer could not be converted into `asset` at ANY price, so `nativeAmount` went
    ///         to `DIVIDEND_TREASURY` instead of sitting owed to holders forever. The payout asset is
    ///         unchanged and nothing accrued is written off — this only ever moves native that was still
    ///         waiting to be converted.
    event DividendBufferSweptToTreasury(address indexed asset, uint256 nativeAmount);

    //////////////////////// Errors //////////////////////

    error DividendsNotActive();
    /// @notice The buffer is not yet worth a distribution. Distinct from `DividendConversionFailed`:
    ///         this one means wait for more earnings, that one means the earnings are there and the
    ///         swap is the problem.
    /// @dev Only ever raised by a call that asked for NOTHING ELSE. A `processDividends` carrying a
    ///      holder list pushes those payouts and returns quietly, because a keeper batching payouts
    ///      must not be punished for the buffer happening to be short.
    error BelowDividendThreshold();
    /// @notice The buffer was fundable and the conversion failed, so nothing was streamed.
    error DividendConversionFailed();
    /// @notice This asset's buffer already moved in this block. Only the funding leg is gated — a call
    ///         carrying holders still pays them.
    error DividendProcessCooldown();
    /// @notice The treasury refused the swept buffer. Reverts the whole call, leaving the buffer where it
    ///         was — the same state a caller who never tried would have seen.
    error DividendSweepFailed();
    error DividendBufferOverflow();
    error DividendReentrancy();
    /// @notice The payout-asset set is not a valid configuration: no assets, more than
    ///         `MAX_DIVIDEND_ASSETS`, a zero weight, weights that do not sum to `DIVIDEND_BPS_TOTAL`, or
    ///         the same asset named twice (which would make `committedDividends` under-report the debt
    ///         and hand the difference to `rescueTokens`).
    error InvalidDividendAssetSet();
    /// @notice `DIVIDEND_SELF_TOKEN` was named alongside other payout assets. Only legal on its own.
    error SelfTokenDividendMustBeSole();
    /// @notice The asset index is at or beyond this token's configured count.
    error DividendAssetOutOfRange();

    //////////////////////// hot path //////////////////////

    /// @dev Settles EVERY configured asset on both sides of a balance change. Called from the token's
    ///      `_update`, BEFORE the balances move — see the ordering rule on the contract docstring, which
    ///      this function is the whole of the enforcement of.
    /// @dev The transferred AMOUNT is deliberately not a parameter: settling reads each account's
    ///      pre-transfer balance, and the accumulator does not care where the tokens are going.
    /// @dev The eligible supply is computed at most once for the whole loop, and only if some asset has
    ///      actually accrued — the same denominator applies to all of them, and it is the single most
    ///      expensive read on this path.
    function _onDividendTransfer(address from, address to) internal {
        uint256 n = _dividendAssetCount();

        bool settleFrom = from != address(0) && !_dividendExcluded(from);
        bool settleTo = to != address(0) && !_dividendExcluded(to);

        // 0 is the "not loaded" sentinel. A genuinely zero eligible supply falls into the paused branch
        // of `_syncDividend`, which does not use the value, so re-reading it there costs a degenerate
        // token a few SLOADs and nobody else anything.
        uint256 supply;
        for (uint256 i; i < n; ++i) {
            uint256 rpt;
            (rpt, supply) = _syncDividend(i, supply);
            if (settleFrom) _settleDividends(from, i, rpt);
            if (settleTo) _settleDividends(to, i, rpt);
        }
    }

    /// @dev Advances one asset's accumulator to now and returns it, alongside the eligible supply it
    ///      ended up using so a caller looping several assets can reuse it.
    ///
    ///      | case                                            | writes                              |
    ///      |-------------------------------------------------|-------------------------------------|
    ///      | not activated, or no time since the last sync    | none                                |
    ///      | time passed, eligible supply above the floor     | the hot slot                        |
    ///      | time passed, eligible supply below the floor     | the clock + the finish line          |
    ///
    /// @dev Between an asset's streams `lastUpdate == periodFinish`, so this is a single warm SLOAD and
    ///      a comparison. That is the whole hot-path cost of that asset while nothing is dripping — and
    ///      it is why the struct puts both clocks and the accumulator in one slot.
    /// @param supplyCache The eligible supply already read in this call, or 0 if none has been.
    function _syncDividend(uint256 i, uint256 supplyCache) internal returns (uint256 rpt, uint256 supply) {
        supply = supplyCache;
        DivAsset storage a = dividendAssets[i];

        rpt = a.rewardPerTokenStored;
        uint256 last = a.lastUpdate;
        uint256 finish = a.periodFinish;
        // `finish == 0` is pre-graduation: nothing can have accrued, and `applicable` is 0 <= `last`.
        uint256 applicable = block.timestamp < finish ? block.timestamp : finish;
        if (applicable <= last) return (rpt, supply);

        if (supply == 0) supply = _dividendEligibleSupply();
        if (supply >= MIN_DIVIDEND_SUPPLY) {
            rpt += (applicable - last) * a.rate * _dividendPrecision(i) / supply;
            // Bounded by `MIN_DIVIDEND_SUPPLY`: the accumulator's lifetime growth cannot exceed the
            // total ever distributed times `1e18 / MIN_DIVIDEND_SUPPLY`, which is 1.
            // forge-lint: disable-next-line(unsafe-typecast)
            a.rewardPerTokenStored = uint128(rpt);
        } else if (a.rate != 0) {
            // PAUSED: credit nobody for this interval, but do not write it off either. Pushing the finish
            // line out by exactly the paused span leaves `rate` untouched and the same total still to
            // deliver, so the value arrives late instead of never — `owed` already counted it, and
            // nothing else can ever release it. Same slot as the clock below, so this costs nothing.
            // forge-lint: disable-next-line(unsafe-typecast)
            a.periodFinish = uint40(finish + (applicable - last));
        }
        // Advances even when the accrual was skipped. See `MIN_DIVIDEND_SUPPLY`.
        // forge-lint: disable-next-line(unsafe-typecast)
        a.lastUpdate = uint40(applicable);
    }

    /// @dev Banks everything `account` has accrued in asset `i` since it was last settled, at the
    ///      CURRENT balance — which is why every caller has to settle before the balance moves.
    function _settleDividends(address account, uint256 i, uint256 rpt) internal {
        Acct storage acct = dividendAccounts[account][i];

        uint256 paid = acct.rewardPerTokenPaid;
        // Nothing has accrued since this account last moved — the common case for an active trader while
        // this asset is not streaming, and the reason a transfer can cost zero account writes.
        if (paid == rpt) return;

        // `rpt` is read straight out of `uint128 rewardPerTokenStored`.
        // forge-lint: disable-next-line(unsafe-typecast)
        acct.rewardPerTokenPaid = uint128(rpt);
        // See `Acct`: bounded by everything the token has ever distributed, and out of reach for any
        // sanely-priced payout asset. SATURATING rather than wrapping, and rather than reverting — the
        // registry vets an asset's liquidity, never its decimals or its supply, so the ceiling is not
        // provably unreachable, and this runs inside `_update`. An unchecked cast would erase a holder's
        // whole banked accrual silently; a revert would freeze their transfers for good. Capping loses
        // only the part above the ceiling and keeps both the token and the claim working, the same
        // trade `_reduceDividendsOwed` makes on the other side of the ledger.
        uint256 accrued = uint256(acct.rewards) + _dividendBalanceOf(account) * (rpt - paid) / _dividendPrecision(i);
        acct.rewards = accrued > type(uint120).max ? type(uint120).max : uint120(accrued);
    }

    /// @dev One asset's accumulator scale. See `DivAsset.precisionExp`. `unchecked` because the exponent
    ///      is at most `DIVIDEND_PRECISION_DECIMALS`, and `10 ** 36` is nowhere near a `uint256`.
    function _dividendPrecision(uint256 i) internal view returns (uint256) {
        unchecked {
            return 10 ** dividendAssets[i].precisionExp;
        }
    }

    /// @dev The instant one asset's stream has accrued up to: now, or its end, whichever came first.
    function _dividendTimeApplicable(uint256 i) private view returns (uint256) {
        uint256 finish = dividendAssets[i].periodFinish;
        return block.timestamp < finish ? block.timestamp : finish;
    }

    //////////////////////// accrual //////////////////////

    /// @dev Buffers `amount` of native earnings, split across the configured assets by
    ///      `dividendWeightsBps`. Consumes the whole amount (returns 0) unless the payout is buffered in
    ///      TOKEN space, in which case it consumes nothing and the caller folds it back to the fund
    ///      wallets — that share was already peeled upstream, in token space, before this ETH existed.
    /// @dev The LAST configured asset takes the remainder rather than its own bps product, so integer
    ///      division cannot strand a wei or hand the same wei to two assets.
    /// @dev Refuses to truncate rather than wrapping. The branch is a bytecode-level assertion, not a
    ///      reachable path — but it is a REVERT on the earnings path, and on V2 that path runs inside a
    ///      sell, so a full buffer would brick sells until someone distributed. That consequence is why
    ///      `pendingNative` is sized to fill its slot instead of to the nearest byte boundary.
    function _accrueDividends(uint256 amount) internal returns (uint256 unconsumed) {
        if (amount == 0) return amount;
        uint256 n = _dividendAssetCount();
        // Unreachable with a non-zero amount — the split only routes a dividends slice when `dividendsBps`
        // is set, which is what turns the feature on — but the fall-through below would report the whole
        // amount CONSUMED while buffering none of it, stranding it as stray native. Cheaper to close than
        // to reason about every future caller.
        if (n == 0) return amount;
        // No token-space short-circuit here, deliberately: `EarningsAllocation._splitEthEarnings` already
        // removes the token-space share from BOTH the numerator and the denominator
        // (`_tokenSpaceDividendBps`), so a sole self-token payout arrives with `dividends == 0` and never
        // reaches this function at all. A guard for it would be dead code paying a cold SLOAD
        // (`dividendAssets[0].token` is in a slot nothing else here touches) on every earnings routing of
        // every dividend token — including the V4 fee-router path, which runs under the hook's budget.
        uint256 remaining = amount;
        for (uint256 i; i < n; ++i) {
            uint256 share = i + 1 == n ? remaining : amount * dividendWeightsBps[i] / DIVIDEND_BPS_TOTAL;
            remaining -= share;
            if (share == 0) continue;

            uint256 updated = uint256(dividendAssets[i].pendingNative) + share;
            require(updated <= type(uint88).max, DividendBufferOverflow());
            // forge-lint: disable-next-line(unsafe-typecast)
            dividendAssets[i].pendingNative = uint88(updated);
        }
        return 0;
    }

    //////////////////////// views //////////////////////

    /// @notice One asset's accumulator as of RIGHT NOW, including whatever its running stream has
    ///         dripped since the last on-chain sync.
    function dividendRewardPerToken(uint256 i) public view returns (uint256 rpt) {
        DivAsset storage a = dividendAssets[i];
        rpt = a.rewardPerTokenStored;
        uint256 last = a.lastUpdate;
        uint256 applicable = _dividendTimeApplicable(i);
        if (applicable <= last) return rpt;

        uint256 supply = _dividendEligibleSupply();
        if (supply < MIN_DIVIDEND_SUPPLY) return rpt;
        return rpt + (applicable - last) * a.rate * _dividendPrecision(i) / supply;
    }

    /// @notice What `holder` would receive in asset `i` if they claimed right now: banked accruals plus
    ///         whatever the running stream has dripped to them since they last moved.
    function previewDividend(address holder, uint256 i) public view returns (uint256) {
        if (_dividendExcluded(holder)) return 0;
        Acct storage acct = dividendAccounts[holder][i];
        return acct.rewards + _dividendBalanceOf(holder) * (dividendRewardPerToken(i) - acct.rewardPerTokenPaid)
            / _dividendPrecision(i);
    }

    /// @notice Dividend money already streamed to holders in `asset` but not yet delivered.
    /// @dev THE single source of truth for "how much of this balance is not ours". Every sweep, swap-back
    ///      and rescue path subtracts this rather than open-coding its own subtraction, so a future
    ///      bucket is added in one place and every call site inherits it.
    /// @dev Sums across the configured set even though `_initializeDividends` rejects a duplicated asset:
    ///      the failure mode of getting this wrong is not a lost balance but a silent transfer of
    ///      holders' money to the owner through `rescueTokens`, and the loop costs nothing to be certain.
    function committedDividends(address asset) public view returns (uint256 owed) {
        uint256 n = _dividendAssetCount();
        for (uint256 i; i < n; ++i) {
            if (dividendAssets[i].token == asset) owed += dividendAssets[i].owed;
        }
    }

    /// @notice Whether asset `i` has gone `STALE_DIVIDEND_WINDOW` without a distribution, i.e. it is
    ///         treated as dead. Unlocks funding below `DIVIDEND_THRESHOLD` and the treasury sweep.
    function dividendsStale(uint256 i) public view returns (bool) {
        uint256 finish = dividendAssets[i].periodFinish;
        return finish != 0 && block.timestamp >= finish + STALE_DIVIDEND_WINDOW;
    }

    //////////////////////// single-asset views //////////////////////
    // The most-read part of the surface a single-asset token had before several were possible, kept
    // verbatim and answering for asset 0.
    //
    // ⚠️ THIS SET IS SMALLER THAN IT WAS, and deliberately: `dividendRate`, `lastDividendUpdate`,
    // `dividendPrecisionExp`, `failedConversionBlock`, `rewardPerTokenStored` and
    // `lastDividendProcessBlock`, plus the no-argument `dividendRewardPerToken` / `dividendsStale`, are
    // gone. Every one of them is `dividendAssets(0).<field>` or the indexed view above, and the token
    // implementation is up against EIP-170 — a getter that only restates a field of a struct this
    // contract already returns is the first thing to spend. Nothing on chain read them (the only
    // in-protocol reader is `committedDividends`, which stays); this is an ABI change for OFF-chain
    // readers of NEWLY created tokens only, since every token already deployed keeps its own bytecode.
    // The ones below stay because they carry the traffic: wallets, the keeper and the indexer.

    /// @notice Asset 0's payout token. See `DivAsset.token`.
    function dividendToken() public view returns (address) {
        return dividendAssets[0].token;
    }

    /// @notice Asset 0's stream end. Also the token-wide "dividends are active" flag: every configured
    ///         asset is activated in the same call, so index 0 answers for all of them.
    function dividendPeriodFinish() public view returns (uint40) {
        return dividendAssets[0].periodFinish;
    }

    /// @notice Asset 0's undelivered ledger. See `DivAsset.owed`.
    function dividendsOwed() public view returns (uint128) {
        return dividendAssets[0].owed;
    }

    /// @notice Asset 0's native buffer awaiting conversion.
    function pendingNative() public view returns (uint88) {
        return dividendAssets[0].pendingNative;
    }

    /// @notice What `holder` would receive in asset 0 right now. See `previewDividend(address,uint256)`.
    function previewDividend(address holder) public view returns (uint256) {
        return previewDividend(holder, 0);
    }

    //////////////////////// internal //////////////////////

    /// @dev Starts every configured asset's accumulator running. Before this, `periodFinish == 0`
    ///      short-circuits the transfer hook and anchors nothing; after it, the staleness clocks are live.
    function _activateDividends() internal {
        uint256 n = _dividendAssetCount();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 nowTs = uint40(block.timestamp);
        for (uint256 i; i < n; ++i) {
            DivAsset storage a = dividendAssets[i];
            a.periodFinish = nowTs;
            a.lastUpdate = nowTs;
        }
        emit DividendsActivated();
    }

    //////////////////////// hooks the token supplies //////////////////////

    /// @dev How many payout assets are configured. Lives on the token, packed into the `pair` slot
    ///      `_update` has already loaded, so reading it on the transfer path is a warm SLOAD.
    function _dividendAssetCount() internal view virtual returns (uint256);

    /// @dev The token's ERC20 balance of `account`.
    function _dividendBalanceOf(address account) internal view virtual returns (uint256);

    /// @dev Addresses that never earn: they hold a balance continuously but are not holders.
    function _dividendExcluded(address account) internal view virtual returns (bool);

    /// @dev `totalSupply` minus the balances of every excluded address. Read on every accumulator
    ///      advance, so it is the denominator in effect for the interval being settled — which is exact,
    ///      because every path that can change it goes through `_update` and therefore syncs first.
    function _dividendEligibleSupply() internal view virtual returns (uint256);

    /// @dev Whether the payout asset must be buffered in TOKEN space rather than as native. Only the
    ///      Uniswap-V2 self-token payout answers true, and only a sole-asset token can configure it.
    function _isTokenSpaceDividendAsset(address asset) internal view virtual returns (bool) {
        asset; // silences the unused-parameter warning without naming the arg away in overrides
        return false;
    }
}
