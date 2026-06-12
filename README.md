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

- `allocate` / `deallocate` (vault-only) move USDC between the vault and the adapter's **idle**
  balance. `deallocate` reverts if the requested USDC hasn't already been bridged back.
- `bridgeToCore`, `transferUsdClass`, `placeOrder`, `cancelOrder`, `bridgeToEvm`
  (allocator-gated, via `IVaultV2.isAllocator`) do the actual trading. They never touch vault
  assets directly — the vault's share price tracks the live position through `realAssets()`.

## Operator flow

1. Curator (timelocked): `addAdapter`, then `increaseAbsoluteCap` for each id from `ids()`.
2. `vault.allocate(adapter, abi.encode(market), amount)` → USDC idle in adapter.
3. `adapter.bridgeToCore(amount)` → lands in the Core **spot** account.
4. `adapter.transferUsdClass(ntl, toPerp=true)` → moves margin to the **perp** account.
5. `adapter.placeOrder(perpIndex, isBuy, px, sz, reduceOnly, tif, cloid)`.
6. Unwind: reduce-only close → `transferUsdClass(false)` → `bridgeToEvm` → `acknowledgeBridgeIn`
   → `vault.deallocate(...)`.

## Valuation & in-flight accounting

`realAssets()` sums everything observable from EVM: idle USDC + Core perp equity + Core spot USDC.
Operations that move value *within* that set (spot↔perp class transfers, orders, Core→EVM bridges)
leave the sum invariant and need no tracking. The only gap is **EVM→Core bridging**: the ERC20
transfer debits idle synchronously while the Core spot credit lands a few L1 blocks later. Each such
bridge is recorded with the L1 block it started (`0x0809` precompile) and added back to `realAssets()`
**only until its age exceeds `settleWindowBlocks`** — after which settlement is guaranteed and the Core
spot balance reflects it, so the add-back self-expires with no double count and no keeper.

Hardening built in:

- Perp equity floored at zero; reads fail closed (revert, never fabricate a value).
- Self-expiring in-transit add-back so a deposit mid-bridge is never read as a loss.
- Optional `maxGainBps` ceiling (curator-set, default off): caps the gain a single read may report
  above cost basis, blunting a one-block mark-price spike. Losses always pass through.
- Config (`settleWindowBlocks`, `maxGainBps`) is curator-gated, not allocator-gated.

## Still open (see inline comments)

- Withdrawal liquidity — instant exits served only from idle USDC; size a `forceDeallocatePenalty`.
- Multi-asset spot valuation — price non-USDC spot via a manipulation-resistant source (oracle).
- Conservative perp re-marking (oracle vs mark) would require tracking the open-markets set.
- Mainnet USDC bridges via the `CoreDepositWallet` helper, not the generic system-address path.

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
