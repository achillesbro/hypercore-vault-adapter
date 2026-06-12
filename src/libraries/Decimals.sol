// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

/// @dev Decimal conversions across the EVM / Core-spot / Core-perp seams for USDC.
///
///      VERIFIED on HyperEVM mainnet (chainid 999) via the tokenInfo precompile (0x080C):
///        tokenInfo(0) = ("USDC", ..., szDecimals: 8, weiDecimals: 8, evmExtraWeiDecimals: -2)
///      i.e. EVM USDC has 6 decimals (weiDecimals + evmExtraWeiDecimals) and
///        Core spot wei = EVM amount * 100.
///      Perp USD ("ntl") carries 6 decimals, equal to EVM USDC units (perp = spot wei / 100).
library Decimals {
    uint256 internal constant SPOT_PER_EVM = 100;

    function evmToSpotWei(uint256 evmAmount) internal pure returns (uint256) {
        return evmAmount * SPOT_PER_EVM;
    }

    function spotWeiToEvm(uint256 spotWei) internal pure returns (uint256) {
        return spotWei / SPOT_PER_EVM;
    }

    function evmToPerpUsd(uint256 evmAmount) internal pure returns (uint256) {
        return evmAmount;
    }

    function perpUsdToEvm(uint256 perpAmount) internal pure returns (uint256) {
        return perpAmount;
    }
}
