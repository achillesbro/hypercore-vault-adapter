// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {MockERC20} from "./MockERC20.sol";

/// @dev WETH9-style wrapped native for the WHYPE bridging branch.
contract MockWrappedNative is MockERC20 {
    constructor() MockERC20("Wrapped HYPE", "WHYPE", 18) {}

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "native send");
    }

    receive() external payable {}
}
