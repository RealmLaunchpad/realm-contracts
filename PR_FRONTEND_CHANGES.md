# Frontend Integration Changes: `refactor/factory-based-token-deployment`

Summary of all function signature and functionality changes that affect frontend integration compared to `main`.

---

## 1. Token Creation

- **Removed**: `LivoLaunchpad.createToken()` no longer exists on the launchpad
- **New**: Token creation is now handled by factory contracts. Each factory may have different input arguments (like the tax configs for instance). Notably, there is no need to pass now graduator, token implementation, bonding curve, etc. They are hardcoded in the different factories:
  - `LivoFactoryBase.createToken(string name, string symbol, address tokenOwner, bytes32 salt)` 
  - `LivoFactoryTaxToken.createToken(string name, string symbol, uint16 sellTaxBps, uint32 taxDurationSeconds)`
- Frontend must call the appropriate factory contract instead of the launchpad:
  - Univ2: `LivoFactoryBase`
  - Univ4: `LivoFactoryBase`
  - Univ4Taxes: `LivoFactoryTaxToken`

## 2. Ownership Management

- **Removed from `LivoLaunchpad`**: `getTokenOwner()`
- **Now on `ILivoToken.owner()` (each token contract directly)**:

## 3. Fee Management (New)

New contracts `LivoFeeHandlerBase` and `LivoFeeHandlerUniV4` handle fee claiming. This logic was before in the Univ4 graduator. Now it is centralized to manage all types of fees (graduation, LPfees, taxes, etc). 

- `claim(address[] tokens)` — claim accrued fees for a token and claims pending from any source
- `getClaimable(address[] tokens, address account)` — view claimable fees (from any source: graduation, taxes, LPfees, etc). This can be retrieved from envio as well.

## 4. Token Interface (`ILivoToken`)

New view/setter functions available on each token:

- `owner()` — returns token owner
- `feeReceiver()` — returns the fee receiver address (equivalent to old tokenOwner/creator)
- `feeHandler()` — returns the fee handler contract address. Each token has a fee handler from where to call claim() and getClaimable()
- `setFeeReceiver(address)` — update fee receiver (token owner only)  -> for the future, if we want people to update their fee receivers. 
