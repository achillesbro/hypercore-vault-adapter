# HyperCore trading adapter for Morpho Vault v2

A Vault v2 adapter that lets a vault on HyperEVM trade **spot and perps on HyperCore**
(Hyperliquid L1). The allocator drives it with the same rights it uses to allocate/deallocate
elsewhere — no new role.

> Not audited, not deployment-ready — but no longer assumption-based. All addresses, encodings,
> and decimals below are **verified against HyperEVM mainnet (chainid 999)** via `eth_call`
> and against the real sources (`morpho-org/vault-v2`, `hyperliquid-dev/hyper-evm-lib`):
>
> | Fact | Value | How verified |
> |---|---|---|
> | USDC Core token index | `0` | `tokenInfo(0)` precompile → name `"USDC"` |
> | USDC ERC20 on HyperEVM | `0xb88339CB7199b77E23DB6E890353E22632Ba630f` | `symbol()`=USDC, `decimals()`=6 on-chain |
> | CoreDepositWallet (EVM→Core USDC) | `0x6B9E773128f453f5c2C60935Ee2DE2CBc5390A24` | `tokenInfo(0).evmContract`; `deposit(uint256,uint32)` selector `0x2b2dfd2c` present in its implementation |
> | Decimal seam | Core spot wei = EVM × 100 | `tokenInfo(0)`: weiDecimals 8, evmExtraWeiDecimals −2 |
> | Precompile ABI shapes (0x0801/0x0809/0x080f) | as in `HyperCoreReader` | live `eth_call` returns decoded cleanly |
> | Action IDs (1, 6, 7, 11, 13) & SPOT_DEX | as in `HyperCoreActions` | `hyper-evm-lib` `HLConstants.sol` |
> | Adapter/vault interfaces | imported from `lib/vault-v2/src` | the real Morpho sources, not hand-rolled |

## The shape

```
src/
  HyperCoreAdapter.sol        the adapter — funding + trading + valuation
  interfaces/
    IAdapter.sol              the 3 functions Vault v2 requires (allocate/deallocate/realAssets)
    IVaultV2.sol              the vault view the adapter reads (asset, isAllocator)
    ICoreWriter.sol           0x3333… system contract — sendRawAction(bytes)
    IERC20.sol
  libraries/
    HyperCoreActions.sol      CoreWriter action encoders (limit order, usd-class xfer, spot send…)
    HyperCoreReader.sol       precompile reads (0x0801 spotBalance, 0x080f accountMarginSummary…)
    Decimals.sol              EVM / Core-spot / Core-perp decimal seams (centralised, VERIFY)
test/
  HyperCoreAdapter.t.sol      runs without a HyperEVM fork
  mocks/                      MockERC20, MockVaultV2, MockCoreWriter, Mock precompiles
```

## Why funding and trading are split

Vault v2 is **synchronous** (deallocate must hand USDC back in the same tx). HyperCore is
**asynchronous** (orders, bridging, and margin transfers settle on a *later* L1 block; reads
don't reflect a just-queued action). So:

- `allocate` / `deallocate` (vault-only) move the underlying between the vault and the adapter's
  **idle** balance. `deallocate` reverts if the requested amount hasn't already been bridged back.
- `bridgeToCore`, `transferUsdClass`, `placeOrder`, `cancelOrder`, `bridgeToEvm`
  (allocator-gated, via `IVaultV2.isAllocator`) do the actual trading. They never touch vault
  assets directly — the vault's share price tracks the live position through `realAssets()`.

## Funding leg: the transit-asset design (USDT0)

Native USDC **cannot** fund a contract's Core account from HyperEVM — proven live: the Circle
CoreDepositWallet silently refuses contract recipients on both its routes (spot indexing and the
perp-dex CoreWriter forward), CCTP inherits the same wallet, and the mainnet USDC ERC20
*blacklists the system address* so the generic path is token-level blocked. The generic HIP-1
linked-token mechanism, however, credits contract senders (proven with HYPE and PURR probes;
funds sent before the Core account exists sit safely in `evmEscrows` until it does).

So the vault's underlying is a **HIP-1 stable with a linked ERC20 — USDT0 on mainnet** (Core
token 268, ERC20 `0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb`, system address `0x2000…010C`,
USDT0/USDC spot pair 166). Full flow rehearsed by a contract end-to-end on testnet
([TransitBridgeProbe](test/probes/TransitBridgeProbe.sol), PURR standing in for USDT0).

## Operator flow

1. Curator (timelocked): `addAdapter`, then `increaseAbsoluteCap` for each id from `ids()`.
2. One-time: create the adapter's Core account (any Core-side dust send) — `bridgeToCore`
   reverts with `CoreAccountMissing` otherwise (escrow-limbo guard).
3. `vault.allocate(adapter, abi.encode(market), amount)` → USDT0 idle in adapter.
4. `adapter.bridgeToCore(amount)` → ERC20 transfer to the system address → Core **spot** credit.
5. IOC-swap USDT0→USDC on spot pair 166 (`placeOrder(10166, …)` or the agent wallet).
6. `adapter.transferUsdClass(ntl, toPerp=true)` → margin to the **perp** account; trade via agent.
7. Unwind: close positions → `transferUsdClass(false)` → swap USDC→USDT0 → `bridgeToEvm`
   (spotSend) → `vault.deallocate(...)`.

## Valuation & in-flight accounting

`realAssets()` sums everything observable from EVM: idle underlying + in-transit + Core spot
underlying + Core spot USDC (1:1, stable-vs-stable) + perp equity. Operations that move value
*within* that set (swaps, class transfers, Core→EVM bridges) leave the sum invariant and need no
tracking. The only gap is **EVM→Core bridging**: the ERC20 transfer debits idle synchronously
while the Core credit lands a few L1 blocks later. Each such bridge is recorded with the L1 block
it started (`0x0809` precompile) and added back to `realAssets()` **only until its age exceeds
`settleWindowBlocks`** — after which settlement is guaranteed and the Core spot balance reflects
it, so the add-back self-expires with no double count and no keeper.

Hardening built in:

- Perp equity floored at zero; reads fail closed (revert, never fabricate a value).
- Self-expiring in-transit add-back so a deposit mid-bridge is never read as a loss.
- Optional `maxGainBps` ceiling (curator-set, default off): caps the gain a single read may report
  above cost basis, blunting a one-block mark-price spike. Losses always pass through.
- Config (`settleWindowBlocks`, `maxGainBps`) is curator-gated, not allocator-gated.

## Still open (see PRODUCTION.md — the living tracker)

- Withdrawal liquidity — instant exits served only from idle underlying (revert model, like Blue).
- Multi-asset spot valuation + priced USDC↔USDT0 conversion (currently 1:1, documented).
- Conservative perp re-marking (oracle vs mark) would require tracking the open-markets set.
- Settlement-window calibration with a measured latency distribution.

## Execution model: agent-wallet route (chosen)

Trading is delegated to an off-chain **agent wallet** rather than placed on-chain. The adapter
authorizes an agent via `approveApiWallet(agent, name)` (CoreWriter action 9 — the only way a
contract, which can't sign off-chain, can delegate trading). The agent then places/cancels orders
through Hyperliquid's normal API/SDK against the adapter's Core account. The agent **cannot
withdraw or move funds** — only the allocator-gated bridge/deallocate paths can, so the agent's
blast radius is bad trades, not theft. `revokeApiWallet(name)` (allocator or curator) is the kill
switch. Fund movement (bridge, spot↔perp) stays on-chain in the adapter; only order execution is
off-chain. On-chain `placeOrder`/`cancelOrder` remain as an optional fallback.

Proven live on testnet (2026-06-12, adapter `0x5a71C5A4DA2c6B5B32B91ef2b83B2d4aC28bFF8e`):

| Step | Result |
|---|---|
| `approveApiWallet` from the contract → CoreWriter action 9 | ✓ agent shows in `extraAgents`, valid ~1yr |
| Agent (holding no funds) opens 0.0002 BTC via SDK, `account_address`=adapter | ✓ filled @ 62739 |
| Position booked under the **adapter's** Core account | ✓ szi 0.0002, uPnL tracked |
| `realAssets()` reflects it on-chain via real precompiles | ✓ ~$5.99 (mark/oracle spread vs API) |
| Agent closes via SDK | ✓ filled @ 62769 |
| `revokeApiWallet` from the contract (approve zero address) | ✓ `extraAgents` empties |
| Agent trade attempt after revoke | ✓ rejected: "API Wallet does not exist" |

Operator tooling: `script/flow/agent_trade.py` (open/close/status via the SDK as the agent).

## Live testnet results (2026-06-12)

Deployed and exercised on HyperEVM testnet (chainid 998):
factory `0x17b98fdd6c04d2db38b4a67a463e50aab630a026`, vault
`0x84ec0fca475d13a7fd3af55b752c584f9791171f`, adapter
`0x67bc637af11b0d3ada30bbd1619530f21e40b550`.

| Leg | Result |
|---|---|
| Deposit + allocate through the real VaultV2 | ✓ |
| In-flight add-back held NAV during bridge window | ✓ (then correctly expired) |
| EVM→Core USDC via Circle CoreDepositWallet, contract recipient | ✗ **silently not credited** (see below) |
| Core-side spotSend of USDC/HYPE to the contract | ✓ |
| `transferUsdClass` from the contract (CoreWriter action 7) | ✓ 42 USDC spot→perp |
| `placeOrder` from the contract (action 1) | ✓ IOC filled 0.0002 BTC @ 64489 |
| Reduce-only close from the contract | ✓ position flat, ~$0.01 round trip |
| `realAssets()` via real precompiles tracking live position | ✓ vault `totalAssets()` matched throughout |
| `bridgeToEvm` from the contract (action 13 sendAsset) | ✓ 40 USDC landed on EVM |
| Deallocate + depositor withdraw at post-loss share price | ✓ |

**The finding:** the Circle CoreDepositWallet (the only indexed EVM→Core path for USDC — plain
ERC20 transfers to the system address are not indexed) refuses to credit smart-contract
recipients: `deposit()` from the adapter and `depositFor(adapter, …)` from an EOA both emit the
correct event but produce no Core ledger entry, and the USDC is absorbed without refund.
Identical calls with an EOA recipient credit in seconds. Contracts hold and use Core USDC
perfectly well once it arrives Core-side. Options before mainnet: (a) verify the mainnet wallet
implementation (different bytecode) credits contracts with a $5 probe; (b) redesign funding
around a HIP-1 stable (e.g. USDT0) whose linked-ERC20 system-address path is the generic
mechanism, swapped to USDC on Core spot; (c) Core-native funding flows.

It also empirically falsified the original "settlement guaranteed after N blocks" assumption —
the in-transit add-back expired against a deposit that never settled, correctly realizing the
loss rather than carrying phantom value indefinitely (the conservative failure mode).

## Testnet deployment runbook

Verified testnet (chainid 998) constants: USDC ERC20 `0x2B3370eE501B4a559b57D449569354196457D8Ab`
(6 decimals), CoreDepositWallet `0x0B80659a4076E9E93C7DbE0f10675A16a3e5C206`
(= `tokenInfo(0).evmContract`), same decimal seam as mainnet.

Dedicated testnet deployer: `0x743312d068bd389930903ce182688E8d8E3F78DA`
(key in `~/.hypercore-testnet/deployer.json` — testnet only, never fund on mainnet beyond activation).

1. **Activation (one-time, human)** — the testnet faucet refuses addresses that don't exist on
   mainnet. Send ~$5 USDC on Hyperliquid **mainnet** (Core-side send) to the deployer address,
   then claim: `curl -X POST -H "Content-Type: application/json" -d
   '{"type":"claimDrip","user":"0x743312d068bd389930903ce182688e8d8e3f78da"}'
   https://api.hyperliquid-testnet.xyz/info` → 1000 mock USDC on testnet Core.
2. Buy a little HYPE on testnet spot (API) and spot-send it to `0x2222...2222` to get native
   gas on HyperEVM, and spot-send USDC to the EVM side for the deposit flow.
3. `python3 script/flow/00_enable_big_blocks.py` — factory deployment needs ~15.7M gas
   (measured), far over the 3M small block.
4. `forge script script/DeployTestnet.s.sol --rpc-url https://rpc.hyperliquid-testnet.xyz/evm
   --private-key ... --broadcast --slow` (simulation already passes against the live RPC).
5. Disable big blocks again (`00_enable_big_blocks.py --off`), export `VAULT` / `ADAPTER`,
   then drive the full cycle with `script/flow/flow.py` (deposit → allocate → bridge →
   usd-class → trade → close → bridge-out → deallocate → withdraw) and verify Core-side
   settlement with `script/flow/check_core_state.py <adapter>`.

Note on trading UX: the adapter is a contract account — it cannot connect to the Hyperliquid
web app (nothing can sign for it). Trading happens through EVM calls to the adapter
(`flow.py trade ...`), while the HL explorer/portfolio pages work read-only for monitoring the
adapter's positions.

## Run

```
forge build
forge test -vv                      # unit tests (mocked HyperCore + mocked vault)
FOUNDRY_PROFILE=fork forge test -vv # fork tests against HyperEVM mainnet
```

### What the fork tests prove (and what they can't)

The fork suite (`test/fork/HyperEVMFork.t.sol`) deploys the **real `VaultV2`** through the real
factory on a fork of HyperEVM mainnet, with **real USDC** as the asset, and exercises the full
cycle against the **real CoreDepositWallet** and **real CoreWriter** bytecode: deposit → allocate →
bridge (real `deposit()` pull) → trade actions (real `sendRawAction`) → simulated Core settlement →
deallocate → withdraw at par, plus cap enforcement, allocator gating, and loss realization into
share price by the real vault accounting.

Two real-chain behaviors surfaced by these tests:
- `VaultV2` uses **transient storage** (`firstTotalAssets`): interest/losses accrue once per
  *transaction*. The fork profile runs with `isolate = true` so each call is its own tx,
  matching live-chain behavior.
- HyperEVM's default block env is the **3M small block** — deploying the factory needs a
  30M big block (`disable_block_gas_limit` in tests; on the real chain, the big-block flag).

Honest limitation: HyperCore **read precompiles are node-level, not EVM bytecode**, so no local
fork can execute them. Their ABI shapes were verified against the live node via `eth_call`
(server-side, where they do run); the fork tests etch shape-identical mocks starting at zero —
which is exactly the Core state of a freshly deployed adapter. Core-side settlement (spot credits,
fills) cannot occur on any fork; only a **testnet deployment** exercises that for real.
