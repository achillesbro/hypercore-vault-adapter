// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {HyperCoreAdapter} from "../src/HyperCoreAdapter.sol";
import {HyperCoreActions} from "../src/libraries/HyperCoreActions.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockWrappedNative} from "./mocks/MockWrappedNative.sol";
import {MockVaultV2} from "./mocks/MockVaultV2.sol";
import {MockCoreWriter} from "./mocks/MockCoreWriter.sol";
import {MockAccountMargin, MockSpotBalance, MockL1Block, MockCoreUserExists, MockBbo} from "./mocks/MockPrecompiles.sol";

contract HyperCoreAdapterTest is Test {
    MockERC20 usdt0; // the underlying: a HIP-1 stable with a linked ERC20 (USDT0-style)
    MockVaultV2 vault;
    HyperCoreAdapter adapter;

    address allocator = address(0xA11);
    address curator = address(0xC0);
    address stranger = address(0xBAD);

    uint64 constant TRANSIT_TOKEN = 268; // example Core token index for the underlying
    int8 constant TRANSIT_EXTRA = -2; // evm = wei * 10^-2  => wei = evm * 100
    uint64 constant USDC_TOKEN = 0;
    uint32 constant PERP_DEX = 0;
    uint64 constant SETTLE_WINDOW = 5; // L1 blocks
    address constant TRANSIT_SYS = address(uint160(0x2000000000000000000000000000000000000000) + 268);

    address constant CORE_WRITER = 0x3333333333333333333333333333333333333333;
    address constant SPOT_BALANCE = address(uint160(0x0801));
    address constant L1_BLOCK = address(uint160(0x0809));
    address constant ACCOUNT_MARGIN = address(uint160(0x080f));
    address constant CORE_USER_EXISTS = address(uint160(0x0810));
    address constant BBO = address(uint160(0x080e));

    uint32 constant SPOT_ASSET = 10166; // underlying/USDC pair asset id
    uint256 constant USD_SCALE = 1e6; // 6-dec underlying, pxDivisor 1e6

    function setUp() public {
        usdt0 = new MockERC20("USDT0", "USDT0", 6);
        vault = new MockVaultV2(address(usdt0), curator);
        adapter = new HyperCoreAdapter(
            address(vault), TRANSIT_TOKEN, TRANSIT_SYS, TRANSIT_EXTRA, PERP_DEX, SETTLE_WINDOW,
            SPOT_ASSET, USD_SCALE, false
        );
        vault.setAllocator(allocator, true);

        // Install the HyperCore system contract + precompiles at their canonical addresses.
        vm.etch(CORE_WRITER, address(new MockCoreWriter()).code);
        vm.etch(ACCOUNT_MARGIN, address(new MockAccountMargin()).code);
        vm.etch(SPOT_BALANCE, address(new MockSpotBalance()).code);
        vm.etch(L1_BLOCK, address(new MockL1Block()).code);
        vm.etch(CORE_USER_EXISTS, address(new MockCoreUserExists()).code);
        vm.etch(BBO, address(new MockBbo()).code);
        MockBbo(BBO).set(1e6, 1e6); // underlying/USDC at exactly 1.0 => USD counts 1:1
        _setL1Block(100);
        MockCoreUserExists(CORE_USER_EXISTS).set(true); // adapter Core account exists by default

        usdt0.mint(address(vault), 1_000_000e6);
    }

    /* helpers */

    function _setL1Block(uint64 n) internal {
        MockL1Block(L1_BLOCK).set(n);
    }

    function _setPerpEquity(uint256 evmUsdc) internal {
        MockAccountMargin(ACCOUNT_MARGIN).set(int64(int256(evmUsdc)), 0, 0, 0);
    }

    function _setTransitSpot(uint256 evmAmount) internal {
        MockSpotBalance(SPOT_BALANCE).set(TRANSIT_TOKEN, uint64(evmAmount * 100), 0, 0);
    }

    function _setUsdcSpot(uint256 evmAmount) internal {
        MockSpotBalance(SPOT_BALANCE).set(USDC_TOKEN, uint64(evmAmount * 100), 0, 0);
    }

    function _allocate(uint256 amount) internal {
        vm.prank(allocator);
        vault.allocate(address(adapter), abi.encode(bytes32("BTC")), amount);
    }

    /* ----------------------------- Funding & valuation basics ---------------------- */

    function test_allocate_pushesIdleAndReportsIds() public {
        vm.prank(allocator);
        (bytes32[] memory ids, int256 change) =
            vault.allocate(address(adapter), abi.encode(bytes32("BTC")), 100_000e6);

        assertEq(usdt0.balanceOf(address(adapter)), 100_000e6);
        assertEq(change, int256(100_000e6));
        assertEq(ids.length, 3);
        assertEq(adapter.netDeposited(), 100_000e6);
        assertEq(adapter.realAssets(), 100_000e6);
    }

    function test_realAssets_sumsAllComponents() public {
        _allocate(100_000e6);
        _setPerpEquity(50_000e6); // Core perp equity (USDC, 1:1)
        _setUsdcSpot(10_000e6); // post-swap Core USDC (1:1)
        _setTransitSpot(20_000e6); // Core-side underlying not yet swapped

        // 100k idle + 50k perp + 10k Core USDC + 20k Core transit
        assertEq(adapter.realAssets(), 180_000e6);
    }

    function test_deallocate_returnsIdleToVault() public {
        _allocate(100_000e6);

        vm.prank(allocator);
        vault.deallocate(address(adapter), abi.encode(bytes32("BTC")), 40_000e6);

        assertEq(usdt0.balanceOf(address(adapter)), 60_000e6);
        assertEq(usdt0.balanceOf(address(vault)), 1_000_000e6 - 60_000e6);
        assertEq(adapter.netDeposited(), 60_000e6);
    }

    function test_deallocate_revertsWithoutIdle() public {
        vm.prank(allocator);
        vm.expectRevert(HyperCoreAdapter.InsufficientIdle.selector);
        vault.deallocate(address(adapter), abi.encode(bytes32("BTC")), 1e6);
    }

    /* ----------------------------- Bridging (transit-asset path) ------------------- */

    function test_bridgeToCore_transfersToSystemAddress() public {
        _allocate(100_000e6);

        vm.prank(allocator);
        adapter.bridgeToCore(100_000e6);

        // The generic HIP-1 mechanism: plain ERC20 transfer to the token's system address.
        assertEq(usdt0.balanceOf(TRANSIT_SYS), 100_000e6);
        assertEq(usdt0.balanceOf(address(adapter)), 0);
    }

    function test_bridgeToCore_revertsIfCoreAccountMissing() public {
        _allocate(100_000e6);
        MockCoreUserExists(CORE_USER_EXISTS).set(false); // funds would land in evmEscrows

        vm.prank(allocator);
        vm.expectRevert(HyperCoreAdapter.CoreAccountMissing.selector);
        adapter.bridgeToCore(100_000e6);
    }

    function test_bridgeToCore_inTransitPreservesValueDuringWindow() public {
        _allocate(100_000e6);

        vm.prank(allocator);
        adapter.bridgeToCore(100_000e6);

        assertEq(usdt0.balanceOf(address(adapter)), 0); // idle drained
        assertEq(adapter.inTransitToCore(), 100_000e6);
        // Without the add-back this would read as a total loss; instead it holds.
        assertEq(adapter.realAssets(), 100_000e6);

        _setL1Block(100 + SETTLE_WINDOW);
        assertEq(adapter.realAssets(), 100_000e6);
    }

    function test_bridgeToCore_addBackExpiresOnceSettled() public {
        _allocate(100_000e6);
        vm.prank(allocator);
        adapter.bridgeToCore(100_000e6); // initL1Block = 100

        // Past the window: settlement guaranteed, Core spot now reflects the transit balance.
        _setL1Block(100 + SETTLE_WINDOW + 1);
        _setTransitSpot(100_000e6);

        assertEq(adapter.inTransitToCore(), 0); // add-back dropped (no double count)
        assertEq(adapter.realAssets(), 100_000e6);
    }

    function test_bridgeToEvm_encodesSpotSendOfTransitToken() public {
        _allocate(100_000e6);
        vm.prank(allocator);
        adapter.bridgeToCore(100_000e6);
        _setL1Block(100 + SETTLE_WINDOW + 1);
        _setTransitSpot(100_000e6);
        assertEq(adapter.realAssets(), 100_000e6);

        vm.prank(allocator);
        adapter.bridgeToEvm(50_000e6); // queued; Core spot still shows funds until settlement
        assertEq(adapter.realAssets(), 100_000e6); // sum invariant — no phantom add-back

        bytes memory a = MockCoreWriter(CORE_WRITER).lastAction();
        assertEq(uint8(a[0]), 1);
        assertEq(uint8(a[3]), 6); // spotSend — the reference-adapter-proven exit path
        // payload = abi.encode(address to, uint64 token, uint64 amountWei)
        (address to, uint64 token, uint64 amountWei) = _decodeSpotSend(a);
        assertEq(to, TRANSIT_SYS);
        assertEq(token, TRANSIT_TOKEN);
        assertEq(amountWei, uint64(50_000e6 * 100)); // wei = evm * 100 (extra = -2)
    }

    function _decodeSpotSend(bytes memory a) internal pure returns (address, uint64, uint64) {
        // strip 4 header bytes
        bytes memory payload = new bytes(a.length - 4);
        for (uint256 i = 4; i < a.length; i++) payload[i - 4] = a[i];
        return abi.decode(payload, (address, uint64, uint64));
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

    function test_bridgeToCore_onlyAllocator() public {
        vm.prank(stranger);
        vm.expectRevert(HyperCoreAdapter.NotAllocator.selector);
        adapter.bridgeToCore(1e6);
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

    /// @dev Mirrors the live-testnet observation (2026-07): the same account value partitions
    ///      differently across the spotBalance/accountMarginSummary precompiles depending on
    ///      the Hyperliquid abstraction mode, but the SUM is identical — realAssets() is
    ///      mode-invariant with no code change.
    function test_realAssets_abstractionModeInvariant() public {
        _allocate(0); // no idle; pure Core-side valuation

        // Standard/split mode: all collateral + uPnL reported in perp accountValue, spot 0.
        _setUsdcSpot(0);
        _setPerpEquity(7_166227);
        uint256 standardMode = adapter.realAssets();

        // Unified mode: spot returns the free balance, accountValue returns held margin + uPnL.
        _setUsdcSpot(5_920027);
        _setPerpEquity(1_246200);
        uint256 unifiedMode = adapter.realAssets();

        assertEq(standardMode, 7_166227);
        assertEq(unifiedMode, 7_166227);
        assertEq(standardMode, unifiedMode);
    }

    /* ----------------------------- API / agent wallet ------------------------------ */

    address agent = address(0xA9E27);

    function test_approveApiWallet_encodesAction9AndStores() public {
        vm.prank(allocator);
        adapter.approveApiWallet(agent, "strategy-1");

        bytes memory a = MockCoreWriter(CORE_WRITER).lastAction();
        assertEq(uint8(a[0]), 1); // version
        assertEq(uint8(a[3]), 9); // == ACTION_ADD_API_WALLET
        address decoded;
        assembly {
            decoded := mload(add(a, 36))
        }
        assertEq(decoded, agent);
        assertEq(adapter.apiWallet(), agent);
        assertEq(adapter.apiWalletName(), "strategy-1");
    }

    function test_approveApiWallet_onlyAllocator() public {
        vm.prank(stranger);
        vm.expectRevert(HyperCoreAdapter.NotAllocator.selector);
        adapter.approveApiWallet(agent, "x");
    }

    function test_revokeApiWallet_byAllocator_clearsAndEncodesZero() public {
        vm.prank(allocator);
        adapter.approveApiWallet(agent, "s");
        vm.prank(allocator);
        adapter.revokeApiWallet("s");

        assertEq(adapter.apiWallet(), address(0));
        bytes memory a = MockCoreWriter(CORE_WRITER).lastAction();
        assertEq(uint8(a[3]), 9);
        address decoded;
        assembly {
            decoded := mload(add(a, 36))
        }
        assertEq(decoded, address(0)); // zero address = deregister
    }

    function test_revokeApiWallet_byCurator_killSwitch() public {
        vm.prank(allocator);
        adapter.approveApiWallet(agent, "s");
        vm.prank(curator); // curator can revoke even though it can't approve
        adapter.revokeApiWallet("s");
        assertEq(adapter.apiWallet(), address(0));
    }

    function test_revokeApiWallet_rejectsStranger() public {
        vm.prank(stranger);
        vm.expectRevert(HyperCoreAdapter.NotAllocator.selector);
        adapter.revokeApiWallet("s");
    }

    /* ----------------------------- Priced valuation -------------------------------- */

    function test_realAssets_pricesUsdViaBboAsk() public {
        // USDC-side value must be converted at the book ask (conservative), not 1:1.
        _setPerpEquity(100e6); // $100 of perp equity
        MockBbo(BBO).set(990000, 1_010000); // underlying trading at 0.99 / 1.01 vs USDC

        // $100 * 1e6 / 1.01e6 = 99.0099 underlying units
        assertEq(adapter.realAssets(), uint256(100e6) * 1e6 / 1_010000);
    }

    function test_realAssets_revertsOnEmptyBook() public {
        _setPerpEquity(100e6);
        MockBbo(BBO).set(0, 0); // no ask: fail closed rather than misprice
        vm.expectRevert(bytes("no ask"));
        adapter.realAssets();
    }

    /* ----------------------------- Native (WHYPE) underlying ----------------------- */

    function test_bridgeToCore_nativeUnwrapsAndSendsValue() public {
        MockWrappedNative whype = new MockWrappedNative();
        vm.deal(address(whype), 100 ether); // backing for withdrawals
        MockVaultV2 hypeVault = new MockVaultV2(address(whype), curator);
        address hypeSystem = 0x2222222222222222222222222222222222222222;
        HyperCoreAdapter hypeAdapter = new HyperCoreAdapter(
            address(hypeVault), 150, hypeSystem, 10, PERP_DEX, SETTLE_WINDOW, 10107, 1e18, true
        );
        hypeVault.setAllocator(allocator, true);
        whype.mint(address(hypeVault), 10 ether);
        vm.prank(allocator);
        hypeVault.allocate(address(hypeAdapter), abi.encode(bytes32("HYPE")), 10 ether);

        vm.prank(allocator);
        hypeAdapter.bridgeToCore(10 ether);

        // WHYPE unwrapped, native value sent to the HYPE system address.
        assertEq(whype.balanceOf(address(hypeAdapter)), 0);
        assertEq(hypeSystem.balance, 10 ether);
        assertEq(hypeAdapter.inTransitToCore(), 10 ether);
        assertEq(hypeAdapter.realAssets(), 10 ether); // add-back holds NAV
    }

    function test_wrapNative_countsArrivalsEitherWay() public {
        MockWrappedNative whype = new MockWrappedNative();
        MockVaultV2 hypeVault = new MockVaultV2(address(whype), curator);
        HyperCoreAdapter hypeAdapter = new HyperCoreAdapter(
            address(hypeVault), 150, 0x2222222222222222222222222222222222222222, 10,
            PERP_DEX, SETTLE_WINDOW, 10107, 1e18, true
        );
        // Core->EVM arrival lands as native: counted pre-wrap and post-wrap identically.
        vm.deal(address(hypeAdapter), 3 ether);
        assertEq(hypeAdapter.realAssets(), 3 ether);
        hypeAdapter.wrapNative();
        assertEq(address(hypeAdapter).balance, 0);
        assertEq(whype.balanceOf(address(hypeAdapter)), 3 ether);
        assertEq(hypeAdapter.realAssets(), 3 ether);
    }
}
