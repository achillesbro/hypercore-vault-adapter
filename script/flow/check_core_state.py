#!/usr/bin/env python3
"""Inspect an address's HyperCore TESTNET state via the public info API.

This is the ground-truth verification tool for the adapter's Core-side account:
spot balances, perp positions, margin summary, open orders, recent fills.

  python3 script/flow/check_core_state.py 0xAdapterAddress
"""

import json
import sys

import urllib.request

API = "https://api.hyperliquid-testnet.xyz/info"


def post(payload: dict) -> dict:
    req = urllib.request.Request(
        API, json.dumps(payload).encode(), {"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)


def main() -> None:
    user = sys.argv[1]
    print("=== spot balances ===")
    print(json.dumps(post({"type": "spotClearinghouseState", "user": user}), indent=2))
    print("=== perp state (positions, margin) ===")
    print(json.dumps(post({"type": "clearinghouseState", "user": user}), indent=2))
    print("=== open orders ===")
    print(json.dumps(post({"type": "openOrders", "user": user}), indent=2))
    print("=== recent fills ===")
    fills = post({"type": "userFills", "user": user})
    print(json.dumps(fills[:5] if isinstance(fills, list) else fills, indent=2))


if __name__ == "__main__":
    main()
