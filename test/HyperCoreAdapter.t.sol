// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {HyperCoreAdapter} from "../src/HyperCoreAdapter.sol";
import {HyperCoreActions} from "../src/libraries/HyperCoreActions.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockVaultV2} from "./mocks/MockVaultV2.sol";
import {MockCoreWriter} from "./mocks/MockCoreWriter.sol";
import {MockAccountMargin, MockSpotBalance} from "./mocks/MockPrecompiles.sol";

interface Vm {
    function etch(address target, bytes calldata code) external;
    function prank(address sender) external;
    function expectRevert(bytes4 selector) external;
}

/// @dev Minimal test base so the scaffold runs without an external forge-std dependency.
contract MiniTest {
    Vm internal constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    function assertEq(uint256 a, uint256 b) internal pure {
        require(a == b, "assertEq(uint) failed");
    }

    function assertEq(int256 a, int256 b) internal pure {
        require(a == b, "assertEq(int) failed");
    }

    function assertTrue(bool c) internal pure {
        require(c, "assertTrue failed");
    }
}

contract HyperCoreAdapterTest is MiniTest {
    MockERC20 usdc;
    MockVaultV2 vault;
    HyperCoreAdapter adapter;

    address allocator = address(0xA11);
    address stranger = address(0xBAD);

    uint64 constant USDC_TOKEN = 0;
    uint32 constant USDC_SPOT = 0;
    uint32 constant PERP_DEX = 0;
    address constant USDC_SYS = address(uint160(0x2000)); // placeholder system address

    address constant CORE_WRITER = 0x3333333333333333333333333333333333333333;
    address constant ACCOUNT_MARGIN = address(uint160(0x080f));
    address constant SPOT_BALANCE = address(uint160(0x0801));

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockVaultV2(address(usdc));
        adapter = new HyperCoreAdapter(address(vault), USDC_TOKEN, USDC_SPOT, PERP_DEX, USDC_SYS);
        vault.setAllocator(allocator, true);

        // Install the HyperCore system contract + precompiles at their canonical addresses.
        vm.etch(CORE_WRITER, address(new MockCoreWriter()).code);
        vm.etch(ACCOUNT_MARGIN, address(new MockAccountMargin()).code);
        vm.etch(SPOT_BALANCE, address(new MockSpotBalance()).code);

        usdc.mint(address(vault), 1_000_000e6);
    }

    function _allocate(uint256 amount) internal returns (bytes32[] memory ids, int256 change) {
        vm.prank(allocator);
        (ids, change) = vault.allocate(address(adapter), abi.encode(bytes32("BTC")), amount);
    }

    function test_allocate_pushesIdleUsdcAndReportsIds() public {
        (bytes32[] memory ids, int256 change) = _allocate(100_000e6);

        assertEq(usdc.balanceOf(address(adapter)), 100_000e6);
        assertEq(change, int256(100_000e6));
        assertEq(ids.length, 3);
        // perp + spot precompiles return 0 here, so realAssets == idle.
        assertEq(adapter.realAssets(), 100_000e6);
    }

    function test_realAssets_sumsIdlePerpAndSpot() public {
        _allocate(100_000e6);

        // Simulate an open perp position worth 105k of equity, and 10k sitting in the spot account.
        MockAccountMargin(ACCOUNT_MARGIN).set(105_000e6, 0, 0, 0);
        MockSpotBalance(SPOT_BALANCE).set(uint64(10_000e6 * 100), 0, 0); // spot wei = evm * 100

        // 100k idle + 105k perp + 10k spot.
        assertEq(adapter.realAssets(), 215_000e6);
    }

    function test_placeOrder_onlyAllocator() public {
        vm.prank(stranger);
        vm.expectRevert(HyperCoreAdapter.NotAllocator.selector);
        adapter.placeOrder(0, true, 1e8, 1e8, false, HyperCoreActions.TIF_IOC, 0);
    }

    function test_placeOrder_encodesVersionedAction() public {
        vm.prank(allocator);
        adapter.placeOrder(0, true, uint64(50_000e8), uint64(1e8), false, HyperCoreActions.TIF_GTC, 0);

        bytes memory a = MockCoreWriter(CORE_WRITER).lastAction();
        assertEq(uint256(uint8(a[0])), 1); // encoding version
        assertEq(uint256(uint8(a[1])), 0); // action id (uint24 big-endian) high byte
        assertEq(uint256(uint8(a[2])), 0);
        assertEq(uint256(uint8(a[3])), 1); // == ACTION_LIMIT_ORDER
        assertEq(MockCoreWriter(CORE_WRITER).actionsCount(), 1);
    }

    function test_deallocate_revertsWithoutIdle() public {
        vm.prank(allocator);
        vm.expectRevert(HyperCoreAdapter.InsufficientIdle.selector);
        vault.deallocate(address(adapter), abi.encode(bytes32("BTC")), 1e6);
    }

    function test_deallocate_returnsIdleToVault() public {
        _allocate(100_000e6);

        vm.prank(allocator);
        vault.deallocate(address(adapter), abi.encode(bytes32("BTC")), 40_000e6);

        assertEq(usdc.balanceOf(address(adapter)), 60_000e6);
        assertEq(usdc.balanceOf(address(vault)), 1_000_000e6 - 60_000e6);
    }

    function test_spotAssetIdOffset() public pure {
        assertEq(uint256(HyperCoreActions.spotAssetId(5)), 10005);
    }
}
