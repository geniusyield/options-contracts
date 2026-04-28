#!/usr/bin/env bash
# option-testnet-demo.sh
#
# Demonstrates the full option lifecycle on Cardano preprod:
#   TX1  createOption    — lock 10 tGENS, mint 10 option tokens
#   TX2  executeOption   — burn 5 option tokens, pay seller 5 ADA
#   TX3  (wait ~180s for option expiry)
#   TX4  retrieveOption  — return remaining 5 tGENS to seller after expiry
#
# Requires:
#   - geniusyield-server running (default: http://localhost:8082)
#   - TEST_WALLET_SKEY_PATH set in the server process environment
#   - jq, curl in PATH
#   - Preprod wallet (01.addr / 01.skey) funded with tADA and tGENS

set -euo pipefail

##############################################################################
# Configuration
##############################################################################

SERVER_URL="${OPTION_SERVER_URL:-http://localhost:8082}"
WALLET_ADDR_FILE="${WALLET_ADDR_FILE:-$(dirname "$0")/../preprod-addresses/01.addr}"
WALLET_ADDR="$(cat "$WALLET_ADDR_FILE")"

# GYAddress in JSON must be CBOR hex, not bech32.
# Convert if the address starts with "addr" (bech32).
bech32_to_hex() {
  local addr="$1"
  python3 - "$addr" << 'PYEOF'
import sys
CHARSET = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l'
addr = sys.argv[1]
idx = addr.rfind('1')
data_str = addr[idx+1:-6]
vals = [CHARSET.index(c) for c in data_str]
acc, bits, result = 0, 0, []
for v in vals:
    acc = (acc << 5) | v
    bits += 5
    while bits >= 8:
        bits -= 8
        result.append((acc >> bits) & 0xff)
print(bytes(result).hex())
PYEOF
}

case "$WALLET_ADDR" in
  addr*) WALLET_ADDR_HEX="$(bech32_to_hex "$WALLET_ADDR")" ;;
  *)     WALLET_ADDR_HEX="$WALLET_ADDR" ;;
esac

# Deposit: preprod tGENS
# Policy: c6e65ba7878b2f8ea0ad39287d3e2fd256dc5c4160fc19bdf4c4d87e
# Token name hex: 7447454e53 ("tGENS")
DEPOSIT_SYMBOL="${DEPOSIT_SYMBOL:-c6e65ba7878b2f8ea0ad39287d3e2fd256dc5c4160fc19bdf4c4d87e}"
DEPOSIT_TOKEN="${DEPOSIT_TOKEN:-7447454e53}"

# Payment: ADA (lovelace)
PAYMENT_SYMBOL="${PAYMENT_SYMBOL:-}"
PAYMENT_TOKEN="${PAYMENT_TOKEN:-}"

# Price: 0.5 ADA per tGENS (as a decimal string accepted by GYRational)
PRICE="${PRICE:-0.5}"

# Option amount: total tokens to lock
AMOUNT="${AMOUNT:-10}"

# Execute amount: partial fill (burn half the option tokens)
EXEC_AMOUNT="${EXEC_AMOUNT:-5}"

# Time window: start now, expire in 3 minutes, cutoff at 1.5 minutes
OPTION_DURATION_SEC="${OPTION_DURATION_SEC:-180}"
CUTOFF_OFFSET_SEC="${CUTOFF_OFFSET_SEC:-90}"

TESTNET_MD="$(dirname "$0")/../TESTNET.md"

##############################################################################
# Helpers
##############################################################################

log()  { echo "[$( date -u +%H:%M:%S)] $*" >&2; }
fail() { echo "[ERROR] $*" >&2; exit 1; }

require_tool() { command -v "$1" >/dev/null 2>&1 || fail "$1 is required but not in PATH"; }
require_tool curl
require_tool jq

check_server() {
  curl -fsS "$SERVER_URL/health" >/dev/null 2>&1 \
    || fail "Server not reachable at $SERVER_URL — start it first (scripts/run-server-preprod.sh)"
}

# ISO8601 timestamp N seconds from now (macOS + GNU date compatible)
future_iso() {
  local offset_sec="$1"
  if date --version >/dev/null 2>&1; then
    # GNU date
    date -u -d "+${offset_sec} seconds" '+%Y-%m-%dT%H:%M:%SZ'
  else
    # macOS date
    date -u -v "+${offset_sec}S" '+%Y-%m-%dT%H:%M:%SZ'
  fi
}

# Call an option endpoint; print JSON response; return tTx
call_option() {
  local endpoint="$1"
  local payload="$2"
  local response
  response=$(curl -fsS -X POST \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$SERVER_URL/DEX/option/$endpoint") \
    || fail "POST /DEX/option/$endpoint failed"
  echo "$response"
}

# Submit an unsigned tx via sign-and-submit-test; return tx_hash
sign_and_submit() {
  local unsigned_tx_hex="$1"
  local payload
  payload=$(jq -n --arg t "$unsigned_tx_hex" '{"originalUnsignedTx": $t}')
  local response
  response=$(curl -fsS -X POST \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$SERVER_URL/Tx/sign-and-submit-test") \
    || fail "POST /Tx/sign-and-submit-test failed"
  echo "$response" | jq -r '.tx_hash'
}

# Find option UTxO ref whose tx hash matches the given tx id
find_option_ref() {
  local tx_hash="$1"
  local infos
  infos=$(curl -fsS "$SERVER_URL/DEX/option") || fail "GET /DEX/option failed"
  # opiRef is serialized as "<txHash>#<idx>" by GYTxOutRef ToJSON
  echo "$infos" | jq -r --arg h "$tx_hash" \
    '.[] | select(.opiRef | startswith($h)) | .opiRef' \
    | head -1
}

append_testnet_md() {
  local label="$1"
  local tx_hash="$2"
  printf "| %-22s | \`%s\` |\n" "$label" "$tx_hash" >> "$TESTNET_MD"
}

##############################################################################
# Main
##############################################################################

log "Option testnet demo — wallet: $WALLET_ADDR"
check_server

START_TIME="$(future_iso 0)"
CUTOFF_TIME="$(future_iso "$CUTOFF_OFFSET_SEC")"
END_TIME="$(future_iso "$OPTION_DURATION_SEC")"

log "Option window: $START_TIME → $END_TIME (cutoff: $CUTOFF_TIME)"

##############################################################################
# TX1: createOption
##############################################################################

log "--- TX1: createOption ---"

CREATE_PAYLOAD=$(jq -n \
  --arg addr    "$WALLET_ADDR_HEX" \
  --arg start   "$START_TIME" \
  --arg end     "$END_TIME" \
  --arg cutoff  "$CUTOFF_TIME" \
  --arg dsym    "$DEPOSIT_SYMBOL" \
  --arg dtok    "$DEPOSIT_TOKEN" \
  --arg psym    "$PAYMENT_SYMBOL" \
  --arg ptok    "$PAYMENT_TOKEN" \
  --arg price   "$PRICE" \
  --argjson amt "$AMOUNT" \
  '{
    usedAddrs:     [$addr],
    change:        $addr,
    start:         $start,
    end:           $end,
    cancelCutoff:  $cutoff,
    depositSymbol: $dsym,
    depositToken:  $dtok,
    paymentSymbol: $psym,
    paymentToken:  $ptok,
    price:         $price,
    amount:        $amt
  }')

CREATE_RESP=$(call_option "create" "$CREATE_PAYLOAD")
CREATE_UNSIGNED_TX=$(echo "$CREATE_RESP" | jq -r '.tTx')
log "Unsigned create tx built — submitting..."

TX1=$(sign_and_submit "$CREATE_UNSIGNED_TX")
log "TX1 (createOption): $TX1"

##############################################################################
# Find the option UTxO ref (may need a moment for the node to index it)
##############################################################################

log "Waiting 10 s for UTxO to be indexed..."
sleep 10

OPTION_REF=""
for attempt in 1 2 3 4 5; do
  OPTION_REF=$(find_option_ref "$TX1")
  if [ -n "$OPTION_REF" ]; then
    break
  fi
  log "  option not indexed yet (attempt $attempt/5), waiting 10 s..."
  sleep 10
done

[ -n "$OPTION_REF" ] || fail "Could not find option UTxO for tx $TX1 after 60 s"
log "Option UTxO ref: $OPTION_REF"

##############################################################################
# TX2: executeOption (partial — EXEC_AMOUNT of AMOUNT tokens)
##############################################################################

log "--- TX2: executeOption ($EXEC_AMOUNT of $AMOUNT tokens) ---"

EXECUTE_PAYLOAD=$(jq -n \
  --arg addr "$WALLET_ADDR_HEX" \
  --arg ref  "$OPTION_REF" \
  --argjson amt "$EXEC_AMOUNT" \
  '{
    usedAddrs: [$addr],
    change:    $addr,
    ref:       $ref,
    amount:    $amt
  }')

EXECUTE_RESP=$(call_option "execute" "$EXECUTE_PAYLOAD")
EXECUTE_UNSIGNED_TX=$(echo "$EXECUTE_RESP" | jq -r '.tTx')
log "Unsigned execute tx built — submitting..."

TX2=$(sign_and_submit "$EXECUTE_UNSIGNED_TX")
log "TX2 (executeOption): $TX2"

##############################################################################
# Wait for the option to expire, then retrieve
##############################################################################

REMAINING_SEC=$(( OPTION_DURATION_SEC + 30 ))
log "--- Waiting ${REMAINING_SEC} s for option expiry (end: $END_TIME) ---"
sleep "$REMAINING_SEC"

##############################################################################
# Refresh the option ref (UTxO changes after partial execute)
##############################################################################

log "Refreshing option UTxO ref after execute..."
OPTION_REF_UPDATED=""
for attempt in 1 2 3 4 5; do
  # After execute the UTxO ref stays the same tx hash but index changes;
  # re-query to get the current live UTxO ref for the remaining tokens.
  OPTION_REF_UPDATED=$(curl -fsS "$SERVER_URL/DEX/option" \
    | jq -r --arg h "$TX1" '.[] | select(.opiRef | startswith($h)) | .opiRef' \
    | head -1)
  # If the original ref was consumed and replaced with a new one use TX2:
  if [ -z "$OPTION_REF_UPDATED" ]; then
    OPTION_REF_UPDATED=$(curl -fsS "$SERVER_URL/DEX/option" \
      | jq -r --arg h "$TX2" '.[] | select(.opiRef | startswith($h)) | .opiRef' \
      | head -1)
  fi
  if [ -n "$OPTION_REF_UPDATED" ]; then
    break
  fi
  log "  option UTxO not found (attempt $attempt/5), waiting 15 s..."
  sleep 15
done

[ -n "$OPTION_REF_UPDATED" ] || fail "Could not find option UTxO after execute for retrieve"
log "Post-execute option UTxO ref: $OPTION_REF_UPDATED"

##############################################################################
# TX3: retrieveOption (seller reclaims remaining deposit after expiry)
##############################################################################

log "--- TX3: retrieveOption ---"

RETRIEVE_PAYLOAD=$(jq -n \
  --arg addr "$WALLET_ADDR_HEX" \
  --arg ref  "$OPTION_REF_UPDATED" \
  '{
    usedAddrs: [$addr],
    change:    $addr,
    ref:       $ref
  }')

RETRIEVE_RESP=$(call_option "retrieve" "$RETRIEVE_PAYLOAD")
RETRIEVE_UNSIGNED_TX=$(echo "$RETRIEVE_RESP" | jq -r '.tTx')
log "Unsigned retrieve tx built — submitting..."

TX3=$(sign_and_submit "$RETRIEVE_UNSIGNED_TX")
log "TX3 (retrieveOption): $TX3"

##############################################################################
# TX4: cancelEarlyOption demo (separate option created fresh)
##############################################################################

log "--- TX4: cancelEarlyOption demo (new option, cancel before cutoff) ---"

CE_START="$(future_iso 0)"
CE_CUTOFF="$(future_iso 300)"
CE_END="$(future_iso 600)"

CE_CREATE_PAYLOAD=$(jq -n \
  --arg addr    "$WALLET_ADDR_HEX" \
  --arg start   "$CE_START" \
  --arg end     "$CE_END" \
  --arg cutoff  "$CE_CUTOFF" \
  --arg dsym    "$DEPOSIT_SYMBOL" \
  --arg dtok    "$DEPOSIT_TOKEN" \
  --arg psym    "$PAYMENT_SYMBOL" \
  --arg ptok    "$PAYMENT_TOKEN" \
  --arg price   "$PRICE" \
  --argjson amt "$AMOUNT" \
  '{
    usedAddrs:     [$addr],
    change:        $addr,
    start:         $start,
    end:           $end,
    cancelCutoff:  $cutoff,
    depositSymbol: $dsym,
    depositToken:  $dtok,
    paymentSymbol: $psym,
    paymentToken:  $ptok,
    price:         $price,
    amount:        $amt
  }')

CE_CREATE_RESP=$(call_option "create" "$CE_CREATE_PAYLOAD")
CE_UNSIGNED=$(echo "$CE_CREATE_RESP" | jq -r '.tTx')
CE_TX=$(sign_and_submit "$CE_UNSIGNED")
log "Cancel-early option created: $CE_TX"

log "Waiting 15 s for UTxO indexing..."
sleep 15

CE_REF=""
for attempt in 1 2 3 4 5; do
  CE_REF=$(find_option_ref "$CE_TX")
  [ -n "$CE_REF" ] && break
  log "  not indexed yet (attempt $attempt/5), waiting 10 s..."
  sleep 10
done

[ -n "$CE_REF" ] || fail "Could not find cancel-early option UTxO for tx $CE_TX"

CANCEL_PAYLOAD=$(jq -n \
  --arg addr "$WALLET_ADDR_HEX" \
  --arg ref  "$CE_REF" \
  '{
    usedAddrs: [$addr],
    change:    $addr,
    ref:       $ref
  }')

CANCEL_RESP=$(call_option "cancel-early" "$CANCEL_PAYLOAD")
CANCEL_UNSIGNED=$(echo "$CANCEL_RESP" | jq -r '.tTx')
TX4=$(sign_and_submit "$CANCEL_UNSIGNED")
log "TX4 (cancelEarlyOption): $TX4"

##############################################################################
# Record results in TESTNET.md
##############################################################################

log "--- Writing results to TESTNET.md ---"

cat >> "$TESTNET_MD" <<EOF

## Option Demo — $(date -u '+%Y-%m-%d')

Wallet: \`$WALLET_ADDR\`
Assets: deposit=tGENS (\`$DEPOSIT_SYMBOL.$DEPOSIT_TOKEN\`), payment=ADA

| Operation         | Tx Hash                                                            |
|-------------------|--------------------------------------------------------------------|
EOF

append_testnet_md "createOption"    "$TX1"
append_testnet_md "executeOption"   "$TX2"
append_testnet_md "retrieveOption"  "$TX3"
append_testnet_md "cancelEarly"     "$TX4"

echo "" >> "$TESTNET_MD"
echo "Preprod explorer: https://preprod.cardanoscan.io/transaction/<hash>" >> "$TESTNET_MD"

log ""
log "Done. Results:"
log "  TX1 createOption:   $TX1"
log "  TX2 executeOption:  $TX2"
log "  TX3 retrieveOption: $TX3"
log "  TX4 cancelEarly:    $TX4"
log ""
log "See TESTNET.md for the full record."
