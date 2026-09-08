## formatting
run `forge fmt` after any modification to .sol files

## tests
`just fast-test` runs the storage-layout check first (`just check-dividend-layout`), so the two always go together. If you run `forge test` directly instead of `just fast-test`, run `just check-dividend-layout` alongside it.

`fast-test` is two builds: the Ethereum-mainnet-forked suites with the token impls retargeted at mainnet, then the Robinhood-mainnet-forked suites (`test/integration/fork/robinhood/`, real xStock dividends) via `just test-robinhood-fork`, which retargets at Robinhood. One build cannot serve both — the impls bake one chain's addresses and refuse a mismatched chain id — so a bare `forge test` only ever runs the suites of whatever chain the tree is currently retargeted to. `fast-test` leaves the tree on mainnet, the committed test default.

The check compares the storage layout of each taxable token against its dividend extension (`RealmTaxableTokenUniV2` vs `RealmDividendLogicUniV2`, and the V4 pair). The extension is `delegatecall`ed with the token's storage, so a layout that drifts would have it writing the wrong slots on live, non-upgradeable clones — and no Solidity test can assert this about itself. Never skip it after touching the token hierarchy (`src/tokens/`), and never "fix" a failure by editing the check.

## docs
Any time a change is made to the contracts in `src/` that affects events, we should update the `docs/events-per-entry-point.md` document. Example changes that should trigger this update:
- event name/signature changes
- event order changes
- new events added or events removed (new functions added / removed) 
