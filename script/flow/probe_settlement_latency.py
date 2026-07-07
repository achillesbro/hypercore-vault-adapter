#!/usr/bin/env python3
"""Live TESTNET probe: settlement latency distribution of the transit funding path.

Measures, in L1 blocks (the unit settleWindowBlocks is denominated in), how long a
HIP-1 system-address bridge takes from EVM tx execution to the Core spot credit
becoming visible to the spotBalance precompile — the exact signal realAssets() reads.

Method, per probe: send a dust amount of native HYPE from the deployer EOA to the HYPE
system address 0x2222...2222 (credits the SENDER's Core spot account, same mechanism the
adapter uses), stamp the L1 block at the tx's EVM block via the l1BlockNumber precompile
(exactly what bridgeToCore stamps), then poll (l1BlockNumber, spotBalance) until the
credit appears. Reports [lower, upper] block bounds per probe (bounded by poll rate).

  python3 script/flow/probe_settlement_latency.py [n_probes]
"""

import json
import sys
import time
from pathlib import Path

import requests
from eth_account import Account

RPC = "https://rpc.hyperliquid-testnet.xyz/evm"
CHAIN_ID = 998
HYPE_SYSTEM = "0x2222222222222222222222222222222222222222"
HYPE_TOKEN = 1105  # testnet Core token index for HYPE (verified via spotClearinghouseState)
PROBE_WEI = 10**15  # 0.001 HYPE per probe
DEPLOYER_KEY = Path.home() / ".hypercore-testnet" / "deployer.json"

L1_BLOCK_PC = "0x0000000000000000000000000000000000000809"
SPOT_PC = "0x0000000000000000000000000000000000000801"


def rpc(method: str, params: list):
    r = requests.post(RPC, json={"jsonrpc": "2.0", "id": 1, "method": method, "params": params},
                      timeout=20).json()
    if "error" in r:
        raise RuntimeError(r["error"])
    return r["result"]


def l1_block(block: str = "latest") -> int:
    return int(rpc("eth_call", [{"to": L1_BLOCK_PC, "data": "0x"}, block]), 16)


def spot_hype(user: str) -> int:
    data = "0x" + user[2:].lower().rjust(64, "0") + hex(HYPE_TOKEN)[2:].rjust(64, "0")
    ret = rpc("eth_call", [{"to": SPOT_PC, "data": data}, "latest"])
    return int(ret[2:66], 16)  # total, wei units


def main() -> None:
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 15
    d = json.loads(DEPLOYER_KEY.read_text())
    if isinstance(d, list):
        d = d[0]
    acct = Account.from_key(d["private_key"])
    print(f"deployer {acct.address}, {n} probes of {PROBE_WEI / 1e18} HYPE each")

    gas_price = int(rpc("eth_gasPrice", []), 16)
    nonce = int(rpc("eth_getTransactionCount", [acct.address, "latest"]), 16)
    results = []

    for i in range(n):
        before = spot_hype(acct.address)
        tx = {"to": HYPE_SYSTEM, "value": PROBE_WEI, "gas": 40_000,
              "gasPrice": gas_price * 2, "nonce": nonce, "chainId": CHAIN_ID}
        raw = acct.sign_transaction(tx).raw_transaction
        txh = rpc("eth_sendRawTransaction", ["0x" + raw.hex()])
        nonce += 1

        # Wait for inclusion, then stamp the L1 block AT the tx's EVM block.
        receipt = None
        for _ in range(120):
            receipt = rpc("eth_getTransactionReceipt", [txh])
            if receipt:
                break
            time.sleep(0.25)
        assert receipt and receipt["status"] == "0x1", f"probe {i}: tx failed {txh}"
        b_send = l1_block(receipt["blockNumber"])

        last_missing = b_send
        b_seen = None
        for _ in range(400):
            cur = l1_block()
            if spot_hype(acct.address) > before:
                b_seen = cur
                break
            last_missing = cur
            time.sleep(0.2)
        assert b_seen is not None, f"probe {i}: credit never appeared (ESCROW? check account)"

        lo, hi = last_missing - b_send, b_seen - b_send
        results.append((lo, hi))
        print(f"probe {i:2d}: L1 blocks [{max(lo, 0)}, {hi}]  "
              f"(sent@{b_send}, missing@{last_missing}, seen@{b_seen})")

    uppers = sorted(hi for _, hi in results)
    print(f"\nupper-bound latency (L1 blocks): min {uppers[0]}  median "
          f"{uppers[len(uppers) // 2]}  max {uppers[-1]}")
    print("NOTE: upper bounds include poll-rate error; the true credit landed between the")
    print("bracketing polls. Size settleWindowBlocks off the MAX upper bound plus margin.")


if __name__ == "__main__":
    main()
