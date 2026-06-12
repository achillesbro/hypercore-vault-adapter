// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @dev Hyperliquid's USDC deposit helper on HyperEVM (the contract tokenInfo(0).evmContract
///      points to). Mainnet: 0x6B9E773128f453f5c2C60935Ee2DE2CBc5390A24 (verified: proxy whose
///      implementation carries selector 0x2b2dfd2c = deposit(uint256,uint32)).
///      `destinationDex`: type(uint32).max = spot, 0 = default perp dex.
interface ICoreDepositWallet {
    function deposit(uint256 evmAmount, uint32 destinationDex) external;
}
