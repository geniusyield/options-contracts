# Security Audit & Readiness Memo — GeniusYield Options Contracts

**Status:** Internal review  
**Scope:** On-chain validators only (`option_spend`, `option_mint`, `option_fee_config`)  
**Implementations reviewed:** PlutusTx/PlutusV2 (`plutustx/`) and Aiken/PlutusV3 (`aiken/`)  
**Date:** 2026-04-28  

---

## Scope & methodology

This memo covers the on-chain smart-contract logic.  
Off-chain infrastructure (API server, key management, frontend) is out of scope.

Review method:

1. Manual line-by-line inspection of both implementations.
2. Cross-check: every check in PlutusTx must appear (semantically) in Aiken and vice versa.
3. Threat modelling by actor × asset.
4. Test-suite gap analysis against the CLB emulator suite in `tests/Option.hs`.

---

## Threat model

### Actors

| Actor | Capabilities | Goal |
|-------|-------------|------|
| Executor (option holder) | Holds option tokens; submits Execute txs | Receive max deposit tokens, pay min payment |
| Seller (writer) | Holds seller key; submitted Create | Protect deposit; cancel or retrieve when appropriate |
| Third party | No position; sees mempool | Extract value from either party |
| Block producer | Can order/delay txs, set slot time within HARDFORK bounds | Reorder or time-manipulate txs |

### Assets at risk

| Asset | Owner | Held in |
|-------|-------|---------|
| Deposited tokens (e.g. tGENS) | Seller | Script UTxO |
| Payment tokens (e.g. ADA) | Executor (pre-Execute) | Executor wallet |
| Position NFT | Contract | Script UTxO |
| Min-ADA (3 ADA) | Seller | Script UTxO |

---

## Threat matrix

| ID | Threat | Actor | Severity | Status |
|----|--------|-------|----------|--------|
| T1 | Datum manipulation on Execute | Executor | **Critical** | Mitigated |
| T2 | Payment bypass | Executor | **Critical** | Mitigated |
| T3 | Over-withdrawal of deposit | Executor | **High** | Mitigated |
| T4 | Premature Retrieve (seller rug-pull) | Seller | **High** | Mitigated |
| T5 | CancelEarly after cutoff | Seller | **High** | Mitigated |
| T6 | Validity range gaming (wide range on Execute) | Executor | **High** | Mitigated |
| T7 | Fee bypass via missing/fake fee-config reference | Executor | **High** | Mitigated |
| T8 | Fee config update without authorisation | Third party | **High** | Mitigated |
| T9 | Datum injection via extra script output | Executor | **Medium** | Mitigated |
| T10 | Option token name forgery | Third party | **Medium** | Mitigated |
| T11 | NFT duplication for same option | Third party | **Medium** | Mitigated |
| T12 | ADA extraction from min-ADA buffer | Executor | **Medium** | Mitigated |
| T13 | Front-running Execute (MEV) | Block producer | **Low** | Accepted |
| T14 | Zero-price option minted by mistake | Seller | **Low** | Accepted (off-chain) |
| T15 | Integer overflow in payment arithmetic | N/A | **Low** | Non-issue |
| T16 | Script version / migration lock-in | N/A | **Info** | Accepted |

---

## Detailed findings

### T1 — Datum manipulation on Execute (Critical → Mitigated)

**Attack:** Executor builds a continuing output at the script address with a modified `OptionDatum` — e.g. extending `end`, reducing `price`, or changing `deposit` to a worthless token.

**Mitigation:**  
Both implementations enforce `sameDatum`: the inline datum on the continuing output must equal the datum from the input being spent.

```haskell
-- PlutusTx
sameDatum = depositDatum == d
```

```aiken
// Aiken
let same_datum =
  when deposit_output.datum is {
    InlineDatum(raw) -> { expect od: OptionDatum = raw; od == d }
    _ -> False
  }
```

**Status:** Full structural equality enforced on every field.  
**Note:** The PlutusTx `Eq` instance omits `opdPrice` from the equality check (line 68 of `Option.hs` jumps from `opdEnd/opdCancelCutoff` to `opdDeposit`). The price fields are not compared. **See T1-OPT below.**

---

### T1-OPT — Missing price equality in PlutusTx `Eq` instance (Medium — Open)

```haskell
-- Current (Option.hs:58-68):
instance Eq OptionDatum where
  x == y =
    (opdRef x == opdRef y)
      && (opdToken x == opdToken y)
      && (opdStart x == opdStart y)
      && (opdEnd x == opdEnd y)
      && (opdCancelCutoff x == opdCancelCutoff y)
      && (opdDeposit x == opdDeposit y)
      && (opdPayment x == opdPayment y)
      && (opdSellerKey x == opdSellerKey y)
      -- ⚠ opdPrice is NOT compared
```

`opdPrice :: Rational` is absent. An executor could replace the datum with one carrying a lower price and `sameDatum` would not catch it.

**Impact:** Executor could ratchet the price down on each partial fill until they eventually execute for free.

**Fix (PlutusTx):** Add `&& (opdPrice x == opdPrice y)` to the `Eq` instance.

**Aiken status:** The Aiken implementation uses Aiken's built-in structural equality (`od == d`), which compares ALL fields including `price`. Aiken is **not affected**.

---

### T2 — Payment bypass (Critical → Mitigated)

**Attack:** Executor burns option tokens but sends zero (or insufficient) payment.

**Mitigation:** Cross-multiply check avoids division:

```haskell
-- PlutusTx
fromInteger actualPayment >= opdPrice * fromInteger amount
-- ↔ actualPayment * denominator >= numerator * amount (no division)
```

```aiken
// Aiken
actual_payment * opd_price.denominator >= opd_price.numerator * amount
```

**Status:** Correct. Integer arithmetic, no floating-point, no division-by-zero.

---

### T3 — Over-withdrawal of deposit (High → Mitigated)

**Attack:** Executor burns `amount` tokens but takes `amount + k` deposit units from the script UTxO.

**Mitigation:**

```haskell
depositTaken = assetClassValueOf ownValue opdDeposit
             - assetClassValueOf depositValue opdDeposit
-- must be ≤ amount
```

ADA is handled separately: `adaTaken ≤ 0` unless the deposit or payment asset IS ADA.

**Status:** Mitigated for both token and ADA deposits.

---

### T4 — Premature Retrieve / seller rug-pull (High → Mitigated)

**Attack:** Seller calls Retrieve before `end`, recovering the deposit while option holders still have valid tokens.

**Mitigation:**

```haskell
-- PlutusTx: validity range must be contained in [end, ∞)
deadlinePassed = from opdEnd `contains` validRange
```

```aiken
// Aiken
let deadline_passed = valid_from_at_least(tx, opd_end)
```

A block producer cannot set slot time before the actual wall time by more than the slot drift tolerance (~3 s on mainnet).

**Status:** Mitigated. Option holders can safely hold tokens up to `end`.

---

### T5 — CancelEarly after cutoff (High → Mitigated)

**Attack:** Seller calls CancelEarly after `cancelCutoff`, revoking options that holders legitimately purchased and expected to be exercisable until `end`.

**Mitigation:**

```haskell
-- PlutusTx: range must be contained in (-∞, cancelCutoff-1]
beforeCutoff = to (opdCancelCutoff - 1) `contains` validRange
```

```aiken
// Aiken (off-by-one handled identically)
let before_cutoff = valid_until_at_most(tx, opd_cancel_cutoff - 1)
```

**Status:** Mitigated. The `-1` offset ensures the boundary is exclusive.

---

### T6 — Validity range gaming on Execute (High → Mitigated)

**Attack:** Executor sets a validity range `[start - 1, end + 1]` which overlaps the execution window, hoping the validator only checks one bound.

**Mitigation:** Execute requires the range to be **contained in** `[start, end]` — both bounds are checked:

```haskell
-- PlutusTx
interval opdStart opdEnd `contains` validRange
```

```aiken
// Aiken checks both bounds independently
valid_from_at_least(tx, opd_start) && valid_until_at_most(tx, opd_end)
```

A range `[start-1, end]` fails because lower bound < start. A range `[start, end+1]` fails because upper bound > end.

**Status:** Mitigated.

---

### T7 — Fee bypass (High → Mitigated)

**Attack:** When fees are enabled, executor omits the fee-config reference input (or provides a fake UTxO without the fee NFT).

**Mitigation:**

```haskell
-- PlutusTx: if fee NFT is non-sentinel and no config found → hard error
Nothing -> traceError "fee config not in reference inputs"
```

```aiken
// Aiken
None -> fail @"fee config not in reference inputs"
```

The fee-config UTxO is identified by the specific NFT asset class baked into the spend validator at deployment. An attacker cannot forge that NFT (standard Cardano NFT uniqueness guarantee).

**Status:** Mitigated.

---

### T8 — Fee config update without authorisation (High → Mitigated)

**Attack:** Attacker submits an `updateFeeConfig` transaction to redirect fee payments to their own address.

**Mitigation:** `OptionFeeConfigValidator` enforces M-of-N multisig:

```haskell
hasSignatures = go 0 (txInfoSignatories info) sigs
  where reqSigs = ofcdReqSignatories d
```

Additionally: config NFT must be present in both input and continuing output, denominator > 0, numerator ≥ 0, reqSignatories ≥ 1 and ≤ len(signatories).

**Status:** Mitigated.

---

### T9 — Datum injection via extra script output (Medium → Mitigated)

**Attack:** Executor creates two outputs at the script address — the legitimate continuing output and a second one with a manipulated datum — hoping the validator reads the wrong one.

**Mitigation:** Both `findDeposit` (PlutusTx) and `find_deposit` (Aiken) require **exactly one** output at the own address:

```haskell
[o] -> ...  -- exactly one
_xs -> traceError "expected exactly one deposit output"
```

**Status:** Mitigated.

---

### T10 — Option token name forgery (Medium → Mitigated)

**Attack:** Attacker mints tokens with a different policy ID but the correct token name, hoping the spend validator accepts them.

**Mitigation:** The datum field `opdToken` stores the full `AssetClass` (policy ID + token name). Execute checks `assetClassValueOf mint opdToken` — the policy ID must match exactly.

**Status:** Mitigated.

---

### T11 — NFT duplication for same option (Medium → Mitigated)

**Attack:** Attacker tries to mint a second NFT with the same token name to confuse NFT-continuity checks.

**Mitigation:** The NFT policy requires consuming the UTxO whose reference hash is the token name. That UTxO can only be consumed once (UTXO model). A second NFT with the same name would require consuming the same UTxO in a second transaction — impossible after the first.

**Status:** Mitigated by Cardano's eUTXO model.

---

### T12 — ADA extraction from min-ADA buffer (Medium → Mitigated)

**Attack:** Executor drains the 3 ADA min-ADA from the continuing output.

**Mitigation:** `notTakenTooMuch` checks that `adaTaken ≤ 0` unless the deposit or payment asset is ADA (in which case ADA movement is expected and is governed by the deposit/payment checks). The ledger also enforces min-ADA independently on every output.

**Status:** Mitigated for the common case. ADA-for-token and token-for-ADA pairs are handled correctly.

---

### T13 — Front-running Execute / MEV (Low → Accepted)

**Description:** A block producer sees a pending Execute tx and inserts their own Execute tx first.

**Impact:** The second (victim) tx fails because the UTxO is already consumed. The victim must retry. No funds are lost — retry succeeds in the next block.

**Accepted:** This is a fundamental property of any UTXO-model DEX. No on-chain mitigation is possible or necessary. Partial execution means even a successful front-run only takes part of the option.

---

### T14 — Zero-price option (Low → Accepted, off-chain)

**Description:** Seller accidentally deploys an option with `price.numerator = 0`, enabling free execution.

**Impact:** The on-chain validator is correct — zero is a valid price meaning "free". This is the seller's choice and is not a contract bug.

**Mitigation (off-chain):** The API server should warn or reject `numerator = 0` unless explicitly confirmed.

---

### T15 — Integer overflow (Low → Non-issue)

**Description:** `actualPayment × denominator` could overflow.

**Status:** Both Haskell `Integer` (PlutusTx) and Aiken `Int` (PlutusV3) are **arbitrary-precision integers** — overflow is impossible.

---

### T16 — Script version / migration (Info)

**Description:** Deploying a new validator version (e.g. V2 → V3) changes the script hash and therefore the validator address. Existing options at the old address remain valid until they expire or are retrieved.

**Accepted:** No action required. Sellers retrieve existing positions at old address; new positions use new address. The two deployments coexist safely.

---

## Open items

| ID | Issue | Priority |
|----|-------|----------|
| **T1-OPT** | PlutusTx `Eq` instance omits `opdPrice` — executor can mutate price in continuing datum | **High — should fix before mainnet** |
| — | `cancelCutoff` invariant (`start ≤ cutoff ≤ end`) is checked off-chain only | Medium — add on-chain assertion in `option_mint` |
| — | No maximum `amount` check in Execute — executor could burn 0 tokens (no-op Execute) | Low — `tokensBurnt 0 = mint opdToken == 0` is true; a zero-Execute is harmless but wasteful |
| — | Fee config `denominator` is not checked to be > 0 in the spend validator (assumed correct from fee config validator) | Low — defensive check would add script size |

---

## Test coverage gap

The CLB test suite (`tests/Option.hs`) covers the 8 primary happy/failure paths.  Missing test cases:

- Partial execution across multiple transactions (multi-fill sequence)
- Execute with fee config present and fee correctly computed
- Execute with fee config present but fee insufficient (should fail)
- CancelEarly with fee config present (fee not required — should succeed without fee output)
- Retrieve with zero remaining deposit (fully executed position)

---

## Readiness verdict

| Area | Status |
|------|--------|
| Core economic logic (payment, deposit, burns) | ✅ Sound |
| Time-window enforcement | ✅ Sound |
| Datum integrity on partial fill | ⚠️ Price field missing from PlutusTx Eq — **fix required** |
| Fee config | ✅ Sound |
| NFT uniqueness | ✅ Sound |
| Front-running / MEV | ✅ Accepted (UTXO model property) |
| Test coverage | ⚠️ Missing fee-path and multi-fill tests |

**Recommendation:** Fix T1-OPT (add `opdPrice` to PlutusTx `Eq`) before mainnet deployment. The Aiken/PlutusV3 implementation is **not affected** — structural equality covers all fields automatically.
