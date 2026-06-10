# HyperCore trading adapter for Morpho Vault v2

A Vault v2 adapter that lets a vault on HyperEVM trade **spot and perps on HyperCore**
(Hyperliquid L1). The allocator drives it with the same rights it uses to allocate/deallocate
elsewhere — no new role.

> Scaffold / design exploration. Encodings, addresses, and decimals are sketched from the
> Hyperliquid docs and `hyper-evm-lib`, and **must be verified against on-chain `tokenInfo`
> before any deployment**. Not audited, not deployment-ready.

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
forge test -vv
```
