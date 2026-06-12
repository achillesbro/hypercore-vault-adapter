#!/usr/bin/env python3
"""Enable big blocks (30M gas) for the deployer on HyperEVM testnet.

Deploying VaultV2Factory needs > 3M gas, which exceeds the small-block limit.
Big blocks are a HyperCore user flag, toggled with the L1 action `evmUserModify`.
Requires: the account exists on TESTNET Core (i.e. the faucet drip has been claimed).

  pip install hyperliquid-python-sdk eth-account
  python3 script/flow/00_enable_big_blocks.py [--off]
"""

import json
import sys
from pathlib import Path

from eth_account import Account
from hyperliquid.exchange import Exchange
from hyperliquid.utils import constants

KEY_FILE = Path.home() / ".hypercore-testnet" / "deployer.json"


def main() -> None:
    data = json.loads(KEY_FILE.read_text())
    if isinstance(data, list):
        data = data[0]
    wallet = Account.from_key(data["private_key"])
    print(f"deployer: {wallet.address}")

    enable = "--off" not in sys.argv
    ex = Exchange(wallet, constants.TESTNET_API_URL)
    result = ex.use_big_blocks(enable)
    print(json.dumps(result, indent=2))
    if result.get("status") == "ok":
        print(f"big blocks {'ENABLED' if enable else 'DISABLED'}")
        if enable:
            print("note: remember to disable after deployment (--off); big blocks are ~1/min")
    else:
        sys.exit(1)


if __name__ == "__main__":
    main()
