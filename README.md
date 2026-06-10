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

## Known sharp edges (see inline comments)

- In-flight accounting during the settlement window (`pendingBridgeOut` is a placeholder).
- `realAssets()` manipulation surface — gains are rate-capped by the vault, losses pass through.
- Withdrawal liquidity — instant exits served only from idle USDC; size a `forceDeallocatePenalty`.
- Mainnet USDC bridges via the `CoreDepositWallet` helper, not the generic system-address path.

## Run

```
forge build
forge test -vv
```
