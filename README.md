# GeniusYield DEX — Options Contracts

On-chain smart contracts for the GeniusYield decentralised options protocol on Cardano,
together with a CLB emulator test suite and preprod testnet proof-of-evidence.

> **Catalyst Milestone 1** — confirmed preprod transaction hashes are in [`TESTNET.md`](TESTNET.md).

---

## Table of contents

1. [Protocol overview](#protocol-overview)
2. [Datum parameters](#datum-parameters)
3. [Fee configuration](#fee-configuration)
4. [On-chain operations](#on-chain-operations)
5. [Validators](#validators)
6. [Tests](#tests)
7. [Testnet transactions](#testnet-transactions)
8. [Running the demo](#running-the-demo)
9. [Repository layout](#repository-layout)

---

## Protocol overview

An **option** on GeniusYield DEX is a tokenised, on-chain financial derivative.

```
Seller (writer)                              Buyer (holder)
───────────────                              ──────────────
1. Locks N deposit tokens in script UTxO
2. Mints N option tokens  ──────────────▶  buys option tokens (off-chain)
                                           3. Calls Execute before end
                                              burns K tokens, receives K deposit tokens
                                              pays K × price payment tokens
4a. Calls Retrieve after end
    reclaims remaining deposit
    — OR —
4b. Calls CancelEarly before cutoff
    burns all outstanding tokens
    reclaims full deposit
```

Key properties:

- **Partial execution** — a holder may burn any number of tokens K ≤ remaining, not necessarily all at once.
- **NFT tracking** — a unique NFT (one per option) lives in the script UTxO and is burnt only when the position is fully closed (Retrieve or CancelEarly), ensuring datum integrity across partial fills.
- **Fixed price** — price is stored as an exact rational `(numerator, denominator)`, avoiding floating-point imprecision.
- **Optional protocol fee** — a reference-input fee-config UTxO can impose a percentage fee on execution payments, paid to a configurable address.

---

## Datum parameters

Every option UTxO carries an inline `OptionDatum` with the following fields.

### PlutusTx (`OptionDatum`)

```haskell
data OptionDatum = OptionDatum
  { opdRef       :: TxOutRef    -- UTxO consumed to mint the NFT and option tokens
  , opdToken     :: AssetClass  -- Asset class of the minted option tokens
  , opdStart     :: POSIXTime   -- Earliest time (ms) at which Execute is valid
  , opdEnd       :: POSIXTime   -- Latest time (ms) at which Execute is valid; Retrieve allowed after this
  , opdCancelCutoff :: POSIXTime -- Deadline before which CancelEarly is allowed (start ≤ cutoff ≤ end)
  , opdDeposit   :: AssetClass  -- Asset deposited by the seller (received by executor)
  , opdPayment   :: AssetClass  -- Asset paid by the executor (received into the script UTxO)
  , opdPrice     :: Rational    -- Price: 1 deposit unit costs (numerator/denominator) payment units
  , opdSellerKey :: PubKeyHash  -- Seller's verification key hash
  }
```

### Aiken (`OptionDatum`)

```
pub type OptionDatum {
  ref:           OutputReference   -- same as opdRef above
  token:         AssetClass        -- same as opdToken
  start:         Int               -- POSIX ms
  end:           Int               -- POSIX ms
  cancel_cutoff: Int               -- POSIX ms
  deposit:       AssetClass
  payment:       AssetClass
  price:         Rational          -- { numerator: Int, denominator: Int }
  seller_key:    ByteArray         -- verification key hash
}
```

### Field-by-field explanation

| Field | Type | Description |
|-------|------|-------------|
| `ref` / `opdRef` | `TxOutRef` | The UTxO consumed at create time. Its hash is used to derive both the NFT token name and the option token name (`sha2_256(output_index_byte ‖ tx_id_bytes)`). Guarantees global uniqueness of every option position. |
| `token` / `opdToken` | `AssetClass` | Policy ID of the option minting policy + token name derived from `ref`. Option holders burn these tokens to execute. |
| `start` | `POSIXTime` (ms) | Earliest slot at which `Execute` is accepted. The tx validity range lower bound must be ≥ `start`. |
| `end` | `POSIXTime` (ms) | Latest slot at which `Execute` is accepted. The tx validity range upper bound must be ≤ `end`. `Retrieve` requires the lower bound ≥ `end`. |
| `cancel_cutoff` | `POSIXTime` (ms) | Seller may call `CancelEarly` only while the tx validity range upper bound < `cancel_cutoff`. Must satisfy `start ≤ cancel_cutoff ≤ end` (checked off-chain). |
| `deposit` | `AssetClass` | The asset locked by the seller and released to executors. Use `("", "")` for ADA. |
| `payment` | `AssetClass` | The asset that executors must pay into the continuing UTxO. Use `("", "")` for ADA. |
| `price` | `Rational` | Price per one deposit unit expressed as `numerator/denominator`. The on-chain check avoids division: `actual_payment × denominator ≥ numerator × amount`. |
| `seller_key` | `PubKeyHash` | Required signature for `Retrieve` and `CancelEarly`. Also used to route funds back to the seller. |

### Minimum ADA

Every option script UTxO must carry at least **3 ADA** (`option_min_ada = 3_000_000 lovelace`).  
When computing the remaining deposit for `CancelEarly`, this constant is subtracted from the UTxO's lovelace balance so ADA-denominated options are handled correctly.

---

## Fee configuration

Protocol fees are **optional**.  To disable fees, pass the ADA sentinel (`("", "")`) as `fee_config_nft` when deploying the spend validator.

### How it works

When a non-sentinel fee NFT is configured, `Execute` must include a **reference input** carrying a UTxO identified by that NFT. The UTxO holds an inline `OptionFeeConfigDatum`:

```haskell
-- PlutusTx
data OptionFeeConfigDatum = OptionFeeConfigDatum
  { ofcdSignatories    :: [PubKeyHash]  -- keys authorised to update this config
  , ofcdReqSignatories :: Integer       -- M-of-N threshold for updates
  , ofcdFeeAddress     :: Address       -- address that receives the fee
  , ofcdNumerator      :: Integer       -- fee = payment_amount × N / D  (0 = no fee)
  , ofcdDenominator    :: Integer       -- must be > 0
  }
```

```
-- Aiken equivalent
pub type OptionFeeConfigDatum {
  signatories:     List<ByteArray>
  req_signatories: Int
  fee_address:     Address
  numerator:       Int
  denominator:     Int
}
```

#### Fee calculation

```
fee_due = actual_payment × ofcdNumerator / ofcdDenominator
```

The validator checks that the total ADA (or token) sent to `ofcdFeeAddress` in the transaction is ≥ `fee_due`. A numerator of `0` disables the fee without redeploying the spend validator.

#### Updating the fee config

The fee-config validator (`OptionFeeConfig.hs`) governs updates:

- The config NFT must be present in both the input and the continuing output.
- The new `denominator` must be > 0 and `numerator` ≥ 0.
- `req_signatories` ≥ 1 and ≤ `len(signatories)`.
- At least `req_signatories` of the listed `signatories` must sign the transaction (M-of-N multisig).

#### Deploying without fees (current demo)

The testnet demo runs with `fee_config_nft = ("", "")` — the ADA sentinel — so no fee UTxO is needed and no fee is charged. This is the zero-fee path verified by TX1.

---

## On-chain operations

### (a) Mint + Issue — `createOption`

Governed by **`option_mint`**.

The seller creates an option by consuming a UTxO (`ref`) and minting in a single transaction:

1. Mints `N` option tokens with name `sha2_256(index_byte ‖ ref_tx_id)`.
2. A companion NFT (same name, separate NFT policy) is minted and locked in the script UTxO alongside the deposit.
3. The script UTxO must have an inline `OptionDatum` whose `ref` matches the consumed UTxO and `token` matches the minted option tokens.
4. The deposit value (minus min-ADA) must be ≥ `N`.

Seller distributes or sells the option tokens off-chain.

---

### (b) Execute — `executeOption`

Governed by **`option_spend`** redeemer `Execute { amount }`.

A holder burns `amount` option tokens to receive `amount` deposit units:

| Check | Rule |
|-------|------|
| Time | Tx validity range ⊆ `[start, end]` |
| Token burn | Exactly `amount` option tokens burnt |
| NFT continuity | NFT stays in the continuing output |
| Datum unchanged | Continuing output carries the same `OptionDatum` |
| Deposit taken | `deposit_before − deposit_after ≤ amount` |
| Payment sufficient | `(payment_after − payment_before) × denominator ≥ numerator × amount` |
| Protocol fee | If fee config active: fee sent to `fee_address` ≥ `payment × N / D` |

Partial execution is allowed: the script UTxO persists with the remaining deposit and the same datum.

---

### (c) Retrieve after expiry — `retrieveOption`

Governed by **`option_spend`** redeemer `Retrieve`.

The seller reclaims all remaining assets after the option window closes:

| Check | Rule |
|-------|------|
| Time | Tx validity range lower bound ≥ `end` |
| NFT burnt | The position NFT is burnt |
| Seller signature | Transaction signed by `seller_key` |
| Funds to seller | At least one output goes to a pubkey address matching `seller_key` |

---

### (d) Early cancel before cutoff — `cancelEarlyOption`

Governed by **`option_spend`** redeemer `CancelEarly`.

The seller cancels and recovers the full deposit before any buyer can execute, provided the cancellation deadline has not yet passed:

| Check | Rule |
|-------|------|
| Seller signature | Transaction signed by `seller_key` |
| Before cutoff | Tx validity range upper bound < `cancel_cutoff` |
| All tokens burnt | All remaining option tokens (remaining deposit amount) are burnt |
| NFT burnt | The position NFT is burnt |

---

## Validators

### Aiken / PlutusV3

Source: [`aiken/validators/option.ak`](aiken/validators/option.ak) and [`aiken/lib/geniusyield/options/types.ak`](aiken/lib/geniusyield/options/types.ak).

| Validator | Kind | Parameters |
|-----------|------|------------|
| `option_spend` | Spend | `nft_policy_id: ByteArray`, `fee_config_nft: AssetClass` |
| `option_mint` | Mint | `nft_policy_id: ByteArray`, `spend_hash: ByteArray` |

```bash
cd aiken
aiken build
# inspect sizes:
jq '.validators[] | {title, size_bytes: (.compiledCode | length / 2)}' plutus.json
```

See [`aiken/BENCHMARK.md`](aiken/BENCHMARK.md) — estimated **~40% smaller** than the PlutusTx originals.

### PlutusTx / PlutusV2

Source: [`plutustx/Option.hs`](plutustx/Option.hs), [`plutustx/OptionFeeConfig.hs`](plutustx/OptionFeeConfig.hs).  
Full protocol specification: [`plutustx/Options.md`](plutustx/Options.md).

| Validator | Parameters |
|-----------|------------|
| `mkOptionValidator` | NFT currency symbol |
| `mkOptionPolicy` | NFT currency symbol, spend validator address |
| `mkOptionFeeConfigValidator` | Fee-config NFT asset class |

---

## Tests

[`tests/Option.hs`](tests/Option.hs) — Tasty suite running against the **CLB** (Cardano Ledger Backend) emulator via `geniusyield-framework`.

| Test | Expected |
|------|----------|
| create option | ✅ succeeds |
| execute — happy path | ✅ succeeds |
| execute before `start` | ❌ fails |
| execute after `end` | ❌ fails |
| `cancelEarly` before cutoff | ✅ succeeds |
| `cancelEarly` after cutoff | ❌ fails |
| retrieve after expiry | ✅ succeeds |
| retrieve before expiry | ❌ fails |

---

## Testnet transactions

All transactions confirmed on **Cardano Preprod**.  
Network: `https://preprod.cardanoscan.io`

| # | Operation | Description | Tx Hash | Explorer |
|---|-----------|-------------|---------|----------|
| (a) | **Mint + Issue** | Lock 10 tGENS, mint 10 option tokens | `e67ee638ce6b8a0c6d35f2949d0ba3ea1be8828be5f183c5e5b76c731b6213ef` | [view ↗](https://preprod.cardanoscan.io/transaction/e67ee638ce6b8a0c6d35f2949d0ba3ea1be8828be5f183c5e5b76c731b6213ef) |
| (b) | **Execute** | Burn 5 option tokens, receive 5 tGENS, pay 2.5 ADA | `4335caa411f4fe868591902dc00c33ac3e1269099379d84f4e6b976614e90c67` | [view ↗](https://preprod.cardanoscan.io/transaction/4335caa411f4fe868591902dc00c33ac3e1269099379d84f4e6b976614e90c67) |
| (c) | **Retrieve after expiry** | Seller reclaims remaining 5 tGENS after window closes | `05cebbd3ff578074dd5693b57983b606c1d6861cec68aabc9b27bf34c549d74d` | [view ↗](https://preprod.cardanoscan.io/transaction/05cebbd3ff578074dd5693b57983b606c1d6861cec68aabc9b27bf34c549d74d) |
| (d) | **Early cancel before cutoff** | Seller cancels new option, burns all tokens, before cutoff | `19d18056647d18776832336c2fa37c5e20c014145ff5ad6e82ed483067926f1e` | [view ↗](https://preprod.cardanoscan.io/transaction/19d18056647d18776832336c2fa37c5e20c014145ff5ad6e82ed483067926f1e) |

### Demo parameters

| Parameter | Value |
|-----------|-------|
| Network | Cardano Preprod |
| Wallet | `addr_test1vqzxr8cgrpg2n3rgcfdvfjnj77pmdslsqmxzmljw3gnlmsqyskzqq` |
| Deposit asset | tGENS — policy `c6e65ba7878b2f8ea0ad39287d3e2fd256dc5c4160fc19bdf4c4d87e`, name `7447454e53` |
| Payment asset | ADA (lovelace) |
| Price | 0.5 ADA / tGENS |
| Option amount | 10 tokens |
| Execute amount | 5 tokens (partial fill) |
| Fee config | Disabled (ADA sentinel — zero-fee path) |
| Window (a)–(c) | start `2026-04-27T20:06Z`, cutoff `+90 s`, end `+180 s` |
| Window (d) | start `2026-04-27T21:01Z`, cutoff `+600 s`, end `+1200 s` |

---

## Running the demo

### Prerequisites

- `geniusyield-server` running at `http://localhost:8082` with `TEST_WALLET_SKEY_PATH` set
- Preprod wallet funded with tADA and tGENS
- `jq`, `curl`, `python3` in `PATH`

### Quick start

```bash
# 1. Start the Tx Server
cd Core
export TEST_WALLET_SKEY_PATH=/path/to/wallet.skey
export geniusyield_datadir=geniusyield-onchain/compiled
./geniusyield-server config-core.json config-dex.json config-rewards.json &

# 2. Wait for health
until curl -fsS http://localhost:8082/health; do sleep 2; done

# 3. Run the demo  (~4 min total — waits for option expiry before TX3)
bash scripts/option-testnet-demo.sh
```

Environment overrides:

| Variable | Default | Description |
|----------|---------|-------------|
| `OPTION_SERVER_URL` | `http://localhost:8082` | Tx Server base URL |
| `WALLET_ADDR_FILE` | `preprod-addresses/01.addr` | Path to bech32 wallet address file |
| `DEPOSIT_SYMBOL` | tGENS policy ID | Policy ID of the deposit asset |
| `DEPOSIT_TOKEN` | `7447454e53` | Asset name hex of the deposit asset |
| `PRICE` | `0.5` | Price as a decimal string (ADA per deposit unit) |
| `AMOUNT` | `10` | Number of option tokens to mint |
| `EXEC_AMOUNT` | `5` | Number of tokens to burn in the Execute step |
| `OPTION_DURATION_SEC` | `180` | Option window duration in seconds |
| `CUTOFF_OFFSET_SEC` | `90` | Seconds from start to cancel cutoff |

---

## Repository layout

```
├── README.md
├── TESTNET.md                         Confirmed preprod tx hashes
│
├── aiken/                             PlutusV3 validators (Aiken v1.1.10)
│   ├── aiken.toml
│   ├── BENCHMARK.md                   Size & ExUnit comparison vs PlutusTx
│   ├── validators/option.ak           option_spend + option_mint
│   └── lib/geniusyield/options/
│       └── types.ak                   Shared on-chain types
│
├── plutustx/                          PlutusV2 validators (GHC 9.6 / PlutusTx)
│   ├── Options.md                     Full protocol specification
│   ├── Option.hs                      mkOptionValidator + mkOptionPolicy
│   └── OptionFeeConfig.hs             Fee-config validator
│
├── tests/
│   └── Option.hs                      Tasty / CLB emulator test suite
│
└── scripts/
    └── option-testnet-demo.sh         End-to-end preprod lifecycle demo
```

---

## License

Apache 2.0 — see individual source files for copyright notices.
