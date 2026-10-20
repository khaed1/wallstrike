#!/usr/bin/env bash
# Records one price sample per 30-minute slot. Run it every few minutes (cron, systemd timer, or a
# keeper service); it does nothing when the current slot already has a valid sample.
#
#   RPC_URL=https://... RECORDER=0x... KEEPER_ACCOUNT=keeper ./script/keeper.sh
#
# KEEPER_ACCOUNT is a `cast wallet import` keystore holding a little ETH for gas. Series need 302 valid
# samples in the last 336 slots (7 days) and 43 in the last 48 (24h); loans need one in the last hour.
set -euo pipefail

: "${RPC_URL:?set RPC_URL}"
: "${RECORDER:?set RECORDER}"
: "${KEEPER_ACCOUNT:?set KEEPER_ACCOUNT}"

slot=$(( $(date +%s) / 1800 ))
valid=$(cast call "$RECORDER" "sample(uint256)((uint32,int24,int24,bool,uint96))" "$slot" --rpc-url "$RPC_URL" \
  | tr -d '()' | cut -d, -f4 | tr -d ' ')
if [ "$valid" = "true" ]; then
  echo "slot $slot already recorded"
  exit 0
fi
cast send "$RECORDER" "poke()" --rpc-url "$RPC_URL" --account "$KEEPER_ACCOUNT"
