# Sketch: hedge your imdUSD position

A front-end flow, not yet built, that sells Wallstrike Exit Tickets to [imdUSD](https://imdusd.com) borrowers as protection for their sIMD collateral. It needs no new contract for the first version.

## Who it is for

An imdUSD borrower has sIMD locked as collateral and imdUSD debt. If IMD falls, their collateral loses value and, below the minimum collateral ratio (`mat`, 170% today), keepers can liquidate it after a grace period of up to 6 hours. Wallstrike lets them lock in a minimum value for that collateral.

## What it does and does not do

- **It does:** pay out at expiry if IMD is below the strike, so a fall that lasts until expiry is offset in ETH.
- **It does not stop a liquidation.** Tickets are exercised only after expiry, while imdUSD can liquidate any time after the grace period. A crash in the middle of a week can still liquidate the position. If the price then recovers by expiry, the ticket pays nothing, and the borrower took both losses.
- **Best fit:** borrowers who keep a cushion that survives day-to-day swings and want protection against a fall that lasts. It is not a substitute for keeping the ratio well above `mat`.

## The screen

The user connects a wallet. The page reads their imdUSD position and Wallstrike's open series, and shows:

| Shown | Source |
|---|---|
| Collateral, in IMD and dollars | imdUSD vault `positions(owner)` (sIMD, 24 decimals), sIMD `convertToAssets`, the vault's dollar price |
| Debt | `positions(owner)` (includes accrued fees) |
| Current ratio and `mat` | `collateralRatio(owner)`, `mat()` |
| Liquidation price | debt × `mat` ÷ 100 ÷ collateral in IMD |
| Any liquidation mark | `liquidationMarks(owner)` |
| Open Wallstrike series in their auction | Wallstrike `getSeries(id)`: strike, expiry, line, tenor |
| Ticket price now | Wallstrike `premiumRate(id)` × strike × amount |

All reads are free. The page should read everything at one block and warn when imdUSD's feeds are stale or diverging, since a liquidation can't happen then but neither can a repair.

## The math, with an example

Illustrative numbers: IMD at $5, ETH at $2,400.

- Collateral: sIMD worth 2,000 IMD = $10,000. Debt: 5,000 imdUSD. `mat` 170%.
- Liquidation price: 5,000 × 1.7 ÷ 2,000 = **$4.25 per IMD**.
- Open series: line 0, 7 days, strike about $4.00 (0.00167 ETH per IMD).

The page offers three sizes:

| Choice | Tickets for | Covers | Weekly cost at about 4.7% of strike value |
|---|---|---|---|
| Full collateral | 2,000 IMD | All of it, below $4 | about $376 |
| Half | 1,000 IMD | Half of it, below $4 | about $188 |
| The excess over the debt | 750 IMD | The collateral above what the debt needs at the strike (2,000 − 5,000 ÷ $4) | about $141 |

It always shows the cost as a share of the collateral per week and per year (here about 3.8% a week for full cover). At IMD's volatility, full cover every week is expensive. Most borrowers should hedge part of the position, or only when they expect a rough period.

The page also compares the strike with the liquidation price:

- **Strike above the liquidation price:** a lasting fall is paid for before the position becomes liquidatable. This is the useful case.
- **Strike below the liquidation price,** as in this example ($4.00 against $4.25): a fall to the strike would make the position liquidatable first. The page says so and shows how much collateral to add or debt to repay to bring the liquidation price under the strike. Here, repaying about 300 imdUSD (debt 4,700, liquidation price about $4.00) or adding about 125 IMD of sIMD does it.

## Transactions

1. **Buy tickets:** `Wallstrike.buyTickets(id, imdAmount, maxPremium, minStrike)`, with `maxPremium` set a little above the quote. The tickets are ERC-1155 tokens in the user's wallet.
2. **During the week:** nothing. The page keeps showing the imdUSD ratio and liquidation status next to the tickets' strike.
3. **At expiry (a 72-hour window), one of three outcomes:**

| IMD at expiry | What the user does | Result |
|---|---|---|
| Above the strike | Nothing | Ticket expires; the premium was the cost of cover |
| Below the strike, position still open | Buy that many IMD on the market and call `exercise(id, amount, false)`, or close the position first and deliver the freed sIMD with `exercise(id, amount, true)` | Receives strike × amount in ETH; buying at the market and delivering at the strike nets (strike − price) × amount |
| Below the strike, position was liquidated | Buy IMD on the market and exercise | Same payout, which offsets part of what the liquidation took |

## Phase 2: close at the strike in one click

The cleanest exit at expiry is to close the imdUSD position and deliver its collateral to Wallstrike, but that needs imdUSD to repay before the collateral is free, and ETH only arrives after delivery. A small helper contract could do it in one transaction:

1. Borrow imdUSD inside a Uniswap v4 unlock from the imdUSD/USDC peg pool.
2. Repay the user's imdUSD debt (`wipe` acts on the caller's own position, so the helper must act for the user, for example through an approved vault proxy or by the user calling it with a permit).
3. Free the sIMD, exercise the ticket with it, receive ETH.
4. Swap enough ETH to USDC to settle the pool, and send the rest to the user.

Open points before building it: whether imdUSD's vault lets a third-party contract repay and withdraw for an owner, the peg pool's depth, and swap costs at each step.

## Open questions

- **Ticket resale.** In a crash mid-week a ticket is worth a lot, but there is no market to sell it into for imdUSD repair money. A secondary market for Wallstrike tickets would make this flow much stronger.
- **Shared price risk.** imdUSD's oracle and Wallstrike's recorder read the same IMD pools. Someone holding a pool down for hours affects both.
- **Talk to the imdUSD builder.** Tickets reduce the losses their liquidations cause, so a link from their terminal ("protect this position") could suit both protocols.
