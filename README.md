# Wallstrike

Reserved exits for IMD and sIMD holders, built on top of IMD's POOL4.

ETH holders sell 30-day, physically settled exit rights on IMD/sIMD, struck below the market. Holders buy them either as a put (Exit Ticket) or as a 30-day ETH loan against sIMD with no price liquidation (Floor Loan). No oracle decides any payout and nothing is sold into POOL4 at settlement.

Status: in development. Contracts, tests and the full design will land here.

## Build

```bash
forge build
forge test
```
