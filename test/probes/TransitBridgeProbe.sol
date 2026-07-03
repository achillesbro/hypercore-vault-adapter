// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "vault-v2/interfaces/IERC20.sol";
import {ICoreWriter} from "../../src/interfaces/ICoreWriter.sol";

/// @dev Rehearses the FULL alternative funding leg for a smart contract, end to end:
///        1. bridgeToCore(): plain ERC20 transfer of a HIP-1 token to its system address
///           (the generic linked-token mechanism — what USDT0 uses on mainnet; PURR on testnet)
///        2. sendRaw(): owner-gated CoreWriter passthrough, used to IOC spot-swap the transit
///           token to USDC on Core and usdClassTransfer the USDC to perp.
///      If every hop credits a CONTRACT account, the USDT0-transit architecture is proven and
///      Circle's contract-recipient-refusing CoreDepositWallet is not needed at all.
contract TransitBridgeProbe {
    ICoreWriter internal constant CORE_WRITER =
        ICoreWriter(0x3333333333333333333333333333333333333333);

    address public immutable owner;
    IERC20 public immutable transitToken; // linked HIP-1 ERC20 (PURR testnet / USDT0 mainnet)
    address public immutable systemAddress; // 0x2000...0000 + core token index

    constructor(address _transitToken, address _systemAddress) {
        owner = msg.sender;
        transitToken = IERC20(_transitToken);
        systemAddress = _systemAddress;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    /// @notice EVM -> Core: the generic HIP-1 path. Core credits THIS contract's spot account.
    function bridgeToCore(uint256 amount) external onlyOwner {
        require(transitToken.transfer(systemAddress, amount), "transfer failed");
    }

    /// @notice Raw CoreWriter passthrough for the rehearsal (spot IOC swap, class transfer...).
    function sendRaw(bytes calldata action) external onlyOwner {
        CORE_WRITER.sendRawAction(action);
    }
}
