// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

/// @dev Encoders for CoreWriter actions.
///      Raw action layout: abi.encodePacked(uint8 version=1, uint24 actionId, abi.encode(payload)).
library HyperCoreActions {
    uint8 internal constant ENCODING_VERSION = 1;

    uint24 internal constant ACTION_LIMIT_ORDER = 1;
    uint24 internal constant ACTION_SPOT_SEND = 6;
    uint24 internal constant ACTION_USD_CLASS_TRANSFER = 7;
    uint24 internal constant ACTION_CANCEL_BY_CLOID = 11;
    uint24 internal constant ACTION_SEND_ASSET = 13;

    // Dex identifiers used by sendAsset (verified against hyper-evm-lib HLConstants).
    uint32 internal constant DEFAULT_PERP_DEX = 0;
    uint32 internal constant SPOT_DEX = type(uint32).max;

    // Time-in-force codes for limit orders.
    uint8 internal constant TIF_ALO = 1; // add-liquidity-only (post-only)
    uint8 internal constant TIF_GTC = 2; // good-til-cancelled
    uint8 internal constant TIF_IOC = 3; // immediate-or-cancel (use for "market" with aggressive px)

    // Asset-id helpers: perp uses the perp index directly; spot is pairIndex + 10000.
    uint32 internal constant SPOT_ASSET_OFFSET = 10000;

    function spotAssetId(uint32 spotPairIndex) internal pure returns (uint32) {
        return spotPairIndex + SPOT_ASSET_OFFSET;
    }

    /// @dev Works for both perp and spot — the distinction is entirely in `asset`.
    ///      `limitPx` and `sz` are pre-scaled by the caller (1e8 * human, respecting szDecimals).
    function limitOrder(
        uint32 asset,
        bool isBuy,
        uint64 limitPx,
        uint64 sz,
        bool reduceOnly,
        uint8 tif,
        uint128 cloid
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            ENCODING_VERSION,
            ACTION_LIMIT_ORDER,
            abi.encode(asset, isBuy, limitPx, sz, reduceOnly, tif, cloid)
        );
    }

    /// @dev Move USD collateral between the spot and perp accounts. `ntl` is in perp USD units.
    function usdClassTransfer(uint64 ntl, bool toPerp) internal pure returns (bytes memory) {
        return abi.encodePacked(ENCODING_VERSION, ACTION_USD_CLASS_TRANSFER, abi.encode(ntl, toPerp));
    }

    /// @dev Send a spot token on HyperCore. Used here to push funds toward an EVM system address.
    function spotSend(address to, uint64 token, uint64 amountWei) internal pure returns (bytes memory) {
        return abi.encodePacked(ENCODING_VERSION, ACTION_SPOT_SEND, abi.encode(to, token, amountWei));
    }

    function cancelByCloid(uint32 asset, uint128 cloid) internal pure returns (bytes memory) {
        return abi.encodePacked(ENCODING_VERSION, ACTION_CANCEL_BY_CLOID, abi.encode(asset, cloid));
    }

    /// @dev Canonical Core->EVM exit (and cross-dex moves): send to the token's EVM system
    ///      address with sourceDex = destinationDex = SPOT_DEX. Mirrors hyper-evm-lib bridgeToEvm.
    function sendAsset(
        address destination,
        address subAccount,
        uint32 sourceDex,
        uint32 destinationDex,
        uint64 token,
        uint64 amountWei
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            ENCODING_VERSION,
            ACTION_SEND_ASSET,
            abi.encode(destination, subAccount, sourceDex, destinationDex, token, amountWei)
        );
    }
}
