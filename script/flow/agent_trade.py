#!/usr/bin/env python3
"""Operator UX demo: an agent EOA trades the ADAPTER's HyperCore account via the SDK.

The agent holds no funds and cannot withdraw — it only signs orders that execute against
the master account (the adapter contract) which the adapter authorized on-chain via
approveApiWallet (CoreWriter action 9). This is the "trading UI" for the agent-wallet route:
the operator runs the standard Hyperliquid SDK, pointing account_address at the adapter.

  ADAPTER=0x... python3 agent_trade.py open  BTC 0.0002
  ADAPTER=0x... python3 agent_trade.py close BTC
  ADAPTER=0x... python3 agent_trade.py status
"""

import json
import os
import sys
from pathlib import Path

from eth_account import Account
from hyperliquid.exchange import Exchange
from hyperliquid.info import Info
from hyperliquid.utils import constants

ADAPTER = os.environ["ADAPTER"]
AGENT_KEY = Path.home() / ".hypercore-testnet" / "agent.json"


def agent():
    d = json.loads(AGENT_KEY.read_text())
    if isinstance(d, list):
        d = d[0]
    return Account.from_key(d["private_key"])


def main():
    cmd = sys.argv[1]
    a = agent()
    # account_address = the adapter: the agent signs, but trades the adapter's account.
    ex = Exchange(a, constants.TESTNET_API_URL, account_address=ADAPTER)
    info = Info(constants.TESTNET_API_URL, skip_ws=True)

    if cmd == "status":
        st = info.user_state(ADAPTER)
        print("adapter perp accountValue:", st["marginSummary"]["accountValue"])
        for p in st["assetPositions"]:
            pos = p["position"]
            print(f"  {pos['coin']}: szi={pos['szi']} entry={pos.get('entryPx')} uPnL={pos.get('unrealizedPnl')}")
        return

    if cmd == "open":
        coin, sz = sys.argv[2], float(sys.argv[3])
        r = ex.market_open(coin, True, sz)  # is_buy=True
        print(json.dumps(r, indent=2))
    elif cmd == "close":
        coin = sys.argv[2]
        r = ex.market_close(coin)
        print(json.dumps(r, indent=2))


if __name__ == "__main__":
    main()
