// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

/// @dev Read-only precompiles for querying HyperCore state from HyperEVM.
///      Each is called via staticcall(abi.encode(args)) — NO function selector — and returns
///      the ABI-encoded struct. Values reflect HyperCore state at EVM block construction time,
///      so a just-queued CoreWriter action is NOT yet visible here (see adapter's pending tracking).
library HyperCoreReader {
    address internal constant POSITION = address(uint160(0x0800));
    address internal constant SPOT_BALANCE = address(uint160(0x0801));
    address internal constant MARK_PX = address(uint160(0x0806));
    address internal constant ORACLE_PX = address(uint160(0x0807));
    address internal constant SPOT_PX = address(uint160(0x0808));
    address internal constant L1_BLOCK_NUMBER = address(uint160(0x0809));
    address internal constant ACCOUNT_MARGIN_SUMMARY = address(uint160(0x080f));

    struct SpotBalance {
        uint64 total;
        uint64 hold;
        uint64 entryNtl;
    }

    struct AccountMarginSummary {
        int64 accountValue; // perp account equity, in perp USD units
        uint64 marginUsed;
        uint64 ntlPos;
        int64 rawUsd;
    }

    function spotBalance(address user, uint64 token) internal view returns (SpotBalance memory) {
        (bool ok, bytes memory ret) = SPOT_BALANCE.staticcall(abi.encode(user, token));
        require(ok, "spotBalance precompile");
        return abi.decode(ret, (SpotBalance));
    }

    function accountMarginSummary(uint32 perpDex, address user)
        internal
        view
        returns (AccountMarginSummary memory)
    {
        (bool ok, bytes memory ret) = ACCOUNT_MARGIN_SUMMARY.staticcall(abi.encode(perpDex, user));
        require(ok, "accountMargin precompile");
        return abi.decode(ret, (AccountMarginSummary));
    }

    function spotPx(uint32 index) internal view returns (uint64) {
        (bool ok, bytes memory ret) = SPOT_PX.staticcall(abi.encode(index));
        require(ok, "spotPx precompile");
        return abi.decode(ret, (uint64));
    }

    function markPx(uint32 index) internal view returns (uint64) {
        (bool ok, bytes memory ret) = MARK_PX.staticcall(abi.encode(index));
        require(ok, "markPx precompile");
        return abi.decode(ret, (uint64));
    }

    /// @dev Current HyperCore L1 block number. Used to age in-flight bridges so their value
    ///      add-back self-expires once settlement is guaranteed.
    function l1BlockNumber() internal view returns (uint64) {
        (bool ok, bytes memory ret) = L1_BLOCK_NUMBER.staticcall(abi.encode());
        require(ok, "l1BlockNumber precompile");
        return abi.decode(ret, (uint64));
    }
}
