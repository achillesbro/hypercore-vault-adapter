// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @dev HyperCore system contract on HyperEVM at 0x3333333333333333333333333333333333333333.
///      Fire-and-forget: queues an action that HyperCore executes on a LATER L1 block.
interface ICoreWriter {
    function sendRawAction(bytes calldata data) external;
}
