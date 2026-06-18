// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {IAdapter} from "vault-v2/interfaces/IAdapter.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {IERC20} from "vault-v2/interfaces/IERC20.sol";
import {ICoreWriter} from "./interfaces/ICoreWriter.sol";
import {ICoreDepositWallet} from "./interfaces/ICoreDepositWallet.sol";
import {HyperCoreActions} from "./libraries/HyperCoreActions.sol";
import {HyperCoreReader} from "./libraries/HyperCoreReader.sol";
import {Decimals} from "./libraries/Decimals.sol";

/// @title HyperCoreAdapter
/// @notice Morpho Vault v2 adapter that trades spot & perps on HyperCore (Hyperliquid L1) from HyperEVM.
/// @dev Two surfaces, deliberately split because HyperCore settles asynchronously:
///        1. Funding   — allocate()/deallocate(), called only by the vault, move USDC vault <-> idle.
///        2. Trading   — allocator-gated functions that bridge, transfer margin, and place/cancel orders.
///      The vault's share price tracks the live position automatically via realAssets().
///
///      Verified against HyperEVM mainnet (chainid 999):
///        - USDC = Core token 0; ERC20 0xb88339CB7199b77E23DB6E890353E22632Ba630f (6 decimals).
///        - EVM->Core USDC goes through CoreDepositWallet 0x6B9E773128f453f5c2C60935Ee2DE2CBc5390A24
///          (the address tokenInfo(0).evmContract points to), via deposit(uint256,uint32).
///        - Core->EVM uses sendAsset (action 13) to the token system address with SPOT_DEX legs.
///        - Core spot wei = EVM USDC * 100 (tokenInfo: weiDecimals 8, evmExtraWeiDecimals -2).
///
///      Valuation model. realAssets() sums everything observable from EVM:
///        EVM idle USDC + Core perp equity + Core spot USDC + in-transit-to-Core.
///      Operations that move value WITHIN that observable set (spot<->perp class transfers,
///      orders, and even Core->EVM bridges) are invariant to the sum and need no tracking.
///      The ONLY gap is EVM->Core bridging: the ERC20 transfer debits idle synchronously while
///      the Core spot credit lands a few L1 blocks later. We add that amount back until the
///      L1-block age proves settlement, so a deposit-in-flight is never read as a loss.
contract HyperCoreAdapter is IAdapter {
    ICoreWriter internal constant CORE_WRITER =
        ICoreWriter(0x3333333333333333333333333333333333333333);

    uint256 internal constant MAX_BPS = 10_000;

    address public immutable parentVault;
    address public immutable asset; // USDC on HyperEVM (the vault's underlying)
    bytes32 public immutable adapterId;

    uint64 public immutable usdcCoreToken; // HyperCore token index for USDC (0 on mainnet)
    uint32 public immutable perpDex; // perp dex index (0 = default)
    address public immutable usdcDepositWallet; // CoreDepositWallet for EVM->Core USDC
    address public immutable usdcSystemAddress; // token system address, Core->EVM destination

    /// @dev EVM->Core bridges awaiting settlement. Appended in non-decreasing initL1Block order,
    ///      so once we reach an entry within the settle window, every later one is too (ages
    ///      decrease as index grows). `pendingHead` skips entries already proven settled.
    struct PendingDeposit {
        uint128 amount; // EVM USDC units in transit to Core
        uint64 initL1Block; // L1 block at which the bridge was initiated
    }

    PendingDeposit[] internal pendingToCore;
    uint256 public pendingHead;

    /// @dev Conservative upper bound (in L1 blocks) on EVM->Core settlement latency. After this
    ///      many blocks the Core spot balance is guaranteed to reflect the deposit, so the
    ///      add-back is dropped to avoid double-counting. Curator-tunable.
    uint64 public settleWindowBlocks;

    /// @dev Net underlying the vault has entrusted (sum of allocate assets - deallocate assets).
    ///      Cost basis used by the optional instantaneous gain ceiling.
    uint256 public netDeposited;

    /// @dev Defense-in-depth: caps the gain realAssets() may report above netDeposited in a single
    ///      read, blunting a one-block mark-price spike. 0 = disabled. Losses always pass through.
    ///      Complements (does not replace) the vault's time-based maxRate gain cap.
    uint16 public maxGainBps;

    error NotVault();
    error NotAllocator();
    error NotCurator();
    error InsufficientIdle();

    event ActionSent(bytes rawAction);
    event BridgedToCore(uint256 amount, uint64 initL1Block);
    event SettleWindowSet(uint64 blocks);
    event MaxGainBpsSet(uint16 bps);
    event ApiWalletApproved(address indexed agent, string name);
    event ApiWalletRevoked(string name);

    modifier onlyVault() {
        if (msg.sender != parentVault) revert NotVault();
        _;
    }

    /// @dev Reuses the vault's allocator set — same accounts that can allocate/deallocate can trade.
    modifier onlyAllocator() {
        if (!IVaultV2(parentVault).isAllocator(msg.sender)) revert NotAllocator();
        _;
    }

    /// @dev Config (risk params) is curator-gated, not allocator-gated. In production these should
    ///      route through the vault's timelock; kept immediate here for the scaffold.
    modifier onlyCurator() {
        if (msg.sender != IVaultV2(parentVault).curator()) revert NotCurator();
        _;
    }

    constructor(
        address _parentVault,
        uint64 _usdcCoreToken,
        uint32 _perpDex,
        address _usdcDepositWallet,
        address _usdcSystemAddress,
        uint64 _settleWindowBlocks
    ) {
        parentVault = _parentVault;
        asset = IVaultV2(_parentVault).asset();
        usdcCoreToken = _usdcCoreToken;
        perpDex = _perpDex;
        usdcDepositWallet = _usdcDepositWallet;
        usdcSystemAddress = _usdcSystemAddress;
        settleWindowBlocks = _settleWindowBlocks;
        adapterId = keccak256(abi.encode("this", address(this)));
        // Allow the vault to pull funds back during deallocate().
        require(IERC20(asset).approve(_parentVault, type(uint256).max), "approve");
    }

    /* ----------------------------- Config (curator-only) --------------------------- */

    function setSettleWindowBlocks(uint64 blocks) external onlyCurator {
        settleWindowBlocks = blocks;
        emit SettleWindowSet(blocks);
    }

    function setMaxGainBps(uint16 bps) external onlyCurator {
        require(bps <= MAX_BPS, "bps");
        maxGainBps = bps;
        emit MaxGainBpsSet(bps);
    }

    /* ----------------------------- Funding (vault-only) ----------------------------- */

    function allocate(bytes memory data, uint256 assets, bytes4, address)
        external
        onlyVault
        returns (bytes32[] memory, int256)
    {
        // USDC has already been transferred in by the vault; it now sits idle until an
        // allocator bridges it to Core. Cap accounting books the inflow as exposure.
        netDeposited += assets;
        return (ids(_market(data)), int256(assets));
    }

    function deallocate(bytes memory data, uint256 assets, bytes4, address)
        external
        onlyVault
        returns (bytes32[] memory, int256)
    {
        // Can only return USDC that an allocator has already bridged back to the EVM side.
        if (IERC20(asset).balanceOf(address(this)) < assets) revert InsufficientIdle();
        netDeposited = assets >= netDeposited ? 0 : netDeposited - assets;
        return (ids(_market(data)), -int256(assets));
    }

    /* ----------------------------- Trading (allocator-gated) ------------------------ */

    /// @notice Bridge idle USDC from HyperEVM into this adapter's HyperCore spot account.
    /// @dev WARNING — empirically BROKEN for contracts on TESTNET (2026-06-12, chainid 998):
    ///      the Circle CoreDepositWallet silently refuses to credit smart-contract recipients.
    ///      Observed: deposit() from this adapter and depositFor(adapter,...) from an EOA both
    ///      succeed on EVM and emit the correct Transfer(from, systemAddress) event, but Core
    ///      never credits (no ledger entry) and the USDC is absorbed with no refund path.
    ///      Identical calldata with an EOA recipient credits within seconds (both dex routings).
    ///      Plain ERC20 transfer to the USDC system address is not indexed at all.
    ///      Contracts CAN hold Core USDC (Core-side spotSend credits them fine) — only this
    ///      EVM->Core leg is blocked. Before mainnet: verify the mainnet wallet (different
    ///      implementation) credits contracts, or redesign around a HIP-1 stable + Core spot swap.
    ///
    ///      Intended path: approve + CoreDepositWallet.deposit(amount, SPOT_DEX).
    ///      The deposit debits idle now; the Core spot credit lands later, so we record an
    ///      in-transit entry that realAssets() adds back until settlement is proven by age.
    function bridgeToCore(uint256 usdcAmount) external onlyAllocator {
        pruneSettled();
        require(IERC20(asset).approve(usdcDepositWallet, usdcAmount), "approve");
        ICoreDepositWallet(usdcDepositWallet).deposit(usdcAmount, HyperCoreActions.SPOT_DEX);
        uint64 nowL1 = HyperCoreReader.l1BlockNumber();
        pendingToCore.push(PendingDeposit({amount: uint128(usdcAmount), initL1Block: nowL1}));
        emit BridgedToCore(usdcAmount, nowL1);
    }

    /// @notice Bridge USDC from the HyperCore spot account back to this adapter on HyperEVM.
    /// @dev sendAsset (action 13) to the token system address, both legs SPOT_DEX — mirrors
    ///      hyper-evm-lib bridgeToEvm. No in-transit tracking: at queue time the funds are still
    ///      visible in Core spot, and on settlement Core spot drops while EVM idle rises together.
    function bridgeToEvm(uint256 usdcAmount) external onlyAllocator {
        uint64 amountWei = uint64(Decimals.evmToSpotWei(usdcAmount));
        _send(
            HyperCoreActions.sendAsset(
                usdcSystemAddress,
                address(0),
                HyperCoreActions.SPOT_DEX,
                HyperCoreActions.SPOT_DEX,
                usdcCoreToken,
                amountWei
            )
        );
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

    /* ----------------------------- API / agent wallet ------------------------------ */

    /// @notice The most recently approved agent (for transparency; events are the full record).
    address public apiWallet;
    string public apiWalletName;

    /// @notice Authorize an off-chain agent wallet to TRADE this adapter's HyperCore account
    ///         (place/cancel spot & perp orders) via Hyperliquid's API/SDK. Primary execution path.
    /// @dev The agent CANNOT withdraw or move funds — getting USDC back to the vault still requires
    ///      the allocator-gated bridge/deallocate functions. Approving an agent therefore delegates
    ///      only the trading authority the allocator already holds, so it is allocator-gated.
    ///      Once approved, the vault cannot veto the agent's individual trades on-chain — size the
    ///      trust accordingly and use revokeApiWallet() (also curator-callable) as the kill switch.
    function approveApiWallet(address agent, string calldata name) external onlyAllocator {
        apiWallet = agent;
        apiWalletName = name;
        _send(HyperCoreActions.addApiWallet(agent, name));
        emit ApiWalletApproved(agent, name);
    }

    /// @notice Deregister the agent wallet under `name`. Callable by an allocator OR the curator
    ///         (curator gets an emergency kill switch independent of the allocator).
    /// @dev Revocation by approving the zero address for the name — VERIFY semantics on testnet
    ///      before relying on it as a security control.
    function revokeApiWallet(string calldata name) external {
        if (!IVaultV2(parentVault).isAllocator(msg.sender) && msg.sender != IVaultV2(parentVault).curator()) {
            revert NotAllocator();
        }
        if (keccak256(bytes(name)) == keccak256(bytes(apiWalletName))) {
            apiWallet = address(0);
            apiWalletName = "";
        }
        _send(HyperCoreActions.addApiWallet(address(0), name));
        emit ApiWalletRevoked(name);
    }

    /* ----------------------------- Valuation --------------------------------------- */

    /// @inheritdoc IAdapter
    /// @dev Conservative: floors perp equity at zero, adds in-transit deposits so a bridge isn't
    ///      read as a loss, and optionally caps single-read gains. Reads fail closed (revert)
    ///      rather than fabricate a value — the vault freezes (liveness) but never misprices.
    function realAssets() public view returns (uint256) {
        uint256 idle = IERC20(asset).balanceOf(address(this));
        uint256 observed = idle + _perpEquityEvm() + _usdcSpotEvm() + _inTransitToCore();
        return _applyGainCeiling(observed);
    }

    /// @dev USDC still in transit EVM->Core whose settlement is not yet guaranteed by age.
    function _inTransitToCore() internal view returns (uint256 total) {
        uint256 n = pendingToCore.length;
        if (pendingHead == n) return 0; // nothing pending: skip the precompile read
        uint64 current = HyperCoreReader.l1BlockNumber();
        uint64 window = settleWindowBlocks;
        for (uint256 i = pendingHead; i < n; i++) {
            uint64 init = pendingToCore[i].initL1Block;
            uint64 age = current >= init ? current - init : 0;
            if (age <= window) {
                // Entries are block-ordered, so every entry from here on is also within window.
                for (uint256 j = i; j < n; j++) total += pendingToCore[j].amount;
                return total;
            }
        }
    }

    function _applyGainCeiling(uint256 observed) internal view returns (uint256) {
        uint16 bps = maxGainBps;
        if (bps == 0 || netDeposited == 0) return observed;
        uint256 ceiling = netDeposited + (netDeposited * bps) / MAX_BPS;
        return observed > ceiling ? ceiling : observed;
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

    /* ----------------------------- In-flight bookkeeping --------------------------- */

    /// @notice Drop settled in-transit entries from the front. Permissionless; also called on
    ///         each bridgeToCore so the pending set stays bounded by bridges-per-window.
    function pruneSettled() public {
        uint64 current = HyperCoreReader.l1BlockNumber();
        uint64 window = settleWindowBlocks;
        uint256 n = pendingToCore.length;
        uint256 h = pendingHead;
        while (h < n) {
            uint64 init = pendingToCore[h].initL1Block;
            if (current >= init && current - init > window) h++;
            else break;
        }
        pendingHead = h;
    }

    function pendingToCoreLength() external view returns (uint256) {
        return pendingToCore.length;
    }

    function inTransitToCore() external view returns (uint256) {
        return _inTransitToCore();
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

    function _market(bytes memory data) internal pure returns (bytes32) {
        return data.length == 0 ? bytes32(0) : abi.decode(data, (bytes32));
    }

    function _send(bytes memory rawAction) internal {
        CORE_WRITER.sendRawAction(rawAction);
        emit ActionSent(rawAction);
    }
}
