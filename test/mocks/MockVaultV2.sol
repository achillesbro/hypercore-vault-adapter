// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {IAdapter} from "../../src/interfaces/IAdapter.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";

/// @dev Minimal stand-in for Morpho Vault v2: implements the IVaultV2 view surface the adapter
///      reads (asset, isAllocator) and replicates the push-then-call / call-then-pull flow.
contract MockVaultV2 {
    address public asset;
    address public curator;
    mapping(address => bool) public isAllocator;

    constructor(address _asset, address _curator) {
        asset = _asset;
        curator = _curator;
    }

    function setAllocator(address account, bool value) external {
        isAllocator[account] = value;
    }

    function allocate(address adapter, bytes calldata data, uint256 assets)
        external
        returns (bytes32[] memory ids, int256 change)
    {
        IERC20(asset).transfer(adapter, assets); // push first
        (ids, change) = IAdapter(adapter).allocate(data, assets, msg.sig, msg.sender);
    }

    function deallocate(address adapter, bytes calldata data, uint256 assets)
        external
        returns (bytes32[] memory ids, int256 change)
    {
        (ids, change) = IAdapter(adapter).deallocate(data, assets, msg.sig, msg.sender);
        IERC20(asset).transferFrom(adapter, address(this), assets); // pull back after
    }
}
