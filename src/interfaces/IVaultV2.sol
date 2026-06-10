// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @dev Minimal view of Morpho Vault v2 that the adapter depends on.
interface IVaultV2 {
    function asset() external view returns (address);
    function isAllocator(address account) external view returns (bool);
    function curator() external view returns (address);
}
