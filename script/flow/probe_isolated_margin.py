#!/usr/bin/env python3
"""Live TESTNET probe: does the accountMarginSummary precompile (0x080F) include ISOLATED margin?

Answers the open valuation question (PRODUCTION.md, loss flow / liquidation): the info API
exposes BOTH `marginSummary` (includes isolated margin + isolated uPnL) and
`crossMarginSummary` (cross only) — the docs don't say which one the precompile returns.
If it is cross-only, an isolated position's margin would be INVISIBLE to realAssets().

Method: the approved agent opens a small ISOLATED BTC position on the adapter's Core
account, we read 0x080F + 0x0801 via eth_call between each step and compare against both
API summaries, then close and restore cross leverage.

  ADAPTER=0x5a71... python3 script/flow/probe_isolated_margin.py
"""

import json
import os
import time
from pathlib import Path

import requests
from eth_account import Account
from hyperliquid.exchange import Exchange
from hyperliquid.info import Info
from hyperliquid.utils import constants

ADAPTER = os.environ.get("ADAPTER", "0x5a71C5A4DA2c6B5B32B91ef2b83B2d4aC28bFF8e")
RPC = "https://rpc.hyperliquid-testnet.xyz/evm"
AGENT_KEY = Path.home() / ".hypercore-testnet" / "agent.json"

MARGIN_PC = "0x000000000000000000000000000000000000080F"
SPOT_PC = "0x0000000000000000000000000000000000000801"


def eth_call(to: str, data: str) -> str:
    r = requests.post(
        RPC,
        json={"jsonrpc": "2.0", "id": 1, "method": "eth_call",
              "params": [{"to": to, "data": data}, "latest"]},
        timeout=20,
    ).json()
    return r["result"]


def _i64(word: str) -> int:
    v = int(word, 16)
    return v - (1 << 256) if v >= 1 << 255 else v


def read_margin_precompile(dex: int = 0) -> dict:
    # abi.encode(uint32 dex, address user) — raw calldata, no selector.
    data = "0x" + hex(dex)[2:].rjust(64, "0") + ADAPTER[2:].lower().rjust(64, "0")
    ret = eth_call(MARGIN_PC, data)[2:]
    words = [ret[i:i + 64] for i in range(0, len(ret), 64)]
    return {
        "accountValue": _i64(words[0]) / 1e6,  # perp USD, 6 decimals
        "marginUsed": int(words[1], 16) / 1e6,
        "ntlPos": int(words[2], 16) / 1e6,
        "rawUsd": _i64(words[3]) / 1e6,
    }


def read_spot_usdc_precompile() -> float:
    data = "0x" + ADAPTER[2:].lower().rjust(64, "0") + hex(0)[2:].rjust(64, "0")
    ret = eth_call(SPOT_PC, data)[2:]
    return int(ret[0:64], 16) / 1e8  # USDC wei decimals 8


def snapshot(info: Info, label: str) -> None:
    st = info.user_state(ADAPTER)
    pc = read_margin_precompile()
    spot = read_spot_usdc_precompile()
    print(f"\n=== {label} ===")
    print(f"API  marginSummary.accountValue      = {st['marginSummary']['accountValue']}"
          f"  (totalMarginUsed {st['marginSummary']['totalMarginUsed']},"
          f" ntlPos {st['marginSummary']['totalNtlPos']})")
    print(f"API  crossMarginSummary.accountValue = {st['crossMarginSummary']['accountValue']}"
          f"  (totalMarginUsed {st['crossMarginSummary']['totalMarginUsed']})")
    print(f"PC   0x080F accountValue             = {pc['accountValue']}"
          f"  (marginUsed {pc['marginUsed']}, ntlPos {pc['ntlPos']}, rawUsd {pc['rawUsd']})")
    print(f"PC   0x0801 spot USDC                = {spot}")
    print(f"     realAssets-style sum (spot + accountValue floored) = "
          f"{spot + max(pc['accountValue'], 0.0):.6f}")
    for p in st["assetPositions"]:
        pos = p["position"]
        print(f"     position {pos['coin']}: szi={pos['szi']} leverage={pos['leverage']}"
              f" marginUsed={pos['marginUsed']} uPnL={pos['unrealizedPnl']}")


def main() -> None:
    d = json.loads(AGENT_KEY.read_text())
    if isinstance(d, list):
        d = d[0]
    agent = Account.from_key(d["private_key"])
    ex = Exchange(agent, constants.TESTNET_API_URL, account_address=ADAPTER)
    info = Info(constants.TESTNET_API_URL, skip_ws=True)

    snapshot(info, "baseline (flat)")

    print("\n-> setting BTC leverage 5x ISOLATED")
    print(ex.update_leverage(5, "BTC", is_cross=False))

    print("-> opening 0.0002 BTC long (isolated)")
    r = ex.market_open("BTC", True, 0.0002)
    print(json.dumps(r, indent=2)[:600])
    if r.get("status") != "ok":
        print("OPEN FAILED — if the exchange refuses isolated under unified mode, that is")
        print("itself the answer: isolated positions are unreachable for this account.")
        return

    time.sleep(4)  # let Core state propagate to the EVM view
    snapshot(info, "ISOLATED position open  <-- the probe")

    print("\n-> closing position")
    print(json.dumps(ex.market_close("BTC"), indent=2)[:400])
    print("-> restoring BTC leverage 5x CROSS")
    print(ex.update_leverage(5, "BTC", is_cross=True))

    time.sleep(4)
    snapshot(info, "closed / restored")


if __name__ == "__main__":
    main()
