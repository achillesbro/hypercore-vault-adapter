// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {IAdapter} from "./interfaces/IAdapter.sol";
import {IVaultV2} from "./interfaces/IVaultV2.sol";
import {ICoreWriter} from "./interfaces/ICoreWriter.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {HyperCoreActions} from "./libraries/HyperCoreActions.sol";
import {HyperCoreReader} from "./libraries/HyperCoreReader.sol";
import {Decimals} from "./libraries/Decimals.sol";

/// @title HyperCoreAdapter
/// @notice Morpho Vault v2 adapter that trades spot & perps on HyperCore (Hyperliquid L1) from HyperEVM.
/// @dev Two surfaces, deliberately split because HyperCore settles asynchronously:
///        1. Funding   — allocate()/deallocate(), called only by the vault, move USDC vault <-> idle.
///        2. Trading   — allocator-gated functions that bridge, transfer margin, and place/cancel orders.
///      The vault's share price tracks the live position automatically via realAssets().
contract HyperCoreAdapter is IAdapter {
    ICoreWriter internal constant CORE_WRITER =
        ICoreWriter(0x3333333333333333333333333333333333333333);

    address public immutable parentVault;
    address public immutable asset; // USDC on HyperEVM (the vault's underlying)
    bytes32 public immutable adapterId;

    uint64 public immutable usdcCoreToken; // HyperCore token index for USDC
    uint32 public immutable usdcSpotIndex; // HyperCore spot pair index for USDC
    uint32 public immutable perpDex; // perp dex index (0 = default)
    address public immutable usdcSystemAddress; // EVM system address used to bridge USDC

    /// @dev USDC bridged Core->EVM but not yet credited on the EVM side. Keeps realAssets()
    ///      from momentarily under-counting during the settlement window. Acknowledged by an
    ///      allocator once the funds land. Production needs stronger reconciliation than this.
    uint256 public pendingBridgeOut;

    error NotVault();
    error NotAllocator();
    error InsufficientIdle();

    event ActionSent(bytes rawAction);
    event BridgeAcknowledged(uint256 amount);

    modifier onlyVault() {
        if (msg.sender != parentVault) revert NotVault();
        _;
    }

    /// @dev Reuses the vault's allocator set — same accounts that can allocate/deallocate can trade.
    modifier onlyAllocator() {
        if (!IVaultV2(parentVault).isAllocator(msg.sender)) revert NotAllocator();
        _;
    }

    constructor(
        address _parentVault,
        uint64 _usdcCoreToken,
        uint32 _usdcSpotIndex,
        uint32 _perpDex,
        address _usdcSystemAddress
    ) {
        parentVault = _parentVault;
        asset = IVaultV2(_parentVault).asset();
        usdcCoreToken = _usdcCoreToken;
        usdcSpotIndex = _usdcSpotIndex;
        perpDex = _perpDex;
        usdcSystemAddress = _usdcSystemAddress;
        adapterId = keccak256(abi.encode("this", address(this)));
        // Allow the vault to pull funds back during deallocate().
        IERC20(asset).approve(_parentVault, type(uint256).max);
    }

    /* ----------------------------- Funding (vault-only) ----------------------------- */

    function allocate(bytes calldata data, uint256 assets, bytes4, address)
        external
        onlyVault
        returns (bytes32[] memory, int256)
    {
        // USDC has already been transferred in by the vault; it now sits idle until an
        // allocator bridges it to Core. Cap accounting books the inflow as exposure.
        return (ids(_market(data)), int256(assets));
    }

    function deallocate(bytes calldata data, uint256 assets, bytes4, address)
        external
        onlyVault
        returns (bytes32[] memory, int256)
    {
        // Can only return USDC that an allocator has already bridged back to the EVM side.
        if (IERC20(asset).balanceOf(address(this)) < assets) revert InsufficientIdle();
        return (ids(_market(data)), -int256(assets));
    }

    /* ----------------------------- Trading (allocator-gated) ------------------------ */

    /// @notice Bridge idle USDC from HyperEVM into this adapter's HyperCore spot account.
    /// @dev Generic HIP-1 path: transfer to the token's EVM system address; Core credits on the
    ///      Transfer event. Canonical USDC on mainnet routes via the CoreDepositWallet helper
    ///      instead — swap this body for that call when wiring real addresses.
    function bridgeToCore(uint256 usdcAmount) external onlyAllocator {
        _safeTransfer(asset, usdcSystemAddress, usdcAmount);
    }

    /// @notice Bridge USDC from the HyperCore spot account back to this adapter on HyperEVM.
    function bridgeToEvm(uint256 usdcAmount) external onlyAllocator {
        pendingBridgeOut += usdcAmount;
        uint64 amountWei = uint64(Decimals.evmToSpotWei(usdcAmount));
        _send(HyperCoreActions.spotSend(usdcSystemAddress, usdcCoreToken, amountWei));
    }

    /// @notice Decrement the in-flight counter once bridged-out USDC has landed in idle balance.
    function acknowledgeBridgeIn(uint256 amount) external onlyAllocator {
        pendingBridgeOut = amount >= pendingBridgeOut ? 0 : pendingBridgeOut - amount;
        emit BridgeAcknowledged(amount);
    }

    /// @notice Move USD collateral between the spot and perp accounts on HyperCore.
    function transferUsdClass(uint64 ntl, bool toPerp) external onlyAllocator {
        _send(HyperCoreActions.usdClassTransfer(ntl, toPerp));
    }

    /// @notice Place a limit order. Spot vs perp is determined by `coreAsset`
    ///         (perp = perp index; spot = HyperCoreActions.spotAssetId(pairIndex)).
    function placeOrder(
        uint32 coreAsset,
        bool isBuy,
        uint64 limitPx,
        uint64 sz,
        bool reduceOnly,
        uint8 tif,
        uint128 cloid
    ) external onlyAllocator {
        _send(HyperCoreActions.limitOrder(coreAsset, isBuy, limitPx, sz, reduceOnly, tif, cloid));
    }

    function cancelOrder(uint32 coreAsset, uint128 cloid) external onlyAllocator {
        _send(HyperCoreActions.cancelByCloid(coreAsset, cloid));
    }

    /* ----------------------------- Valuation --------------------------------------- */

    /// @inheritdoc IAdapter
    /// @dev Conservative: floors perp equity at zero. Note the vault rate-caps gains, which
    ///      blunts short-lived mark-price inflation; losses pass through to share price in full.
    function realAssets() public view returns (uint256) {
        uint256 idle = IERC20(asset).balanceOf(address(this));
        return idle + _perpEquityEvm() + _usdcSpotEvm() + pendingBridgeOut;
    }

    function _perpEquityEvm() internal view returns (uint256) {
        HyperCoreReader.AccountMarginSummary memory s =
            HyperCoreReader.accountMarginSummary(perpDex, address(this));
        if (s.accountValue <= 0) return 0;
        return Decimals.perpUsdToEvm(uint256(uint64(s.accountValue)));
    }

    function _usdcSpotEvm() internal view returns (uint256) {
        HyperCoreReader.SpotBalance memory b =
            HyperCoreReader.spotBalance(address(this), usdcCoreToken);
        return Decimals.spotWeiToEvm(b.total);
    }

    /* ----------------------------- Risk ids ---------------------------------------- */

    /// @notice The risk buckets each allocation consumes. The curator must set a non-zero
    ///         absoluteCap (via increaseAbsoluteCap with the matching idData preimage) for each.
    function ids(bytes32 market) public view returns (bytes32[] memory ids_) {
        ids_ = new bytes32[](3);
        ids_[0] = adapterId; // per-adapter total
        ids_[1] = keccak256(abi.encode("hypercore", address(this))); // total HyperCore exposure
        ids_[2] = keccak256(abi.encode("hypercore/market", address(this), market)); // per market
    }

    /* ----------------------------- Internals --------------------------------------- */

    function _market(bytes calldata data) internal pure returns (bytes32) {
        return data.length == 0 ? bytes32(0) : abi.decode(data, (bytes32));
    }

    function _send(bytes memory rawAction) internal {
        CORE_WRITER.sendRawAction(rawAction);
        emit ActionSent(rawAction);
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory ret) =
            token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "transfer failed");
    }
}
