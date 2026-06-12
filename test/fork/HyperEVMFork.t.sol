// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {VaultV2Factory} from "vault-v2/VaultV2Factory.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {IERC20} from "vault-v2/interfaces/IERC20.sol";

import {HyperCoreAdapter} from "../../src/HyperCoreAdapter.sol";
import {HyperCoreActions} from "../../src/libraries/HyperCoreActions.sol";
import {MockAccountMargin, MockSpotBalance, MockL1Block} from "../mocks/MockPrecompiles.sol";

/// @title HyperEVM mainnet fork test
/// @notice Runs against a fork of HyperEVM (chainid 999) with REAL contracts:
///         - the REAL Morpho VaultV2 (deployed fresh on the fork via the real factory),
///         - the REAL USDC ERC20 (0xb88339..., verified symbol/decimals on-chain),
///         - the REAL CoreDepositWallet proxy (0x6B9E..., the contract tokenInfo(0).evmContract
///           points to; deposit(uint256,uint32) selector verified in its implementation),
///         - the REAL CoreWriter system contract (0x3333...).
///
///         LIMITATION (stated, not hidden): HyperCore read precompiles (0x0800+) are implemented
///         in the node, not as EVM bytecode, so a local fork (revm) cannot execute them. Their
///         ABI shapes were verified against the LIVE node via eth_call (see HyperCoreReader docs);
///         here they are etched with those verified shapes and start at zero — which is exactly
///         the Core state of a freshly deployed adapter. Core-side settlement (spot credits,
///         fills) cannot occur on a fork; the etched precompiles simulate it.
///
///         Run: forge test --match-path "test/fork/*" --fork-url https://rpc.hyperliquid.xyz/evm
///         (or FOUNDRY_PROFILE=fork forge test ... ; excluded from plain `forge test`)
contract HyperEVMForkTest is Test {
    // Real HyperEVM mainnet addresses — all verified on-chain (see commit message / README).
    address constant USDC = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;
    address constant CORE_DEPOSIT_WALLET = 0x6B9E773128f453f5c2C60935Ee2DE2CBc5390A24;
    address constant USDC_SYSTEM = 0x2000000000000000000000000000000000000000;
    address constant CORE_WRITER = 0x3333333333333333333333333333333333333333;

    address constant SPOT_BALANCE_PC = address(uint160(0x0801));
    address constant L1_BLOCK_PC = address(uint160(0x0809));
    address constant ACCOUNT_MARGIN_PC = address(uint160(0x080f));

    uint64 constant USDC_TOKEN = 0; // verified: tokenInfo(0).name == "USDC"
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

        // Sanity: the real contracts are present on the fork.
        assertGt(CORE_WRITER.code.length, 0, "CoreWriter missing");
        assertGt(CORE_DEPOSIT_WALLET.code.length, 0, "CoreDepositWallet missing");
        assertEq(IERC20(USDC).decimals(), 6, "USDC decimals");

        // Deploy the REAL vault through the REAL factory.
        VaultV2Factory factory = new VaultV2Factory();
        vault = IVaultV2(factory.createVaultV2(owner, USDC, bytes32(0)));

        vm.prank(owner);
        vault.setCurator(curator);

        // Timelocks are zero on a fresh vault: submit + immediate execution (canonical flow).
        vm.prank(curator);
        vault.submit(abi.encodeCall(IVaultV2.setIsAllocator, (allocator, true)));
        vault.setIsAllocator(allocator, true);

        adapter = new HyperCoreAdapter(
            address(vault), USDC_TOKEN, PERP_DEX, CORE_DEPOSIT_WALLET, USDC_SYSTEM, SETTLE_WINDOW
        );

        vm.prank(curator);
        vault.submit(abi.encodeCall(IVaultV2.addAdapter, (address(adapter))));
        vault.addAdapter(address(adapter));

        // Caps take the idData PREIMAGE; the adapter returns keccak256 of these exact encodings.
        _raiseCaps(abi.encode("this", address(adapter)));
        _raiseCaps(abi.encode("hypercore", address(adapter)));
        _raiseCaps(abi.encode("hypercore/market", address(adapter), bytes32("BTC")));

        // Read precompiles cannot execute in revm (node-level, not bytecode) — etch the
        // shape-verified mocks. Zero state == the true Core state of a fresh adapter.
        vm.etch(ACCOUNT_MARGIN_PC, address(new MockAccountMargin()).code);
        vm.etch(SPOT_BALANCE_PC, address(new MockSpotBalance()).code);
        vm.etch(L1_BLOCK_PC, address(new MockL1Block()).code);
        MockL1Block(L1_BLOCK_PC).set(1000);

        // Fund the depositor with real USDC.
        deal(USDC, depositor, 1_000_000e6);
        vm.prank(depositor);
        IERC20(USDC).approve(address(vault), type(uint256).max);
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

        assertEq(IERC20(USDC).balanceOf(address(adapter)), 100_000e6);
        assertEq(adapter.realAssets(), 100_000e6);
        assertEq(vault.allocation(adapter.adapterId()), 100_000e6);
        // The real vault's totalAssets reflects the adapter through accrueInterest/realAssets.
        assertEq(vault.totalAssets(), 100_000e6);
    }

    function test_fork_capsEnforced_byRealVault() public {
        // An unknown market id has no caps set -> the real vault must refuse the allocation.
        vm.prank(depositor);
        vault.deposit(10_000e6, depositor);
        vm.prank(allocator);
        vm.expectRevert(); // ZeroAbsoluteCap
        vault.allocate(address(adapter), abi.encode(bytes32("DOGE")), 10_000e6);
    }

    function test_fork_onlyAllocator_enforcedByRealVault() public {
        vm.prank(depositor);
        vault.deposit(10_000e6, depositor);
        vm.expectRevert(); // Unauthorized — depositor is not an allocator
        vm.prank(depositor);
        vault.allocate(address(adapter), abi.encode(bytes32("BTC")), 10_000e6);
    }

    /* ----------------------------- Real bridge contract ---------------------------- */

    function test_fork_bridgeToCore_realDepositWallet() public {
        _depositAndAllocate(100_000e6);

        uint256 walletBefore = IERC20(USDC).balanceOf(CORE_DEPOSIT_WALLET);
        uint256 systemBefore = IERC20(USDC).balanceOf(USDC_SYSTEM);

        // This executes the REAL CoreDepositWallet proxy + implementation bytecode.
        vm.prank(allocator);
        adapter.bridgeToCore(100_000e6);

        // EVM side: USDC left the adapter through the real deposit contract.
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0, "idle should be drained");
        uint256 movedToWallet = IERC20(USDC).balanceOf(CORE_DEPOSIT_WALLET) - walletBefore;
        uint256 movedToSystem = IERC20(USDC).balanceOf(USDC_SYSTEM) - systemBefore;
        assertEq(movedToWallet + movedToSystem, 100_000e6, "USDC must sit in the deposit path");

        // Valuation: in-transit add-back keeps the vault's NAV whole during the window.
        assertEq(adapter.inTransitToCore(), 100_000e6);
        assertEq(adapter.realAssets(), 100_000e6);
        assertEq(vault.totalAssets(), 100_000e6);
    }

    function test_fork_fullCycle_withSimulatedSettlement() public {
        _depositAndAllocate(100_000e6);

        vm.prank(allocator);
        adapter.bridgeToCore(100_000e6);

        // -- Core settles a few L1 blocks later (cannot happen on a fork; simulated via the
        //    etched precompiles, with the add-back expiry doing the real work). --
        MockL1Block(L1_BLOCK_PC).set(1000 + SETTLE_WINDOW + 1);
        MockSpotBalance(SPOT_BALANCE_PC).set(uint64(100_000e6 * 100), 0, 0);

        assertEq(adapter.inTransitToCore(), 0);
        assertEq(adapter.realAssets(), 100_000e6);
        assertEq(vault.totalAssets(), 100_000e6);

        // Move collateral to perp + place an order through the REAL CoreWriter.
        vm.recordLogs();
        vm.startPrank(allocator);
        adapter.transferUsdClass(uint64(100_000e6), true);
        adapter.placeOrder(0, true, 50_000e8, 1e6, false, HyperCoreActions.TIF_GTC, 1);
        vm.stopPrank();
        // The real CoreWriter must have accepted both actions (it emits one log per action).
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 coreWriterLogs;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == CORE_WRITER) coreWriterLogs++;
        }
        assertEq(coreWriterLogs, 2, "CoreWriter should emit one log per action");

        // Position now lives on perp (simulate: spot -> perp equity).
        MockSpotBalance(SPOT_BALANCE_PC).set(0, 0, 0);
        MockAccountMargin(ACCOUNT_MARGIN_PC).set(int64(uint64(100_000e6)), 0, 0, 0);
        assertEq(adapter.realAssets(), 100_000e6);

        // Unwind: equity back to spot, bridge out, funds land on EVM, vault pulls them back.
        MockAccountMargin(ACCOUNT_MARGIN_PC).set(0, 0, 0, 0);
        MockSpotBalance(SPOT_BALANCE_PC).set(uint64(100_000e6 * 100), 0, 0);
        vm.prank(allocator);
        adapter.bridgeToEvm(100_000e6); // queues sendAsset on the real CoreWriter

        // Core executes the withdrawal: spot drops, EVM idle rises (simulated).
        MockSpotBalance(SPOT_BALANCE_PC).set(0, 0, 0);
        deal(USDC, address(adapter), 100_000e6);
        assertEq(adapter.realAssets(), 100_000e6);

        vm.prank(allocator);
        vault.deallocate(address(adapter), abi.encode(bytes32("BTC")), 100_000e6);
        assertEq(IERC20(USDC).balanceOf(address(vault)), 100_000e6);
        assertEq(vault.allocation(adapter.adapterId()), 0);

        // Depositor exits through the real vault at par.
        vm.prank(depositor);
        vault.withdraw(100_000e6, depositor, depositor);
        assertEq(IERC20(USDC).balanceOf(depositor), 1_000_000e6);
    }

    function test_fork_lossOnCore_realizedByRealVault() public {
        _depositAndAllocate(100_000e6);
        vm.prank(allocator);
        adapter.bridgeToCore(100_000e6);

        // Settlement, then a 30% trading loss on the perp account.
        MockL1Block(L1_BLOCK_PC).set(1000 + SETTLE_WINDOW + 1);
        MockAccountMargin(ACCOUNT_MARGIN_PC).set(int64(uint64(70_000e6)), 0, 0, 0);

        assertEq(adapter.realAssets(), 70_000e6);
        // The real vault realizes the loss into share price on the next accrual.
        vault.accrueInterest();
        assertEq(vault.totalAssets(), 70_000e6);
    }
}
