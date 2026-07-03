// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {IAdapter} from "vault-v2/interfaces/IAdapter.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {IERC20} from "vault-v2/interfaces/IERC20.sol";
import {ICoreWriter} from "./interfaces/ICoreWriter.sol";
import {HyperCoreActions} from "./libraries/HyperCoreActions.sol";
import {HyperCoreReader} from "./libraries/HyperCoreReader.sol";
import {Decimals} from "./libraries/Decimals.sol";

/// @title HyperCoreAdapter
/// @notice Morpho Vault v2 adapter that trades spot & perps on HyperCore (Hyperliquid L1) from HyperEVM.
/// @dev Two surfaces, deliberately split because HyperCore settles asynchronously:
///        1. Funding   — allocate()/deallocate(), called only by the vault, move the underlying
///                       between the vault and the adapter's idle EVM balance.
///        2. Trading   — allocator-gated bridging/margin functions plus an agent wallet
///                       (approveApiWallet) for order execution via Hyperliquid's API/SDK.
///      The vault's share price tracks the live position automatically via realAssets().
///
///      FUNDING LEG — the "transit asset" design (probed live on testnet, 2026-06):
///      Native USDC's EVM->Core path (Circle CoreDepositWallet) silently refuses to credit
///      smart-contract recipients on BOTH its routes (spot synthetic-event indexing and the
///      perp-dex CoreWriter forward), and CCTP inherits the same wallet — so a contract can
///      NEVER fund its Core account with native USDC from HyperEVM. The generic HIP-1
///      linked-token mechanism, however, DOES credit contracts: a plain ERC20 transfer to the
///      token's system address (0x2000...0 + core index) credits the SENDER's Core spot account
///      (escrowed in `evmEscrows` until the account exists — hence the coreUserExists gate).
///
///      Therefore the vault's underlying must be a HIP-1 stable with a linked ERC20 (USDT0 on
///      mainnet). Flow in:  transfer underlying -> system address (Core spot credit) ->
///      allocator IOC-swaps to USDC on the TOKEN/USDC spot pair (via the agent or placeOrder)
///      -> transferUsdClass to perp. Flow out is the reverse, exiting with spotSend (action 6,
///      the reference-adapter-proven path) back to the system address.
///
///      Valuation model. realAssets() sums everything observable from EVM:
///        idle underlying (EVM) + in-transit-to-Core + Core spot underlying + Core spot USDC
///        + perp equity. USDC-denominated Core value (spot USDC, perp equity) is counted 1:1
///        in underlying units — acceptable for a USD-stable underlying (USDT0); a priced
///        conversion is a valuation-hardening follow-up. Operations that move value WITHIN
///        the observable set (swaps, class transfers, Core->EVM bridges) are invariant to the
///        sum. The ONLY gap is EVM->Core bridging: the ERC20 transfer debits idle synchronously
///        while the Core credit lands a few L1 blocks later — bridged amounts are added back
///        until their L1-block age proves settlement.
contract HyperCoreAdapter is IAdapter {
    ICoreWriter internal constant CORE_WRITER =
        ICoreWriter(0x3333333333333333333333333333333333333333);

    uint256 internal constant MAX_BPS = 10_000;

    /// @dev USDC is Core token 0 on both mainnet and testnet (verified via tokenInfo).
    uint64 internal constant USDC_CORE_TOKEN = 0;

    address public immutable parentVault;
    address public immutable asset; // vault underlying: a HIP-1 stable with linked ERC20 (USDT0)
    bytes32 public immutable adapterId;

    uint64 public immutable transitCoreToken; // Core token index of the underlying
    address public immutable transitSystemAddress; // 0x2000...0 + transitCoreToken
    /// @dev tokenInfo(transitCoreToken).evmExtraWeiDecimals: evm = wei * 10^extra.
    ///      USDT0/USDC-style tokens: -2 (wei = evm * 100). Verified per token before deploy.
    int8 public immutable transitEvmExtraWeiDecimals;
    uint32 public immutable perpDex; // perp dex index (0 = default)

    /// @dev EVM->Core bridges awaiting settlement. Appended in non-decreasing initL1Block order,
    ///      so once we reach an entry within the settle window, every later one is too (ages
    ///      decrease as index grows). `pendingHead` skips entries already proven settled.
    struct PendingDeposit {
        uint128 amount; // EVM underlying units in transit to Core
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
    error CoreAccountMissing();

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
    ///      route through the vault's timelock; kept immediate for now (see PRODUCTION.md).
    modifier onlyCurator() {
        if (msg.sender != IVaultV2(parentVault).curator()) revert NotCurator();
        _;
    }

    constructor(
        address _parentVault,
        uint64 _transitCoreToken,
        address _transitSystemAddress,
        int8 _transitEvmExtraWeiDecimals,
        uint32 _perpDex,
        uint64 _settleWindowBlocks
    ) {
        parentVault = _parentVault;
        asset = IVaultV2(_parentVault).asset();
        transitCoreToken = _transitCoreToken;
        transitSystemAddress = _transitSystemAddress;
        transitEvmExtraWeiDecimals = _transitEvmExtraWeiDecimals;
        perpDex = _perpDex;
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
        // Underlying has already been transferred in by the vault; it now sits idle until an
        // allocator bridges it to Core. Cap accounting books the inflow as exposure.
        netDeposited += assets;
        return (ids(_market(data)), int256(assets));
    }

    function deallocate(bytes memory data, uint256 assets, bytes4, address)
        external
        onlyVault
        returns (bytes32[] memory, int256)
    {
        // Can only return underlying that an allocator has already bridged back to the EVM side.
        if (IERC20(asset).balanceOf(address(this)) < assets) revert InsufficientIdle();
        netDeposited = assets >= netDeposited ? 0 : netDeposited - assets;
        return (ids(_market(data)), -int256(assets));
    }

    /* ----------------------------- Bridging (allocator-gated) ----------------------- */

    /// @notice Bridge idle underlying from HyperEVM into this adapter's HyperCore spot account
    ///         via the generic HIP-1 linked-token mechanism: a plain ERC20 transfer to the
    ///         token's system address credits the SENDER on Core. Proven for contract senders
    ///         and recipients (unlike the Circle USDC wallet — see contract natspec).
    /// @dev Gated on the Core account existing: funds sent before creation sit in evmEscrows
    ///      (safe but invisible to balances and to realAssets()). Create the account once by
    ///      sending any Core-side dust to this address.
    ///      The transfer debits idle now; the Core credit lands a few L1 blocks later, so an
    ///      in-transit entry keeps realAssets() whole until settlement is proven by age.
    function bridgeToCore(uint256 amount) external onlyAllocator {
        if (!HyperCoreReader.coreUserExists(address(this))) revert CoreAccountMissing();
        pruneSettled();
        require(IERC20(asset).transfer(transitSystemAddress, amount), "transfer failed");
        uint64 nowL1 = HyperCoreReader.l1BlockNumber();
        pendingToCore.push(PendingDeposit({amount: uint128(amount), initL1Block: nowL1}));
        emit BridgedToCore(amount, nowL1);
    }

    /// @notice Bridge underlying from the HyperCore spot account back to this adapter on
    ///         HyperEVM: spotSend (action 6) to the token's system address — the path used by
    ///         the reference mainnet adapter and proven live in our v1 flow.
    /// @dev No in-transit tracking: at queue time the funds are still visible in Core spot, and
    ///      on settlement Core spot drops while EVM idle rises together — the sum is invariant.
    function bridgeToEvm(uint256 amount) external onlyAllocator {
        uint64 amountWei = _evmToWei(amount);
        _send(HyperCoreActions.spotSend(transitSystemAddress, transitCoreToken, amountWei));
    }

    /// @notice Move USD collateral between the spot and perp accounts on HyperCore.
    function transferUsdClass(uint64 ntl, bool toPerp) external onlyAllocator {
        _send(HyperCoreActions.usdClassTransfer(ntl, toPerp));
    }

    /// @notice Place a limit order (on-chain fallback; primary execution is the agent wallet).
    ///         Spot vs perp is determined by `coreAsset` (perp = perp index; spot =
    ///         HyperCoreActions.spotAssetId(pairIndex)). Used notably to IOC-swap the underlying
    ///         to USDC (and back) on its Core spot pair as part of the funding flow.
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
    /// @dev The agent CANNOT move funds to external destinations: `agentSendAsset` is
    ///      protocol-restricted to the master's own accounts ("Agent can only send asset to same
    ///      user or their sub-accounts" — verified live on testnet). It CAN trade and shuffle
    ///      funds between this account's spot/perp/sub-accounts. Getting funds back to the vault
    ///      still requires the allocator-gated bridge/deallocate functions. Approving an agent
    ///      therefore delegates only trading authority, so it is allocator-gated.
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
    /// @dev Revocation by approving the zero address for the name — verified live on testnet
    ///      (extraAgents empties; subsequent agent orders are rejected).
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
    ///      Core USDC (spot + perp equity) counts 1:1 in underlying units (stable-vs-stable);
    ///      a priced conversion is tracked as a valuation-hardening follow-up.
    function realAssets() public view returns (uint256) {
        uint256 idle = IERC20(asset).balanceOf(address(this));
        uint256 observed = idle + _transitSpotEvm() + _usdcSpotEvm() + _perpEquityEvm() + _inTransitToCore();
        return _applyGainCeiling(observed);
    }

    /// @dev Underlying still in transit EVM->Core whose settlement is not yet guaranteed by age.
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

    /// @dev Core spot balance of the underlying, converted wei -> EVM units.
    function _transitSpotEvm() internal view returns (uint256) {
        HyperCoreReader.SpotBalance memory b =
            HyperCoreReader.spotBalance(address(this), transitCoreToken);
        return _weiToEvm(b.total);
    }

    /// @dev Core spot USDC (post-swap trading capital), counted 1:1 in underlying units.
    ///      Skipped when the underlying IS Core USDC (avoids double counting in fork tests).
    function _usdcSpotEvm() internal view returns (uint256) {
        if (transitCoreToken == USDC_CORE_TOKEN) return 0;
        HyperCoreReader.SpotBalance memory b =
            HyperCoreReader.spotBalance(address(this), USDC_CORE_TOKEN);
        return Decimals.spotWeiToEvm(b.total);
    }

    /* ----------------------------- Decimal conversions ------------------------------ */

    /// @dev evm = wei * 10^extra (tokenInfo semantics), so wei = evm / 10^extra.
    function _evmToWei(uint256 evmAmount) internal view returns (uint64) {
        int8 extra = transitEvmExtraWeiDecimals;
        uint256 wei_;
        if (extra <= 0) wei_ = evmAmount * (10 ** uint8(-extra));
        else wei_ = evmAmount / (10 ** uint8(extra));
        require(wei_ > 0 && wei_ <= type(uint64).max, "wei out of range");
        return uint64(wei_);
    }

    function _weiToEvm(uint64 weiAmount) internal view returns (uint256) {
        int8 extra = transitEvmExtraWeiDecimals;
        if (extra <= 0) return uint256(weiAmount) / (10 ** uint8(-extra));
        return uint256(weiAmount) * (10 ** uint8(extra));
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
