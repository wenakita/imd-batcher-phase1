// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IRegistry4626
 * @author 0xakita.eth
 * @notice Registry interface for core 4626 addresses (supports creator, agent, and future ecosystems).
 * @dev Used by vaults, OFTs, and helpers to resolve per-lane ecosystem contracts via registry lookups.
 */
interface IRegistry4626 {
    // =================================
    // STRUCTS
    // =================================

    /**
     * @notice Information about a registered lane token (creator coin or agent token)
     */
    struct TokenInfo {
        address token; // Lane token address (creator coin or agent token)
        string name; // Token name
        string symbol; // Token symbol
        address vault; // Lane vault address (CreatorOVault / AgentOVault)
        address shareOFT; // Lane ShareOFT address
        address wrapper; // Lane vault wrapper address
        address oracle; // Lane oracle address (per-token IOracle4626 price oracle)
        address gaugeController; // Lane gauge controller address (per-token fee distribution)
        address creator; // Creator's address (admin/EOA signer)
        address canonicalWallet; // Canonical smart wallet (ERC-4337 / Coinbase Smart Wallet)
        // Used as: ERC-8004 agent identity, asset holder,
        // lottery prize recipient, and vault owner
        address pool; // Primary liquidity pool
        uint24 poolFee; // Pool fee tier (e.g., 3000 = 0.3%)
        uint256 primaryChainId; // Chain where token originated
        bool isActive; // Active status
        uint256 registeredAt; // Registration timestamp
    }

    /**
     * @notice Chain configuration
     */
    struct ChainConfig {
        uint256 chainId;
        string chainName;
        address wrappedNativeToken;
        string wrappedNativeSymbol;
        address poolManager; // Uniswap V4 PoolManager
        address swapRouter; // UniversalRouter
        address positionManager; // V4 PositionManager
        address quoter; // Quoter
        address chainlinkNativeFeed;
        bool isActive;
    }

    /**
     * @notice LayerZero configuration per chain
     */
    struct LzConfig {
        address endpoint;
        uint32 eid;
        address sendLib;
        address receiveLib;
        address executor;
        address dvn;
        address lzReadDvn;
        address[] optionalDvns;
        uint64 confirmations;
        bool isConfigured;
        bool useCustomOApp;
    }

    /**
     * @notice Per-creator Solana OVault mesh configuration.
     */
    struct OmnichainVaultMeshConfig {
        uint32 solanaEid;
        address hubComposer;
        address assetMeshToken;
        address shareMeshToken;
        bytes32 solanaAssetMint;
        bytes32 solanaSharePeer;
        bool enabled;
    }

    // =================================
    // EVENTS
    // =================================

    event TokenRegistered(
        address indexed token,
        string name,
        string symbol,
        address indexed creator,
        address vault,
        address shareOFT,
        address wrapper
    );

    event TokenUpdated(address indexed token);
    event TokenStatusChanged(address indexed token, bool isActive);
    event CanonicalWalletSet(address indexed token, address indexed wallet);
    event RemoteOFTPeerSet(address indexed token, uint32 indexed chainEid, address remoteOFT);
    event RemoteOFTPeerRemoved(address indexed token, uint32 indexed chainEid);
    event RemoteOFTPeerBytes32Set(address indexed token, uint32 indexed chainEid, bytes32 remoteOFT);
    event RemoteOFTPeerBytes32Removed(address indexed token, uint32 indexed chainEid);
    event OmnichainVaultMeshConfigured(
        address indexed token,
        uint32 indexed solanaEid,
        address hubComposer,
        address assetMeshToken,
        address shareMeshToken,
        bytes32 solanaAssetMint,
        bytes32 solanaSharePeer,
        bool enabled
    );

    event ChainRegistered(uint256 indexed chainId, string chainName);
    event ChainUpdated(uint256 indexed chainId);
    event ChainStatusChanged(uint256 indexed chainId, bool isActive);

    event LayerZeroEndpointUpdated(uint256 indexed chainId, address endpoint);
    event LzConfigUpdated(uint256 indexed chainId);

    event EcosystemContractSet(uint256 indexed chainId, string contractType, address indexed contractAddress);

    // =================================
    // CREATOR COIN MANAGEMENT
    // =================================

    /**
     * @notice Register a new lane token
     * @param _token Lane token address
     * @param _name Token name
     * @param _symbol Token symbol
     * @param _creator Creator's address
     * @param _pool Primary liquidity pool
     * @param _poolFee Pool fee tier
     */
    function registerToken(
        address _token,
        string calldata _name,
        string calldata _symbol,
        address _creator,
        address _pool,
        uint24 _poolFee
    ) external;

    /**
     * @notice Owner correction for a token's creator authority
     */
    function setCreator(address _token, address _creator) external;

    /**
     * @notice Set vault address for a token
     */
    function setVault(address _token, address _vault) external;

    /**
     * @notice Set ShareOFT address for a token
     */
    function setShareOFTForToken(address _token, address _shareOFT) external;

    /**
     * @notice Set wrapper address for a token
     */
    function setWrapperForToken(address _token, address _wrapper) external;

    /**
     * @notice Set oracle address for a token
     */
    function setOracleForToken(address _token, address _oracle) external;

    /**
     * @notice Set gauge controller address for a token
     */
    function setGaugeControllerForToken(address _token, address _gaugeController) external;

    /**
     * @notice Set active status for a token
     */
    function setTokenStatus(address _token, bool _isActive) external;

    /**
     * @notice Set the canonical smart wallet for a creator
     * @dev Unified on-chain identity (ERC-4337 / ERC-8004 / vault owner / lottery recipient).
     *      Auth: registry owner may set/override; otherwise only the token creator may set,
     *      and only as a self-bind (`msg.sender == creator == _wallet`). Replacing a different
     *      non-zero binding requires live rebind enabled and owner (one-shot latch).
     * @param _token Lane token address
     * @param _wallet Canonical smart wallet address
     */
    function setCanonicalWallet(address _token, address _wallet) external;

    /**
     * @notice Configure Solana OVault mesh metadata for a creator coin.
     */
    function setOmnichainVaultMesh(address _token, OmnichainVaultMeshConfig calldata _cfg) external;

    // =================================
    // CREATOR COIN GETTERS
    // =================================

    /**
     * @notice Get full token info
     */
    function getTokenInfo(address _token) external view returns (TokenInfo memory);

    /**
     * @notice Get vault for a token
     */
    function getVaultForToken(address _token) external view returns (address);

    /**
     * @notice Get ShareOFT for a token
     */
    function getShareOFTForToken(address _token) external view returns (address);

    /**
     * @notice Get wrapper for a token
     */
    function getWrapperForToken(address _token) external view returns (address);

    /**
     * @notice Get oracle for a token
     */
    function getOracleForToken(address _token) external view returns (address);

    /**
     * @notice Get gauge controller for a token
     */
    function getGaugeControllerForToken(address _token) external view returns (address);

    /**
     * @notice Reverse-lookup: get the token address for a given ShareOFT
     */
    function getTokenForShareOFT(address _shareOFT) external view returns (address);

    /**
     * @notice Get the canonical smart wallet for a creator
     * @dev Returns address(0) if not set
     */
    function getCanonicalWallet(address _token) external view returns (address);

    /**
     * @notice Reverse-lookup: get the token address for a canonical wallet
     */
    function getTokenForCanonicalWallet(address _wallet) external view returns (address);

    /**
     * @notice Read Solana OVault mesh metadata for a creator coin.
     */
    function getOmnichainVaultMesh(address _token) external view returns (OmnichainVaultMeshConfig memory);

    /**
     * @notice Returns true when this creator coin is currently eligible for Solana deposit routing.
     */
    function isSolanaDepositEligible(address _token) external view returns (bool);

    /**
     * @notice Returns configured Solana asset mint for a creator coin.
     */
    function getSolanaAssetMint(address _token) external view returns (bytes32);

    // =================================
    // REMOTE OFT PEER TRACKING
    // =================================

    /**
     * @notice Set remote OFT peer for EVM-addressable chains.
     */
    function setRemoteOFTPeer(address _token, uint32 _chainEid, address _remoteOFT) external;

    /**
     * @notice Remove remote OFT peer for EVM-addressable chains.
     */
    function removeRemoteOFTPeer(address _token, uint32 _chainEid) external;

    /**
     * @notice Get remote OFT peer for EVM-addressable chains.
     */
    function getRemoteOFTPeer(address _token, uint32 _chainEid) external view returns (address);

    /**
     * @notice Get all remote OFT peer chains for EVM-addressable peers.
     */
    function getRemoteOFTChains(address _token) external view returns (uint32[] memory);

    /**
     * @notice Get all remote EVM OFT peers for a token.
     */
    function getAllRemoteOFTPeers(address _token) external view returns (uint32[] memory eids, address[] memory ofts);

    /**
     * @notice Reverse-lookup token for EVM remote OFT address.
     */
    function getTokenForRemoteOFT(address _remoteOFT) external view returns (address);

    /**
     * @notice Set remote OFT peer for non-EVM chains using bytes32 identity (e.g., Solana pubkey).
     */
    function setRemoteOFTPeerBytes32(address _token, uint32 _chainEid, bytes32 _remoteOFT) external;

    /**
     * @notice Remove remote bytes32 OFT peer mapping.
     */
    function removeRemoteOFTPeerBytes32(address _token, uint32 _chainEid) external;

    /**
     * @notice Get remote bytes32 OFT peer.
     */
    function getRemoteOFTPeerBytes32(address _token, uint32 _chainEid) external view returns (bytes32);

    /**
     * @notice Get all chain EIDs with bytes32 remote peers.
     */
    function getRemoteOFTChainsBytes32(address _token) external view returns (uint32[] memory);

    /**
     * @notice Get all bytes32 remote OFT peers for a token.
     */
    function getAllRemoteOFTPeersBytes32(address _token) external view returns (uint32[] memory eids, bytes32[] memory peers);

    /**
     * @notice Reverse-lookup token for bytes32 remote OFT identity.
     */
    function getTokenForRemoteOFTBytes32(bytes32 _remoteOFT) external view returns (address);

    /**
     * @notice Get all registered tokens
     */
    function getAllTokens() external view returns (address[] memory);

    /**
     * @notice Check if a token is registered
     */
    function isTokenRegistered(address _token) external view returns (bool);

    /**
     * @notice Check if a token is registered AND active
     * @dev Returns false if not registered or if deactivated
     */
    function isTokenActive(address _token) external view returns (bool);

    // =================================
    // CHAIN CONFIGURATION
    // =================================

    /**
     * @notice Register a new chain
     */
    function registerChain(uint256 _chainId, string calldata _chainName, address _wrappedNativeToken, bool _isActive)
        external;

    /**
     * @notice Set DEX infrastructure for a chain
     */
    function setDexInfrastructure(
        uint256 _chainId,
        address _poolManager,
        address _swapRouter,
        address _positionManager,
        address _quoter
    ) external;

    /**
     * @notice Set chain active status
     */
    function setChainStatus(uint256 _chainId, bool _isActive) external;

    /**
     * @notice Get chain configuration
     */
    function getChainConfig(uint256 _chainId) external view returns (ChainConfig memory);

    /**
     * @notice Get all supported chains
     */
    function getSupportedChains() external view returns (uint256[] memory);

    /**
     * @notice Get current chain ID
     */
    function getCurrentChainId() external view returns (uint256);

    /**
     * @notice Check if chain is supported
     */
    function isChainSupported(uint256 _chainId) external view returns (bool);

    // =================================
    // LAYERZERO CONFIGURATION
    // =================================

    /**
     * @notice Set LayerZero endpoint for a chain
     */
    function setLayerZeroEndpoint(uint256 _chainId, address _endpoint) external;

    /**
     * @notice LayerZero endpoint stored for `_chainId`.
     * @dev Reverts when that chain has no endpoint. Base is pinned in the constructor.
     *      There is no fallback to the canonical endpoint for other chains.
     */
    function getLayerZeroEndpoint(uint256 _chainId) external view returns (address);

    /**
     * @notice Set chain ID to LayerZero EID mapping
     */
    function setChainIdToEid(uint256 _chainId, uint32 _eid) external;

    /**
     * @notice Get EID for a chain ID
     */
    function getEidForChainId(uint256 _chainId) external view returns (uint32);

    /**
     * @notice Get chain ID for an EID
     */
    function getChainIdForEid(uint32 _eid) external view returns (uint256);

    /**
     * @notice Get full LZ config for a chain
     */
    function getLzConfig(uint256 _chainId) external view returns (LzConfig memory);

    /**
     * @notice Get effective LZ config (custom or default)
     */
    function getEffectiveLzConfig(uint256 _chainId) external view returns (LzConfig memory);

    // =================================
    // ECOSYSTEM CONTRACTS
    // =================================

    /**
     * @notice Set lottery manager for a chain
     */
    function setLotteryManager(uint256 _chainId, address _manager) external;

    /**
     * @notice Get lottery manager for a chain
     */
    function getLotteryManager(uint256 _chainId) external view returns (address);

    /**
     * @notice Set gauge controller for a chain
     */
    function setGaugeController(uint256 _chainId, address _controller) external;

    /**
     * @notice Get gauge controller for a chain
     */
    function getGaugeController(uint256 _chainId) external view returns (address);

    /**
     * @notice Set gas reserve for a chain
     */
    function setGasReserve(uint256 _chainId, address _reserve) external;

    /**
     * @notice Get gas reserve for a chain
     */
    function getGasReserve(uint256 _chainId) external view returns (address);

    // =================================
    // CHAIN LOOKUPS
    // =================================

    /**
     * @notice Get wrapped native token for a chain
     */
    function getWrappedNativeToken(uint256 _chainId) external view returns (address);

    /**
     * @notice Get pool manager for a chain
     */
    function getPoolManager(uint256 _chainId) external view returns (address);

    /**
     * @notice Get swap router for a chain
     */
    function getSwapRouter(uint256 _chainId) external view returns (address);

    /**
     * @notice Check if this is the hub chain
     */
    function isHubChain() external view returns (bool);

    /**
     * @notice Get hub chain ID
     */
    function hubChainId() external view returns (uint256);

    /**
     * @notice Get hub chain EID
     */
    function hubChainEid() external view returns (uint32);

    // =================================
    // VAULT KIND / LANE INTEGRATION META
    // =================================
    // `AgentIntegrationMeta` is a historical name for product-lane metadata (creator or agent).
    // Rename to LaneIntegrationMeta only on a future registry epoch.
    // `setAgentIntegrationMeta` is authorized-factory-or-owner (same gate as `registerToken`).

    enum VaultKind {
        Creator,
        Agent
    }

    struct AgentIntegrationMeta {
        VaultKind vaultKind;
        address nativeAgentVault;
        address taxRecipient;
        address taxAccountingAdapter;
        address pairToken;
        address uniswapV2Pair;
        bytes32 implementationFingerprint;
    }

    event AgentIntegrationMetaSet(address indexed token, VaultKind vaultKind);

    /// @notice Set lane meta for `token`. Caller must be registry owner or an authorized factory.
    /// @dev One-shot by default (SCAN-M3). Replacing an existing meta requires owner + live rebind.
    function setAgentIntegrationMeta(address token, AgentIntegrationMeta calldata meta) external;

    function getAgentIntegrationMeta(address token) external view returns (AgentIntegrationMeta memory);

    function getVaultKind(address token) external view returns (VaultKind);
}

