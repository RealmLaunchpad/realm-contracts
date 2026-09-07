## formatting
run `forge fmt` after any modification to .sol files

## tests
`just fast-test` runs the storage-layout check first (`just check-dividend-layout`), so the two always go together. If you run `forge test` directly instead of `just fast-test`, run `just check-dividend-layout` alongside it.

The check compares the storage layout of each taxable token against its dividend extension (`LivoTaxableTokenUniV2` vs `LivoDividendLogicUniV2`, and the V4 pair). The extension is `delegatecall`ed with the token's storage, so a layout that drifts would have it writing the wrong slots on live, non-upgradeable clones — and no Solidity test can assert this about itself. Never skip it after touching the token hierarchy (`src/tokens/`), and never "fix" a failure by editing the check.

## docs
Any time a change is made to the contracts in `src/` that affects events, we should update the `docs/events-per-entry-point.md` document. Example changes that should trigger this update:
- event name/signature changes
- event order changes
- new events added or events removed (new functions added / removed) 
