#!/usr/bin/env bash
# Wallstrike keeper. Run it every few minutes (cron, systemd timer, or a keeper service). Each step does
# nothing when there is nothing to do.
#
#   RPC_URL=https://... RECORDER=0x... KEEPER_ACCOUNT=keeper ./script/keeper.sh
#   VAULTS="0xWeekly 0xMonthly" also rolls those writer vaults.
#
# KEEPER_ACCOUNT is a `cast wallet import` keystore holding a little ETH for gas.
#
# 1. Records one price sample per 30-minute slot. Series need 252 valid samples in the last 336 slots
#    (7 days) and 36 in the last 48 (24 hours).
# 2. For each vault: ends its round once the series has settled, and starts the next round when this
#    week's series for its product is open for deposits (opening the series if nobody has), at least
#    12 hours after the last round ended.
set -euo pipefail

: "${RPC_URL:?set RPC_URL}"
: "${RECORDER:?set RECORDER}"
: "${KEEPER_ACCOUNT:?set KEEPER_ACCOUNT}"

# A failed step is logged and skipped, so one failure never stops the other steps.
send() {
  if cast send "$@" --rpc-url "$RPC_URL" --account "$KEEPER_ACCOUNT" >/dev/null; then echo "sent $2"; else echo "failed $2 on $1" >&2; fi
}
# Sends only if a dry run succeeds.
try() {
  if cast call "$@" --rpc-url "$RPC_URL" >/dev/null 2>&1; then send "$@"; fi
}

slot=$(( $(date +%s) / 1800 ))
valid=$(cast call "$RECORDER" "sample(uint256)((uint32,int24,int24,bool,uint96))" "$slot" --rpc-url "$RPC_URL" \
  | tr -d '()' | cut -d, -f4 | tr -d ' ')
if [ "$valid" = "true" ]; then
  echo "slot $slot already recorded"
else
  try "$RECORDER" "poke()"
fi

# A call that would revert (round not settled yet, within 12 hours of the last round, deposit window
# closed, ...) is skipped.
for vault in ${VAULTS:-}; do
  try "$vault" "endRound()"
  try "$vault" "startRound()"
done
