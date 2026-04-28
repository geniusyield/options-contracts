# Testnet Transaction Log

This file records on-chain transaction hashes from preprod testnet demonstrations.
All transactions are on the **Cardano Preprod** network.

Explorer: `https://preprod.cardanoscan.io/transaction/<hash>`

---

## Options — Milestone 1 Demo

Run via `scripts/option-testnet-demo.sh`.

### How to run

```bash
cd Core

# 1. Start the Tx Server
export TEST_WALLET_SKEY_PATH=skeys/01.skey
cabal run geniusyield-server -- config-core.json config-dex.json config-rewards.json &

# 2. Wait for server health
until curl -fsS http://localhost:8082/health; do sleep 2; done

# 3. Run the demo (takes ~4 min for the expiry wait)
bash scripts/option-testnet-demo.sh
```

### Parameters

| Parameter       | Value                                                                        |
|-----------------|------------------------------------------------------------------------------|
| Network         | Preprod                                                                      |
| Wallet          | `addr_test1vqzxr8cgrpg2n3rgcfdvfjnj77pmdslsqmxzmljw3gnlmsqyskzqq`           |
| Deposit asset   | tGENS (`c6e65ba7878b2f8ea0ad39287d3e2fd256dc5c4160fc19bdf4c4d87e.7447454e53`) |
| Payment asset   | ADA (lovelace)                                                               |
| Price           | 0.5 ADA / tGENS                                                              |
| Option amount   | 10 tokens                                                                    |
| Execute amount  | 5 tokens (partial fill)                                                      |
| Window (TX1–TX3)| start=2026-04-27T20:06Z, cutoff=+90s, end=+180s                             |
| Window (TX4)    | start=2026-04-27T21:01Z, cutoff=+600s, end=+1200s                           |

### Recorded transactions

| Operation      | Tx Hash                                                                | Cardanoscan |
|----------------|------------------------------------------------------------------------|-------------|
| createOption   | `e67ee638ce6b8a0c6d35f2949d0ba3ea1be8828be5f183c5e5b76c731b6213ef`   | [view](https://preprod.cardanoscan.io/transaction/e67ee638ce6b8a0c6d35f2949d0ba3ea1be8828be5f183c5e5b76c731b6213ef) |
| executeOption  | `4335caa411f4fe868591902dc00c33ac3e1269099379d84f4e6b976614e90c67`   | [view](https://preprod.cardanoscan.io/transaction/4335caa411f4fe868591902dc00c33ac3e1269099379d84f4e6b976614e90c67) |
| retrieveOption | `05cebbd3ff578074dd5693b57983b606c1d6861cec68aabc9b27bf34c549d74d`   | [view](https://preprod.cardanoscan.io/transaction/05cebbd3ff578074dd5693b57983b606c1d6861cec68aabc9b27bf34c549d74d) |
| cancelEarly    | `19d18056647d18776832336c2fa37c5e20c014145ff5ad6e82ed483067926f1e`   | [view](https://preprod.cardanoscan.io/transaction/19d18056647d18776832336c2fa37c5e20c014145ff5ad6e82ed483067926f1e) |

---

## Contract coverage

| On-chain validator check          | Covered by                           |
|-----------------------------------|--------------------------------------|
| Minting policy — correct token    | TX1 (createOption)                   |
| Validator — execute within window | TX2 (executeOption)                  |
| Validator — retrieve after expiry | TX3 (retrieveOption)                 |
| Validator — cancel before cutoff  | TX4 (cancelEarly)                    |
| Validator — fee payment           | TX1 (no fee config = zero fee path)  |
