// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {VaultV2Factory} from "vault-v2/VaultV2Factory.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";

import {HyperCoreAdapter} from "../src/HyperCoreAdapter.sol";

/// @notice Deploys the full stack on HyperEVM TESTNET (chainid 998):
///         real VaultV2 (via the real factory) + HyperCoreAdapter, wires roles and caps.
///
///         All testnet constants verified on-chain (see README):
///         - USDC ERC20: 0x2B3370eE501B4a559b57D449569354196457D8Ab (symbol USDC, 6 decimals)
///         - CoreDepositWallet: 0x0B80659a4076E9E93C7DbE0f10675A16a3e5C206 (= tokenInfo(0).evmContract)
///         - USDC Core token index: 0; decimal seam identical to mainnet (wei = evm * 100)
///
///         IMPORTANT: deploying the factory needs > 3M gas. The deployer account must have
///         big blocks enabled on testnet first (see script/flow/00_enable_big_blocks.py).
///
///         Run:
///           forge script script/DeployTestnet.s.sol --rpc-url $TESTNET_RPC \
///             --private-key $PRIVATE_KEY --broadcast --slow
contract DeployTestnet is Script {
    address constant USDC = 0x2B3370eE501B4a559b57D449569354196457D8Ab;
    address constant CORE_DEPOSIT_WALLET = 0x0B80659a4076E9E93C7DbE0f10675A16a3e5C206;
    address constant USDC_SYSTEM = 0x2000000000000000000000000000000000000000;

    uint64 constant USDC_TOKEN = 0;
    uint32 constant PERP_DEX = 0;
    uint64 constant SETTLE_WINDOW = 30; // generous for testnet
    bytes32 constant MARKET = bytes32("BTC");

    function run() external {
        require(block.chainid == 998, "expected HyperEVM testnet");
        address deployer = vm.envOr("DEPLOYER", msg.sender);

        vm.startBroadcast();

        // For the testnet dry run a single EOA holds every role: owner, curator, allocator.
        VaultV2Factory factory = new VaultV2Factory();
        IVaultV2 vault = IVaultV2(factory.createVaultV2(deployer, USDC, bytes32(0)));

        vault.setCurator(deployer);
        vault.submit(abi.encodeCall(IVaultV2.setIsAllocator, (deployer, true)));
        vault.setIsAllocator(deployer, true);

        // Set maxRate BEFORE registering the adapter: setMaxRate accrues interest, which polls
        // every adapter's realAssets() — and that reads HyperCore precompiles, which exist on
        // the live chain but cannot execute in forge's local pre-broadcast simulation.
        // Without a non-zero maxRate the vault never recognizes gains (protocol max = 200% APR).
        vault.setMaxRate(uint256(200e16) / uint256(365 days));

        HyperCoreAdapter adapter = new HyperCoreAdapter(
            address(vault), USDC_TOKEN, PERP_DEX, CORE_DEPOSIT_WALLET, USDC_SYSTEM, SETTLE_WINDOW
        );

        vault.submit(abi.encodeCall(IVaultV2.addAdapter, (address(adapter))));
        vault.addAdapter(address(adapter));

        _raiseCaps(vault, abi.encode("this", address(adapter)));
        _raiseCaps(vault, abi.encode("hypercore", address(adapter)));
        _raiseCaps(vault, abi.encode("hypercore/market", address(adapter), MARKET));

        vm.stopBroadcast();

        console.log("factory :", address(factory));
        console.log("vault   :", address(vault));
        console.log("adapter :", address(adapter));
        console.log("roles   : owner/curator/allocator =", deployer);
    }

    function _raiseCaps(IVaultV2 vault, bytes memory idData) internal {
        vault.submit(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, type(uint128).max)));
        vault.increaseAbsoluteCap(idData, type(uint128).max);
        vault.submit(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, 1e18)));
        vault.increaseRelativeCap(idData, 1e18);
    }
}
