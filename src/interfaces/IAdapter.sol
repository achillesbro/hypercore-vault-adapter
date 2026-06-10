// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @dev The mandatory surface every Morpho Vault v2 adapter must implement.
///      Mirrors morpho-org/vault-v2 src/interfaces/IAdapter.sol.
interface IAdapter {
    /// @dev Called by the vault AFTER it has transferred `assets` of the underlying to this adapter.
    ///      Returns the risk `ids` this allocation touches and the signed `change` in the
    ///      adapter's measured position value (used by the vault for per-id cap accounting).
    function allocate(bytes memory data, uint256 assets, bytes4 selector, address sender)
        external
        returns (bytes32[] memory ids, int256 change);

    /// @dev Called by the vault BEFORE it pulls `assets` of the underlying back via transferFrom.
    function deallocate(bytes memory data, uint256 assets, bytes4 selector, address sender)
        external
        returns (bytes32[] memory ids, int256 change);

    /// @dev Current value of the adapter's investments, denominated in the vault's underlying asset.
    ///      Polled by the vault on every accrueInterest(); it is the sole source of truth for share price.
    function realAssets() external view returns (uint256 assets);
}
