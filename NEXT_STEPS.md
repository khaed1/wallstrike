# Where development stopped

Last updated 2026-10-20.

## Done

| Part | State |
|---|---|
| `ImdPriceRecorder` | Done. 30-minute samples of POOL4's `refTick`, the buy wall and the sIMD rate; 7-day mean, wall percentile, realized volatility, live pessimistic tick. |
| `Wallstrike` | Done. Weekly series, Exit Tickets, Floor Loans, live re-pricing, pro rata writer pools, guardian pause, 48-hour timelock owner. Reviewed twice; all confirmed findings fixed. |
| `WriterVault` | Done. Auto-rolling writer vault, one product per vault. Reviewed once; all confirmed findings fixed (see below). |
| Scripts | `script/Deploy.s.sol` (recorder, timelock, Wallstrike, weekly and monthly vaults; simulated on a mainnet fork, not broadcast) and `script/keeper.sh` (recorder samples, vault rounds). |
| Tests | 78 unit and fuzz tests and 3 mainnet fork tests, all passing on the last run (2026-10-20). |
| README | Plain-language explanation, the (3,3) game, how TVL grows, writer vaults, technical design, risks. |

### Writer vault review: what changed last

The last review of `WriterVault` found no loss of funds. Fixed in the final commit:

- A round needs shares at risk and at least 0.1 ETH (`MIN_ROUND_ETH`), so dust or forced ETH cannot occupy the vault or strand a round's IMD.
- `withdraw` is instant-only and reverts during a round; `requestWithdraw` queues; `cancelWithdraw` works until the series' auction starts.
- A round can start only 12 hours after the previous one ended (`MIN_IDLE`), so holders always get a window to leave.
- `keeper.sh` logs and skips a failed step instead of aborting, and dry-runs `poke` first.

Documented rather than changed: the vault's unused ETH stays in Wallstrike until the round ends, and the vault joins every series of its product whatever its terms.

## Not done yet

1. **Run the full test suite again** before any deployment: `forge test` and `MAINNET_RPC_URL=... forge test --mc ForkTest`. The last run passed, but run it again after any change.
2. **External audit** of `Wallstrike`, `WriterVault` and `ImdPriceRecorder`. Internal AI reviews are not a substitute, especially before raising caps.
3. **Deployment**, which needs your wallet: `ADMIN` (a multisig), `FEE_RECIPIENT`, `GUARDIAN`, then `script/Deploy.s.sol` with `--broadcast`. Nothing has been deployed.
4. **A keeper** running `script/keeper.sh` every few minutes with `RECORDER` and `VAULTS` set. The first series can open about 7 days after deployment.
5. **Legal advice** on offering options and loans.

## Ideas for later

- Let a vault spread across several series (or both tenors), so ETH above one series' cap is not idle.
- Pay queued vault withdrawals their share of released ETH right after the auction.
- Caps that follow a rule, such as a share of measured IMD exit depth.
- Accept wstETH from writers so idle capital earns staking yield.
- Make vault shares transferable (an ERC-20).
- Sell only when terms are acceptable: an optional minimum premium or maximum strike for the vault.

## imdUSD

[imdUSD](https://imdusd.com) is a third-party stablecoin (source: [fa11up/infer-protocol](https://github.com/fa11up/infer-protocol)) borrowed against sIMD. Its vault was deployed on 2026-10-11 (`0x0b69F8DA8D8cE521d74Ea69a7A3475B77302EF82`). On 2026-10-21 it had about 145.8k imdUSD in circulation, about 147.3k of debt against a 1M ceiling, sIMD collateral worth about 82.6k IMD, and a 170% minimum collateral ratio. Its IMD price comes from IdentityMD oracle panels signed by one key, and it has its own token, INFER, distributed through points.

**Decision so far: don't use imdUSD as money inside Wallstrike.** Writers backing tickets with imdUSD, or strikes set in imdUSD, would pay out in a currency backed by the same IMD the tickets insure. Tickets pay when IMD crashes, which is when imdUSD is most likely to slip below $1. If dollar strikes are ever wanted, use a stablecoin that does not depend on IMD.

**Do treat imdUSD borrowers as customers.** Their sIMD collateral is what Wallstrike tickets protect. [docs/imdusd-hedge.md](docs/imdusd-hedge.md) sketches a "hedge your imdUSD position" front-end flow. Tickets hedge the collateral's value at expiry; they do not stop a liquidation in the middle of a week. Phase 2 of the sketch is a one-click "close the position at the strike" helper.

**Watch:**

- Their oracle and Wallstrike's recorder read the same IMD pools; an attack holding a pool down for hours affects both.
- An imdUSD liquidation cascade sends sIMD to liquidators who must sell it; Wallstrike writers end up buying it. Keep caps conservative while both protocols are young.
- Talk to the imdUSD builder: a "protect this position" link from their terminal could suit both protocols.
