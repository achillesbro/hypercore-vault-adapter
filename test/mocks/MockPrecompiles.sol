// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

/// @dev HyperCore precompiles are called with raw calldata (no selector) via staticcall.
///      Each mock answers reads through fallback(bytes) and exposes a `set` for tests to configure
///      state. `set` carries a real selector so it never collides with the zero-prefixed read calls.
///      Etch these at the precompile addresses with vm.etch, then call set().

contract MockAccountMargin {
    int64 internal accountValue;
    uint64 internal marginUsed;
    uint64 internal ntlPos;
    int64 internal rawUsd;

    function set(int64 _accountValue, uint64 _marginUsed, uint64 _ntlPos, int64 _rawUsd) external {
        accountValue = _accountValue;
        marginUsed = _marginUsed;
        ntlPos = _ntlPos;
        rawUsd = _rawUsd;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(accountValue, marginUsed, ntlPos, rawUsd);
    }
}

contract MockSpotBalance {
    uint64 internal total;
    uint64 internal hold;
    uint64 internal entryNtl;

    function set(uint64 _total, uint64 _hold, uint64 _entryNtl) external {
        total = _total;
        hold = _hold;
        entryNtl = _entryNtl;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(total, hold, entryNtl);
    }
}
