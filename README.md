# GeniusYield DEX — Options Contracts

On-chain smart contracts for the GeniusYield decentralised options protocol on Cardano.

## Overview

This repository contains the on-chain validator code, a protocol specification, a test suite, and a testnet demo script for the GeniusYield options product — part of the [Catalyst Milestone 1](TESTNET.md) proof of evidence.

An option contract lets a **seller** lock a deposit asset and mint option tokens.  
Any **holder** of those tokens may execute (partially or fully) within the agreed window, receiving the deposited asset against a fixed payment.  
The seller may cancel early before the cutoff or retrieve remaining assets after expiry.

---

## Repository layout

```
├── aiken/                  PlutusV3 validators (Aiken)
│   ├── aiken.toml
│   ├── BENCHMARK.md        Size & ExUnit comparison vs PlutusTx
│   ├── validators/
│   │   └── option.ak       option_spend + option_mint validators
│   └── lib/geniusyield/options/
│       └── types.ak        Shared on-chain types
│
├── plutustx/               PlutusV2 validators (Haskell / PlutusTx)
│   ├── Options.md          Protocol specification
│   ├── Option.hs           mkOptionValidator + mkOptionPolicy
│   └── OptionFeeConfig.hs  Fee-config validator
│
├── tests/
│   └── Option.hs           Tasty test suite (CLB emulator)
│
├── scripts/
│   └── option-testnet-demo.sh   End-to-end preprod demo
│
└── TESTNET.md              Confirmed preprod transaction hashes
```

---

## On-chain operations

| Redeemer      | Who calls it  | When                                 | Effect                                          |
|---------------|---------------|--------------------------------------|-------------------------------------------------|
| `Execute`     | Option holder | Between `start` and `end`            | Burns N option tokens, receives N deposit units |
| `Retrieve`    | Seller        | After `end`                          | Reclaims remaining deposit + NFT is burnt       |
| `CancelEarly` | Seller        | Before `cancelCutoff`                | Burns all outstanding tokens + NFT              |

---

## Aiken (PlutusV3) validators

### Build

```bash
cd aiken
aiken build
```

After a successful build `plutus.json` is written with the compiled UPLC.

### Script sizes

```bash
aiken build
jq '.validators[] | {title, size_bytes: (.compiledCode | length / 2)}' plutus.json
```

See [`aiken/BENCHMARK.md`](aiken/BENCHMARK.md) for a detailed comparison against the PlutusTx originals.

---

## PlutusTx (PlutusV2) validators

The Haskell sources under `plutustx/` are part of the GeniusYield server (`Core` monorepo) and compiled via GHC 9.6 / PlutusTx.  See [`plutustx/Options.md`](plutustx/Options.md) for the full protocol specification.

---

## Tests

The `tests/Option.hs` test suite uses the **CLB** (Cardano Ledger Backend) emulator via the `geniusyield-framework` test helpers and covers:

| Test | Expected result |
|------|-----------------|
| create option | succeeds |
| execute (happy path) | succeeds |
| execute before `start` | fails |
| execute after `end` | fails |
| `cancelEarly` before cutoff | succeeds |
| `cancelEarly` after cutoff | fails |
| retrieve after expiry | succeeds |
| retrieve before expiry | fails |

---

## Testnet demo

[`scripts/option-testnet-demo.sh`](scripts/option-testnet-demo.sh) drives the full lifecycle against **Cardano Preprod**:

1. **TX1** `createOption` — lock 10 tGENS, mint 10 option tokens  
2. **TX2** `executeOption` — burn 5 tokens, receive 5 tGENS against 2.5 ADA  
3. **TX3** `retrieveOption` — seller reclaims remaining 5 tGENS after expiry  
4. **TX4** `cancelEarlyOption` — seller cancels a fresh option before cutoff  

Confirmed preprod hashes are recorded in [`TESTNET.md`](TESTNET.md).

### Requirements

- `geniusyield-server` running at `http://localhost:8082`
- `TEST_WALLET_SKEY_PATH` set in the server environment
- `jq`, `curl`, `python3` in `PATH`
- Preprod wallet funded with tADA and tGENS

```bash
bash scripts/option-testnet-demo.sh
```

---

## License

Apache 2.0 — see individual source files for copyright notices.
