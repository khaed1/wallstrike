# Wallstrike

**Reserved exits for IMD and sIMD holders.** ETH holders back 7-day and 30-day exit rights on IMD, struck below the market. Holders buy them as a put (an **Exit Ticket**) or take a non-liquidating ETH loan against sIMD (a **Floor Loan**). Every ticket is fully backed by ETH locked at purchase, settlement is physical, and no oracle decides any payout.

| | |
|---|---|
| **Status** | Built and tested, not deployed. Unit, fuzz and mainnet-fork tests pass. Not audited. |
| **Chain** | Ethereum mainnet only: sIMD exists only there. |
| **Token** | None. Fees are paid in ETH. |

## Why

IMD's on-chain exit liquidity is thin. On 2026-10-20, Ethereum pools could absorb only about 40 ETH of IMD sells within a 20% price drop, while sIMD held about 1.89M IMD (about $8.6M). A large holder who sells into that depth loses heavily to slippage, and when several try at once it becomes a run. Wallstrike lets them reserve an exit price in advance from ETH holders who want IMD at a discount and are paid a premium to wait.

## How it works

```
week N   openSeries(line, tenor)   strike fixed from the recorder, never read again
day 0-1  writers deposit ETH       can withdraw until the auction starts
day 1-2  auction                   buyers take Exit Tickets, borrowers take Floor Loans
                                   premium falls from 2x the Black-Scholes floor to the floor
         after the auction         writers claim back the ETH no ticket or loan used
expiry   + 72h exercise window     ticket holders deliver IMD or sIMD and get the strike in ETH
                                   borrowers repay to get their sIMD back
then     finalize, claim           writers split the ETH, IMD and sIMD left, pro rata
```

**Series.** Anyone can open one series per strike line and tenor per calendar week:

| Line | Strike |
|---|---|
| 0 | 80% of the 7-day mean price, lowered to the buy wall if the wall is cheaper |
| 1 | 60% of the 7-day mean price, lowered to the buy wall if the wall is cheaper |

Tenors are 7 and 30 days from the end of the auction. "The buy wall" is the top of POOL4's ETH backstop band (its 24-hour median), so the strike is normally no higher than where IMD's own protocol would buy. A wall at or above the market (being filled) is ignored, and a wall more than 50% below the market counts as 50% below, so pushing the wall around can never block a series.

**Exit Tickets** are ERC-1155 tokens (id = series id, amount = IMD in wei). After expiry the holder delivers that much IMD, or `sIMD.previewWithdraw(amount)` sIMD shares, and receives `amount × strike` ETH. Tickets are transferable.

**Floor Loans.** A borrower posts sIMD and receives 35% of its IMD value, priced at the lower of the strike and the current price. The fee, taken upfront, is the larger of 3% and the value of the put the loan embeds (struck at the principal). There is no price liquidation. The borrower repays the principal before the exercise window closes and gets the sIMD back, or keeps the ETH and the writers keep the sIMD. Collateral is valued at the lower of sIMD's live rate and its rate at opening plus 1%, so a same-transaction donation cannot inflate a loan.

**Premiums** sell in a one-day Dutch auction from twice a floor down to the floor. The floor is a Black-Scholes put value, re-priced at every sale from the lower of POOL4's `refTick` price and the main pool's live price over the time left to expiry, and never below the floor computed at opening. A fall during the deposit window or the auction is therefore always charged for, and pushing the main pool up does nothing. Pricing volatility is the larger of 200% and 125% of the recorder's 7-day realized volatility; realized IMD/ETH volatility has been 178-391%.

**Writers** deposit ETH into a series before its auction, with no first-come limit. If deposits exceed the series cap, every writer is put at risk pro rata and the excess comes back after the auction, together with any capacity no ticket or open loan used. After the exercise window, each writer takes a pro rata share of the remaining ETH, the delivered IMD and sIMD, and the sIMD of unpaid loans. Fees, loan-to-value, the cap and the pricing volatility are fixed per series when it opens.

## Prices: the recorder

No usable IMD price average exists on-chain: neither POOL4 nor the main ETH/IMD pool keeps price observations, and the IMD Uniswap v3 pools have an observation cardinality of 1. [`ImdPriceRecorder`](src/ImdPriceRecorder.sol) builds one. Every 30 minutes anyone can record a sample of:

- POOL4's `refTick`: the hook's rate-limited follower of the previous swap block's closing tick. A transaction cannot move it, and it moves at most `maxRefStep` (200) ticks per update.
- The top of POOL4's buy wall (`backstop().tickLower`).
- sIMD's rate (`convertToAssets(1e24)`).

A sample counts only if POOL4 is open, funded and rebalancing, `maxRefStep` is at most 200, and `refTick` is within 400 ticks (about 4%) of the main hookless pool's tick. A valid sample cannot be overwritten; an invalid one can be replaced by a later valid one in the same slot.

A series needs 302 valid samples in the last 7 days (280 consecutive pairs for the volatility) and 43 in the last 24 hours. Sales and loans read the live pessimistic price directly, so they do not depend on the keeper. The recorder has no owner and no parameters.

## What the owner can and cannot do

The deploy script makes a 48-hour `TimelockController`, controlled by `ADMIN` (use a multisig), the owner. The owner can:

- set caps for new deposits, tickets and loans
- set the protocol fee (up to 20%), the loan fee (up to 10%), the loan-to-value (up to 50%) and the volatility floor (100-500%), for series opened afterwards
- pause new series, deposits, ticket sales and loans, and unpause
- set a guardian, which can pause at once but not unpause
- change the fee recipient

Neither can touch an open series, a ticket, a loan or a writer's balance, or stop exercise, repayment, finalization or claims.

Launch caps: 10 ETH per series, 2.5 ETH of ticket collateral per account per series, 25 ETH of open ticket collateral overall, 10 ETH of open loan principal overall, 1 ETH per loan. The protocol fee is 10% of premiums and loan fees.

## The IMD contracts it reads

All verified on mainnet on 2026-10-20.

| Contract | Address | What matters |
|---|---|---|
| IMD | [`0xD34a…63B7`](https://etherscan.io/address/0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7) | LayerZero OFT, standard ERC-20, no transfer fee, no pause. |
| sIMD | [`0x9Efa…7247`](https://etherscan.io/address/0x9efa934d9fad4ae28c998a40195646b965a97247) | ERC-4626, owner renounced. One-block hold: a mint stamps the receiver, who cannot redeem in that block; transfers pass the stamp on but are never blocked. Wallstrike only ever transfers sIMD. |
| POOL4 hook (CappedBurnHook) | [`0xc6C9…2840`](https://etherscan.io/address/0xc6c965bd164c483e87d0b550671798e9a3602840) | Owned by an EOA that can close or retune the market at any time. The recorder treats every value it reads as untrusted. |
| Main ETH/IMD pool | v4 pool `0xb07d…bfb3` | Hookless, about 25x POOL4's liquidity. Used only to cross-check `refTick`. |
| Uniswap v4 PoolManager | [`0x0000…8A90`](https://etherscan.io/address/0x000000000004444c5dc75cb358380d2e3de08a90) | Pool state is read with `StateLibrary` (`extsload`). |

## Risks

- **Writers carry real tail risk.** In a crash they receive IMD or sIMD at the strike and can exit only into thin pools. Premiums are the only cushion.
- **POOL4 is controlled by one EOA.** If it closes the market, disables rebalancing or loosens `refTick`'s rate limit, samples become invalid and no new series opens. Open series are unaffected, since they need no price.
- **Thin markets.** The 7-day mean and the wall can still be nudged at a cost, and a buyer with a loose `maxPremium` can be sandwiched by someone moving the main pool; caps keep the value at stake small, and front ends should quote `premiumRate` and pass a tight `maxPremium`.
- **Keepers.** The recorder needs a sample every 30 minutes and finished series should be finalized promptly, since open exposure counts against the global caps until then. Both calls are permissionless.
- **Not audited.** Do not deploy with more than the launch caps before an external audit.
- **Legal.** Options and loans are regulated in many places. Get advice before launching.

## Build, test, deploy

```bash
forge build
forge test                                                       # unit and fuzz tests
MAINNET_RPC_URL=https://... forge test --mc ForkTest -vv         # against the real IMD contracts
ADMIN=0x... FEE_RECIPIENT=0x... forge script script/Deploy.s.sol \
  --rpc-url $MAINNET_RPC_URL --account deployer --broadcast --verify
RPC_URL=https://... RECORDER=0x... KEEPER_ACCOUNT=keeper ./script/keeper.sh   # every few minutes
```

After deploying, the recorder needs about 7 days of samples before the first series can open.
