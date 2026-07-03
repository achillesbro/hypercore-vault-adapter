// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {VaultV2Factory} from "vault-v2/VaultV2Factory.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {IERC20} from "vault-v2/interfaces/IERC20.sol";

import {HyperCoreAdapter} from "../../src/HyperCoreAdapter.sol";
import {HyperCoreActions} from "../../src/libraries/HyperCoreActions.sol";
import {MockAccountMargin, MockSpotBalance, MockL1Block, MockCoreUserExists} from "../mocks/MockPrecompiles.sol";

/// @title HyperEVM mainnet fork test
/// @notice Runs against a fork of HyperEVM (chainid 999) with REAL contracts: the real Morpho
///         VaultV2 (deployed fresh via the real factory), real USDT0 as the underlying,
///         and the real CoreWriter system contract.
///
///         The funding leg is the TRANSIT-ASSET design: bridgeToCore is a plain ERC20
///         transfer of USDT0 to its system address (the generic HIP-1 mechanism, proven live
///         on testnet for contract senders/recipients — see PRODUCTION.md). Core-side indexing
///         cannot execute on any fork; the ERC20 leg and accounting are exercised for real.
///
///         LIMITATION (stated, not hidden): HyperCore read precompiles (0x0800+) are implemented
///         in the node, not as EVM bytecode, so a local fork (revm) cannot execute them. Their
///         ABI shapes were verified against the LIVE node via eth_call; here they are etched
///         with those verified shapes and start at zero — the Core state of a fresh adapter.
///
///         Run: FOUNDRY_PROFILE=fork forge test
contract HyperEVMForkTest is Test {
    // Real HyperEVM mainnet addresses — verified on-chain (see README).
    // Underlying = USDT0 (Core token 268, evm_extra_wei_decimals -2, USDT0/USDC spot pair 166),
    // the HIP-1 stable whose linked-ERC20 system-address path credits contract senders.
    // (Native USDC cannot be used: its ERC20 BLACKLISTS the system address — verified on this
    // fork — so the generic path is token-level blocked and only the contract-recipient-refusing
    // Circle wallet remains for USDC.)
    address constant USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;
    address constant USDT0_SYSTEM = 0x200000000000000000000000000000000000010C;
    address constant CORE_WRITER = 0x3333333333333333333333333333333333333333;

    address constant SPOT_BALANCE_PC = address(uint160(0x0801));
    address constant L1_BLOCK_PC = address(uint160(0x0809));
    address constant ACCOUNT_MARGIN_PC = address(uint160(0x080f));
    address constant CORE_USER_EXISTS_PC = address(uint160(0x0810));

    uint64 constant TRANSIT_TOKEN = 268; // USDT0 Core token index (verified via spotMeta)
    int8 constant TRANSIT_EXTRA = -2; // verified: wei = evm * 100
    uint32 constant PERP_DEX = 0;
    uint64 constant SETTLE_WINDOW = 10;

    address owner = makeAddr("owner");
    address curator = makeAddr("curator");
    address allocator = makeAddr("allocator");
    address depositor = makeAddr("depositor");

    IVaultV2 vault;
    HyperCoreAdapter adapter;

    function setUp() public {
        vm.createSelectFork(vm.envOr("HYPEREVM_RPC_URL", string("https://rpc.hyperliquid.xyz/evm")));
        assertEq(block.chainid, 999, "expected HyperEVM mainnet");

        assertGt(CORE_WRITER.code.length, 0, "CoreWriter missing");
        assertEq(IERC20(USDT0).decimals(), 6, "USDT0 decimals");

        VaultV2Factory factory = new VaultV2Factory();
        vault = IVaultV2(factory.createVaultV2(owner, USDT0, bytes32(0)));

        vm.prank(owner);
        vault.setCurator(curator);

        vm.prank(curator);
        vault.submit(abi.encodeCall(IVaultV2.setIsAllocator, (allocator, true)));
        vault.setIsAllocator(allocator, true);

        adapter = new HyperCoreAdapter(
            address(vault), TRANSIT_TOKEN, USDT0_SYSTEM, TRANSIT_EXTRA, PERP_DEX, SETTLE_WINDOW
        );

        vm.prank(curator);
        vault.submit(abi.encodeCall(IVaultV2.addAdapter, (address(adapter))));
        vault.addAdapter(address(adapter));

        _raiseCaps(abi.encode("this", address(adapter)));
        _raiseCaps(abi.encode("hypercore", address(adapter)));
        _raiseCaps(abi.encode("hypercore/market", address(adapter), bytes32("BTC")));

        // Read precompiles cannot execute in revm — etch the shape-verified mocks.
        vm.etch(ACCOUNT_MARGIN_PC, address(new MockAccountMargin()).code);
        vm.etch(SPOT_BALANCE_PC, address(new MockSpotBalance()).code);
        vm.etch(L1_BLOCK_PC, address(new MockL1Block()).code);
        vm.etch(CORE_USER_EXISTS_PC, address(new MockCoreUserExists()).code);
        MockL1Block(L1_BLOCK_PC).set(1000);
        MockCoreUserExists(CORE_USER_EXISTS_PC).set(true);

        deal(USDT0, depositor, 1_000_000e6);
        vm.prank(depositor);
        IERC20(USDT0).approve(address(vault), type(uint256).max);
    }

    function _raiseCaps(bytes memory idData) internal {
        vm.startPrank(curator);
        vault.submit(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, type(uint128).max)));
        vault.submit(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, 1e18)));
        vm.stopPrank();
        vault.increaseAbsoluteCap(idData, type(uint128).max);
        vault.increaseRelativeCap(idData, 1e18);
    }

    function _depositAndAllocate(uint256 amount) internal {
        vm.prank(depositor);
        vault.deposit(amount, depositor);
        vm.prank(allocator);
        vault.allocate(address(adapter), abi.encode(bytes32("BTC")), amount);
    }

    /* ----------------------------- Real vault integration -------------------------- */

    function test_fork_depositAllocate_realVault() public {
        _depositAndAllocate(100_000e6);

        assertEq(IERC20(USDT0).balanceOf(address(adapter)), 100_000e6);
        assertEq(adapter.realAssets(), 100_000e6);
        assertEq(vault.allocation(adapter.adapterId()), 100_000e6);
        assertEq(vault.totalAssets(), 100_000e6);
    }

    function test_fork_capsEnforced_byRealVault() public {
        vm.prank(depositor);
        vault.deposit(10_000e6, depositor);
        vm.prank(allocator);
        vm.expectRevert(); // ZeroAbsoluteCap — no caps set for this market id
        vault.allocate(address(adapter), abi.encode(bytes32("DOGE")), 10_000e6);
    }

    function test_fork_onlyAllocator_enforcedByRealVault() public {
        vm.prank(depositor);
        vault.deposit(10_000e6, depositor);
        vm.expectRevert(); // Unauthorized
        vm.prank(depositor);
        vault.allocate(address(adapter), abi.encode(bytes32("BTC")), 10_000e6);
    }

    /* ----------------------------- Transit-asset bridge ---------------------------- */

    function test_fork_bridgeToCore_systemAddressTransfer() public {
        _depositAndAllocate(100_000e6);

        uint256 sysBefore = IERC20(USDT0).balanceOf(USDT0_SYSTEM);

        vm.prank(allocator);
        adapter.bridgeToCore(100_000e6);

        // The generic HIP-1 mechanism: ERC20 moved to the token's system address.
        assertEq(IERC20(USDT0).balanceOf(address(adapter)), 0, "idle should be drained");
        assertEq(IERC20(USDT0).balanceOf(USDT0_SYSTEM) - sysBefore, 100_000e6);

        // Valuation: in-transit add-back keeps the vault's NAV whole during the window.
        assertEq(adapter.inTransitToCore(), 100_000e6);
        assertEq(adapter.realAssets(), 100_000e6);
        assertEq(vault.totalAssets(), 100_000e6);
    }

    function test_fork_bridgeToCore_blockedWithoutCoreAccount() public {
        _depositAndAllocate(10_000e6);
        MockCoreUserExists(CORE_USER_EXISTS_PC).set(false);

        vm.prank(allocator);
        vm.expectRevert(HyperCoreAdapter.CoreAccountMissing.selector);
        adapter.bridgeToCore(10_000e6);
    }

    function test_fork_fullCycle_withSimulatedSettlement() public {
        _depositAndAllocate(100_000e6);

        vm.prank(allocator);
        adapter.bridgeToCore(100_000e6);

        // -- Core settles a few L1 blocks later (simulated via the etched precompiles). --
        MockL1Block(L1_BLOCK_PC).set(1000 + SETTLE_WINDOW + 1);
        MockSpotBalance(SPOT_BALANCE_PC).set(TRANSIT_TOKEN, uint64(100_000e6 * 100), 0, 0);

        assertEq(adapter.inTransitToCore(), 0);
        assertEq(adapter.realAssets(), 100_000e6);
        assertEq(vault.totalAssets(), 100_000e6);

        // Move collateral to perp + place an order through the REAL CoreWriter.
        vm.recordLogs();
        vm.startPrank(allocator);
        adapter.transferUsdClass(uint64(100_000e6), true);
        adapter.placeOrder(0, true, 50_000e8, 1e6, false, HyperCoreActions.TIF_GTC, 1);
        vm.stopPrank();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 coreWriterLogs;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == CORE_WRITER) coreWriterLogs++;
        }
        assertEq(coreWriterLogs, 2, "CoreWriter should emit one log per action");

        // Position now lives on perp (simulate: spot -> perp equity).
        MockSpotBalance(SPOT_BALANCE_PC).set(TRANSIT_TOKEN, 0, 0, 0);
        MockAccountMargin(ACCOUNT_MARGIN_PC).set(int64(uint64(100_000e6)), 0, 0, 0);
        assertEq(adapter.realAssets(), 100_000e6);

        // Unwind: equity back to spot, bridge out, funds land on EVM, vault pulls them back.
        MockAccountMargin(ACCOUNT_MARGIN_PC).set(0, 0, 0, 0);
        MockSpotBalance(SPOT_BALANCE_PC).set(TRANSIT_TOKEN, uint64(100_000e6 * 100), 0, 0);
        vm.prank(allocator);
        adapter.bridgeToEvm(100_000e6); // queues spotSend on the real CoreWriter

        MockSpotBalance(SPOT_BALANCE_PC).set(TRANSIT_TOKEN, 0, 0, 0);
        deal(USDT0, address(adapter), 100_000e6);
        assertEq(adapter.realAssets(), 100_000e6);

        vm.prank(allocator);
        vault.deallocate(address(adapter), abi.encode(bytes32("BTC")), 100_000e6);
        assertEq(IERC20(USDT0).balanceOf(address(vault)), 100_000e6);
        assertEq(vault.allocation(adapter.adapterId()), 0);

        vm.prank(depositor);
        vault.withdraw(100_000e6, depositor, depositor);
        assertEq(IERC20(USDT0).balanceOf(depositor), 1_000_000e6);
    }

    function test_fork_lossOnCore_realizedByRealVault() public {
        _depositAndAllocate(100_000e6);
        vm.prank(allocator);
        adapter.bridgeToCore(100_000e6);

        // Settlement, then a 30% trading loss on the perp account.
        MockL1Block(L1_BLOCK_PC).set(1000 + SETTLE_WINDOW + 1);
        MockAccountMargin(ACCOUNT_MARGIN_PC).set(int64(uint64(70_000e6)), 0, 0, 0);

        assertEq(adapter.realAssets(), 70_000e6);
        vault.accrueInterest();
        assertEq(vault.totalAssets(), 70_000e6);
    }
}
