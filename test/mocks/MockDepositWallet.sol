// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "vault-v2/interfaces/IERC20.sol";
import {ICoreDepositWallet} from "../../src/interfaces/ICoreDepositWallet.sol";

/// @dev Mimics the CoreDepositWallet's EVM-visible effect: pulls approved USDC from the caller.
///      (The Core-side spot credit is off-chain and happens blocks later — exactly the seam the
///      adapter's in-transit accounting models.)
contract MockDepositWallet is ICoreDepositWallet {
    address public immutable usdc;
    uint32 public lastDestinationDex;

    constructor(address _usdc) {
        usdc = _usdc;
    }

    function deposit(uint256 evmAmount, uint32 destinationDex) external {
        lastDestinationDex = destinationDex;
        require(IERC20(usdc).transferFrom(msg.sender, address(this), evmAmount), "pull failed");
    }
}
