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
