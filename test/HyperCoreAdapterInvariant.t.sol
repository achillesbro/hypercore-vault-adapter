// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {HyperCoreAdapter} from "../src/HyperCoreAdapter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockVaultV2} from "./mocks/MockVaultV2.sol";
import {MockCoreWriter} from "./mocks/MockCoreWriter.sol";
import {MockAccountMargin, MockSpotBalance, MockL1Block, MockCoreUserExists, MockBbo} from "./mocks/MockPrecompiles.sol";

/// @dev Drives the adapter through random funding sequences while playing HyperCore's role:
///      it mirrors every bridge and credits the mock spot balance exactly when the entry ages
///      out of the settle window (the settlement model the add-back design assumes — the
///      deviation from that model is pinned separately by the characterization test in
///      HyperCoreAdapterFuzz.t.sol). No trading, no gains/losses: every operation only MOVES
///      value, so NAV must be conserved exactly.
contract FundingHandler is StdUtils {
    MockERC20 immutable usdt0;
    MockVaultV2 immutable vault;
    HyperCoreAdapter immutable adapter;
    MockSpotBalance immutable spotMock;
    MockL1Block immutable l1Mock;
    uint64 immutable transitToken;
    uint64 immutable window;

    struct Pending {
        uint128 amount;
        uint64 initBlock;
    }

    Pending[] public mirror; // bridges not yet credited to Core spot
    uint256 public mirrorHead;
    uint64 public l1Now;
    uint256 public coreSpotEvm; // modeled Core spot balance, EVM units

    constructor(
        MockERC20 _usdt0,
        MockVaultV2 _vault,
        HyperCoreAdapter _adapter,
        MockSpotBalance _spotMock,
        MockL1Block _l1Mock,
        uint64 _transitToken,
        uint64 _window,
        uint64 _startBlock
    ) {
        usdt0 = _usdt0;
        vault = _vault;
        adapter = _adapter;
        spotMock = _spotMock;
        l1Mock = _l1Mock;
        transitToken = _transitToken;
        window = _window;
        l1Now = _startBlock;
    }

    function allocate(uint256 amount) external {
        uint256 available = usdt0.balanceOf(address(vault));
        if (available < 1) return;
        amount = bound(amount, 1, available);
        vault.allocate(address(adapter), abi.encode(bytes32("BTC")), amount);
    }

    function deallocate(uint256 amount) external {
        uint256 idle = usdt0.balanceOf(address(adapter));
        if (idle < 1) return;
        amount = bound(amount, 1, idle);
        vault.deallocate(address(adapter), abi.encode(bytes32("BTC")), amount);
    }

    function bridgeToCore(uint256 amount) external {
        uint256 idle = usdt0.balanceOf(address(adapter));
        if (idle < 1) return;
        amount = bound(amount, 1, idle);
        adapter.bridgeToCore(amount);
        mirror.push(Pending(uint128(amount), l1Now));
    }

    function bridgeToEvm(uint256 amount) external {
        if (coreSpotEvm < 1) return;
        amount = bound(amount, 1, coreSpotEvm);
        adapter.bridgeToEvm(amount);
        // Model settlement of the exit in the same step: Core spot drops, EVM idle rises.
        // (The sum is invariant at every intermediate point too — bridgeToEvm's natspec.)
        coreSpotEvm -= amount;
        spotMock.set(transitToken, uint64(coreSpotEvm * 100), 0, 0);
        usdt0.mint(address(adapter), amount);
    }

    /// @dev Advance HyperCore time; credit every bridge whose window just elapsed — the exact
    ///      block the adapter stops adding it back, so value never vanishes nor doubles.
    function advanceL1(uint256 blocks_) external {
        l1Now += uint64(bound(blocks_, 1, 12));
        l1Mock.set(l1Now);
        uint256 h = mirrorHead;
        while (h < mirror.length && l1Now - mirror[h].initBlock > window) {
            coreSpotEvm += mirror[h].amount;
            h++;
        }
        mirrorHead = h;
        spotMock.set(transitToken, uint64(coreSpotEvm * 100), 0, 0);
    }

    function prune(uint256) external {
        adapter.pruneSettled();
    }
}

/// @title Session D: invariant tests — funding operations are NAV-invariant.
/// @notice The adapter's core accounting claim: allocate / deallocate / bridgeToCore /
///         bridgeToEvm / settlement / pruning only MOVE value between observable places
///         (vault, idle, in-transit, Core spot). Under any interleaving, realAssets() must
///         equal net deposits exactly — a bridge is never read as a loss, settlement is never
///         read as a gain, and pruning is pure bookkeeping.
contract HyperCoreAdapterInvariantTest is Test {
    MockERC20 usdt0;
    MockVaultV2 vault;
    HyperCoreAdapter adapter;
    FundingHandler handler;

    address curator = address(0xC0);

    uint64 constant TRANSIT_TOKEN = 268;
    int8 constant TRANSIT_EXTRA = -2;
    uint64 constant SETTLE_WINDOW = 5;
    uint64 constant START_BLOCK = 100;
    address constant TRANSIT_SYS = address(uint160(0x2000000000000000000000000000000000000000) + 268);

    address constant CORE_WRITER = 0x3333333333333333333333333333333333333333;
    address constant SPOT_BALANCE = address(uint160(0x0801));
    address constant L1_BLOCK = address(uint160(0x0809));
    address constant ACCOUNT_MARGIN = address(uint160(0x080f));
    address constant CORE_USER_EXISTS = address(uint160(0x0810));
    address constant BBO = address(uint160(0x080e));

    function setUp() public {
        usdt0 = new MockERC20("USDT0", "USDT0", 6);
        vault = new MockVaultV2(address(usdt0), curator);
        adapter = new HyperCoreAdapter(
            address(vault), TRANSIT_TOKEN, TRANSIT_SYS, TRANSIT_EXTRA, 0, SETTLE_WINDOW,
            10166, 1e6, false
        );

        vm.etch(CORE_WRITER, address(new MockCoreWriter()).code);
        vm.etch(ACCOUNT_MARGIN, address(new MockAccountMargin()).code);
        vm.etch(SPOT_BALANCE, address(new MockSpotBalance()).code);
        vm.etch(L1_BLOCK, address(new MockL1Block()).code);
        vm.etch(CORE_USER_EXISTS, address(new MockCoreUserExists()).code);
        vm.etch(BBO, address(new MockBbo()).code);
        MockBbo(BBO).set(1e6, 1e6);
        MockL1Block(L1_BLOCK).set(START_BLOCK);
        MockCoreUserExists(CORE_USER_EXISTS).set(true);

        usdt0.mint(address(vault), 1_000_000e6);

        handler = new FundingHandler(
            usdt0, vault, adapter, MockSpotBalance(SPOT_BALANCE), MockL1Block(L1_BLOCK),
            TRANSIT_TOKEN, SETTLE_WINDOW, START_BLOCK
        );
        vault.setAllocator(address(handler), true);

        targetContract(address(handler));
    }

    /// @dev THE accounting invariant: with zero trading pnl, NAV == net deposits, always —
    ///      across bridges in flight, partial settlements, exits and prunes in any order.
    function invariant_fundingOpsConserveNav() public view {
        assertEq(adapter.realAssets(), adapter.netDeposited());
    }

    /// @dev netDeposited must itself mirror the vault's view of what it entrusted.
    function invariant_netDepositedMatchesVaultFlows() public view {
        assertEq(
            adapter.netDeposited(),
            1_000_000e6 - usdt0.balanceOf(address(vault))
        );
    }

    function invariant_pendingHeadNeverPassesLength() public view {
        assertLe(adapter.pendingHead(), adapter.pendingToCoreLength());
    }

    /// @dev The add-back can never exceed what the vault has entrusted (no fabricated value).
    function invariant_inTransitBounded() public view {
        assertLe(adapter.inTransitToCore(), adapter.netDeposited());
    }
}
