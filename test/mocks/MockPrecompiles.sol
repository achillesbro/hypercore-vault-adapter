// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

/// @dev HyperCore precompiles are called with raw calldata (no selector) via staticcall.
///      Each mock answers reads through fallback(bytes) and exposes a `set` for tests to configure
///      state. `set` carries a real selector so it never collides with the zero-prefixed read calls.
///      Etch these at the precompile addresses with vm.etch, then call set().

/// @dev Keyed by perp dex: reads decode (uint32 dex, address user) like the real 0x080f.
contract MockAccountMargin {
    struct S {
        int64 accountValue;
        uint64 marginUsed;
        uint64 ntlPos;
        int64 rawUsd;
    }

    mapping(uint32 => S) internal summaries;

    function set(uint32 dex, int64 _accountValue, uint64 _marginUsed, uint64 _ntlPos, int64 _rawUsd) external {
        summaries[dex] = S(_accountValue, _marginUsed, _ntlPos, _rawUsd);
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        (uint32 dex,) = abi.decode(data, (uint32, address));
        S memory s = summaries[dex];
        return abi.encode(s.accountValue, s.marginUsed, s.ntlPos, s.rawUsd);
    }
}

/// @dev Keyed by token index: reads decode (address user, uint64 token) like the real 0x0801.
contract MockSpotBalance {
    struct Bal {
        uint64 total;
        uint64 hold;
        uint64 entryNtl;
    }

    mapping(uint64 => Bal) internal balances;

    function set(uint64 token, uint64 total, uint64 hold, uint64 entryNtl) external {
        balances[token] = Bal(total, hold, entryNtl);
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        (, uint64 token) = abi.decode(data, (address, uint64));
        Bal memory b = balances[token];
        return abi.encode(b.total, b.hold, b.entryNtl);
    }
}

contract MockL1Block {
    uint64 internal blockNumber;

    function set(uint64 _blockNumber) external {
        blockNumber = _blockNumber;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(blockNumber);
    }
}

contract MockBbo {
    uint64 internal bid;
    uint64 internal ask;

    function set(uint64 _bid, uint64 _ask) external {
        bid = _bid;
        ask = _ask;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(bid, ask);
    }
}

contract MockCoreUserExists {
    bool internal exists;

    function set(bool _exists) external {
        exists = _exists;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(exists);
    }
}
