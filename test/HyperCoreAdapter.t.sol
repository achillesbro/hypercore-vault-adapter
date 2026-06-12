// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {HyperCoreAdapter} from "../src/HyperCoreAdapter.sol";
import {HyperCoreActions} from "../src/libraries/HyperCoreActions.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockVaultV2} from "./mocks/MockVaultV2.sol";
import {MockCoreWriter} from "./mocks/MockCoreWriter.sol";
import {MockDepositWallet} from "./mocks/MockDepositWallet.sol";
import {MockAccountMargin, MockSpotBalance, MockL1Block} from "./mocks/MockPrecompiles.sol";

contract HyperCoreAdapterTest is Test {
    MockERC20 usdc;
    MockVaultV2 vault;
    MockDepositWallet depositWallet;
    HyperCoreAdapter adapter;

    address allocator = address(0xA11);
    address curator = address(0xC0);
    address stranger = address(0xBAD);

    uint64 constant USDC_TOKEN = 0;
    uint32 constant PERP_DEX = 0;
    uint64 constant SETTLE_WINDOW = 5; // L1 blocks
    address constant USDC_SYS = 0x2000000000000000000000000000000000000000;

    address constant CORE_WRITER = 0x3333333333333333333333333333333333333333;
    address constant SPOT_BALANCE = address(uint160(0x0801));
    address constant L1_BLOCK = address(uint160(0x0809));
    address constant ACCOUNT_MARGIN = address(uint160(0x080f));

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockVaultV2(address(usdc), curator);
        depositWallet = new MockDepositWallet(address(usdc));
        adapter = new HyperCoreAdapter(
            address(vault), USDC_TOKEN, PERP_DEX, address(depositWallet), USDC_SYS, SETTLE_WINDOW
        );
        vault.setAllocator(allocator, true);

        // Install the HyperCore system contract + precompiles at their canonical addresses.
        vm.etch(CORE_WRITER, address(new MockCoreWriter()).code);
        vm.etch(ACCOUNT_MARGIN, address(new MockAccountMargin()).code);
        vm.etch(SPOT_BALANCE, address(new MockSpotBalance()).code);
        vm.etch(L1_BLOCK, address(new MockL1Block()).code);
        _setL1Block(100);

        usdc.mint(address(vault), 1_000_000e6);
    }

    /* helpers */

    function _setL1Block(uint64 n) internal {
        MockL1Block(L1_BLOCK).set(n);
    }

    function _setPerpEquity(uint256 evmUsdc) internal {
        MockAccountMargin(ACCOUNT_MARGIN).set(int64(int256(evmUsdc)), 0, 0, 0);
    }

    function _setSpotBalance(uint256 evmUsdc) internal {
        MockSpotBalance(SPOT_BALANCE).set(uint64(evmUsdc * 100), 0, 0); // spot wei = evm * 100
    }

    function _allocate(uint256 amount) internal {
        vm.prank(allocator);
        vault.allocate(address(adapter), abi.encode(bytes32("BTC")), amount);
    }

    /* ----------------------------- Funding & valuation basics ---------------------- */

    function test_allocate_pushesIdleUsdcAndReportsIds() public {
        vm.prank(allocator);
        (bytes32[] memory ids, int256 change) =
            vault.allocate(address(adapter), abi.encode(bytes32("BTC")), 100_000e6);

        assertEq(usdc.balanceOf(address(adapter)), 100_000e6);
        assertEq(change, int256(100_000e6));
        assertEq(ids.length, 3);
        assertEq(adapter.netDeposited(), 100_000e6);
        assertEq(adapter.realAssets(), 100_000e6);
    }

    function test_realAssets_sumsIdlePerpAndSpot() public {
        _allocate(100_000e6);
        _setPerpEquity(105_000e6);
        _setSpotBalance(10_000e6);

        assertEq(adapter.realAssets(), 215_000e6); // 100k idle + 105k perp + 10k spot
    }

    function test_deallocate_returnsIdleToVault() public {
        _allocate(100_000e6);

        vm.prank(allocator);
        vault.deallocate(address(adapter), abi.encode(bytes32("BTC")), 40_000e6);

        assertEq(usdc.balanceOf(address(adapter)), 60_000e6);
        assertEq(usdc.balanceOf(address(vault)), 1_000_000e6 - 60_000e6);
        assertEq(adapter.netDeposited(), 60_000e6);
    }

    function test_deallocate_revertsWithoutIdle() public {
        vm.prank(allocator);
        vm.expectRevert(HyperCoreAdapter.InsufficientIdle.selector);
        vault.deallocate(address(adapter), abi.encode(bytes32("BTC")), 1e6);
    }

    /* ----------------------------- In-flight accounting ---------------------------- */

    function test_bridgeToCore_pullsViaDepositWalletWithSpotDex() public {
        _allocate(100_000e6);

        vm.prank(allocator);
        adapter.bridgeToCore(100_000e6);

        assertEq(usdc.balanceOf(address(depositWallet)), 100_000e6);
        assertEq(depositWallet.lastDestinationDex(), type(uint32).max); // SPOT_DEX
    }

    function test_bridgeToCore_inTransitPreservesValueDuringWindow() public {
        _allocate(100_000e6);

        // Bridge moves USDC out of EVM idle synchronously; Core spot not yet credited.
        vm.prank(allocator);
        adapter.bridgeToCore(100_000e6);

        assertEq(usdc.balanceOf(address(adapter)), 0); // idle drained
        assertEq(adapter.inTransitToCore(), 100_000e6);
        // Without the add-back this would read as a total loss; instead it holds.
        assertEq(adapter.realAssets(), 100_000e6);

        // Still within the settle window a few blocks later.
        _setL1Block(100 + SETTLE_WINDOW);
        assertEq(adapter.realAssets(), 100_000e6);
    }

    function test_bridgeToCore_addBackExpiresOnceSettled() public {
        _allocate(100_000e6);
        vm.prank(allocator);
        adapter.bridgeToCore(100_000e6); // initL1Block = 100

        // Past the window: settlement guaranteed, so the Core spot precompile now reflects it.
        _setL1Block(100 + SETTLE_WINDOW + 1);
        _setSpotBalance(100_000e6);

        assertEq(adapter.inTransitToCore(), 0); // add-back dropped (no double count)
        assertEq(adapter.realAssets(), 100_000e6); // value now observed in Core spot
    }

    function test_bridgeToCore_noDoubleCountWhenSpotCreditsEarly() public {
        _allocate(100_000e6);
        vm.prank(allocator);
        adapter.bridgeToCore(100_000e6);

        // If Core credits before the window elapses, the add-back transiently over-counts by at
        // most the bridge size; it resolves exactly once the window passes.
        _setSpotBalance(100_000e6);
        assertEq(adapter.realAssets(), 200_000e6); // bounded transient over-count

        _setL1Block(100 + SETTLE_WINDOW + 1);
        assertEq(adapter.realAssets(), 100_000e6); // exact after the window
    }

    function test_bridgeToEvm_doesNotDoubleCount() public {
        _allocate(100_000e6);
        // Funds already on Core spot; queueing a withdrawal must not change realAssets.
        vm.prank(allocator);
        adapter.bridgeToCore(100_000e6);
        _setL1Block(100 + SETTLE_WINDOW + 1);
        _setSpotBalance(100_000e6);
        assertEq(adapter.realAssets(), 100_000e6);

        vm.prank(allocator);
        adapter.bridgeToEvm(100_000e6); // queued; Core spot still shows funds until settlement
        assertEq(adapter.realAssets(), 100_000e6); // unchanged — no phantom add-back

        // Verify it queued a sendAsset (action 13) to the system address.
        bytes memory a = MockCoreWriter(CORE_WRITER).lastAction();
        assertEq(uint8(a[0]), 1);
        assertEq(uint8(a[3]), 13);
    }

    function test_pruneSettled_advancesHead() public {
        _allocate(300_000e6);
        vm.prank(allocator);
        adapter.bridgeToCore(100_000e6); // block 100
        _setL1Block(101);
        vm.prank(allocator);
        adapter.bridgeToCore(100_000e6); // block 101
        assertEq(adapter.pendingToCoreLength(), 2);

        _setL1Block(101 + SETTLE_WINDOW + 1); // both entries past their window here
        adapter.pruneSettled();
        assertEq(adapter.pendingHead(), 2);
        assertEq(adapter.inTransitToCore(), 0);
    }

    /* ----------------------------- Gain ceiling (defense-in-depth) ----------------- */

    function test_maxGainBps_clampsInflatedRead() public {
        _allocate(100_000e6);
        vm.prank(curator);
        adapter.setMaxGainBps(1000); // allow at most +10% above cost basis

        _setPerpEquity(200_000e6); // mark-price spike

        // observed = 100k idle + 200k perp = 300k, clamped to 100k * 1.10 = 110k.
        assertEq(adapter.realAssets(), 110_000e6);
    }

    function test_maxGainBps_disabledByDefault() public {
        _allocate(100_000e6);
        _setPerpEquity(200_000e6);
        assertEq(adapter.realAssets(), 300_000e6); // no ceiling when bps == 0
    }

    function test_maxGainBps_lossesAlwaysPassThrough() public {
        _allocate(100_000e6);
        vm.prank(curator);
        adapter.setMaxGainBps(1000);

        vm.prank(allocator);
        adapter.bridgeToCore(100_000e6);
        _setL1Block(100 + SETTLE_WINDOW + 1);
        _setPerpEquity(70_000e6); // a loss on Core

        assertEq(adapter.realAssets(), 70_000e6); // loss not clamped
    }

    /* ----------------------------- Access control ---------------------------------- */

    function test_placeOrder_onlyAllocator() public {
        vm.prank(stranger);
        vm.expectRevert(HyperCoreAdapter.NotAllocator.selector);
        adapter.placeOrder(0, true, 1e8, 1e8, false, HyperCoreActions.TIF_IOC, 0);
    }

    function test_config_onlyCurator() public {
        vm.prank(allocator); // an allocator is NOT a curator
        vm.expectRevert(HyperCoreAdapter.NotCurator.selector);
        adapter.setMaxGainBps(500);
    }

    function test_placeOrder_encodesVersionedAction() public {
        vm.prank(allocator);
        adapter.placeOrder(0, true, uint64(50_000e8), uint64(1e8), false, HyperCoreActions.TIF_GTC, 0);

        bytes memory a = MockCoreWriter(CORE_WRITER).lastAction();
        assertEq(uint8(a[0]), 1); // encoding version
        assertEq(uint8(a[1]), 0); // action id (uint24 big-endian) high byte
        assertEq(uint8(a[2]), 0);
        assertEq(uint8(a[3]), 1); // == ACTION_LIMIT_ORDER
        assertEq(MockCoreWriter(CORE_WRITER).actionsCount(), 1);
    }

    function test_spotAssetIdOffset() public pure {
        assertEq(uint256(HyperCoreActions.spotAssetId(5)), 10005);
    }
}
