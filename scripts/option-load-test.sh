#!/usr/bin/env bash
# option-load-test.sh
#
# Load test: sends N sequential tx-build requests to the Tx Server option endpoints.
# Verifies ≥95% success rate and reports min/avg/max latency.
#
# Usage:
#   ./scripts/option-load-test.sh
#
# Env overrides:
#   OPTION_SERVER_URL  — default: http://localhost:8082
#   LT_REQUESTS        — total requests to send (default: 30)
#   LT_WALLET_ADDR_HEX — CBOR-hex wallet address
#   LT_DURATION_SEC    — option window length for each request (default: 3600)

set -euo pipefail

SERVER_URL="${OPTION_SERVER_URL:-http://localhost:8082}"
N="${LT_REQUESTS:-30}"
OPTION_DURATION_SEC="${LT_DURATION_SEC:-3600}"

# Preprod tGENS
DEPOSIT_SYMBOL="${DEPOSIT_SYMBOL:-c6e65ba7878b2f8ea0ad39287d3e2fd256dc5c4160fc19bdf4c4d87e}"
DEPOSIT_TOKEN="${DEPOSIT_TOKEN:-7447454e53}"
PAYMENT_SYMBOL="${PAYMENT_SYMBOL:-}"
PAYMENT_TOKEN="${PAYMENT_TOKEN:-}"
PRICE="${PRICE:-0.5}"
AMOUNT="${AMOUNT:-1}"

##############################################################################
# Address helper (bech32 → hex, identical to demo script)
##############################################################################

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

if [ -n "${LT_WALLET_ADDR_HEX:-}" ]; then
  WALLET_ADDR_HEX="$LT_WALLET_ADDR_HEX"
elif [ -f "$(dirname "$0")/../preprod-addresses/01.addr" ]; then
  RAW_ADDR="$(cat "$(dirname "$0")/../preprod-addresses/01.addr")"
  case "$RAW_ADDR" in
    addr*) WALLET_ADDR_HEX="$(bech32_to_hex "$RAW_ADDR")" ;;
    *)     WALLET_ADDR_HEX="$RAW_ADDR" ;;
  esac
else
  echo "[ERROR] Set LT_WALLET_ADDR_HEX or place wallet address in preprod-addresses/01.addr" >&2
  exit 1
fi

##############################################################################
# Helpers
##############################################################################

require_tool() { command -v "$1" >/dev/null 2>&1 || { echo "[ERROR] $1 required"; exit 1; }; }
require_tool curl
require_tool jq
require_tool python3

log() { echo "[$(date -u +%H:%M:%S)] $*" >&2; }

future_iso() {
  local offset_sec="$1"
  if date --version >/dev/null 2>&1; then
    date -u -d "+${offset_sec} seconds" '+%Y-%m-%dT%H:%M:%SZ'
  else
    date -u -v "+${offset_sec}S" '+%Y-%m-%dT%H:%M:%SZ'
  fi
}

check_server() {
  curl -fsS "$SERVER_URL/health" >/dev/null 2>&1 \
    || { echo "[ERROR] Server not reachable at $SERVER_URL" >&2; exit 1; }
}

##############################################################################
# One tx-build request; echoes latency_ms on success, "FAIL" on error
##############################################################################

send_one() {
  local start_ms
  local end_ms
  local start_iso end_iso cutoff_iso

  start_iso="$(future_iso 0)"
  cutoff_iso="$(future_iso $(( OPTION_DURATION_SEC / 2 )))"
  end_iso="$(future_iso "$OPTION_DURATION_SEC")"

  local payload
  payload=$(jq -n \
    --arg addr   "$WALLET_ADDR_HEX" \
    --arg start  "$start_iso" \
    --arg end    "$end_iso" \
    --arg cutoff "$cutoff_iso" \
    --arg dsym   "$DEPOSIT_SYMBOL" \
    --arg dtok   "$DEPOSIT_TOKEN" \
    --arg psym   "$PAYMENT_SYMBOL" \
    --arg ptok   "$PAYMENT_TOKEN" \
    --arg price  "$PRICE" \
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

  start_ms=$(python3 -c 'import time; print(int(time.time()*1000))')

  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$payload" \
    --max-time 30 \
    "$SERVER_URL/DEX/option/create" 2>/dev/null) || http_code="000"

  end_ms=$(python3 -c 'import time; print(int(time.time()*1000))')
  local latency=$(( end_ms - start_ms ))

  if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
    echo "OK $latency"
  else
    echo "FAIL $http_code $latency"
  fi
}

##############################################################################
# Main
##############################################################################

log "Option load test — $N requests to $SERVER_URL"
check_server

PASS=0
FAIL=0
TOTAL_LATENCY=0
MIN_LATENCY=999999
MAX_LATENCY=0
FAIL_CODES=""

SUITE_START=$(python3 -c 'import time; print(int(time.time()*1000))')

for i in $(seq 1 "$N"); do
  result=$(send_one)
  status=$(echo "$result" | awk '{print $1}')
  latency=$(echo "$result" | awk '{print $2}')

  if [ "$status" = "OK" ]; then
    PASS=$(( PASS + 1 ))
    log "  [$i/$N] OK  — ${latency} ms"
  else
    FAIL=$(( FAIL + 1 ))
    code=$(echo "$result" | awk '{print $3}')
    FAIL_CODES="$FAIL_CODES $code"
    log "  [$i/$N] FAIL (HTTP $code) — ${latency} ms"
  fi

  TOTAL_LATENCY=$(( TOTAL_LATENCY + latency ))
  [ "$latency" -lt "$MIN_LATENCY" ] && MIN_LATENCY=$latency
  [ "$latency" -gt "$MAX_LATENCY" ] && MAX_LATENCY=$latency
done

SUITE_END=$(python3 -c 'import time; print(int(time.time()*1000))')
SUITE_DURATION_SEC=$(( (SUITE_END - SUITE_START) / 1000 ))
AVG_LATENCY=$(( TOTAL_LATENCY / N ))
SUCCESS_RATE=$(python3 -c "print(f'{$PASS/$N*100:.1f}')")

echo ""
echo "================================================================"
echo " Option Load Test Results"
echo "================================================================"
echo " Requests  : $N"
echo " Duration  : ${SUITE_DURATION_SEC}s"
echo " Pass      : $PASS"
echo " Fail      : $FAIL"
echo " Success % : ${SUCCESS_RATE}%"
echo " Latency   : min=${MIN_LATENCY}ms  avg=${AVG_LATENCY}ms  max=${MAX_LATENCY}ms"
[ -n "${FAIL_CODES// /}" ] && echo " Fail codes:${FAIL_CODES}"
echo "================================================================"

# Exit 1 if success rate < 95%
PASS_THRESHOLD=$(python3 -c "import math; print(math.ceil($N * 0.95))")
if [ "$PASS" -lt "$PASS_THRESHOLD" ]; then
  echo "[FAIL] Success rate ${SUCCESS_RATE}% is below 95% threshold." >&2
  exit 1
else
  echo "[PASS] Success rate ${SUCCESS_RATE}% meets the ≥95% threshold."
fi
