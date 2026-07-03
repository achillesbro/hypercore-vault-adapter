# Production readiness tracker

> Scope note: this adapter is currently for **internal / educational / testing purposes**.
> Items marked `[deferred]` are acknowledged but out of scope until the purpose changes
> (real third-party money). Check boxes as items land; each item names the session that owns it.
>
> Suggested session split (run as separate Claude sessions, in this order):
> - **Session A — CCTP funding leg** (tier 0, highest leverage, may change bridge architecture)
> - **Session B — realAssets() hardening** (tier 1, independent of A)
> - **Session C — timelock & guard** (tier 2, small, independent)
> - **Session D — integration round-trip + loss behavior** (after A lands)
>
> Sessions touch the same files (`src/HyperCoreAdapter.sol`) — run them sequentially or on
> branches, and let each session update only its own checkboxes here.

## Current status (proven on live testnet, 2026-06)

- [x] Vault V2 adapter surface (`allocate`/`deallocate`/`realAssets`) against the real VaultV2
- [x] Verified chain constants (mainnet + testnet): USDC token 0, deposit wallet, decimal seams
- [x] In-flight EVM→Core accounting (self-expiring, L1-block-stamped add-back)
- [x] CoreWriter actions from the contract: usdClassTransfer, placeOrder (filled), cancel, sendAsset
- [x] Agent-wallet route: approveApiWallet/revokeApiWallet (action 9), live open/close via SDK,
      revocation kill switch verified ("API Wallet does not exist" post-revoke)
- [x] Loss realization through real vault accounting (fork test, isolate mode)
- [x] Operator tooling: `flow.py`, `agent_trade.py`, `accept_terms.py`, `check_core_state.py`
- [x] 22 unit tests + 6 mainnet-fork tests green

Deployed (testnet, chainid 998): vault `0x84ec0fca475d13a7fd3af55b752c584f9791171f`,
adapter v2 `0x5a71C5A4DA2c6B5B32B91ef2b83B2d4aC28bFF8e`,
agent `0x19De5F4569e2622485d966f6CF8a3e84a9A6a111`.

## Tier 0 — blockers

### Funding leg: EVM→Core USDC for a contract account — **Session A**

Finding (2026-06-12, testnet): the Circle CoreDepositWallet silently refuses to credit
smart-contract recipients — `deposit()` from the adapter and `depositFor(adapter,…)` from an
EOA both emit correct events but produce **no Core ledger entry**; funds are absorbed
(500 tUSDC lost proving it). EOA recipients credit in seconds. Plain ERC20→system-address
transfers are not indexed for USDC.

**RESOLVED (2026-06, `funding-leg-hardening` branch): transit-asset design (USDT0), CCTP ruled out.**

- [x] CCTP investigated: `CctpForwarder` sits next to `CoreDepositWallet` in
      `circlefin/hyperevm-circle-contracts` and forwards **into the same wallet** → CCTP
      inherits the contract-recipient refusal. Dead end for contracts. (CCTP v2 core is live on
      HyperEVM, domain 19, canonical CREATE2 addresses — irrelevant to us now.)
- [x] Root cause localized by reading the wallet source: NO recipient restriction in the EVM
      code — the refusal is HyperCore's off-chain indexer. Both wallet routes fail for contract
      recipients: the spot route (synthetic `Transfer(recipient, systemAddress)` — ignored) and
      the perp route (wallet self-credits then CoreWriter `sendAsset` forwards — the send is
      dropped for contract destinations; verified in the wallet's Core ledger: our 2 tUSDC
      probe credited the wallet but produced no onward `send`, while an EOA deposit minutes
      earlier forwarded fine).
- [x] Native-USDC generic path is **token-level blocked**: the mainnet USDC ERC20 *blacklists
      the system address* ("Blacklistable: account is blacklisted", verified on fork). USDC can
      never use the HIP-1 path; the Circle wallet is its only (EOA-only) door.
- [x] Generic HIP-1 mechanism proven **live for contracts** (testnet probes):
      native HYPE → `0x2222…` credited the sending contract; PURR linked-ERC20 →
      `0x2000…0001` credited the sending contract. Discovery: funds sent before the Core
      account exists sit safely in **`evmEscrows`** and credit in full once the account is
      created (vs. the wallet path where funds are absorbed unrecoverably).
- [x] **Full funding leg rehearsed end-to-end by a contract** (`test/probes/TransitBridgeProbe.sol`,
      testnet): bridge 4.9965 PURR via system address → IOC spot-sell 4 PURR @ 4.5795 → 18.31
      Core USDC → `usdClassTransfer` → perp accountValue 18.0. Zero EOA custody.
- [x] Adapter reworked to the transit design: underlying = HIP-1 stable (USDT0 mainnet);
      `bridgeToCore` = ERC20 transfer to `transitSystemAddress`, gated on `coreUserExists`
      (0x0810) to avoid escrow limbo; `bridgeToEvm` = `spotSend` (action 6, the
      reference-adapter-proven exit); swaps to/from USDC via `placeOrder` on the spot pair
      (or the agent); in-flight accounting unchanged. Circle wallet dependency deleted.
- [x] `realAssets()` extended: idle + in-transit + Core spot underlying + Core spot USDC +
      perp equity; USDC counted 1:1 in underlying units (stable-vs-stable — priced conversion
      is a Session B follow-up). 23 unit + 7 fork tests green (fork uses real USDT0).
- [x] Mainnet USDT0 constants verified: Core token **268**, ERC20
      `0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb` (6 decimals), `evm_extra_wei_decimals -2`,
      system address `0x2000…010C`, **USDT0/USDC spot pair 166** (asset id 10166).
- [ ] Operational prerequisite at deployment: create the adapter's Core account (any Core-side
      dust send) before first bridge — enforced by the `CoreAccountMissing` revert
- [ ] Live end-to-end run on mainnet with small size (testnet has no USDT0; the mechanism was
      rehearsed with PURR) — folds into Session D

### Audit

- [deferred] Professional audit — not required for educational use. Revisit before any real funds.

## Tier 1 — correctness & safety

### Account abstraction modes (unified accounts) — **resolved (verified live, 2026-07-03)**

Hyperliquid now has per-account *abstraction modes*: **unified** (single balance per asset,
spot collateralizes perps), **portfolio margin**, **standard/split** (the old model, still
recommended by the docs for automated users), and legacy dex-abstraction ("default", being
discontinued). Verified live on the testnet adapter by flipping modes with the agent:

- **`realAssets()` is mode-invariant, zero code change needed**: the precompiles partition
  value cleanly. Standard: spot=0, perp `accountValue`=collateral+uPnL. Unified: spot=free
  balance, `accountValue`=held margin+uPnL. Observed sums identical (7.166227 both ways);
  encoded as `test_realAssets_abstractionModeInvariant`.
- `transferUsdClass` is a **silent no-op under unified** (tx succeeds, Core drops action 7,
  no ledger entry) — harmless; still needed for standard-mode accounts.
- Mode changes: `agentSetAbstraction` (agent-signed) works — the agent flipped the adapter
  `default → unified`. Transitions are **refused with open positions/orders**, and moving
  OUT of unified was refused even when flat → treat unified as **one-way for contract
  accounts** (leaving may require a user signature a contract can't produce). Choose at
  deployment, deliberately, while flat.
- Recommendation for the adapter: **unified** — removes the class-transfer step from the
  funding flow (bridge → swap → trade) and the "USDC stuck in wrong class" failure mode.
  The 50k-actions/day cap is irrelevant at vault scale. (Docs recommend standard for
  builders mainly for that cap + builder-fee accrual, which we don't use.)
- [ ] Multi-dex caveat (now sharper under unified): only `perpDex` is read by valuation;
      USDT0 spot can collateralize USDT-margined HIP-3 dexes (e.g. CASH perps) under unified,
      which would be INVISIBLE to `realAssets()`. Forbid via operator policy until multi-dex
      margin reading lands — **Session B**
- The testnet adapter `0x5a71…` now runs in unified mode (live reference).

### Underlying expansion (multi-asset vaults) — decision record (2026-07-03)

Decision: keep the transit design (option 1); USDT HIP-3 perps sunset kills the no-swap
variant; EOA-relay and HL-escalation options rejected. Swap cost quantified live:
USDT0/USDC 4.4bps spread + 1.4bps taker (80% stable-pair discount) ≈ ~7bps round trip on
flows only. EXPANDED to non-stable underlyings — verified constants:

| Underlying | Core idx | EVM form | USDC pair | usdToUnderlyingScale |
|---|---|---|---|---|
| USDT0 | 268 | ERC20 `0xB8CE59FC…5ebb` (6d) | 166 (asset 10166) | 1e6 |
| HYPE | 150 | native → WHYPE `0x5555…5555` (18d) | 107 (asset 10107) | 1e18 |
| UBTC | 197 | ERC20 `0x9fdb…3463` (8d) | 142 (asset 10142) | 1e5 |

- [x] Native-underlying branch: bridgeToCore unwraps WHYPE → sends value to `0x2222…2222`
      (mechanism proven live by HypeBridgeProbe); Core→EVM arrivals land native, `wrapNative()`
      (permissionless) re-wraps; realAssets counts native pre-wrap.
- [x] Priced valuation via bbo ask (see above) — required for non-stable underlyings.
- [ ] HYPE/BTC as DIRECT perp collateral = **portfolio margin** mode (eligible: HYPE, BTC,
      USDC, USDT): cannot be verified on testnet ($10k account-value floor) and adds
      borrow-fee mechanics to valuation — deferred; until then non-stable underlyings swap
      to USDC on their pair like USDT0 does — **Session B/D**
- [ ] Live rehearsal of the WHYPE loop on testnet (HYPE is native there too) — **Session D**

### realAssets() hardening — **Session B**

- [ ] Multi-asset spot valuation: value non-USDC spot holdings on-chain via precompiles —
      `spotPx` (0x0808), `markPx` (0x0806), `oraclePx` (0x0807), and **`bbo` (0x080e) for
      order-book mid** ((bid+ask)/2). Off-chain cross-check via info endpoint `allMids`.
      Decide the source hierarchy (oracle > mid > mark?) and haircut policy.
- [x] Price the USDC↔underlying conversion in `realAssets()` — DONE: USD-denominated Core
      value (perp equity + spot USDC) is priced via the `bbo` precompile (0x080e) at the ASK
      of the UNDERLYING/USDC pair (conservative; fails closed on an empty book). Replaces the
      1:1 stable assumption and prices depeg risk. bbo raw px scaling verified on-chain:
      human px * 10^(8 - baseSzDecimals).
- [ ] Open-markets registry: track which perps/spot pairs the account can hold so valuation
      can enumerate and conservatively re-mark positions (mark vs oracle divergence)
- [ ] Confirm `accountMarginSummary.accountValue` semantics under isolated vs cross margin
- [ ] Per-market `szDecimals`/`weiDecimals`/tick/lot verification for every market traded
      (read `tokenInfo`/`perpAssetInfo` precompiles; no hardcoding)

### Settlement window calibration — **Session A or D**

`settleWindowBlocks` bounds the NAV mispricing window in BOTH directions (see README):
too short → add-back expires before Core credits → transient phantom loss (attacker buys
shares cheap, NAV pops back); too long → a silently-failed deposit carries phantom value →
exiting depositors overpaid at remaining LPs' expense. Testnet already falsified one
assumed bound.

- [ ] Measure real settlement latency distribution of the transit path (HIP-1 system-address
      credits — observed seconds-fast on testnet probes, needs a distribution not anecdotes)
- [ ] Set window = measured p99 + margin; document the residual mispricing bound
- [ ] Consider reconciliation against the Core spot balance delta (the credit is observable
      via the spotBalance precompile) instead of pure time expiry

### Withdrawals & liquidity — **resolved (design decision)**

Decision: **revert on insufficient idle liquidity** (`InsufficientIdle`), same model as
regular Morpho vaults — it is on the curator/allocator to keep enough idle or unwind
positions. Notes from investigation:

- The HyperCore adapter **cannot** be the vault's `liquidityAdapter`: VaultV2's `withdraw`
  auto-deallocates the shortfall **synchronously in the same tx** (VaultV2.sol L810), and
  Core-side funds cannot arrive synchronously. It would only serve from the adapter's idle
  EVM balance, which adds nothing over vault idle.
- ERC-7540 async redemptions would be a vault-level wrapper, not an adapter concern — out of
  scope here.
- [ ] (optional, later) calibrate `forceDeallocatePenalty` so forced exits price in unwind cost

### Loss flow / liquidation — **Session D**

No bad-debt vector like Blue (no borrowing against inflated oracle); the loss path is:
position loses / gets liquidated → `accountValue` drops → `realAssets()` drops →
**share price decreases at next `accrueInterest()`** (confirmed in fork test; losses pass
through in full, gains are `maxRate`-capped).

- [ ] Check HL docs: liquidation mechanics for the account (cross vs isolated), whether
      `accountValue` can be negative post-liquidation (we floor at 0), and any state that
      could wedge `realAssets()` (open orders' `hold`, isolated margin remnants)
- [ ] Testnet experiment: force a small liquidation on the adapter account, observe
      `realAssets()`/share price through it

## Tier 2 — trust model & governance

- [deferred] Agent-key OpSec (custody, rotation ~1yr expiry `validUntil`, off-chain risk
  limits) — internal use for now. NEVER reuse the testnet pattern (key in chat/browser) on
  mainnet.
- [ ] **Timelock `approveApiWallet`** — **Session C**. Changing the agent is the highest-trust
      action on the adapter (delegates all trading). Route it through the vault's
      submit/timelock pattern (or an adapter-level timelock mirroring it). Keep
      `revokeApiWallet` instant (kill switch must not be timelocked).
- [ ] Move `setSettleWindowBlocks` / `setMaxGainBps` behind the same timelock — **Session C**
- [ ] (optional) Guard layer à la deployed adapter's `requireTrustline`: every state-changing
      call passes an oracle-approval / sanity check (price bands, max notional per action,
      allowed-assets whitelist). Lightweight on-chain checks are enough for educational use.
      — **Session C**
- [deferred] Production role assignment (multisigs), caps policy, adapterRegistry

## Tier 3 — testing, ops, deploy (after the contract stabilizes)

- [ ] Fuzz/invariant tests on accounting + in-flight edges; adversarial tests (mark
      manipulation, precompile-revert fails closed, reentrancy) — **Session D**
- [ ] Full testnet round-trip with REAL Core settlement once Session A lands — **Session D**
- [ ] Monitoring: `realAssets()` deviation alerts, agent activity watch, pending-bridge
      reconciliation; decide if `pruneSettled` needs a keeper
- [ ] Mainnet constants + deploy runbook (big blocks for deploy ~15.7M gas; confirm every
      runtime op fits 3M small blocks)

## Reference material

- CCTP on HyperCore: https://developers.circle.com/cctp/concepts/cctp-on-hypercore
- HL info endpoint (allMids, order book): https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint
- HL docs MCP (added to user scope): `hyperliquid-docs` — available in new Claude sessions
- Reverse-engineered reference adapter: `0x37c0e43A6D3c19A66ce30da6F5CfD68f73c4cAC4`
  (vault `0xd9e4D1e387dCfDCB96560992685a96e3f36CdB2e`) — agent-wallet route, requireTrustline
  guard at `0x411F955295d199EbDCc297236F5373C61DcCA242` → singleton `0x3323840a5400adf89c48Dfe608Bb28fD71212da5`
