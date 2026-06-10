// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

/// @dev Decimal conversions across the EVM / Core-spot / Core-perp seams for USDC.
///      All factors MUST be verified against the tokenInfo precompile before mainnet.
///      Assumptions encoded here (typical USDC):
///        - EVM USDC: 6 decimals
///        - Core spot USDC wei: 8 decimals  -> spot wei = evm * 100
///        - Core perp USD units: 6 decimals -> perp == evm USDC numerically (perp = spot wei / 100)
library Decimals {
    uint256 internal constant SPOT_PER_EVM = 100; // core spot wei carries 2 more decimals than EVM USDC

    function evmToSpotWei(uint256 evmAmount) internal pure returns (uint256) {
        return evmAmount * SPOT_PER_EVM;
    }

    function spotWeiToEvm(uint256 spotWei) internal pure returns (uint256) {
        return spotWei / SPOT_PER_EVM;
    }

    function evmToPerpUsd(uint256 evmAmount) internal pure returns (uint256) {
        return evmAmount; // identity under the assumptions above
    }

    function perpUsdToEvm(uint256 perpAmount) internal pure returns (uint256) {
        return perpAmount; // identity under the assumptions above
    }
}
