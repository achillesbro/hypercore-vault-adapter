// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {ICoreWriter} from "../../src/interfaces/ICoreWriter.sol";

/// @dev Records actions so tests can inspect the encoded bytes. Etched at 0x3333...3333.
contract MockCoreWriter is ICoreWriter {
    bytes public lastAction;
    bytes[] public actions;

    function sendRawAction(bytes calldata data) external {
        lastAction = data;
        actions.push(data);
    }

    function actionsCount() external view returns (uint256) {
        return actions.length;
    }
}
