# Wallstrike

**Reserved exits for IMD and sIMD holders.** ETH holders back 7-day and 30-day exit rights on IMD, struck below the market. Holders buy them as a put (an **Exit Ticket**) or take a non-liquidating ETH loan against sIMD (a **Floor Loan**). Every ticket is fully backed by ETH locked at purchase, settlement is physical, and no oracle decides any payout.

| | |
|---|---|
| **Status** | Built and tested, not deployed. Unit, fuzz and mainnet-fork tests pass. An internal adversarial review of the core contracts found two confirmed issues (deposit squatting, repaid-loan capacity) and several pricing and liveness issues; all are fixed and covered by tests. Not externally audited. |
| **Chain** | Ethereum mainnet only: sIMD exists only there. |
| **Token** | None. Fees are paid in ETH. |

## In plain words

Wallstrike lets IMD holders **book a guaranteed selling price in advance**, paid in ETH, from people who are happy to buy IMD if it gets cheap. It works like insurance on your IMD: you pay a small fee now, and if the price crashes you can still sell at the agreed price.

The dollar figures below are illustrative, using IMD at about $5 and ETH at about $2,400.

### The problem it solves

IMD's markets are thin. On 2026-10-20, Ethereum pools could absorb only about 40 ETH (about $95k) of IMD sells before the price dropped 20%, while sIMD held about 1.89M IMD (about $8.6M). So if you hold, say, $100k of IMD:

- selling it all at once would crash the price by itself;
- when bad news hits, every big holder rushes to sell first, and whoever is last gets the worst price. That's a run.

Wallstrike gives those holders a pre-booked exit, so they don't have to race.

### What "strike" means

**The strike is the guaranteed selling price.** If you hold an Exit Ticket with a strike of $4, you can sell your IMD for $4 each at expiry, however low the market has fallen.

Each weekly series has its strike calculated automatically when it opens, at one of two levels:

- **Line 0:** 80% of IMD's average price over the last 7 days.
- **Line 1:** 60% of that average.

The strike can also be lowered toward POOL4's buy wall (where IMD's own pool keeps ETH ready to buy back IMD), but by at most 20%. With IMD around $5, line 0's strike sits at about $4.

A higher strike gives more protection and costs more. A lower strike is cheaper but only protects you in a deep crash. The strike is fixed in ETH per IMD, not in dollars; "$4" is just its value today.

### The three kinds of users

**1. IMD holders who want protection buy an Exit Ticket.** You pay a fee (the *premium*) upfront. In return you hold the right, after the expiry date, to sell your IMD at the strike.

Example: you hold 1,000 IMD, the strike is $4, and a 7-day ticket costs about 4.7% of $4,000, roughly $190. It costs up to twice that if you buy early in the one-day sale.

| IMD price at expiry | What you do | Result |
|---|---|---|
| $6 | Nothing; the ticket expires | You lose the $190, but your IMD is worth $6,000 |
| $4 | Nothing; same as the market | You lose the $190 |
| $2 | Exercise: hand over 1,000 IMD, receive $4,000 in ETH | Without the ticket you'd get under $2,000, less after slippage. You saved over $2,000 for $190 |

It works like house insurance: you pay a little each period, and it only matters on the bad day.

**2. sIMD stakers who need cash take a Floor Loan.** You want ETH but don't want to sell or unstake. You post your sIMD and borrow ETH against it.

Example: sIMD worth 1,000 IMD.

- You borrow 35% of its value at the strike: 35% × $4,000 = $1,400 (about 0.59 ETH).
- The fee is about 3%, taken upfront, so you receive about $1,358.
- Repay $1,400 before the deadline and you get your sIMD back.

What makes it different from normal crypto loans is that there is **no liquidation**. If IMD crashes and your sIMD falls to $1,000, nobody force-sells it. You choose: repay and take your sIMD back, or walk away, keep the $1,358, and let the lenders keep the sIMD.

**3. ETH holders who want IMD cheaper become writers.** Writers are the other side of every ticket and loan. You deposit ETH into a series and earn the premiums and loan fees.

Your risk: if IMD crashes, ticket holders sell you their IMD at the strike, so you end up owning IMD bought at $4 while the market says $2. It's like being paid to keep a buy order open below the market:

- **If the price holds,** you get your ETH back plus fees after about 10 days (for a 7-day series).
- **If it crashes,** you end up buying IMD at the strike, a discount to where it was a week earlier, and you keep the premiums.

ETH that no buyer used comes back to you right after the one-day sale.

Writers who don't want to come back every week can use a **writer vault** instead: deposit ETH once and the vault writes every round for you (see [Writer vaults](#writer-vaults)).

### A week, step by step

1. **Any day of the week, a series opens.** Anyone can open it. The strike is calculated and locked.
2. **Day 1: writers deposit ETH.** They can still withdraw.
3. **Day 2: the sale.** Holders buy tickets and stakers take loans. Ticket prices start at double and fall over the day.
4. **About a week later (or 30 days for 30-day series): expiry.** For the next 3 days:
    - ticket holders can exercise (deliver IMD, receive ETH);
    - borrowers can repay.
5. **Settlement:** writers collect what's left: ETH, plus any IMD or sIMD that was delivered or left behind by unpaid loans.

### What everyone gets

| Who | Gets | Gives up |
|---|---|---|
| IMD holder (ticket) | A guaranteed exit price; no need to panic-sell | The premium |
| sIMD staker (loan) | ETH now, stays staked, no liquidation risk | A fee, plus the sIMD if they don't repay |
| ETH holder (writer) | Premium and fee income; IMD at a discount if it drops | Risk of buying IMD above the market in a crash |
| The protocol (fee recipient) | 10% of all premiums and loan fees, in ETH | Running the keeper; audit and legal costs |
| IMD itself | Fewer panic dumps, a new use for sIMD, and ETH buyers waiting below the market | – |

### Why it fits IMD

- It uses **POOL4's buy wall** as a reference for where strikes sit.
- It gives **sIMD** a new job, as loan collateral and as a way to settle tickets.
- It turns IMD's biggest weakness, thin liquidity that makes big exits painful, into the thing people pay for.

That's the Olympus (3,3) idea applied to exits. With a pre-booked exit, rushing to sell first stops being the smart move, so the run doesn't start. The next section shows why.

## The (3,3) game

The original (3,3) from Olympus is a game between two holders who each choose to **stake** (hold) or **sell**. If both stake, both win: (3,3). If one sells, the seller does fine and the holder is hurt. If both sell, it crashes: (−3,−3). The trouble is that once you suspect the other side will sell, selling first becomes your best move. So fear alone can start a run, and that is what broke Olympus.

Wallstrike adds a third choice: **reserve an exit** (buy an Exit Ticket). Here is the game for two big IMD holders during a scare. Numbers are each player's change over 30 days, in percent, and are illustrative:

| | Other **holds** | Other **reserves** | Other **dumps** |
|---|---|---|---|
| **You hold** | (0, 0) | (0, −2) | (−35, −16) |
| **You reserve** | (−2, 0) | (−2, −2) | (−20, −16) |
| **You dump** | (−16, −35) | (−16, −20) | (−25, −25): the run |

- **Without Wallstrike**, only "hold" and "dump" exist. If the other side dumps, dumping too (−25) beats holding (−35), so a run can start from fear alone.
- **With Wallstrike**, "reserve" beats "dump" whatever the other side does (−2 > −16, −2 > −16, −20 > −25). Paying about 2% guarantees an exit price, far cheaper than the slippage of selling into thin pools in a panic. The run stops being the best move, so it doesn't start.

The difference from Olympus: Olympus paid people to stay with newly minted tokens. Wallstrike removes the reason to leave first, and the people who pay for it are the insured holders themselves. No emissions are needed. The effect only reaches as far as the capacity, though: at launch caps (25 ETH of tickets) it protects a few large holders, not the whole IMD market.

## How TVL grows

TVL here is the writer ETH at risk in series (including through writer vaults) plus the sIMD posted for Floor Loans. Writers only stay if their return beats their risk, so TVL follows this loop:

```
more holders want protection -> more premiums -> higher writer return -> more writer ETH
        ^                                                                        |
        +---- bigger caps, more strikes and tenors, a deeper IMD market <--------+
```

**Where writers' return comes from.** At 2026-10-20 prices a 7-day ticket costs 4.7-9.4% of strike notional, depending on when in the auction it sells. With half of a series' capacity used, writers earn roughly 2-4% a week before losses; in crash weeks they buy IMD above the market, which is the loss side. Their edge over fair value comes from the auction starting at twice the floor, the 25% volatility markup and the floor itself. It works best for writers who wanted IMD at a lower price anyway.

**What limits TVL:**

1. **Caps, kept small on purpose:** 10 ETH per series, 25 ETH of tickets in total, 10 ETH of loans. Deposits above a series cap are accepted but returned after the auction, so they are not real TVL. Caps rise through the 48-hour timelock, and should rise only after an audit and as IMD liquidity deepens.
2. **Manual deposits every week.** Writer vaults remove this: deposit once, and the vault rolls into every round.
3. **Idle ETH earns nothing** between sales.
4. **Demand can't outgrow IMD.** sIMD holds about $8.6M and exit depth is about $95k. A hedging market much bigger than its underlying won't fill.

**What would grow it, roughly in order of impact:**

1. **Writer vaults.** Built: see below. TVL stays from round to round instead of having to be won back every week, the way the Ribbon and Thetanuts option vaults grew.
2. **Caps that follow a rule**, for example open tickets as a set share of measured exit depth, so capacity grows automatically as IMD's market deepens.
3. **Yield on idle writer capital**, for example accepting wstETH so waiting ETH earns staking yield. That raises writer returns without raising risk.
4. **Floor Loans as a reason to stay staked.** Getting ETH without unstaking makes sIMD better to hold, and posted sIMD counts as TVL too.
5. **Partners.** IMD's own team could put buy-wall ETH to work writing tickets, and seat holders could insure their income. Both need IMD's cooperation.

**What to avoid:** launching a token to pay writers emissions. TVL would grow fast and leave faster, and it brings back the run problem Wallstrike exists to solve. If a token comes later, its safer job is backstop staking (holders cover writers' losses in exchange for fees), funded by real fee revenue.

## Writer vaults

[`WriterVault`](src/WriterVault.sol) writes one product (a strike line and a tenor) for its depositors, round after round. The deploy script creates two: **weekly** (line 0, 7-day series) and **monthly** (line 1, 30-day series).

```
deposit()      ETH waits for the next round
startRound()   anyone: joins this week's series (opening it if needed), deposits all the vault's ETH
               ... the series runs: auction, expiry, exercise window ...
endRound()     anyone: collects the series' ETH, IMD and sIMD; pays queued withdrawals
startRound()   the next week a series is open: the same shares roll into it automatically
```

- **One series at a time.** A 7-day series takes 12 days from opening to settlement, so the weekly vault runs a round every two weeks; the monthly vault about every five.
- **Shares are priced only between rounds**, when the vault holds nothing but ETH, so no price oracle is involved. Deposits always wait for the next round and become shares at its starting price, and can be cancelled until then.
- **Withdrawals** are instant between rounds. During a round the shares stay at risk and their ETH is paid at the round's closing price; claim it with `claim()`.
- **IMD and sIMD** that the vault receives (exercised tickets, unpaid loans) are not part of the share price. They are split among that round's shareholders pro rata and claimed with `claim()`, so writers get the discounted IMD they signed up for. Depositors who join later get none of an earlier round's IMD.
- **No owner, no fee.** `startRound` and `endRound` are permissionless; the keeper script calls them. Shares are not transferable in this version.

## How it works, in detail

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

Tenors are 7 and 30 days from the end of the auction. "The buy wall" is the top of POOL4's ETH backstop band. Wallstrike reads it as its 24-hour 25th percentile toward the higher price, so a move has to be held for 18 hours to count. The wall can lower a line's strike by at most 20%, and a wall at or above the market (being filled) is ignored, so pushing the wall around can neither block a series nor drag its strike far down.

**Exit Tickets** are ERC-1155 tokens (id = series id, amount = IMD in wei). After expiry the holder delivers that much IMD, or `sIMD.previewWithdraw(amount)` sIMD shares, and receives `amount × strike` ETH. Tickets are transferable.

**Floor Loans.** A borrower posts sIMD and receives 35% of its IMD value, priced at the lower of the strike and the current price. The fee, taken upfront, is the larger of 3% and the value of the put the loan embeds (struck at the principal). There is no price liquidation. The borrower repays the principal before the exercise window closes and gets the sIMD back, or keeps the ETH and the writers keep the sIMD. Collateral is valued at the lower of sIMD's live rate and its rate at opening plus 1%, so a same-transaction donation cannot inflate a loan.

**Premiums** sell in a one-day Dutch auction from twice a floor down to the floor. The floor is a Black-Scholes put value, re-priced at every sale from the lower of POOL4's `refTick` price and the main pool's live price over the time left until the exercise window closes (holders choose when to exercise within it), and never below the floor computed at opening. A fall during the deposit window or the auction is therefore always charged for, and pushing the main pool up does nothing. Pricing volatility is the larger of 200% and 125% of the recorder's 7-day realized volatility; realized IMD/ETH volatility has been 178-391%.

**Writers** deposit ETH into a series before its auction, with no first-come limit. If deposits exceed the series cap, every writer is put at risk pro rata and the excess comes back after the auction, together with any capacity no ticket or open loan used. After the exercise window, each writer takes a pro rata share of the remaining ETH, the delivered IMD and sIMD, and the sIMD of unpaid loans. Fees, loan-to-value, the cap and the pricing volatility are fixed per series when it opens.

## Prices: the recorder

No usable IMD price average exists on-chain: neither POOL4 nor the main ETH/IMD pool keeps price observations, and the IMD Uniswap v3 pools have an observation cardinality of 1. [`ImdPriceRecorder`](src/ImdPriceRecorder.sol) builds one. Every 30 minutes anyone can record a sample of:

- POOL4's `refTick`: the hook's rate-limited follower of the closing tick of the previous block that swapped in POOL4. The first POOL4 swap of a block updates it, but only toward that earlier close and by at most `maxRefStep` (200) ticks, so no transaction can set the value it reads.
- The top of POOL4's buy wall (`backstop().tickLower`).
- sIMD's rate (`convertToAssets(1e24)`).

A sample counts only if POOL4 is open, funded and rebalancing, `maxRefStep` is at most 200, and `refTick` is within 400 ticks (about 4%) of the main hookless pool's tick. A valid sample cannot be overwritten; an invalid one can be replaced by a later valid one in the same slot.

A series needs 252 valid samples in the last 7 days (200 consecutive pairs for the volatility) and 36 in the last 24 hours, 75% coverage in both, so a keeper outage costs at most a day or two. Sales and loans read the live pessimistic price directly, so they do not depend on the keeper. The recorder has no owner and no parameters.

## What the owner can and cannot do

The deploy script makes a 48-hour `TimelockController`, controlled by `ADMIN` (use a multisig), the owner, and sets `GUARDIAN` (a fast-response address) as the guardian. The owner can:

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
- **Known limits.** Per-account caps can be split across addresses; the global caps are what bound exposure. Delivered IMD and sIMD stay in the contract until the exercise window closes. sIMD paid out by `repay` or `claim` in a block where someone stamped Wallstrike's balance cannot be redeemed until the next block.
- **Keepers.** The recorder needs a sample every 30 minutes, finished series should be finalized promptly (open exposure counts against the global caps until then), and writer vaults need `endRound` and `startRound` called. All of these are permissionless, and `script/keeper.sh` does them.
- **Not audited.** Do not deploy with more than the launch caps before an external audit.
- **Legal.** Options and loans are regulated in many places. Get advice before launching.

## Build, test, deploy

```bash
forge build
forge test                                                       # unit and fuzz tests
MAINNET_RPC_URL=https://... forge test --mc ForkTest -vv         # against the real IMD contracts
ADMIN=0x... FEE_RECIPIENT=0x... GUARDIAN=0x... forge script script/Deploy.s.sol \
  --rpc-url $MAINNET_RPC_URL --account deployer --broadcast --verify
RPC_URL=https://... RECORDER=0x... VAULTS="0x... 0x..." KEEPER_ACCOUNT=keeper ./script/keeper.sh   # every few minutes
```

After deploying, the recorder needs about 7 days of samples before the first series can open.
