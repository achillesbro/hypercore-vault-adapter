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

Lead: **CCTP on HyperCore** (https://developers.circle.com/cctp/concepts/cctp-on-hypercore).
CCTP v2 `TokenMessengerV2.depositForBurn` with hook data calls a `CctpForwarder` contract on
HyperEVM which forwards USDC to a specified **HyperCore recipient**. CCTP is contract-friendly
by design on the burn side. Live on testnet (limits: recipient must exist on HyperCore mainnet;
≤ $1000 testnet USDC).

- [ ] Read the full CCTP-on-HyperCore docs + `CctpForwarder` source; get contract addresses
- [ ] Determine whether the **HyperCore recipient can be a smart contract** (the open question —
      if the forwarder ultimately routes through the same CoreDepositWallet indexing, the
      restriction may persist; test with $5 before building)
- [ ] If viable: reimplement `bridgeToCore` via CCTP (burn on HyperEVM → forwarder hook →
      Core credit), keeping the in-flight accounting model (attestation latency ≠ 0)
- [ ] If not viable: fallback design — HIP-1 stable (USDT0) linked-ERC20 system-address path
      + Core spot swap to USDC (adds swap leg + slippage to bridge and `realAssets()`)
- [ ] Testnet probe of the chosen path with small amounts before wiring into the adapter
- [ ] Update `bridgeToEvm` if CCTP also improves the exit path (current sendAsset path works)

### Audit

- [deferred] Professional audit — not required for educational use. Revisit before any real funds.

## Tier 1 — correctness & safety

### realAssets() hardening — **Session B**

- [ ] Multi-asset spot valuation: value non-USDC spot holdings on-chain via precompiles —
      `spotPx` (0x0808), `markPx` (0x0806), `oraclePx` (0x0807), and **`bbo` (0x080e) for
      order-book mid** ((bid+ask)/2). Off-chain cross-check via info endpoint `allMids`.
      Decide the source hierarchy (oracle > mid > mark?) and haircut policy.
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

- [ ] Measure real settlement latency distribution of the chosen funding path (CCTP
      attestation time if Session A lands CCTP)
- [ ] Set window = measured p99 + margin; document the residual mispricing bound
- [ ] Consider event/receipt-based reconciliation instead of pure time expiry if CCTP
      provides a verifiable delivery signal

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
