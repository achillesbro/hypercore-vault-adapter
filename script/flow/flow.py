#!/usr/bin/env python3
"""Operator CLI for the HyperCore adapter on HyperEVM TESTNET.

This is the "trading UI": the adapter is a contract account on HyperCore, so it cannot
connect to the Hyperliquid web app (no private key to sign with). All trading goes through
EVM transactions to the adapter, which queues CoreWriter actions. The Hyperliquid UI/explorer
remains useful READ-ONLY (paste the adapter address into the portfolio view).

Setup:
  pip install eth-account
  export VAULT=0x... ADAPTER=0x...           # printed by DeployTestnet.s.sol

Full flow:
  python3 flow.py status                      # EVM + Core view of vault/adapter
  python3 flow.py deposit 1000                # 1. depositor -> vault idle (USDC)
  python3 flow.py allocate 1000               # 2a. vault idle -> adapter idle
  python3 flow.py bridge 1000                 # 2b. adapter idle -> Core spot (async!)
  python3 flow.py usd-class 900 --to-perp     # 2c. spot -> perp collateral
  python3 flow.py trade BTC buy 0.001         # 3. market-ish IOC order
  python3 flow.py trade BTC sell 0.001 --reduce-only   # 4. close
  python3 flow.py usd-class 900 --to-spot
  python3 flow.py bridge-out 1000             # 5a. Core spot -> adapter idle (async!)
  python3 flow.py deallocate 1000             # 5b. adapter idle -> vault idle
  python3 flow.py withdraw 1000               # 5c. vault -> depositor
"""

import argparse
import json
import ssl
import time
import urllib.request
from pathlib import Path

from eth_account import Account

try:
    import certifi

    _SSL_CTX = ssl.create_default_context(cafile=certifi.where())
except ImportError:
    _SSL_CTX = ssl.create_default_context()

RPC = "https://rpc.hyperliquid-testnet.xyz/evm"
INFO = "https://api.hyperliquid-testnet.xyz/info"
CHAIN_ID = 998
USDC = "0x2B3370eE501B4a559b57D449569354196457D8Ab"
KEY_FILE = Path.home() / ".hypercore-testnet" / "deployer.json"

import os

from eth_utils import to_checksum_address

def _cs(a):
    return to_checksum_address(a) if a else ""

VAULT = _cs(os.environ.get("VAULT", ""))
ADAPTER = _cs(os.environ.get("ADAPTER", ""))


def rpc(method, params):
    req = urllib.request.Request(
        RPC,
        json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
        {"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=20, context=_SSL_CTX) as r:
        out = json.load(r)
    if "error" in out:
        raise RuntimeError(out["error"])
    return out["result"]


def info(payload):
    req = urllib.request.Request(INFO, json.dumps(payload).encode(), {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20, context=_SSL_CTX) as r:
        return json.load(r)


def load_account():
    data = json.loads(KEY_FILE.read_text())
    if isinstance(data, list):
        data = data[0]
    return Account.from_key(data["private_key"])


def selector(sig):
    from eth_hash.auto import keccak

    return keccak(sig.encode())[:4]


def enc_uint(v, bits=256):
    return int(v).to_bytes(32, "big")


def enc_addr(a):
    return bytes(12) + bytes.fromhex(a[2:])


def enc_bool(b):
    return enc_uint(1 if b else 0)


def call(to, data):
    return rpc("eth_call", [{"to": to, "data": "0x" + data.hex()}, "latest"])


def send(acct, to, data, gas=2_000_000):
    nonce = int(rpc("eth_getTransactionCount", [acct.address, "pending"]), 16)
    gas_price = int(rpc("eth_gasPrice", []), 16)
    tx = {
        "to": to,
        "data": "0x" + data.hex(),
        "gas": gas,
        "gasPrice": max(gas_price, 10**9),
        "nonce": nonce,
        "chainId": CHAIN_ID,
        "value": 0,
    }
    raw = acct.sign_transaction(tx).raw_transaction
    h = rpc("eth_sendRawTransaction", ["0x" + raw.hex()])
    print(f"tx {h} ...", end=" ", flush=True)
    for _ in range(60):
        rcpt = rpc("eth_getTransactionReceipt", [h])
        if rcpt:
            ok = int(rcpt["status"], 16) == 1
            print("OK" if ok else "REVERTED")
            if not ok:
                raise SystemExit(1)
            return h
        time.sleep(1)
    raise SystemExit("timeout waiting for receipt")


def usdc6(amount_str):
    return int(round(float(amount_str) * 1e6))


# ---- order math: scale price/size per HyperCore rules ----


def perp_asset(coin):
    meta = info({"type": "meta"})
    for i, a in enumerate(meta["universe"]):
        if a["name"] == coin:
            return i, int(a["szDecimals"])
    raise SystemExit(f"unknown perp coin {coin}")


def mark_price(coin):
    mids = info({"type": "allMids"})
    return float(mids[coin])


def order_wire(coin, is_buy, size, limit_px, slippage=0.03):
    asset, sz_dec = perp_asset(coin)
    px = limit_px if limit_px else mark_price(coin) * (1 + slippage if is_buy else 1 - slippage)
    # price: max 5 significant figures and max (6 - szDecimals) decimals for perps
    px = float(f"{px:.5g}")
    px = round(px, 6 - sz_dec)
    sz = round(float(size), sz_dec)
    px_u64 = int(round(px * 1e8))
    sz_u64 = int(round(sz * 1e8))
    return asset, px_u64, sz_u64, px, sz


# ---- commands ----


def cmd_status(_):
    bal = int(call(USDC, selector("balanceOf(address)") + enc_addr(VAULT)), 16)
    print(f"vault idle USDC      : {bal/1e6:.2f}")
    bal = int(call(USDC, selector("balanceOf(address)") + enc_addr(ADAPTER)), 16)
    print(f"adapter idle USDC    : {bal/1e6:.2f}")
    ra = int(call(ADAPTER, selector("realAssets()")), 16)
    print(f"adapter realAssets() : {ra/1e6:.2f}")
    ta = int(call(VAULT, selector("totalAssets()")), 16)
    print(f"vault totalAssets()  : {ta/1e6:.2f}")
    it = int(call(ADAPTER, selector("inTransitToCore()")), 16)
    print(f"in transit to Core   : {it/1e6:.2f}")
    print("--- Core (testnet API) ---")
    spot = info({"type": "spotClearinghouseState", "user": ADAPTER})
    print("spot balances:", json.dumps(spot.get("balances", []), indent=1))
    perp = info({"type": "clearinghouseState", "user": ADAPTER})
    print("perp accountValue:", perp.get("marginSummary", {}).get("accountValue"))
    for p in perp.get("assetPositions", []):
        pos = p["position"]
        print(f"position {pos['coin']}: szi={pos['szi']} entry={pos.get('entryPx')} uPnL={pos.get('unrealizedPnl')}")


def cmd_deposit(args):
    acct = load_account()
    amt = usdc6(args.amount)
    send(acct, USDC, selector("approve(address,uint256)") + enc_addr(VAULT) + enc_uint(amt))
    send(acct, VAULT, selector("deposit(uint256,address)") + enc_uint(amt) + enc_addr(acct.address))


def cmd_allocate(args):
    acct = load_account()
    amt = usdc6(args.amount)
    market = b"BTC".ljust(32, b"\x00")
    # allocate(address,bytes,uint256) with data = abi.encode(bytes32("BTC"))
    head = enc_addr(ADAPTER) + enc_uint(0x60) + enc_uint(amt)
    data = enc_uint(32) + market
    send(acct, VAULT, selector("allocate(address,bytes,uint256)") + head + data)


def cmd_bridge(args):
    acct = load_account()
    send(acct, ADAPTER, selector("bridgeToCore(uint256)") + enc_uint(usdc6(args.amount)))
    print("note: Core spot credit lands on a later L1 block; check `status`")


def cmd_usd_class(args):
    acct = load_account()
    ntl = usdc6(args.amount)  # perp USD carries 6 decimals == EVM USDC units
    send(
        acct,
        ADAPTER,
        selector("transferUsdClass(uint64,bool)") + enc_uint(ntl) + enc_bool(args.to_perp),
    )


def cmd_trade(args):
    acct = load_account()
    is_buy = args.side == "buy"
    asset, px_u64, sz_u64, px, sz = order_wire(args.coin, is_buy, args.size, args.limit)
    tif = 2 if args.limit else 3  # GTC for explicit limits, IOC otherwise
    print(f"{args.side} {sz} {args.coin}-PERP @ {px} (asset={asset}, tif={tif})")
    data = (
        selector("placeOrder(uint32,bool,uint64,uint64,bool,uint8,uint128)")
        + enc_uint(asset)
        + enc_bool(is_buy)
        + enc_uint(px_u64)
        + enc_uint(sz_u64)
        + enc_bool(args.reduce_only)
        + enc_uint(tif)
        + enc_uint(int(time.time()))  # cloid
    )
    send(acct, ADAPTER, data)
    print("note: fill is async; check `status` / userFills in a few seconds")


def cmd_bridge_out(args):
    acct = load_account()
    send(acct, ADAPTER, selector("bridgeToEvm(uint256)") + enc_uint(usdc6(args.amount)))
    print("note: EVM credit lands on a later L1 block; check `status`")


def cmd_deallocate(args):
    acct = load_account()
    amt = usdc6(args.amount)
    market = b"BTC".ljust(32, b"\x00")
    head = enc_addr(ADAPTER) + enc_uint(0x60) + enc_uint(amt)
    data = enc_uint(32) + market
    send(acct, VAULT, selector("deallocate(address,bytes,uint256)") + head + data)


def cmd_withdraw(args):
    acct = load_account()
    amt = usdc6(args.amount)
    send(
        acct,
        VAULT,
        selector("withdraw(uint256,address,address)")
        + enc_uint(amt)
        + enc_addr(acct.address)
        + enc_addr(acct.address),
    )


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    for name in ("deposit", "allocate", "bridge", "bridge-out", "deallocate", "withdraw"):
        sp = sub.add_parser(name)
        sp.add_argument("amount", help="USDC amount, human units")
    sp = sub.add_parser("usd-class")
    sp.add_argument("amount")
    g = sp.add_mutually_exclusive_group(required=True)
    g.add_argument("--to-perp", action="store_true")
    g.add_argument("--to-spot", dest="to_perp", action="store_false")
    sp = sub.add_parser("trade")
    sp.add_argument("coin")
    sp.add_argument("side", choices=["buy", "sell"])
    sp.add_argument("size", help="base size, human units")
    sp.add_argument("--limit", type=float, default=None, help="limit price (default: IOC at mark +/- 3%%)")
    sp.add_argument("--reduce-only", action="store_true")
    args = p.parse_args()

    if args.cmd != "status" and not (VAULT and ADAPTER):
        raise SystemExit("set VAULT and ADAPTER env vars (printed by DeployTestnet.s.sol)")

    {
        "status": cmd_status,
        "deposit": cmd_deposit,
        "allocate": cmd_allocate,
        "bridge": cmd_bridge,
        "usd-class": cmd_usd_class,
        "trade": cmd_trade,
        "bridge-out": cmd_bridge_out,
        "deallocate": cmd_deallocate,
        "withdraw": cmd_withdraw,
    }[args.cmd](args)


if __name__ == "__main__":
    main()
