// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

/// @dev Minimal probe: can a SMART CONTRACT bridge an asset EVM->Core for ITSELF through the
///      generic HIP-1 system-address mechanism? Uses native HYPE (system address 0x2222...2222).
///      This is the mechanism USDT0/HIP-1 tokens use — unlike USDC, which routes through the
///      Circle CoreDepositWallet whose both paths refuse contract recipients (proven 2026-06).
contract HypeBridgeProbe {
    address constant HYPE_SYSTEM = 0x2222222222222222222222222222222222222222;

    receive() external payable {}

    function bridgeAll() external {
        (bool ok,) = HYPE_SYSTEM.call{value: address(this).balance}("");
        require(ok, "bridge send failed");
    }
}
