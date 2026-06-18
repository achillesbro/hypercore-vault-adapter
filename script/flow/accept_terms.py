#!/usr/bin/env python3
"""Accept Hyperliquid testnet Terms of Use for a raw key, off-wallet.

Browser wallets (Rabby/MetaMask) often refuse Hyperliquid's signing format — the EIP-712
domain pins chainId=1 and verifyingContract=0x0 regardless of the connected network. Since
our deployer/agent are raw keys, we sign the AcceptTerms struct directly and submit it.

Endpoint + shape reverse-engineered from the testnet app bundle:
  POST /info  { type:"acceptTerms2", user, time, signature:{r,s,v}, signatureChainId:"0x1" }
The signed EIP-712 struct is Hyperliquid:AcceptTerms { hyperliquidChain, time }.

  python3 accept_terms.py deployer
  python3 accept_terms.py agent
"""

import json
import ssl
import sys
import time
import urllib.request
from pathlib import Path

from eth_account import Account
from eth_account.messages import encode_typed_data

try:
    import certifi

    CTX = ssl.create_default_context(cafile=certifi.where())
except ImportError:
    CTX = ssl.create_default_context()

INFO = "https://api.hyperliquid-testnet.xyz/info"


def load(name):
    d = json.loads((Path.home() / ".hypercore-testnet" / f"{name}.json").read_text())
    return (d[0] if isinstance(d, list) else d)["private_key"]


def accept(pk):
    acct = Account.from_key(pk)
    t = int(time.time() * 1000)
    domain = {
        "name": "HyperliquidSignTransaction",
        "version": "1",
        "chainId": 1,
        "verifyingContract": "0x0000000000000000000000000000000000000000",
    }
    types = {
        "Hyperliquid:AcceptTerms": [
            {"name": "hyperliquidChain", "type": "string"},
            {"name": "time", "type": "uint64"},
        ]
    }
    sig = acct.sign_message(
        encode_typed_data(domain_data=domain, message_types=types, message_data={"hyperliquidChain": "Testnet", "time": t})
    )
    body = {
        "type": "acceptTerms2",
        "user": acct.address.lower(),
        "time": t,
        "signature": {"r": "0x%064x" % sig.r, "s": "0x%064x" % sig.s, "v": sig.v},
        "signatureChainId": "0x1",
    }
    req = urllib.request.Request(INFO, json.dumps(body).encode(), {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20, context=CTX) as r:
        ok = r.status == 200
        print(f"{acct.address}: HTTP {r.status} {'ACCEPTED' if ok else r.read().decode()[:160]}")


if __name__ == "__main__":
    accept(load(sys.argv[1] if len(sys.argv) > 1 else "deployer"))
