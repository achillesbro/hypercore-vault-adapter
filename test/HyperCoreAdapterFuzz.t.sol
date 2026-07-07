// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {HyperCoreAdapter} from "../src/HyperCoreAdapter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockVaultV2} from "./mocks/MockVaultV2.sol";
import {MockCoreWriter} from "./mocks/MockCoreWriter.sol";
import {MockAccountMargin, MockSpotBalance, MockL1Block, MockCoreUserExists, MockBbo} from "./mocks/MockPrecompiles.sol";

/// @dev Test-only harness exposing the adapter's internal math and (deliberately bypassing the
///      timelock) direct setters, so fuzz runs don't pay the submit/execute round-trip per case.
contract HyperCoreAdapterHarness is HyperCoreAdapter {
    constructor(
        address _parentVault,
        uint64 _transitCoreToken,
        address _transitSystemAddress,
        int8 _transitEvmExtraWeiDecimals,
        uint32 _perpDex,
        uint64 _settleWindowBlocks,
        uint32 _underlyingSpotAsset,
        uint256 _usdToUnderlyingScale,
        bool _isNativeUnderlying
    )
        HyperCoreAdapter(
            _parentVault,
            _transitCoreToken,
            _transitSystemAddress,
            _transitEvmExtraWeiDecimals,
            _perpDex,
            _settleWindowBlocks,
            _underlyingSpotAsset,
            _usdToUnderlyingScale,
            _isNativeUnderlying
        )
    {}

    function evmToWei(uint256 a) external view returns (uint64) {
        return _evmToWei(a);
    }

    function weiToEvm(uint64 a) external view returns (uint256) {
        return _weiToEvm(a);
    }

    function applyGainCeiling(uint256 observed) external view returns (uint256) {
        return _applyGainCeiling(observed);
    }

    function usdToUnderlying(uint256 usd6) external view returns (uint256) {
        return _usdToUnderlying(usd6);
    }

    function setNetDepositedDirect(uint256 n) external {
        netDeposited = n;
    }

    function setMaxGainBpsDirect(uint16 b) external {
        maxGainBps = b;
    }
}

/// @dev Etched over a precompile address to model a node-level read failure: every call reverts.
contract RevertingPrecompile {
    fallback(bytes calldata) external returns (bytes memory) {
        revert("precompile down");
    }
}

/// @title Session D: fuzz + adversarial tests on accounting and in-flight edges.
/// @notice Three families:
///         1. Fuzzed properties of the pure math (decimal seams, gain ceiling, USD pricing).
///         2. Fuzzed in-flight bridge accounting against an explicit model.
///         3. Adversarial reads: every precompile failing closed, mark/book manipulation
///            bounded by the gain ceiling, negative equity floored — plus a characterization
///            test pinning the KNOWN double-count window (see PRODUCTION.md, settlement
///            window calibration).
contract HyperCoreAdapterFuzzTest is Test {
    MockERC20 usdt0;
    MockVaultV2 vault;
    HyperCoreAdapterHarness adapter;

    address allocator = address(0xA11);
    address curator = address(0xC0);

    uint64 constant TRANSIT_TOKEN = 268;
    int8 constant TRANSIT_EXTRA = -2; // wei = evm * 100
    uint32 constant PERP_DEX = 0;
    uint64 constant SETTLE_WINDOW = 5;
    address constant TRANSIT_SYS = address(uint160(0x2000000000000000000000000000000000000000) + 268);

    address constant CORE_WRITER = 0x3333333333333333333333333333333333333333;
    address constant SPOT_BALANCE = address(uint160(0x0801));
    address constant L1_BLOCK = address(uint160(0x0809));
    address constant ACCOUNT_MARGIN = address(uint160(0x080f));
    address constant CORE_USER_EXISTS = address(uint160(0x0810));
    address constant BBO = address(uint160(0x080e));

    uint32 constant SPOT_ASSET = 10166;
    uint256 constant USD_SCALE = 1e6;
    uint64 constant START_BLOCK = 100;

    function setUp() public {
        usdt0 = new MockERC20("USDT0", "USDT0", 6);
        vault = new MockVaultV2(address(usdt0), curator);
        adapter = new HyperCoreAdapterHarness(
            address(vault), TRANSIT_TOKEN, TRANSIT_SYS, TRANSIT_EXTRA, PERP_DEX, SETTLE_WINDOW,
            SPOT_ASSET, USD_SCALE, false
        );
        vault.setAllocator(allocator, true);

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
    }

    function _allocate(uint256 amount) internal {
        vm.prank(allocator);
        vault.allocate(address(adapter), abi.encode(bytes32("BTC")), amount);
    }

    /* ----------------------------- Decimal seams ----------------------------------- */

    /// @dev extra = -2 (USDT0-style): evm -> wei -> evm is exact for any representable amount.
    function testFuzz_decimalRoundtrip_negativeExtra(uint256 evmAmount) public view {
        evmAmount = bound(evmAmount, 1, uint256(type(uint64).max) / 100);
        uint64 wei_ = adapter.evmToWei(evmAmount);
        assertEq(wei_, evmAmount * 100);
        assertEq(adapter.weiToEvm(wei_), evmAmount);
    }

    /// @dev extra > 0 (WHYPE-style, evm 18d vs wei 8d): wei -> evm -> wei is exact; the
    ///      evm -> wei direction floors sub-wei dust (never rounds up = never overstates).
    function testFuzz_decimalRoundtrip_positiveExtra(uint64 weiAmount, uint256 dust) public {
        HyperCoreAdapterHarness hype = new HyperCoreAdapterHarness(
            address(vault), 150, address(0x2222222222222222222222222222222222222222), 10,
            PERP_DEX, SETTLE_WINDOW, 10107, 1e18, false
        );
        weiAmount = uint64(bound(weiAmount, 1, type(uint64).max));
        uint256 evm = hype.weiToEvm(weiAmount);
        assertEq(evm, uint256(weiAmount) * 1e10);
        assertEq(hype.evmToWei(evm), weiAmount);

        dust = bound(dust, 0, 1e10 - 1); // below one Core wei
        assertEq(hype.evmToWei(evm + dust), weiAmount); // floored, not rounded up
    }

    function testFuzz_evmToWei_revertsOutOfRange(uint256 evmAmount) public {
        evmAmount = bound(evmAmount, uint256(type(uint64).max) / 100 + 1, type(uint128).max);
        vm.expectRevert(bytes("wei out of range"));
        adapter.evmToWei(evmAmount);

        vm.expectRevert(bytes("wei out of range"));
        adapter.evmToWei(0); // zero wei is refused too (a no-op spotSend would be queued)
    }

    /* ----------------------------- Gain ceiling ------------------------------------ */

    function testFuzz_gainCeiling_properties(uint256 observed, uint256 net, uint16 bps) public {
        observed = bound(observed, 0, 1e30);
        net = bound(net, 0, 1e30);
        bps = uint16(bound(bps, 0, 10_000));
        adapter.setNetDepositedDirect(net);
        adapter.setMaxGainBpsDirect(bps);

        uint256 result = adapter.applyGainCeiling(observed);

        if (bps == 0 || net == 0) {
            assertEq(result, observed); // disabled: passthrough
        } else {
            uint256 ceiling = net + (net * bps) / 10_000;
            assertEq(result, observed > ceiling ? ceiling : observed);
            assertLe(result, ceiling); // gains can never exceed cost basis + bps
            if (observed <= net) assertEq(result, observed); // losses ALWAYS pass through
        }
    }

    /* ----------------------------- USD -> underlying pricing ----------------------- */

    function testFuzz_usdToUnderlying_exactAndMonotonic(uint256 usd6, uint64 ask1, uint64 ask2)
        public
    {
        usd6 = bound(usd6, 0, 1e30);
        ask1 = uint64(bound(ask1, 1, type(uint64).max - 1));
        ask2 = uint64(bound(ask2, ask1 + 1, type(uint64).max)); // strictly worse (higher) ask

        MockBbo(BBO).set(1, ask1);
        uint256 r1 = adapter.usdToUnderlying(usd6);
        assertEq(r1, usd6 * USD_SCALE / ask1);

        MockBbo(BBO).set(1, ask2);
        uint256 r2 = adapter.usdToUnderlying(usd6);
        assertLe(r2, r1); // a higher ask can only shrink reported NAV — conservative direction
    }

    function test_usdToUnderlying_zeroSkipsBook() public {
        MockBbo(BBO).set(0, 0); // even an empty book is fine when there is no USD value
        assertEq(adapter.usdToUnderlying(0), 0);
    }

    /* ----------------------------- In-flight bridge accounting --------------------- */

    /// @dev Random bridge sequence checked against an explicit model: at any later block,
    ///      inTransitToCore() must equal exactly the sum of bridges still within the window,
    ///      and realAssets() must equal idle + that sum (no spot credit, no equity).
    function testFuzz_inTransit_matchesModel(uint256 seed) public {
        uint256 n = bound(seed, 1, 8);
        _allocate(500_000e6);

        uint64[8] memory initBlocks;
        uint256[8] memory amounts;
        uint64 current = START_BLOCK;
        uint256 bridged;

        for (uint256 i; i < n; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            current += uint64(r % 4); // 0-3 L1 blocks between bridges
            MockL1Block(L1_BLOCK).set(current);
            uint256 amt = bound(r >> 128, 1e6, 50_000e6);
            vm.prank(allocator);
            adapter.bridgeToCore(amt);
            initBlocks[i] = current;
            amounts[i] = amt;
            bridged += amt;
        }

        current += uint64(uint256(keccak256(abi.encode(seed, "adv"))) % 40);
        MockL1Block(L1_BLOCK).set(current);

        uint256 expected;
        for (uint256 i; i < n; i++) {
            if (current - initBlocks[i] <= SETTLE_WINDOW) expected += amounts[i];
        }

        assertEq(adapter.inTransitToCore(), expected, "in-transit vs model");
        // Expired-but-uncredited entries read as a loss (the 'window too short' direction);
        // everything still in the window holds NAV. Exact formula either way:
        assertEq(adapter.realAssets(), 500_000e6 - bridged + expected, "NAV vs model");

        adapter.pruneSettled();
        uint256 head = adapter.pendingHead();
        assertLe(head, adapter.pendingToCoreLength());
        for (uint256 i; i < n; i++) {
            // Prune must drop exactly the aged-out prefix — nothing more, nothing less.
            if (i < head) assertGt(current - initBlocks[i], SETTLE_WINDOW);
            else assertLe(current - initBlocks[i], SETTLE_WINDOW);
        }
        assertEq(adapter.inTransitToCore(), expected, "prune must not change valuation");
    }

    /* ----------------------------- Adversarial reads ------------------------------- */

    /// @dev Liquidations can leave accountValue NEGATIVE transiently (ADL doc: "if a user's
    ///      account value ... becomes negative"); the floor must hold for the whole int64 range.
    function testFuzz_negativeEquity_flooredAtZero(int64 v) public {
        vm.assume(v <= 0);
        _allocate(100_000e6);
        MockAccountMargin(ACCOUNT_MARGIN).set(PERP_DEX, v, 0, 0, 0);
        assertEq(adapter.realAssets(), 100_000e6); // idle only; no revert, no underflow
    }

    function test_precompileDown_spotBalance_failsClosed() public {
        _allocate(1e6);
        vm.etch(SPOT_BALANCE, address(new RevertingPrecompile()).code);
        vm.expectRevert(bytes("spotBalance precompile"));
        adapter.realAssets();
    }

    function test_precompileDown_accountMargin_failsClosed() public {
        _allocate(1e6);
        vm.etch(ACCOUNT_MARGIN, address(new RevertingPrecompile()).code);
        vm.expectRevert(bytes("accountMargin precompile"));
        adapter.realAssets();
    }

    function test_precompileDown_bbo_failsClosed() public {
        _allocate(1e6);
        MockAccountMargin(ACCOUNT_MARGIN).set(PERP_DEX, 1e6, 0, 0, 0); // USD value > 0 forces pricing
        vm.etch(BBO, address(new RevertingPrecompile()).code);
        vm.expectRevert(bytes("bbo precompile"));
        adapter.realAssets();
    }

    function test_precompileDown_l1Block_failsClosed() public {
        _allocate(10e6);
        vm.prank(allocator);
        adapter.bridgeToCore(10e6); // creates a pending entry so valuation needs the L1 block
        vm.etch(L1_BLOCK, address(new RevertingPrecompile()).code);
        vm.expectRevert(bytes("l1BlockNumber precompile"));
        adapter.realAssets();
    }

    function test_precompileDown_coreUserExists_blocksBridge() public {
        _allocate(10e6);
        vm.etch(CORE_USER_EXISTS, address(new RevertingPrecompile()).code);
        vm.prank(allocator);
        vm.expectRevert(bytes("coreUserExists precompile"));
        adapter.bridgeToCore(10e6); // funds must not move when the escrow gate can't be read
    }

    /// @dev Book manipulation: an attacker pinning the underlying/USDC ask to dust would
    ///      multiply USD-denominated NAV ~1e6x. The gain ceiling bounds the damage to +bps.
    function test_dustAsk_boundedByGainCeiling() public {
        _allocate(100_000e6);
        MockAccountMargin(ACCOUNT_MARGIN).set(PERP_DEX, 100_000e6, 0, 0, 0);
        adapter.setMaxGainBpsDirect(1000); // +10%

        MockBbo(BBO).set(1, 1); // ask crashed to one raw tick
        assertEq(adapter.realAssets(), 110_000e6); // clamped, not 1e17

        adapter.setMaxGainBpsDirect(0); // ceiling off: document the unbounded exposure
        assertEq(adapter.realAssets(), 100_000e6 + uint256(100_000e6) * USD_SCALE / 1);
    }

    /// @dev CHARACTERIZATION of a known mispricing (kept, documented — not a regression):
    ///      the add-back expires by AGE, so a deposit that credits Core spot BEFORE the window
    ///      elapses is counted twice (spot + add-back) until expiry. This is the 'window too
    ///      long' direction of the settlement-window trade-off applied to SUCCESSFUL deposits,
    ///      overstating NAV by the bridged amount for (window - actual latency) blocks. At the
    ///      vault level the overstatement is blunted by the maxRate cap on gains (and by
    ///      maxGainBps if set), and it self-corrects at expiry. The fix under consideration is
    ///      reconciliation against the observable spot-balance delta — see PRODUCTION.md
    ///      "Settlement window calibration".
    function test_characterization_earlyCredit_doubleCountsUntilExpiry() public {
        _allocate(100_000e6);
        vm.prank(allocator);
        adapter.bridgeToCore(100_000e6); // init at block 100, window 5

        // Core credits fast (block 102), well before the window closes.
        MockL1Block(L1_BLOCK).set(102);
        MockSpotBalance(SPOT_BALANCE).set(TRANSIT_TOKEN, uint64(100_000e6 * 100), 0, 0);

        // Both the spot credit AND the in-transit add-back are counted: NAV reads 2x.
        assertEq(adapter.realAssets(), 200_000e6);

        // Self-corrects the moment the entry ages out.
        MockL1Block(L1_BLOCK).set(100 + SETTLE_WINDOW + 1);
        assertEq(adapter.realAssets(), 100_000e6);
    }
}
