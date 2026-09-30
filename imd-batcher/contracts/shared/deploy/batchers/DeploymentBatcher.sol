// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IRegistry4626} from "@4626/shared/interfaces/core/IRegistry4626.sol";
import {IAgentGaugeController} from "@4626/agent/interfaces/IAgentGaugeController.sol";
import {IAgentTokenV4} from "@4626/agent/interfaces/IAgentTokenV4.sol";
import {ICreatorGaugeController} from "@4626/creator/interfaces/ICreatorGaugeController.sol";
import {IOVault4626} from "@4626/shared/interfaces/vault/IOVault4626.sol";
import {IOVaultWrapper4626} from "@4626/shared/interfaces/vault/IOVaultWrapper4626.sol";
import {IShareOFT4626} from "@4626/shared/interfaces/vault/IShareOFT4626.sol";
import {ITradeFeeCollector4626} from "@4626/shared/interfaces/revenue/ITradeFeeCollector4626.sol";
import {IAjnaPool, IAjnaPoolFactory} from "@4626/shared/interfaces/external/IAjnaPool.sol";
import {LinearVesting4626} from "@4626/shared/distribution/LinearVesting4626.sol";
import {IOFT, SendParam, MessagingFee, OFTReceipt} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {AkitaHonorLaunchInventory} from "@4626/shared/deploy/AkitaHonorLaunchInventory.sol";

interface IUniversalCreate2DeployerFromStore {
    function deploy(bytes32 salt, bytes32 codeId, bytes calldata constructorArgs) external returns (address addr);
    function computeAddress(bytes32 salt, bytes32 initCodeHash) external view returns (address);
    function store() external view returns (address);
    function authorizedDeployers(address deployer) external view returns (bool);
}

interface IUniversalBytecodeStoreView {
    function get(bytes32 codeId) external view returns (bytes memory);
    function pointers(bytes32 codeId) external view returns (address);
}

/// @dev AUDIT-2026-07-08-NEW-H — phase modules consult the batcher shell for codeId allowlist.
interface IDeploymentBatcherCodeAllowlist {
    function requireApprovedCodeId(bytes32 codeId) external view;
}

interface IApprovedV4HooksRegistryAdmin {
    function setHookApproval(address hook, bool approved) external;
    function transferOwnership(address newOwner) external;
}

interface IUniV4ConfigurableStrategy {
    function configurePool(address _poolManager, address _positionManager, address _permit2, PoolKey calldata _poolKey)
        external;
    function transferOwnership(address newOwner) external;
}

interface IOVaultLPManagerMesh is IUniV4ConfigurableStrategy {
    function setTwapOracle(address _oracle) external;
    function setManager(address _manager, bool _status) external;
    function setVault(address _vault) external;
}

interface ICCALaunchArmMesh {
    function getLifecycleStatus()
        external
        view
        returns (
            uint8 phase,
            address auction,
            bool isGraduated,
            bool auctionWindowOpen,
            bool claimOpen,
            bool currencySwept,
            bool unsoldSwept,
            bool migrated,
            bool failedFinalized,
            uint64 startBlock,
            uint64 endBlock,
            uint64 claimBlock,
            uint64 migrationBlock,
            uint64 sweepBlock,
            uint256 lpReserveAmount,
            uint256 clearingPrice,
            uint256 currencyRaised
        );
    function lpManager() external view returns (address);
    function setLpManager(address _lpManager) external;
    function getPoolKey() external view returns (PoolKey memory);
}

interface IDeploymentBatcherShareMesh {
    function protocolTreasury() external view returns (address);
}

contract DeploymentBatcherPhase3Helper {
    uint24 internal constant V3_FEE_TIER = 3000;
    // Charm managerFee uses 1e6 precision (100% = 1_000_000).
    uint24 internal constant CHARM_MANAGER_FEE_PIPS = 160_000; // 16%
    uint24 internal constant CHARM_DEFAULT_PROTOCOL_FEE_PIPS = 10_000; // 1%
    int24 internal constant CHARM_MIN_TICK_MOVE = 10;
    int24 internal constant CHARM_MAX_TWAP_DEVIATION = 500;
    uint32 internal constant CHARM_TWAP_DURATION = 300;
    // 125% min collateral ratio for Charm→Ajna borrow backstop (matches integration tests).
    uint256 internal constant CHARM_AJNA_MIN_COLLATERAL_RATIO_BPS = 12_500;
    // Finite Charm→Ajna borrow caps (owner may raise later via setAjnaBorrowConfig).
    // Prevents unlimited drain of sibling Ajna sleeve / external quote liquidity.
    uint256 internal constant CHARM_AJNA_MAX_DEBT = 100_000 ether;
    uint256 internal constant CHARM_AJNA_MAX_BORROW_PER_WITHDRAW = 10_000 ether;

    address internal constant CHARM_FACTORY = 0x5B7B8b487D05F77977b7ABEec5F922925B9b2aFa;
    address internal constant CHARM_FACTORY_GOVERNANCE = 0x424cdd9021AF88A86C76b245e24583f9a71e32a1;
    address internal constant CHARM_FACTORY_GOVERNANCE_LEGACY = 0x94D85f9E8707fd8955D36173Ee48138E972609c6;

    error NotBatcher();
    error NotOwner();
    error InvalidCodeId();
    error Phase3ManagementMismatch(address expected, address actual);
    /// @notice ODA-464-F05: Phase3 creatorToken must match vault.asset().
    error Phase3AssetMismatch(address expectedAsset, address creatorToken);
    error MissingInitialSqrtPriceX96();
    error V3PoolMissing();
    error CharmFactoryGovernanceMismatch(address expected, address actual);
    error CharmFactoryProtocolFeeMismatch(uint256 expected, uint256 actual);
    error CharmVaultManagerMismatch(address expected, address actual);
    error Phase3HelperLostAdmin();
    error MissingCreatorOracleForSynergy();
    error ZeroAddress();
    error InvalidWeight();
    error AjnaPoolCollateralNotUsdc(address collateral);
    error AjnaPoolQuoteMismatch(address quote, address expected);

    IUniversalCreate2DeployerFromStore public immutable create2Deployer;
    address public immutable protocolTreasury;
    address public immutable protocolAutomation;
    address public immutable usdc;
    address public immutable uniswapV3Factory;
    address public immutable uniswapRouter;
    address public immutable ajnaFactory;
    address public immutable batcher;

    constructor(
        address _create2Deployer,
        address _protocolTreasury,
        address _protocolAutomation,
        address _usdc,
        address _uniswapV3Factory,
        address _uniswapRouter,
        address _ajnaFactory,
        address _batcher
    ) {
        // FIX: L-02 (4626-350) — CHARM_FACTORY / CHARM_FACTORY_GOVERNANCE
        // addresses above are hardcoded Base-mainnet values; deploying this
        // helper on any other chain would silently call into a non-existent
        // contract (or, worse, an attacker-controlled address if the same
        // slot happens to be occupied). Refuse to deploy anywhere except
        // Base mainnet (chainid 8453) so the invariant is enforced at
        // construction time rather than at first use.
        require(block.chainid == 8453, "Phase3Helper: Base only");
        create2Deployer = IUniversalCreate2DeployerFromStore(_create2Deployer);
        protocolTreasury = _protocolTreasury;
        if (_protocolAutomation == address(0)) revert ZeroAddress();
        protocolAutomation = _protocolAutomation;
        usdc = _usdc;
        uniswapV3Factory = _uniswapV3Factory;
        uniswapRouter = _uniswapRouter;
        ajnaFactory = _ajnaFactory;
        if (_batcher == address(0)) revert ZeroAddress();
        batcher = _batcher;
    }

    function deployPhase3Strategies(
        DeploymentBatcher.Phase3Params calldata params,
        DeploymentBatcher.StrategyCodeIds calldata codeIds,
        bytes32 baseSalt
    ) external returns (DeploymentBatcher.Phase3Result memory out) {
        if (msg.sender != batcher) revert NotBatcher();
        if (params.creatorToken == address(0) || params.owner == address(0) || params.vault == address(0)) {
            revert ZeroAddress();
        }
        if (IOwnableView(params.vault).owner() != params.owner) revert NotOwner();
        if (ICreatorOVaultManagementView(params.vault).management() != batcher) {
            revert Phase3ManagementMismatch(batcher, ICreatorOVaultManagementView(params.vault).management());
        }
        // ODA-464-F05: bind strategy pipeline asset to the vault's actual underlying.
        address vaultAsset = ICreatorOVaultAssetView(params.vault).asset();
        if (vaultAsset != params.creatorToken) {
            revert Phase3AssetMismatch(vaultAsset, params.creatorToken);
        }
        if (params.solanaWeightBps != 0) revert InvalidWeight();
        if (params.charmWeightBps > 10_000 || params.ajnaWeightBps > 10_000) revert InvalidWeight();
        uint256 totalProductiveWeight = params.charmWeightBps + params.ajnaWeightBps;
        if (totalProductiveWeight == 0 || totalProductiveWeight > 10_000) revert InvalidWeight();
        if (params.charmWeightBps != 0) {
            if (codeIds.charmAlphaVaultDeploy == bytes32(0) || codeIds.charmStrategy4626 == bytes32(0)) {
                revert InvalidCodeId();
            }
            IDeploymentBatcherCodeAllowlist(batcher).requireApprovedCodeId(codeIds.charmAlphaVaultDeploy);
            IDeploymentBatcherCodeAllowlist(batcher).requireApprovedCodeId(codeIds.charmStrategy4626);
        }
        if (params.ajnaWeightBps != 0) {
            if (
                codeIds.ajnaVaultAuth == bytes32(0) || codeIds.ajnaVault == bytes32(0)
                    || codeIds.erc4626StrategyAdapter == bytes32(0)
            ) {
                revert InvalidCodeId();
            }
            IDeploymentBatcherCodeAllowlist(batcher).requireApprovedCodeId(codeIds.ajnaVaultAuth);
            IDeploymentBatcherCodeAllowlist(batcher).requireApprovedCodeId(codeIds.ajnaVault);
            IDeploymentBatcherCodeAllowlist(batcher).requireApprovedCodeId(codeIds.erc4626StrategyAdapter);
        }

        address v3Pool = IUniswapV3Factory(uniswapV3Factory).getPool(params.creatorToken, usdc, V3_FEE_TIER);
        if (v3Pool == address(0)) {
            if (params.initialSqrtPriceX96 == 0) revert MissingInitialSqrtPriceX96();
            v3Pool = IUniswapV3Factory(uniswapV3Factory).createPool(params.creatorToken, usdc, V3_FEE_TIER);
            if (v3Pool == address(0)) revert V3PoolMissing();
            IUniswapV3Pool(v3Pool).initialize(params.initialSqrtPriceX96);
        }
        out.v3Pool = v3Pool;

        bool wireCharmAjnaSynergy = params.charmWeightBps != 0 && params.ajnaWeightBps != 0;
        address ajnaPool = address(0);
        if (wireCharmAjnaSynergy || params.ajnaWeightBps != 0) {
            ajnaPool = _resolveAjnaPool(params.creatorToken);
        }

        // AutoLiquidityV4 (Charm-replacement V4 LP) is NOT part of this Phase-3
        // pipeline. Greenfield `v4LpWeightBps` is 0 — deploy via
        // `StrategyDeploymentBatcher.deployAutoLiquidityV4` only when a
        // post-deploy `v4_active_lp` entitlement is active. Do not remove Charm.

        // Charm active LP is an OPT-IN strategy gated behind the
        // `charm_active_lp` creator-feature activation ($100 USDC, enforced
        // off-chain by the deploy session). If the creator did not pay,
        // the outer batcher passes `charmWeightBps == 0` and we skip the
        // entire Charm pipeline (no factory call, no strategy deploy, no
        // addStrategy on the vault). Return zero addresses so downstream
        // callers can detect the skip. See docs/operations/creator-strategy-features.md.
        if (params.charmWeightBps != 0) {
            (out.charmVault, out.charmStrategy) =
                _deployCharmPipeline(params, codeIds, baseSalt, v3Pool, wireCharmAjnaSynergy);
        }

        // Ajna lending sleeve is an OPT-IN strategy gated behind the
        // `ajna_sleeve` creator-feature activation. Same skip pattern
        // as Charm above.
        if (params.ajnaWeightBps != 0) {
            bytes32 ajnaAuthSalt = _saltFor(baseSalt, "ajnaVaultAuth");
            out.ajnaVaultAuth = create2Deployer.deploy(ajnaAuthSalt, codeIds.ajnaVaultAuth, abi.encode(address(this)));

            if (params.ajnaBufferRatioBps != 0) {
                IAjnaVaultAuthConfigurator(out.ajnaVaultAuth).setBufferRatio(params.ajnaBufferRatioBps);
            }
            if (params.ajnaMinBucketIndex != 0) {
                IAjnaVaultAuthConfigurator(out.ajnaVaultAuth).setMinBucketIndex(params.ajnaMinBucketIndex);
            }
            if (params.ajnaKeeper != address(0)) {
                IAjnaVaultAuthConfigurator(out.ajnaVaultAuth).setKeeper(params.ajnaKeeper, true);
            }
            // Always authorize the hot automation Safe as an Ajna keeper so emergency
            // inner.moveToBuffer / buffer drains do not need a post-deploy setKeeper.
            // params.ajnaKeeper remains the Keepr EOA (can coexist).
            IAjnaVaultAuthConfigurator(out.ajnaVaultAuth).setKeeper(protocolAutomation, true);

            // Arm toll/tax at zero so later fee changes require the 24h timelock.
            IAjnaVaultAuthConfigurator(out.ajnaVaultAuth).setToll(0);
            IAjnaVaultAuthConfigurator(out.ajnaVaultAuth).setTax(0);

            bytes32 ajnaVaultSalt = _saltFor(baseSalt, "ajnaVault");
            bytes memory ajnaVaultArgs = abi.encode(
                ajnaPool, params.creatorToken, params.ajnaVaultName, params.ajnaVaultSymbol, out.ajnaVaultAuth
            );
            out.ajnaVault = create2Deployer.deploy(ajnaVaultSalt, codeIds.ajnaVault, ajnaVaultArgs);

            bytes32 ajnaSalt = _saltFor(baseSalt, "ajnaStrategyAdapter");
            bytes memory ajnaArgs = abi.encode(params.vault, out.ajnaVault, address(this));
            out.ajnaStrategy = create2Deployer.deploy(ajnaSalt, codeIds.erc4626StrategyAdapter, ajnaArgs);
            IERC4626StrategyAdapterAdmin(out.ajnaStrategy).setIdleBufferBps(0);
            IAjnaVaultAuthConfigurator(out.ajnaVaultAuth).setSwapper(out.ajnaStrategy);
            IOwnableTransfer(out.ajnaStrategy).transferOwnership(protocolTreasury);
            // FIX: F-21 — verify this helper is still admin before transferring, to fail explicitly
            // instead of silently leaving auth locked to this helper address
            if (!IAjnaVaultAuthConfigurator(out.ajnaVaultAuth).isAdmin(address(this))) revert Phase3HelperLostAdmin();
            // Protocol automation Safe operates Ajna (setMinBucketIndex); treasury keeps adapter ownership only.
            // Two-step handoff: nominate here; Safe must call acceptAdmin() to complete.
            IAjnaVaultAuthConfigurator(out.ajnaVaultAuth).transferAdmin(protocolAutomation);
        }

        if (wireCharmAjnaSynergy) {
            address oracle = _resolveCreatorOracle(params.creatorToken);
            if (oracle == address(0)) revert MissingCreatorOracleForSynergy();
            _wireCharmAjnaSynergy(out.charmStrategy, ajnaPool, oracle);
            IOwnableTransfer(out.charmStrategy).transferOwnership(protocolTreasury);
        }

        // Solana share liquidity is seeded via the 30% ShareOFT auto-bridge at
        // finalizePhase2 (Pipe A / solana_ovault_mesh).
        if (params.solanaWeightBps != 0) revert InvalidWeight();
    }

    function _resolveAjnaPool(address creatorToken) internal returns (address ajnaPool) {
        bytes32 subsetHash = IAjnaPoolFactory(ajnaFactory).ERC20_NON_SUBSET_HASH();
        ajnaPool = IAjnaPoolFactory(ajnaFactory).deployedPools(subsetHash, usdc, creatorToken);
        if (ajnaPool == address(0)) {
            uint256 ajnaInterestRate = 5e16;
            uint256 minRate = IAjnaPoolFactory(ajnaFactory).MIN_RATE();
            uint256 maxRate = IAjnaPoolFactory(ajnaFactory).MAX_RATE();
            if (ajnaInterestRate < minRate) ajnaInterestRate = minRate;
            if (ajnaInterestRate > maxRate) ajnaInterestRate = maxRate;
            ajnaPool = IAjnaPoolFactory(ajnaFactory).deployPool(usdc, creatorToken, ajnaInterestRate);
        }
        address collateral = IAjnaPool(ajnaPool).collateralAddress();
        address quote = IAjnaPool(ajnaPool).quoteTokenAddress();
        if (collateral != usdc) revert AjnaPoolCollateralNotUsdc(collateral);
        if (quote != creatorToken) revert AjnaPoolQuoteMismatch(quote, creatorToken);
    }

    function _resolveCreatorOracle(address creatorToken) internal view returns (address oracle) {
        address reg = IDeploymentBatcherRegistryAccess(batcher).registry();
        oracle = IRegistry4626(reg).getTokenInfo(creatorToken).oracle;
    }

    function _wireCharmAjnaSynergy(address charmStrategy, address ajnaPool, address oracle) internal {
        ICharmStrategy4626(charmStrategy).setAssetOracle(oracle);
        ICharmStrategy4626(charmStrategy).setAjnaPool(ajnaPool);
        ICharmStrategy4626(charmStrategy).setAjnaBorrowConfig(
            true,
            CHARM_AJNA_MAX_DEBT,
            CHARM_AJNA_MAX_BORROW_PER_WITHDRAW,
            CHARM_AJNA_MIN_COLLATERAL_RATIO_BPS,
            0,
            0
        );
    }

    function _deployCharmPipeline(
        DeploymentBatcher.Phase3Params calldata params,
        DeploymentBatcher.StrategyCodeIds calldata codeIds,
        bytes32 baseSalt,
        address v3Pool,
        bool deferOwnershipTransfer
    ) internal returns (address charmVault, address charmStrategy) {
        _enforceCharmFactoryGovernance(params.expectedCharmProtocolFeePips);
        charmVault = ICharmFactory(CHARM_FACTORY)
            .createVault(
                ICharmFactory.VaultParams({
                pool: v3Pool,
                manager: protocolAutomation,
                managerFee: CHARM_MANAGER_FEE_PIPS,
                rebalanceDelegate: params.owner,
                maxTotalSupply: type(uint256).max,
                baseThreshold: 3000,
                limitThreshold: 6000,
                fullRangeWeight: 0,
                period: 1800,
                minTickMove: CHARM_MIN_TICK_MOVE,
                maxTwapDeviation: CHARM_MAX_TWAP_DEVIATION,
                twapDuration: CHARM_TWAP_DURATION,
                name: params.charmVaultName,
                symbol: params.charmVaultSymbol
            })
            );
        _enforceCharmVaultManager(charmVault, protocolAutomation);

        bytes32 charmStratSalt = _saltFor(baseSalt, "charmStrategyV3");
        bytes memory charmStratArgs =
            abi.encode(params.vault, params.creatorToken, usdc, uniswapRouter, charmVault, v3Pool, address(this));
        charmStrategy = create2Deployer.deploy(charmStratSalt, codeIds.charmStrategy4626, charmStratArgs);
        ICharmStrategy4626(charmStrategy).initializeApprovals();
        if (!deferOwnershipTransfer) {
            IOwnableTransfer(charmStrategy).transferOwnership(protocolTreasury);
        }
    }

    function _saltFor(bytes32 baseSalt, string memory label) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(baseSalt, label));
    }

    function _enforceCharmFactoryGovernance(uint24 expectedProtocolFeePipsConfig) internal view {
        try ICharmFactory(CHARM_FACTORY).governance() returns (address governance) {
            if (!_isAllowedCharmFactoryGovernance(governance)) {
                revert CharmFactoryGovernanceMismatch(CHARM_FACTORY_GOVERNANCE, governance);
            }
        } catch {
            revert CharmFactoryGovernanceMismatch(CHARM_FACTORY_GOVERNANCE, address(0));
        }

        uint24 expectedProtocolFeePips =
            expectedProtocolFeePipsConfig == 0 ? CHARM_DEFAULT_PROTOCOL_FEE_PIPS : expectedProtocolFeePipsConfig;
        try ICharmFactory(CHARM_FACTORY).protocolFee() returns (uint24 protocolFeePips) {
            if (protocolFeePips != expectedProtocolFeePips) {
                revert CharmFactoryProtocolFeeMismatch(expectedProtocolFeePips, protocolFeePips);
            }
        } catch {
            revert CharmFactoryProtocolFeeMismatch(expectedProtocolFeePips, type(uint256).max);
        }
    }

    function _enforceCharmVaultManager(address charmVault, address expectedManager) internal view {
        try ICharmVaultManager(charmVault).manager() returns (address manager) {
            if (manager != expectedManager) {
                revert CharmVaultManagerMismatch(expectedManager, manager);
            }
        } catch {
            revert CharmVaultManagerMismatch(expectedManager, address(0));
        }
    }

    function _isAllowedCharmFactoryGovernance(address governance) internal pure returns (bool) {
        return governance == CHARM_FACTORY_GOVERNANCE || governance == CHARM_FACTORY_GOVERNANCE_LEGACY;
    }
}

contract DeploymentBatcherShareMeshHelper {
    error NotBatcher();
    error NotOwner();
    error InvalidCodeId();
    error ZeroAddress();
    error ShareMeshNotReady();
    error ShareMeshAlreadyDeployed();

    IUniversalCreate2DeployerFromStore public immutable create2Deployer;
    address public immutable poolManager;
    address public immutable permit2;
    address public immutable batcher;

    constructor(address _create2Deployer, address _poolManager, address _permit2, address _batcher) {
        create2Deployer = IUniversalCreate2DeployerFromStore(_create2Deployer);
        poolManager = _poolManager;
        permit2 = _permit2;
        if (_batcher == address(0)) revert ZeroAddress();
        batcher = _batcher;
    }

    function deployShareMeshLpManager(
        DeploymentBatcher.ShareMeshDeployParams calldata params,
        DeploymentBatcher.ShareMeshCodeIds calldata codeIds,
        bytes32 baseSalt
    ) external returns (DeploymentBatcher.ShareMeshDeployResult memory out) {
        if (msg.sender != batcher) revert NotBatcher();
        if (
            params.creatorToken == address(0) || params.shareOFT == address(0) || params.vault == address(0)
                || params.ccaLaunchArm == address(0) || params.oracle == address(0) || params.owner == address(0)
                || params.positionManager == address(0) || params.poolHook == address(0)
                || params.registryOwner == address(0) || params.keeperManager == address(0)
        ) {
            revert ZeroAddress();
        }
        if (IOwnableView(params.vault).owner() != params.owner) revert NotOwner();
        if (codeIds.approvedV4HooksRegistry == bytes32(0) || codeIds.lpManager == bytes32(0)) {
            revert InvalidCodeId();
        }
        IDeploymentBatcherCodeAllowlist(batcher).requireApprovedCodeId(codeIds.approvedV4HooksRegistry);
        IDeploymentBatcherCodeAllowlist(batcher).requireApprovedCodeId(codeIds.lpManager);

        ICCALaunchArmMesh cca = ICCALaunchArmMesh(params.ccaLaunchArm);
        (,, bool isGraduated,,, bool currencySwept,, bool migrated,,,,,,,,,) = cca.getLifecycleStatus();
        if (!isGraduated || !currencySwept || !migrated) revert ShareMeshNotReady();
        if (cca.lpManager() != address(0)) revert ShareMeshAlreadyDeployed();

        bytes32 registrySalt = _saltFor(baseSalt, "shareMeshHookRegistry");
        out.hookRegistry =
            create2Deployer.deploy(registrySalt, codeIds.approvedV4HooksRegistry, abi.encode(address(this)));

        uint256 hooksLength = params.hooksToApprove.length;
        for (uint256 i = 0; i < hooksLength; i++) {
            IApprovedV4HooksRegistryAdmin(out.hookRegistry).setHookApproval(params.hooksToApprove[i], true);
        }
        IApprovedV4HooksRegistryAdmin(out.hookRegistry).setHookApproval(params.poolHook, true);

        bytes32 managerSalt = _saltFor(baseSalt, "shareMeshOVaultLPManager");
        out.lpManager = create2Deployer.deploy(
            managerSalt,
            codeIds.lpManager,
            abi.encode(params.shareOFT, address(0), params.vault, address(this), out.hookRegistry)
        );

        PoolKey memory poolKey = cca.getPoolKey();
        IOVaultLPManagerMesh(out.lpManager).configurePool(poolManager, params.positionManager, permit2, poolKey);
        IOVaultLPManagerMesh(out.lpManager).setTwapOracle(params.oracle);
        IOVaultLPManagerMesh(out.lpManager).setManager(params.keeperManager, true);
        IOVaultLPManagerMesh(out.lpManager).setVault(params.vault);

        address treasury = IDeploymentBatcherShareMesh(batcher).protocolTreasury();
        IOVaultLPManagerMesh(out.lpManager).transferOwnership(treasury);
        IApprovedV4HooksRegistryAdmin(out.hookRegistry).transferOwnership(params.registryOwner);

        cca.setLpManager(out.lpManager);
    }

    function _saltFor(bytes32 baseSalt, string memory label) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(baseSalt, label));
    }
}

contract DeploymentBatcherUtilsHelper {
    function toLower(string calldata input) external pure returns (string memory) {
        bytes memory b = bytes(input);
        for (uint256 i = 0; i < b.length; i++) {
            uint8 c = uint8(b[i]);
            if (c >= 65 && c <= 90) {
                b[i] = bytes1(c + 32);
            }
        }
        return string(b);
    }

    function toUpper(string calldata input) external pure returns (string memory) {
        bytes memory b = bytes(input);
        for (uint256 i = 0; i < b.length; i++) {
            uint8 c = uint8(b[i]);
            if (c >= 97 && c <= 122) {
                b[i] = bytes1(c - 32);
            }
        }
        return string(b);
    }

    function deriveBaseSalt(address creatorToken, address owner, uint256 chainId, string calldata version)
        external
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(creatorToken, owner, chainId, "4626:deploy:", version));
    }

    function saltFor(bytes32 baseSalt, string calldata label) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(baseSalt, label));
    }

    /// @notice ShareOFT CREATE2 salt scoped per creator token.
    /// @dev AUDIT-2026-07-08-C01: previous salt was `owner + symbol + version` only, so two
    ///      tokens under the same owner/symbol/version collided and phase-1 could adopt
    ///      and re-wire a foreign ShareOFT. Include `creatorToken` so each vault gets a
    ///      unique salt while remote deploys of the same token still share address parity.
    function deriveShareOftSalt(
        address creatorToken,
        address owner,
        string calldata shareSymbolLower,
        string calldata version
    ) external pure returns (bytes32) {
        bytes32 base = keccak256(abi.encodePacked(creatorToken, owner, shareSymbolLower));
        return keccak256(abi.encodePacked(base, "CreatorShareOFT:", version));
    }

    /// @dev Legacy salt (pre C-01). Kept only for read/debug of historical deploys.
    function deriveShareOftSaltLegacy(address owner, string calldata shareSymbolLower, string calldata version)
        external
        pure
        returns (bytes32)
    {
        bytes32 base = keccak256(abi.encodePacked(owner, shareSymbolLower));
        return keccak256(abi.encodePacked(base, "CreatorShareOFT:", version));
    }

    function phase1ParamsHash(
        address creatorToken,
        address owner,
        string calldata vaultName,
        string calldata vaultSymbol,
        string calldata shareName,
        string calldata shareSymbol,
        string calldata version,
        DeploymentBatcher.VaultKind vaultKind
    ) external pure returns (bytes32) {
        return keccak256(
            abi.encode(creatorToken, owner, vaultName, vaultSymbol, shareName, shareSymbol, version, vaultKind)
        );
    }

    function phase1CodeIdsHash(bytes32 vault, bytes32 wrapper, bytes32 shareOFT, bytes32 oftBootstrap)
        external
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(vault, wrapper, shareOFT, oftBootstrap));
    }
}

interface IUniversalBytecodeStore {
    function get(bytes32 codeId) external view returns (bytes memory);
}

interface IOwnableView {
    function owner() external view returns (address);
}

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

interface ICCALaunchArm {
    function setApprovedLauncher(address launcher, bool approved) external;
    function setOracleConfig(address _oracle, address _poolManager, address _taxHook, address _feeRecipient) external;
    function setLaunchDiscountBps(uint16 _discountBps) external;
    function setLaunchTickSpacingBps(uint16 _tickSpacingBps) external;
    function setLaunchBlockTimeSeconds(uint64 _secondsPerBlock) external;
    function setRecipients(address _fundsRecipient, address _tokensRecipient) external;
    function setBackingVault(address _backingVault) external;
    function setMigrationConfig(
        address _positionManager,
        address _positionRecipient,
        address _operator,
        uint64 _migrationDelayBlocks,
        uint64 _sweepDelayBlocks
    ) external;
    function launchAuction(uint256 amount, uint256 floorPrice, uint128 requiredRaise, bytes calldata auctionSteps)
        external
        returns (address auction);
    function launchAuctionWithReserve(
        uint256 amount,
        uint256 lpReserveAmount,
        uint256 floorPrice,
        uint128 requiredRaise,
        bytes calldata auctionSteps
    ) external returns (address auction);
    function transferOwnership(address newOwner) external;
}

interface IOwnableTransfer {
    function transferOwnership(address newOwner) external;
}

interface IOFTBootstrapRegistry {
    function getLayerZeroEndpoint(uint256 chainId) external pure returns (address);
}

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
}

interface IUniswapV3Pool {
    function initialize(uint160 sqrtPriceX96) external;
}

/**
 * @notice Charm Finance Alpha Vault Factory
 * @dev Base: 0x5B7B8b487D05F77977b7ABEec5F922925B9b2aFa
 *      Vaults created via this factory appear on alpha.charm.fi UI
 */
interface ICharmFactory {
    struct VaultParams {
        address pool;
        address manager;
        uint24 managerFee;
        address rebalanceDelegate;
        uint256 maxTotalSupply;
        int24 baseThreshold;
        int24 limitThreshold;
        uint24 fullRangeWeight;
        uint32 period;
        int24 minTickMove;
        int24 maxTwapDeviation;
        uint32 twapDuration;
        string name;
        string symbol;
    }

    function createVault(VaultParams calldata params) external returns (address vault);
    function governance() external view returns (address);
    function protocolFee() external view returns (uint24);
}

interface ICharmVaultManager {
    function manager() external view returns (address);
}

interface IDeploymentBatcherRegistryAccess {
    function registry() external view returns (address);
}

interface ICharmStrategy4626 {
    function initializeApprovals() external;
    function setAssetOracle(address _assetOracle) external;
    function setAjnaPool(address _ajnaPool) external;
    function setAjnaBorrowConfig(
        bool _enabled,
        uint256 _maxDebt,
        uint256 _maxBorrowPerWithdraw,
        uint256 _minCollateralRatioBps,
        uint256 _borrowLimitIndex,
        uint256 _repayLimitIndex
    ) external;
}

interface ICreatorOVaultStrategyManager {
    function addStrategy(address strategy, uint256 weight) external;
    function setAutoAllocate(bool autoAllocate) external;
}

interface ICreatorOVaultManagementView {
    function management() external view returns (address);
}

interface ICreatorOVaultAssetView {
    function asset() external view returns (address);
}

interface IAjnaVaultAuthConfigurator {
    function setBufferRatio(uint256 bufferRatioBps) external;
    function setMinBucketIndex(uint256 minBucketIndex) external;
    function setSwapper(address swapper) external;
    function setKeeper(address keeper, bool isKeeper) external;
    function setToll(uint256 tollBps) external;
    function setTax(uint256 taxBps) external;
    // FIX: F-04/F-21 — updated to two-step admin transfer pattern
    function transferAdmin(address admin) external;
    function acceptAdmin() external;
    function isAdmin(address account) external view returns (bool);
    function pendingAdmin() external view returns (address);
}

interface IERC4626StrategyAdapterAdmin {
    function setIdleBufferBps(uint256 newBps) external;
}

interface IVaultRolePolicyManager {
    function validateRoleAssignments(
        uint256 policyId,
        address owner,
        address management,
        address keeper,
        address emergencyAdmin
    ) external view;
}

interface IDeploymentBatcherSolanaConfig {
    struct OVaultRuntimeConfig {
        address hubComposer;
        uint32 solanaEid;
        bool enabled;
    }

    function getOVaultRuntimeConfig() external view returns (OVaultRuntimeConfig memory);

    function solanaDestination() external view returns (bytes32);

    function shareBridgeGasLimit() external view returns (uint128);
}

/// @dev Spoke EVM CCA inventory custody after Base finalize (async fanout).
interface IDeploymentBatcherSpokeInventory {
    /// @notice Recipient of SPOKE_INVENTORY_BPS ShareOFT; zero means protocolTreasury.
    function resolveSpokeInventoryRecipient() external view returns (address);
}

interface IERC20MetadataLite {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
}

interface IOFTPeerConfig {
    function peers(uint32 eid) external view returns (bytes32 peer);
    function setPeer(uint32 _eid, bytes32 _peer) external;
}

/// @dev Phase-1 CREATE2 orchestration lives in a delegatecall module to keep batcher initcode under EIP-3860.
contract DeploymentBatcherPhase1Module {
    error NotBatcherContext();
    error ZeroAddress();
    error InvalidCodeId();
    error SymbolTooLong();
    error Phase1StateMismatch();
    error Phase1CoreMissing();
    error Phase1ShareOFTMissing();
    error Phase1ShareOFTAlreadyBound(address shareOFT, address existingVault, address expectedVault);
    error Phase1Missing();
    /// @notice Nonzero ShareOFT salt override must equal the derived CREATE2 salt (blocks squats).
    error InvalidShareOftSaltOverride();

    IUniversalCreate2DeployerFromStore public immutable create2Deployer;
    IUniversalBytecodeStore public immutable bytecodeStore;
    address public immutable registry;
    address public immutable vaultCoreModule;
    address public immutable agentVaultCoreModule;
    address public immutable vaultStrategiesModule;
    address public immutable vaultAdminModule;
    address public immutable vaultActivationBatcher;
    DeploymentBatcherUtilsHelper public immutable utilsHelper;
    address public immutable batcher;

    constructor(
        address _create2Deployer,
        address _bytecodeStore,
        address _registry,
        address _vaultCoreModule,
        address _agentVaultCoreModule,
        address _vaultStrategiesModule,
        address _vaultAdminModule,
        address _vaultActivationBatcher,
        address _utilsHelper,
        address _batcher
    ) {
        require(block.chainid == 8453, "Phase1Module: Base only");
        if (_create2Deployer == address(0)) revert ZeroAddress();
        create2Deployer = IUniversalCreate2DeployerFromStore(_create2Deployer);
        if (_bytecodeStore == address(0)) revert ZeroAddress();
        bytecodeStore = IUniversalBytecodeStore(_bytecodeStore);
        if (_registry == address(0)) revert ZeroAddress();
        registry = _registry;
        if (_vaultCoreModule == address(0)) revert ZeroAddress();
        vaultCoreModule = _vaultCoreModule;
        agentVaultCoreModule = _agentVaultCoreModule;
        if (_vaultStrategiesModule == address(0)) revert ZeroAddress();
        vaultStrategiesModule = _vaultStrategiesModule;
        if (_vaultAdminModule == address(0)) revert ZeroAddress();
        vaultAdminModule = _vaultAdminModule;
        vaultActivationBatcher = _vaultActivationBatcher;
        if (_utilsHelper == address(0) || _batcher == address(0)) revert ZeroAddress();
        utilsHelper = DeploymentBatcherUtilsHelper(_utilsHelper);
        batcher = _batcher;
    }

    function deployPhase1Core(
        DeploymentBatcher.Phase1Params calldata params,
        DeploymentBatcher.CodeIds calldata codeIds,
        DeploymentBatcher.Phase1SplitState calldata existing,
        bytes32 shareOftSaltOverride
    ) external returns (DeploymentBatcher.Phase1Result memory out, DeploymentBatcher.Phase1SplitState memory state) {
        if (address(this) != batcher) revert NotBatcherContext();
        if (params.creatorToken == address(0) || params.owner == address(0)) revert ZeroAddress();
        _requirePhase1CodeIds(codeIds);
        if (bytes(params.shareSymbol).length > 32) revert SymbolTooLong();

        (bytes32 shareOftSalt, bytes32 paramsHash, bytes32 codeIdsHash,) =
            _phase1Identity(params, codeIds, shareOftSaltOverride);

        state = existing;
        if (state.coreDone) {
            if (
                state.paramsHash != paramsHash || state.codeIdsHash != codeIdsHash || state.shareOftSalt != shareOftSalt
            ) {
                revert Phase1StateMismatch();
            }
            out.oftBootstrapRegistry = state.oftBootstrapRegistry;
            out.vault = state.vault;
            out.wrapper = state.wrapper;
            out.shareOFT = state.shareOFT;
            return (out, state);
        }

        bytes32 baseSalt = utilsHelper.deriveBaseSalt(params.creatorToken, params.owner, block.chainid, params.version);
        address tempOwner = address(this);
        bool isAgent = params.vaultKind == DeploymentBatcher.VaultKind.Agent;
        bytes32 vaultSalt = utilsHelper.saltFor(baseSalt, isAgent ? "agentVault" : "vault");
        bytes32 wrapperSalt = utilsHelper.saltFor(baseSalt, isAgent ? "agentWrapper" : "wrapper");
        address coreModule = isAgent ? agentVaultCoreModule : vaultCoreModule;
        if (isAgent && agentVaultCoreModule == address(0)) revert ZeroAddress();

        bytes32 oftBootstrapSalt = keccak256("4626:OFTBootstrapRegistry:v1");
        out.oftBootstrapRegistry = create2Deployer.computeAddress(oftBootstrapSalt, codeIds.oftBootstrap);
        if (out.oftBootstrapRegistry.code.length == 0) {
            create2Deployer.deploy(oftBootstrapSalt, codeIds.oftBootstrap, bytes(""));
        }

        bytes memory vaultArgs = abi.encode(params.creatorToken, tempOwner, params.vaultName, params.vaultSymbol);
        // ODA-429-F3: adopt CREATE2 occupant after integrity check (ShareOFT parity).
        bool vaultAdopted;
        (out.vault, vaultAdopted) = _deployOrAdopt(vaultSalt, codeIds.vault, vaultArgs);
        if (vaultAdopted) {
            // Already deployed from a prior attempt — modules may already be wired.
            try IOVault4626(out.vault).setModulesOnce(coreModule, vaultStrategiesModule, vaultAdminModule) {}
            catch {
                if (IOVault4626(out.vault).coreModule() != coreModule) revert Phase1StateMismatch();
                if (IOVault4626(out.vault).strategiesModule() != vaultStrategiesModule) {
                    revert Phase1StateMismatch();
                }
                if (IOVault4626(out.vault).adminModule() != vaultAdminModule) revert Phase1StateMismatch();
            }
        } else {
            IOVault4626(out.vault).setModulesOnce(coreModule, vaultStrategiesModule, vaultAdminModule);
        }

        bytes memory wrapperArgs = abi.encode(params.creatorToken, out.vault, tempOwner);
        (out.wrapper,) = _deployOrAdopt(wrapperSalt, codeIds.wrapper, wrapperArgs);

        out.shareOFT = address(0);

        state.oftBootstrapRegistry = out.oftBootstrapRegistry;
        state.vault = out.vault;
        state.wrapper = out.wrapper;
        state.shareOFT = address(0);
        state.shareOftSalt = shareOftSalt;
        state.paramsHash = paramsHash;
        state.codeIdsHash = codeIdsHash;
        state.vaultKind = params.vaultKind;
        state.coreDone = true;
        state.finalized = false;
    }

    function finalizePhase1Split(
        DeploymentBatcher.Phase1Params calldata params,
        DeploymentBatcher.CodeIds calldata codeIds,
        DeploymentBatcher.Phase1SplitState calldata existing,
        bytes32 shareOftSaltOverride
    ) external returns (DeploymentBatcher.Phase1Result memory out, DeploymentBatcher.Phase1SplitState memory state) {
        if (address(this) != batcher) revert NotBatcherContext();
        if (params.creatorToken == address(0) || params.owner == address(0)) revert ZeroAddress();
        _requirePhase1CodeIds(codeIds);
        if (bytes(params.shareSymbol).length > 32) revert SymbolTooLong();

        (bytes32 expectedShareOftSalt, bytes32 paramsHash, bytes32 codeIdsHash,) =
            _phase1Identity(params, codeIds, shareOftSaltOverride);
        string memory shareSymbolUpper = utilsHelper.toUpper(params.shareSymbol);

        state = existing;
        if (!state.coreDone) revert Phase1CoreMissing();
        if (
            state.paramsHash != paramsHash || state.codeIdsHash != codeIdsHash
                || state.shareOftSalt != expectedShareOftSalt
        ) {
            revert Phase1StateMismatch();
        }

        out.oftBootstrapRegistry = state.oftBootstrapRegistry;
        out.vault = state.vault;
        out.wrapper = state.wrapper;
        if (out.vault.code.length == 0 || out.wrapper.code.length == 0) revert Phase1CoreMissing();

        if (state.finalized) {
            if (state.shareOFT == address(0) || state.shareOFT.code.length == 0) revert Phase1Missing();
            out.shareOFT = state.shareOFT;
            return (out, state);
        }

        bytes memory shareOftArgs =
            abi.encode(params.shareName, shareSymbolUpper, out.oftBootstrapRegistry, address(this));
        bytes32 shareOftInitCodeHash = _deriveInitCodeHash(codeIds.shareOFT, shareOftArgs);
        try create2Deployer.deploy(state.shareOftSalt, codeIds.shareOFT, shareOftArgs) returns (
            address deployedShareOFT
        ) {
            out.shareOFT = deployedShareOFT;
        } catch {
            // AUDIT-2026-07-08-C01: only adopt a pre-existing ShareOFT when it is still
            // unbound (vault == 0) or already pointed at this vault. Never re-wire a
            // ShareOFT that belongs to another vault (salt collision / squat reuse).
            address expectedAddr = create2Deployer.computeAddress(state.shareOftSalt, shareOftInitCodeHash);
            if (expectedAddr.code.length == 0) revert Phase1ShareOFTMissing();
            bytes32 verifyHash = keccak256(bytes.concat(bytecodeStore.get(codeIds.shareOFT), shareOftArgs));
            if (verifyHash != shareOftInitCodeHash) revert Phase1StateMismatch();
            address existingVault = IShareOFT4626(expectedAddr).vault();
            if (existingVault != address(0) && existingVault != out.vault) {
                revert Phase1ShareOFTAlreadyBound(expectedAddr, existingVault, out.vault);
            }
            out.shareOFT = expectedAddr;
        }

        IOVaultWrapper4626(out.wrapper).setShareOFT(out.shareOFT);
        IShareOFT4626(out.shareOFT).setRegistry(address(registry));
        IShareOFT4626(out.shareOFT).setVault(out.vault);
        IShareOFT4626(out.shareOFT).setWrapper(out.wrapper);
        IShareOFT4626(out.shareOFT).setMinter(out.wrapper, true);
        IShareOFT4626(out.shareOFT).setHubConfig(true, 0, address(0));

        IOVault4626(out.vault).setWhitelist(out.wrapper, true);
        IOVault4626(out.vault).setWhitelist(address(this), true);
        // LeftClaw #509 U-03: adapter-ness is explicit — the cooldown exemption no
        // longer infers it from `code.length` (EIP-7702 gives EOAs code).
        IOVault4626(out.vault).setTrustedAdapter(out.wrapper, true);
        IOVault4626(out.vault).setTrustedAdapter(address(this), true);
        if (vaultActivationBatcher != address(0)) {
            IOVault4626(out.vault).setWhitelist(vaultActivationBatcher, true);
            IOVault4626(out.vault).setTrustedAdapter(vaultActivationBatcher, true);
        }

        state.shareOFT = out.shareOFT;
        state.finalized = true;
    }

    function _phase1Identity(
        DeploymentBatcher.Phase1Params calldata params,
        DeploymentBatcher.CodeIds calldata codeIds,
        bytes32 shareOftSaltOverride
    ) internal returns (bytes32 shareOftSalt, bytes32 paramsHash, bytes32 codeIdsHash, bytes32 baseSalt) {
        string memory shareSymbolLower = utilsHelper.toLower(params.shareSymbol);
        baseSalt = utilsHelper.deriveBaseSalt(params.creatorToken, params.owner, block.chainid, params.version);
        // ODA-494-H01: nonzero override is a confirmation of the derived salt only — never a
        // free-form CREATE2 salt (would let callers squat another owner's ShareOFT address).
        bytes32 derivedShareOftSalt =
            utilsHelper.deriveShareOftSalt(params.creatorToken, params.owner, shareSymbolLower, params.version);
        if (shareOftSaltOverride == bytes32(0)) {
            shareOftSalt = derivedShareOftSalt;
        } else if (shareOftSaltOverride != derivedShareOftSalt) {
            revert InvalidShareOftSaltOverride();
        } else {
            shareOftSalt = derivedShareOftSalt;
        }
        paramsHash = utilsHelper.phase1ParamsHash(
            params.creatorToken,
            params.owner,
            params.vaultName,
            params.vaultSymbol,
            params.shareName,
            params.shareSymbol,
            params.version,
            params.vaultKind
        );
        codeIdsHash =
            utilsHelper.phase1CodeIdsHash(codeIds.vault, codeIds.wrapper, codeIds.shareOFT, codeIds.oftBootstrap);
    }

    function _requirePhase1CodeIds(DeploymentBatcher.CodeIds calldata codeIds) internal view {
        if (
            codeIds.vault == bytes32(0) || codeIds.wrapper == bytes32(0) || codeIds.shareOFT == bytes32(0)
                || codeIds.oftBootstrap == bytes32(0)
        ) {
            revert InvalidCodeId();
        }
        // AUDIT-2026-07-08-NEW-H: reject unallowlisted bytecode ids when batcher enforces.
        IDeploymentBatcherCodeAllowlist(batcher).requireApprovedCodeId(codeIds.vault);
        IDeploymentBatcherCodeAllowlist(batcher).requireApprovedCodeId(codeIds.wrapper);
        IDeploymentBatcherCodeAllowlist(batcher).requireApprovedCodeId(codeIds.shareOFT);
        IDeploymentBatcherCodeAllowlist(batcher).requireApprovedCodeId(codeIds.oftBootstrap);
    }

    function _deriveInitCodeHash(bytes32 codeId, bytes memory constructorArgs) internal view returns (bytes32) {
        bytes memory creationCode = bytecodeStore.get(codeId);
        return keccak256(bytes.concat(creationCode, constructorArgs));
    }

    /// @dev ODA-429-F3 — deploy or adopt an existing CREATE2 address after verifying
    ///      the store-derived init-code hash matches the predicted deployment.
    function _deployOrAdopt(bytes32 salt, bytes32 codeId, bytes memory constructorArgs)
        internal
        returns (address addr, bool adopted)
    {
        bytes32 initCodeHash = _deriveInitCodeHash(codeId, constructorArgs);
        addr = create2Deployer.computeAddress(salt, initCodeHash);
        if (addr.code.length > 0) {
            // CREATE2 address match already binds occupant to this salt+initCodeHash.
            // Reject EIP-7702 designators that can occupy the predicted address.
            bytes memory code = addr.code;
            if (code.length >= 3 && code[0] == 0xef && code[1] == 0x01 && code[2] == 0x00) {
                revert Phase1StateMismatch();
            }
            return (addr, true);
        }
        return (create2Deployer.deploy(salt, codeId, constructorArgs), false);
    }
}

contract DeploymentBatcherPhase2Module {
    using SafeERC20 for IERC20;

    /// @dev Launch inventory (bps / 10_000). Base live book is 25% = 12.5% auction + 12.5% LP
    ///      (50/50 within-leg, self-funded). Spoke EVM share (RH+Arb+Eth+Uni = 25%) is
    ///      inventory only — not a live CCA or LP book.
    uint16 internal constant BPS_DENOMINATOR = 10_000;
    uint16 internal constant VESTING_BPS = 2_500;
    uint16 internal constant SOLANA_BPS = 2_500;
    uint16 internal constant BASE_AUCTION_BPS = 1_250;
    uint16 internal constant BASE_LP_RESERVE_BPS = 1_250;
    uint16 internal constant SPOKE_INVENTORY_BPS = 2_500;
    /// @notice Allowed first-deposit range (creator-token principal, 18 decimals).
    /// @dev Must stay >= CreatorOVault.MINIMUM_FIRST_DEPOSIT (50M). The upper bound
    ///      keeps the launch inventory split within sizes the CCA + LZ bridge lanes
    ///      have been validated for.
    uint256 internal constant MIN_FIRST_DEPOSIT = 50_000_000e18;
    uint256 internal constant MAX_FIRST_DEPOSIT = 100_000_000e18;
    uint16 internal constant DEFAULT_LAUNCH_DISCOUNT_BPS = 9_800;
    uint16 internal constant DEFAULT_LAUNCH_TICK_SPACING_BPS = 100;
    uint128 internal constant DEFAULT_SHARE_BRIDGE_GAS_LIMIT = 200_000;

    error NotBatcherContext();
    error ZeroAddress();
    error SolanaShareBridgeNotConfigured();
    error SolanaShareOftPeerNotConfigured();
    error InsufficientSolanaBridgeFee(uint256 required, uint256 provided);
    error RegistryCreatorMismatch(address creatorToken, address registeredCreator, address requestedOwner);
    /// @dev ODA-464-F01 — first registry write requires Ownable match or a 1-unit token hold.
    error InsufficientCreatorTokenControl(address creatorToken, uint256 requiredBalance);
    error SolanaBridgeRefundFailed();
    error AuctionAmountMismatch();
    error InvalidDepositAmount();
    error Phase1Missing();
    error Phase2Missing();
    error Phase1StateMismatch();
    error InvalidCreatorTreasury(address provided);
    // Canonical terminology note (AGENTS.md): this error guards the
    // creatorCoinPayoutRecipient (external earnings) lane. The field name
    // `payoutRecipient` is retained for on-chain ABI compatibility; all new
    // code and docs must use the five mandated lane names.
    error InvalidCreatorCoinPayoutRecipient();
    error InvalidCodeId();

    struct FinalizeExecutionResult {
        uint256 auctionAmount;
        uint256 lpReserveAmount;
        uint256 solanaAmount;
        uint256 vestingAmount;
        uint256 spokeInventoryAmount;
        address spokeInventoryRecipient;
        address vestingAddress;
        uint64 vestingStartTimestamp;
        uint64 vestingDurationSeconds;
    }

    IUniversalCreate2DeployerFromStore public immutable create2Deployer;
    address public immutable registry;
    address public immutable chainlinkEthUsd;
    address public immutable poolManager;
    address public immutable taxHook;
    address public immutable protocolTreasury;
    address public immutable lotteryManager;
    address public immutable vaultActivationBatcher;
    address public immutable batcher;
    /// @dev Module contract address (not batcher). Used to read/write pending init-code
    ///      hashes from delegatecall context without changing shell `Phase2CoreParams` ABI.
    address private immutable moduleSelf;

    /// @dev salt => CREATE2 init-code hash published by precreate (AA95 reuse without store.get).
    mapping(bytes32 => bytes32) public pendingInitCodeHash;

    error NotAuthorizedInitCodeHashWriter();

    constructor(
        address _create2Deployer,
        address _registry,
        address _chainlinkEthUsd,
        address _poolManager,
        address _taxHook,
        address _protocolTreasury,
        address _lotteryManager,
        address _vaultActivationBatcher,
        address _batcher
    ) {
        create2Deployer = IUniversalCreate2DeployerFromStore(_create2Deployer);
        registry = _registry;
        chainlinkEthUsd = _chainlinkEthUsd;
        poolManager = _poolManager;
        taxHook = _taxHook;
        protocolTreasury = _protocolTreasury;
        lotteryManager = _lotteryManager;
        vaultActivationBatcher = _vaultActivationBatcher;
        if (_batcher == address(0)) revert NotBatcherContext();
        batcher = _batcher;
        moduleSelf = address(this);
    }

    /**
     * @notice Publish CREATE2 init-code hashes for gauge/cca/oracle salts before phase2 UserOp.
     * @dev Callable on the module contract itself (not via batcher delegatecall). Keeps the live
     *      shell's `deployPhase2Core` ABI unchanged while enabling AA95-friendly reuse.
     */
    function setPendingInitCodeHashes(bytes32[3] calldata salts, bytes32[3] calldata hashes) external {
        // ODA-429-F1: hash writes steer CREATE2 wiring for gauge/cca/oracle.
        // Restrict to protocolTreasury only — do not delegate this to the
        // external CREATE2 factory's unmanaged `authorizedDeployers` allowlist.
        if (msg.sender != protocolTreasury) {
            revert NotAuthorizedInitCodeHashWriter();
        }
        for (uint256 i = 0; i < 3; i++) {
            if (salts[i] != bytes32(0)) {
                pendingInitCodeHash[salts[i]] = hashes[i];
            }
        }
    }

    /// @dev Dead footgun: always hard-coded Creator. Shell routes through
    ///      `deployPhase2CoreOrchestrator` with `p1state.vaultKind`.
    error UsePhase2Orchestrator();

    function deployPhase2Core(
        DeploymentBatcher.Phase2CoreParams calldata, /* params */
        DeploymentBatcher.CodeIds calldata, /* codeIds */
        bytes32, /* baseSalt */
        string calldata /* shareSymbolLower */
    ) external view returns (DeploymentBatcher.Phase2Result memory) {
        if (address(this) != batcher) revert NotBatcherContext();
        revert UsePhase2Orchestrator();
    }

    function deployPhase2CoreOrchestrator(
        DeploymentBatcher.Phase2CoreParams calldata params,
        DeploymentBatcher.CodeIds calldata codeIds,
        bytes32 baseSalt,
        string calldata shareSymbolLower,
        DeploymentBatcher.Phase1SplitState calldata p1state,
        address rolePolicyManager,
        uint256 rolePolicyId
    ) external returns (DeploymentBatcher.Phase2Result memory out) {
        if (address(this) != batcher) revert NotBatcherContext();
        if (params.creatorToken == address(0) || params.owner == address(0)) revert ZeroAddress();
        if (params.vault == address(0) || params.wrapper == address(0) || params.shareOFT == address(0)) {
            revert ZeroAddress();
        }
        if (rolePolicyManager != address(0)) {
            IVaultRolePolicyManager(rolePolicyManager)
                .validateRoleAssignments(rolePolicyId, params.owner, params.owner, params.owner, params.owner);
        }
        if (codeIds.gauge == bytes32(0) || codeIds.cca == bytes32(0) || codeIds.oracle == bytes32(0)) {
            revert InvalidCodeId();
        }
        IDeploymentBatcherCodeAllowlist(batcher).requireApprovedCodeId(codeIds.gauge);
        IDeploymentBatcherCodeAllowlist(batcher).requireApprovedCodeId(codeIds.cca);
        IDeploymentBatcherCodeAllowlist(batcher).requireApprovedCodeId(codeIds.oracle);
        if (params.vault.code.length == 0 || params.wrapper.code.length == 0 || params.shareOFT.code.length == 0) {
            revert Phase1Missing();
        }
        if (!p1state.finalized) revert Phase1Missing();
        if (p1state.vault != params.vault || p1state.wrapper != params.wrapper || p1state.shareOFT != params.shareOFT) {
            revert Phase1StateMismatch();
        }
        if (params.creatorTreasury != address(0) && params.creatorTreasury != protocolTreasury) {
            revert InvalidCreatorTreasury(params.creatorTreasury);
        }
        if (params.payoutRecipient != address(0)) revert InvalidCreatorCoinPayoutRecipient();
        return _deployPhase2CoreBody(params, codeIds, baseSalt, shareSymbolLower, p1state.vaultKind);
    }

    function _wireGaugeAssetToken(address gaugeController, address assetToken, DeploymentBatcher.VaultKind vaultKind)
        internal
    {
        if (vaultKind == DeploymentBatcher.VaultKind.Agent) {
            IAgentGaugeController(gaugeController).setAgentToken(assetToken);
        } else {
            ICreatorGaugeController(gaugeController).setCreatorCoin(assetToken);
        }
    }

    function _deployPhase2CoreBody(
        DeploymentBatcher.Phase2CoreParams calldata params,
        DeploymentBatcher.CodeIds calldata codeIds,
        bytes32 baseSalt,
        string calldata shareSymbolLower,
        DeploymentBatcher.VaultKind vaultKind
    ) internal returns (DeploymentBatcher.Phase2Result memory out) {
        address treasury = protocolTreasury;
        address tempOwner = address(this);

        bytes32 gaugeSalt = _saltFor(baseSalt, "gauge");
        bytes32 ccaSalt = _saltFor(baseSalt, "cca");
        bytes32 oracleSalt = _saltFor(baseSalt, "oracle");

        // Base caps eth_sendRawTransaction at 2^24 gas and EntryPoint AA95 further
        // shrinks call+verification under that cap. The three CREATE2 fan-outs alone
        // exceed a single UserOp budget, so allow pre-created addresses (same salt /
        // codeId / constructor args) and only spend UserOp gas on wiring.
        bytes memory gaugeArgs = abi.encode(params.shareOFT, treasury, protocolTreasury, tempOwner);
        out.gaugeController = _deployOrExisting(gaugeSalt, codeIds.gauge, gaugeArgs);

        // CCA currency is native ETH (address(0)). Do not pass USDC — the ShareOFT book is ■/ETH only.
        bytes memory ccaArgs = abi.encode(params.shareOFT, address(0), params.vault, params.vault, tempOwner);
        out.ccaLaunchArm = _deployOrExisting(ccaSalt, codeIds.cca, ccaArgs);

        bytes memory oracleArgs = abi.encode(registry, chainlinkEthUsd, shareSymbolLower, tempOwner);
        out.oracle = _deployOrExisting(oracleSalt, codeIds.oracle, oracleArgs);

        IShareOFT4626(params.shareOFT).setGaugeController(out.gaugeController);

        ITradeFeeCollector4626(out.gaugeController).setVault(params.vault);
        ITradeFeeCollector4626(out.gaugeController).setWrapper(params.wrapper);
        _wireGaugeAssetToken(out.gaugeController, params.creatorToken, vaultKind);
        if (vaultKind == DeploymentBatcher.VaultKind.Agent) {
            // FIX: ODA-508-1 (operational) — whitelist the gauge in the wrapper while the
            // batcher still owns it: waives the unwrapFee on the gauge's burn-slice unwraps
            // (and, per current wrapper semantics, the wrapper cooldown). The burn path is
            // independently dust-poison-safe via the wrapper's amount-scoped hot-balance
            // accounting (ODA-507-1). Agent lane only; the creator gauge is deliberately
            // not fee-exempt on its wrapper.
            IOVaultWrapper4626(params.wrapper).setWhitelist(out.gaugeController, true);
        }
        if (lotteryManager != address(0)) {
            ITradeFeeCollector4626(out.gaugeController).setLotteryManager(lotteryManager);
        }
        ITradeFeeCollector4626(out.gaugeController).setOracle(out.oracle);

        IOVault4626(params.vault).setGaugeController(out.gaugeController);
        IOVault4626(params.vault).setCcaLaunchArm(out.ccaLaunchArm);

        ICCALaunchArm(out.ccaLaunchArm).setApprovedLauncher(address(this), true);
        // C-15: this approval is the batcher's privileged launch role. VaultActivationBatcher
        // must not exercise it for a public deposit. Launch stays behind the vault owner,
        // a positive OP_ACTIVATE grant, or an action-bound launch intent.
        if (vaultActivationBatcher != address(0)) {
            ICCALaunchArm(out.ccaLaunchArm).setApprovedLauncher(vaultActivationBatcher, true);
        }
        ICCALaunchArm(out.ccaLaunchArm).setRecipients(out.ccaLaunchArm, out.ccaLaunchArm);
        ICCALaunchArm(out.ccaLaunchArm).setBackingVault(params.vault);
        ICCALaunchArm(out.ccaLaunchArm).setMigrationConfig(address(0), protocolTreasury, protocolTreasury, 1, 14_400);
        ICCALaunchArm(out.ccaLaunchArm).setOracleConfig(out.oracle, poolManager, taxHook, out.gaugeController);
        ICCALaunchArm(out.ccaLaunchArm).setLaunchDiscountBps(DEFAULT_LAUNCH_DISCOUNT_BPS);
        ICCALaunchArm(out.ccaLaunchArm).setLaunchTickSpacingBps(DEFAULT_LAUNCH_TICK_SPACING_BPS);

        // Persist product-lane kind so Registry4626.getVaultKind is correct after deploy.
        // ODA-430-F5: registry now requires registerToken before setAgentIntegrationMeta.
        // ODA-464-F01: first-writer registerToken is a permanent squat — require proof of
        // control over creatorToken before the first registration (not mere self-naming).
        // Agent-specific fields (tax adapter / pair) are left zero unless a later epoch adds params.
        {
            IRegistry4626 reg = IRegistry4626(registry);
            if (reg.getTokenInfo(params.creatorToken).token == address(0)) {
                _requireCreatorTokenControl(params.creatorToken, params.owner, false);
                (string memory name, string memory symbol) = _readTokenMetadata(params.creatorToken);
                reg.registerToken(params.creatorToken, name, symbol, params.owner, address(0), 0);
            }
        }
        _setVaultKindMeta(params.creatorToken, params.vault, vaultKind);
    }

    /// @dev ODA-464-F01: block gas-only registry squats. Prefer Ownable.owner() match;
    ///      otherwise require holding ≥ 1 whole token unit unless `allowDepositProof`
    ///      (finalize after MIN_FIRST_DEPOSIT pull).
    function _requireCreatorTokenControl(address creatorToken, address owner_, bool allowDepositProof) internal view {
        try IOwnableView(creatorToken).owner() returns (address tokenOwner) {
            if (tokenOwner != address(0)) {
                if (tokenOwner != owner_) {
                    revert RegistryCreatorMismatch(creatorToken, tokenOwner, owner_);
                }
                return;
            }
        } catch {}

        if (allowDepositProof) return;

        uint256 need = 1;
        try IERC20Decimals(creatorToken).decimals() returns (uint8 d) {
            if (d > 0 && d <= 36) need = 10 ** uint256(d);
        } catch {}
        // Phase deploys allow `authorizedPhaseCallers` to act for `owner_`; control
        // proof must check the represented owner, not the intermediary caller.
        if (IERC20(creatorToken).balanceOf(owner_) < need) {
            revert InsufficientCreatorTokenControl(creatorToken, need);
        }
    }

    /// @dev When a pending init-code hash is published for `salt`, reuse checks skip
    ///      `store.get()` (AA95). Precreate writes hashes via `setPendingInitCodeHashes`
    ///      on the module contract. Zero keeps the legacy derive-via-get path.
    error InitCodeHashMismatch();

    function _deployOrExisting(bytes32 salt, bytes32 codeId, bytes memory constructorArgs)
        internal
        returns (address addr)
    {
        address storeAddr = create2Deployer.store();
        if (storeAddr != address(0)) {
            // Read from module storage (not batcher storage) while running under delegatecall.
            bytes32 publishedHash = DeploymentBatcherPhase2Module(moduleSelf).pendingInitCodeHash(salt);
            bytes32 resolvedHash = publishedHash;
            if (resolvedHash == bytes32(0)) {
                // Legacy path: materialize creation bytecode to derive the hash.
                if (IUniversalBytecodeStoreView(storeAddr).pointers(codeId) == address(0)) {
                    // Let deploy() surface CodeNotFound.
                    return create2Deployer.deploy(salt, codeId, constructorArgs);
                }
                bytes memory creationCode = IUniversalBytecodeStoreView(storeAddr).get(codeId);
                resolvedHash = keccak256(bytes.concat(creationCode, constructorArgs));
            }
            addr = create2Deployer.computeAddress(salt, resolvedHash);
            // ODA-429-F1: always verify reused code matches the approved codeId's
            // real bytecode — the "already deployed" branch previously skipped
            // integrity and could adopt attacker-steered CREATE2 occupants.
            bytes memory creationCode = IUniversalBytecodeStoreView(storeAddr).get(codeId);
            bytes32 realHash = keccak256(bytes.concat(creationCode, constructorArgs));
            if (publishedHash != bytes32(0) && realHash != publishedHash) {
                revert InitCodeHashMismatch();
            }
            if (addr.code.length > 0) {
                if (realHash != resolvedHash) revert InitCodeHashMismatch();
                return addr;
            }
        }
        addr = create2Deployer.deploy(salt, codeId, constructorArgs);
    }

    /// @dev Writes AgentIntegrationMeta (historical name for lane meta). Requires the batcher
    ///      (or this delegatecall context's address(this) = batcher) to be an authorized factory
    ///      or the registry owner. Registry auth change lands with the next registry epoch.
    function _setVaultKindMeta(
        address token,
        address vault,
        DeploymentBatcher.VaultKind vaultKind
    ) internal {
        IRegistry4626.AgentIntegrationMeta memory meta;
        meta.vaultKind = vaultKind == DeploymentBatcher.VaultKind.Agent
            ? IRegistry4626.VaultKind.Agent
            : IRegistry4626.VaultKind.Creator;
        if (vaultKind == DeploymentBatcher.VaultKind.Agent) {
            meta.nativeAgentVault = vault;
        }
        IRegistry4626(registry).setAgentIntegrationMeta(token, meta);
    }

    function finalizePhase2Execution(DeploymentBatcher.Phase2FinalizeParams calldata params, bytes32 baseSalt)
        public
        returns (FinalizeExecutionResult memory result)
    {
        if (address(this) != batcher) revert NotBatcherContext();

        IERC20(params.creatorToken).forceApprove(params.wrapper, params.depositAmount);
        uint256 shareTokens = IOVaultWrapper4626(params.wrapper).deposit(params.depositAmount);

        if (AkitaHonorLaunchInventory.isHonorToken(params.creatorToken)) {
            uint256 honorAmount;
            (
                result.vestingAmount,
                result.auctionAmount,
                result.lpReserveAmount,
                result.spokeInventoryAmount,
                result.solanaAmount,
                honorAmount
            ) = AkitaHonorLaunchInventory.splitShareTokens(shareTokens);
            if (honorAmount > 0) {
                IERC20(params.shareOFT).safeTransfer(params.owner, honorAmount);
            }
        } else {
            // Exact 10_000 bps — no dust remainder.
            result.vestingAmount = (shareTokens * VESTING_BPS) / BPS_DENOMINATOR;
            result.solanaAmount = (shareTokens * SOLANA_BPS) / BPS_DENOMINATOR;
            result.auctionAmount = (shareTokens * BASE_AUCTION_BPS) / BPS_DENOMINATOR;
            result.lpReserveAmount = (shareTokens * BASE_LP_RESERVE_BPS) / BPS_DENOMINATOR;
            result.spokeInventoryAmount = (shareTokens * SPOKE_INVENTORY_BPS) / BPS_DENOMINATOR;
        }

        if (result.lpReserveAmount > 0) {
            IERC20(params.shareOFT).safeTransfer(params.ccaLaunchArm, result.lpReserveAmount);
        }

        if (result.spokeInventoryAmount > 0) {
            address recipient = _resolveSpokeInventoryRecipient();
            if (recipient == address(0)) revert ZeroAddress();
            result.spokeInventoryRecipient = recipient;
            IERC20(params.shareOFT).safeTransfer(recipient, result.spokeInventoryAmount);
        }

        if (result.solanaAmount > 0) {
            IDeploymentBatcherSolanaConfig config = IDeploymentBatcherSolanaConfig(batcher);
            IDeploymentBatcherSolanaConfig.OVaultRuntimeConfig memory runtime = config.getOVaultRuntimeConfig();
            _ensureRegistryAndShareOftPeerWired(params, runtime.solanaEid);
            _bridgeShareAllocationToSolana(params.shareOFT, result.solanaAmount);
        }

        if (result.vestingAmount > 0) {
            result.vestingStartTimestamp = uint64(block.timestamp);
            result.vestingDurationSeconds = uint64(365 days);
            bytes32 vestingSalt = keccak256(abi.encodePacked(baseSalt, "vesting"));
            LinearVesting4626 vesting = new LinearVesting4626{salt: vestingSalt}(
                params.shareOFT, params.owner, result.vestingStartTimestamp, result.vestingDurationSeconds, batcher
            );
            result.vestingAddress = address(vesting);
            IERC20(params.shareOFT).safeTransfer(result.vestingAddress, result.vestingAmount);
            LinearVesting4626(result.vestingAddress).seed();
        }

        IOVault4626(params.vault).setProtocolRescue(protocolTreasury);
        // M-23: vault + wrapper are Ownable2Step — transferOwnership NOMINATES.
        // Creator CSW must `acceptOwnership()` on the vault; `protocolTreasury` must
        // accept the wrapper (and gauge below). Until then this batcher remains owner.
        IOVault4626(params.vault).transferOwnership(params.owner);
        IOVaultWrapper4626(params.wrapper).transferOwnership(protocolTreasury);
        IShareOFT4626(params.shareOFT).transferOwnership(protocolTreasury);
        // ODA-508-L8: the gauge is Ownable2Step — this NOMINATES the treasury. Deploy
        // choreography: `protocolTreasury` must call `acceptOwnership()` on the gauge to
        // complete the handoff; until then this batcher remains the owner of record.
        ITradeFeeCollector4626(params.gaugeController).transferOwnership(protocolTreasury);
        ICCALaunchArm(params.ccaLaunchArm).transferOwnership(protocolTreasury);
        IOwnableTransfer(params.oracle).transferOwnership(protocolTreasury);
    }

    /// @dev Live v1.21/v1.22 shells lack `resolveSpokeInventoryRecipient` (v1.23.0 activates via
    ///      Phase2Module hot-swap only). Prefer the shell override when present; otherwise custody
    ///      on this module's immutable `protocolTreasury`.
    function _resolveSpokeInventoryRecipient() internal view returns (address recipient) {
        recipient = protocolTreasury;
        try IDeploymentBatcherSpokeInventory(batcher).resolveSpokeInventoryRecipient() returns (address resolved) {
            if (resolved != address(0)) recipient = resolved;
        } catch {}
    }

    function _readTokenMetadata(address token) internal view returns (string memory name, string memory symbol) {
        try IERC20MetadataLite(token).name() returns (string memory tokenName) {
            name = tokenName;
        } catch {
            name = "Unknown";
        }
        try IERC20MetadataLite(token).symbol() returns (string memory tokenSymbol) {
            symbol = tokenSymbol;
        } catch {
            symbol = "UNK";
        }
    }

    function _ensureRegistryAndShareOftPeerWired(
        DeploymentBatcher.Phase2FinalizeParams calldata params,
        uint32 solanaEid
    ) internal {
        if (solanaEid == 0) {
            revert SolanaShareBridgeNotConfigured();
        }

        IRegistry4626 reg = IRegistry4626(registry);
        IRegistry4626.TokenInfo memory info = reg.getTokenInfo(params.creatorToken);
        if (info.token == address(0)) {
            // Finalize already pulled MIN_FIRST_DEPOSIT — treat that as control proof
            // for non-Ownable tokens (balance may now be zero after deposit).
            _requireCreatorTokenControl(params.creatorToken, params.owner, true);
            (string memory name, string memory symbol) = _readTokenMetadata(params.creatorToken);
            reg.registerToken(params.creatorToken, name, symbol, params.owner, address(0), 0);
            info = reg.getTokenInfo(params.creatorToken);
        } else if (info.creator != params.owner) {
            revert RegistryCreatorMismatch(params.creatorToken, info.creator, params.owner);
        }
        if (info.vault == address(0)) {
            reg.setVault(params.creatorToken, params.vault);
        }
        if (info.wrapper == address(0)) {
            reg.setWrapperForToken(params.creatorToken, params.wrapper);
        }
        if (info.shareOFT == address(0)) {
            reg.setShareOFTForToken(params.creatorToken, params.shareOFT);
        }
        if (info.gaugeController == address(0)) {
            reg.setGaugeControllerForToken(params.creatorToken, params.gaugeController);
        }
        if (info.oracle == address(0)) {
            reg.setOracleForToken(params.creatorToken, params.oracle);
        }

        bytes32 peer = reg.getRemoteOFTPeerBytes32(params.creatorToken, solanaEid);
        if (peer == bytes32(0)) revert SolanaShareOftPeerNotConfigured();

        bytes32 currentPeer = IOFTPeerConfig(params.shareOFT).peers(solanaEid);
        if (currentPeer != peer) {
            IOFTPeerConfig(params.shareOFT).setPeer(solanaEid, peer);
        }
    }

    function _shareBridgeGasLimit(IDeploymentBatcherSolanaConfig config) internal view returns (uint128 gasLimit) {
        gasLimit = config.shareBridgeGasLimit();
        if (gasLimit == 0) gasLimit = DEFAULT_SHARE_BRIDGE_GAS_LIMIT;
    }

    // slither-disable-next-line arbitrary-send-eth
    function _bridgeShareAllocationToSolana(address shareOFT, uint256 amount) internal {
        IDeploymentBatcherSolanaConfig config = IDeploymentBatcherSolanaConfig(batcher);
        IDeploymentBatcherSolanaConfig.OVaultRuntimeConfig memory runtime = config.getOVaultRuntimeConfig();
        if (!runtime.enabled || runtime.solanaEid == 0) revert SolanaShareBridgeNotConfigured();
        bytes32 destination = config.solanaDestination();
        if (destination == bytes32(0)) revert SolanaShareBridgeNotConfigured();

        SendParam memory sendParam = SendParam({
            dstEid: runtime.solanaEid,
            to: destination,
            amountLD: amount,
            minAmountLD: 0,
            extraOptions: OptionsBuilder.addExecutorLzReceiveOption(
                OptionsBuilder.newOptions(), _shareBridgeGasLimit(config), 0
            ),
            composeMsg: "",
            oftCmd: ""
        });
        (,, OFTReceipt memory oftReceipt) = IOFT(shareOFT).quoteOFT(sendParam);
        sendParam.minAmountLD = oftReceipt.amountReceivedLD;
        MessagingFee memory fee = IOFT(shareOFT).quoteSend(sendParam, false);
        if (msg.value < fee.nativeFee) revert InsufficientSolanaBridgeFee(fee.nativeFee, msg.value);

        IOFT(shareOFT).send{value: fee.nativeFee}(sendParam, fee, msg.sender);

        uint256 surplus = msg.value - fee.nativeFee;
        if (surplus > 0) {
            (bool ok,) = payable(msg.sender).call{value: surplus}("");
            if (!ok) revert SolanaBridgeRefundFailed();
        }
    }

    function _saltFor(bytes32 baseSalt, string memory label) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(baseSalt, label));
    }

    function launchDeferredAuctionExecution(
        address shareOFT,
        address ccaLaunchArm,
        uint256 amount,
        uint256 lpReserveAmount,
        uint256 floorPriceQ96,
        uint128 requiredRaise,
        bytes calldata auctionSteps
    ) external returns (address auction) {
        if (address(this) != batcher) revert NotBatcherContext();
        if (IERC20(shareOFT).balanceOf(address(this)) < amount) revert AuctionAmountMismatch();
        IERC20(shareOFT).forceApprove(ccaLaunchArm, amount);
        auction = ICCALaunchArm(ccaLaunchArm)
            .launchAuctionWithReserve(amount, lpReserveAmount, floorPriceQ96, requiredRaise, auctionSteps);
    }

    error Phase2WiringMismatch();

    /// @dev ODA-464-F06: MIN/MAX_FIRST_DEPOSIT are expressed in 18-decimal whole-token units.
    function _scaledDepositBounds(address creatorToken) internal view returns (uint256 minDeposit, uint256 maxDeposit) {
        uint8 decimals = 18;
        try IERC20Decimals(creatorToken).decimals() returns (uint8 d) {
            decimals = d;
        } catch {}
        if (decimals == 18) {
            return (MIN_FIRST_DEPOSIT, MAX_FIRST_DEPOSIT);
        }
        if (decimals < 18) {
            uint256 scale = 10 ** (18 - decimals);
            return (MIN_FIRST_DEPOSIT / scale, MAX_FIRST_DEPOSIT / scale);
        }
        uint256 upScale = 10 ** (decimals - 18);
        return (MIN_FIRST_DEPOSIT * upScale, MAX_FIRST_DEPOSIT * upScale);
    }

    /// @dev LeftClaw #509 (launch-seed lead): expected vault-side receipt of the launch
    ///      seed after the wrapper path's two taxed hops (batcher→wrapper pull,
    ///      wrapper→vault deposit), netted by the token's quoted worst-case plain-transfer
    ///      tax. Falls back to the nominal amount when the token exposes no quote.
    function _expectedSeedReceived(address token, uint256 amount) internal view returns (uint256) {
        uint256 buyBps;
        try IAgentTokenV4(token).buyTaxBps() returns (uint16 bps) {
            buyBps = bps;
        } catch {
            return amount;
        }
        uint256 sellBps;
        try IAgentTokenV4(token).sellTaxBps() returns (uint16 bps) {
            sellBps = bps;
        } catch {
            return amount;
        }
        uint256 taxBps = sellBps > buyBps ? sellBps : buyBps;
        if (taxBps == 0) return amount;
        if (taxBps > 10_000) taxBps = 10_000;
        uint256 oneHop = (amount * (10_000 - taxBps)) / 10_000;
        return (oneHop * (10_000 - taxBps)) / 10_000;
    }

    function _validateFinalizePhase2(
        DeploymentBatcher.Phase2FinalizeParams calldata params,
        DeploymentBatcher.Phase1SplitState calldata p1state
    ) internal view {
        if (params.creatorToken == address(0) || params.owner == address(0)) revert ZeroAddress();
        if (params.vault == address(0) || params.wrapper == address(0) || params.shareOFT == address(0)) {
            revert ZeroAddress();
        }
        if (params.gaugeController == address(0) || params.ccaLaunchArm == address(0) || params.oracle == address(0)) {
            revert ZeroAddress();
        }
        // ODA-464-F06: scale 18-decimal deposit bounds to the creator token's decimals.
        (uint256 minDeposit, uint256 maxDeposit) = _scaledDepositBounds(params.creatorToken);
        // LeftClaw #509 (launch-seed lead): the FLOOR binds what the vault is expected
        // to RECEIVE — the wrapper path taxes both hops (batcher→wrapper pull,
        // wrapper→vault deposit), so a nominal-50M seed silently under-seeds a taxed
        // lane and can even brick finalization behind the vault's first-deposit
        // minimum. The CAP stays nominal (it bounds treasury exposure, not receipts).
        // Tokens without a tax quote (e.g. untaxed creator tokens) keep the legacy
        // nominal check.
        uint256 expectedReceived = _expectedSeedReceived(params.creatorToken, params.depositAmount);
        if (expectedReceived < minDeposit || params.depositAmount > maxDeposit) {
            revert InvalidDepositAmount();
        }
        if (params.vault.code.length == 0 || params.wrapper.code.length == 0 || params.shareOFT.code.length == 0) {
            revert Phase1Missing();
        }
        if (
            params.gaugeController.code.length == 0 || params.ccaLaunchArm.code.length == 0
                || params.oracle.code.length == 0
        ) {
            revert Phase2Missing();
        }
        if (!p1state.finalized) revert Phase1Missing();
        if (p1state.vault != params.vault || p1state.wrapper != params.wrapper || p1state.shareOFT != params.shareOFT) {
            revert Phase1StateMismatch();
        }
        // Bind finalize recipients to vault-wired Phase2 core (blocks diverted LP reserve).
        if (params.gaugeController != IOVault4626(params.vault).gaugeController()) revert Phase2WiringMismatch();
        if (params.ccaLaunchArm != IOVault4626(params.vault).ccaLaunchArm()) revert Phase2WiringMismatch();
        if (params.oracle != ITradeFeeCollector4626(params.gaugeController).oracle()) revert Phase2WiringMismatch();
    }

    function finalizePhase2Orchestrator(
        DeploymentBatcher.Phase2FinalizeParams calldata params,
        DeploymentBatcher.Phase1SplitState calldata p1state,
        bytes32 baseSalt
    ) public returns (DeploymentBatcher.Phase2Result memory out, FinalizeExecutionResult memory execution) {
        if (address(this) != batcher) revert NotBatcherContext();
        _validateFinalizePhase2(params, p1state);
        out.gaugeController = params.gaugeController;
        out.ccaLaunchArm = params.ccaLaunchArm;
        out.oracle = params.oracle;
        execution = finalizePhase2Execution(params, baseSalt);
    }

    struct FinalizeEntryResult {
        DeploymentBatcher.Phase2Result phase2;
        FinalizeExecutionResult execution;
    }

    error PermitTokenMismatch();
    error PermitAmountTooLow();

    function finalizePhase2Entry(
        DeploymentBatcher.Phase2FinalizeParams calldata params,
        DeploymentBatcher.Phase1SplitState calldata p1state,
        bytes32 baseSalt
    ) external payable returns (FinalizeEntryResult memory result) {
        if (address(this) != batcher) revert NotBatcherContext();
        IERC20(params.creatorToken).safeTransferFrom(msg.sender, address(this), params.depositAmount);
        (result.phase2, result.execution) = finalizePhase2Orchestrator(params, p1state, baseSalt);
    }

    function finalizePhase2EntryWithPermit2(
        DeploymentBatcher.Phase2FinalizeParams calldata params,
        DeploymentBatcher.Phase1SplitState calldata p1state,
        bytes32 baseSalt,
        address permit2,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) external payable returns (FinalizeEntryResult memory result) {
        if (address(this) != batcher) revert NotBatcherContext();
        if (permit.permitted.token != params.creatorToken) revert PermitTokenMismatch();
        if (permit.permitted.amount < params.depositAmount) revert PermitAmountTooLow();
        ISignatureTransfer.SignatureTransferDetails memory details =
            ISignatureTransfer.SignatureTransferDetails({to: address(this), requestedAmount: params.depositAmount});
        ISignatureTransfer(permit2).permitTransferFrom(permit, details, msg.sender, signature);
        (result.phase2, result.execution) = finalizePhase2Orchestrator(params, p1state, baseSalt);
    }
}

/**
 * @title DeploymentBatcher
 * @author 0xakita.eth
 * @notice Multi-transaction 4626 deployment orchestrator (Phases 1–3) for creator, agent, and future ecosystems.
 * @dev Lane-specific logic (e.g. creator vesting, agent tax) is branched via params and registry.
 *      We can no longer deploy the full stack in one transaction on Base due to code-deposit gas limits.
 *      This contract splits deployment into multiple calls:
 *      - Phase 1: deploy vault + wrapper + shareOFT + minimal wiring (no token pulls / no auction)
 *      - Phase 2a: deploy gauge + CCA + oracle + wiring (no token pulls)
 *      - Phase 2b: deposit + vesting + ownership transfers (plus optional deferred auction)
 */
contract DeploymentBatcher is ReentrancyGuard {
    modifier onlyProtocolTreasury() {
        if (msg.sender != protocolTreasury) revert NotProtocolTreasury();
        _;
    }

    /// @notice Charm Finance Alpha Vault Factory on Base.
    address public constant CHARM_FACTORY = 0x5B7B8b487D05F77977b7ABEec5F922925B9b2aFa;

    // ── Launch inventory split (bps / 10_000) ───────────────────────
    /// @notice Minimum deposit amount (50M tokens, 18 decimals)
    uint256 public constant MIN_DEPOSIT = 50_000_000e18;
    /// @notice Maximum deposit amount (100M tokens, 18 decimals)
    /// @dev Enforcement lives in DeploymentBatcherPhase2Module._validateFinalizePhase2
    ///      (hot-swappable). The live shell at 0xa99058… predates the 100M widening and
    ///      still reports 50M here; these getters are informational only.
    uint256 public constant MAX_DEPOSIT = 100_000_000e18;
    uint16 public constant BPS_DENOMINATOR = 10_000;
    /// @notice Creator linear vesting share of ■ at finalize
    uint16 public constant VESTING_BPS = 2_500;
    /// @notice Solana mesh auto-bridge share of ■ at finalize
    uint16 public constant SOLANA_BPS = 2_500;
    /// @notice Base CCA auction inventory (50% of Base's 25% live book = 12.5% of supply)
    uint16 public constant BASE_AUCTION_BPS = 1_250;
    /// @notice Base CCA LP reserve for post-auction seedLpManager (50% of Base's 25% live book)
    uint16 public constant BASE_LP_RESERVE_BPS = 1_250;
    /// @notice Spoke EVM inventory (RH+Arb+Eth+Uni) custodied — not a live CCA/LP book
    uint16 public constant SPOKE_INVENTORY_BPS = 2_500;
    /// @notice Within the live Base CCA leg: auction share (50%, self-funded)
    uint16 public constant CCA_LEG_AUCTION_BPS = 5_000;
    /// @notice Within the live Base CCA leg: LP reserve share (50%, self-funded)
    uint16 public constant CCA_LEG_LP_RESERVE_BPS = 5_000;
    /// @notice Default launch discount (98% of oracle-derived reference price).
    uint16 public constant DEFAULT_LAUNCH_DISCOUNT_BPS = 9_800;
    /// @notice Default launch tick spacing (1% of derived floor price).
    uint16 public constant DEFAULT_LAUNCH_TICK_SPACING_BPS = 100;

    struct CodeIds {
        bytes32 vault;
        bytes32 wrapper;
        bytes32 shareOFT;
        bytes32 gauge;
        bytes32 cca;
        bytes32 oracle;
        bytes32 oftBootstrap;
    }

    enum VaultKind {
        Creator,
        Agent
    }

    struct Phase1Params {
        address creatorToken;
        address owner;
        string vaultName;
        string vaultSymbol;
        string shareName;
        string shareSymbol;
        string version;
        VaultKind vaultKind;
    }

    // === Canonical Value Lane Terminology (AGENTS.md) ===
    // The five mandated lane names are: tradeFeeCollector, creatorCoinPayoutRecipient,
    // creatorTreasury, jackpotCustodian, jackpotPayoutAuthority.
    // The struct field below retains the legacy name `payoutRecipient` only for
    // on-chain ABI / calldata compatibility with existing callers. All comments,
    // errors, and new code must use the canonical `creatorCoinPayoutRecipient`
    // framing for the external earnings lane (the one that feeds CreatorPayoutRouter
    // → VaultShareBurnStream for PPS accretion).
    struct Phase2Params {
        address creatorToken;
        address owner;
        address creatorTreasury;
        address payoutRecipient; // creatorCoinPayoutRecipient (external earnings lane per AGENTS.md canonical terminology)
        address vault;
        address wrapper;
        address shareOFT;
        string shareSymbol;
        string version;
        uint256 depositAmount;
        uint128 requiredRaise;
        uint256 floorPriceQ96; // Ignored by strategy; launch floor is derived onchain.
        bytes auctionSteps;
    }

    struct Phase2CoreParams {
        address creatorToken;
        address owner;
        address creatorTreasury;
        address payoutRecipient; // creatorCoinPayoutRecipient (external earnings lane per AGENTS.md canonical terminology)
        address vault;
        address wrapper;
        address shareOFT;
        string shareSymbol;
        string version;
        uint256 floorPriceQ96; // Ignored by strategy; launch floor is derived onchain.
        // NOTE: AA95 init-code hashes are NOT on this struct — changing it would break the live
        // shell's deployPhase2Core selector. Precreate publishes hashes on the Phase2 module via
        // `setPendingInitCodeHashes` instead (see DeploymentBatcherPhase2Module).
    }

    struct Phase2FinalizeParams {
        address creatorToken;
        address owner;
        address vault;
        address wrapper;
        address shareOFT;
        address gaugeController;
        address ccaLaunchArm;
        address oracle;
        string version;
        uint256 depositAmount;
        uint128 requiredRaise;
        uint256 floorPriceQ96; // Ignored by strategy; launch floor is derived onchain.
        bytes auctionSteps;
    }

    struct Phase1Result {
        address oftBootstrapRegistry;
        address vault;
        address wrapper;
        address shareOFT;
    }

    struct Phase1SplitState {
        address oftBootstrapRegistry;
        address vault;
        address wrapper;
        address shareOFT;
        bytes32 shareOftSalt;
        bytes32 paramsHash;
        bytes32 codeIdsHash;
        bool coreDone;
        bool finalized;
        VaultKind vaultKind;
    }

    struct Phase2Result {
        address gaugeController;
        address ccaLaunchArm;
        address oracle;
        address auction;
    }

    struct PendingAuction {
        address shareOFT;
        address ccaLaunchArm;
        uint256 amount;
        uint256 lpReserveAmount;
    }

    struct DeferredAuctionParams {
        address creatorToken;
        address owner;
        address shareOFT;
        string version;
        uint256 floorPriceQ96; // Ignored by strategy; launch floor is derived onchain.
        uint128 requiredRaise;
        bytes auctionSteps;
    }

    struct StrategyCodeIds {
        bytes32 charmAlphaVaultDeploy;
        bytes32 charmStrategy4626;
        bytes32 ajnaVaultAuth;
        bytes32 ajnaVault;
        bytes32 erc4626StrategyAdapter;
        bytes32 solanaStrategy;
    }

    struct Phase3Params {
        address creatorToken;
        address owner;
        address vault;
        string version;
        // If the CREATOR/USDC V3 pool does not exist yet, we can create it with this initial price.
        // If the pool already exists, you can pass 0 and we'll skip initialization.
        uint160 initialSqrtPriceX96;
        string charmVaultName;
        string charmVaultSymbol;
        string ajnaVaultName;
        string ajnaVaultSymbol;
        uint256 charmWeightBps;
        uint256 ajnaWeightBps;
        uint256 solanaWeightBps;
        uint256 ajnaBufferRatioBps;
        uint256 ajnaMinBucketIndex;
        address ajnaKeeper;
        address solanaKeeper;
        uint64 solanaMaxNavAge;
        uint16 solanaMaxNavDeltaBpsPerUpdate;
        uint16 solanaMinBaseLiquidityBps;
        address solanaBridgeAddress;
        bool enableAutoAllocate;
        // Optional override: expected Charm factory protocol fee in 1e6 precision.
        // Set to 0 to use CHARM_DEFAULT_PROTOCOL_FEE_PIPS.
        uint24 expectedCharmProtocolFeePips;
    }

    struct Phase3Result {
        address v3Pool;
        address charmVault;
        address charmStrategy;
        address ajnaVaultAuth;
        address ajnaVault;
        address ajnaStrategy;
        address solanaStrategy;
    }

    struct ShareMeshCodeIds {
        bytes32 approvedV4HooksRegistry;
        bytes32 lpManager;
    }

    struct ShareMeshDeployParams {
        address creatorToken;
        address shareOFT;
        address vault;
        address ccaLaunchArm;
        address oracle;
        address owner;
        string version;
        address positionManager;
        address poolHook;
        address registryOwner;
        address keeperManager;
        address[] hooksToApprove;
    }

    struct ShareMeshDeployResult {
        address hookRegistry;
        address lpManager;
    }

    struct OVaultRuntimeConfig {
        address hubComposer;
        uint32 solanaEid;
        bool enabled;
    }

    error ZeroAddress();
    error InvalidDepositAmount();
    error InvalidCodeId();
    error NotOwner();
    error Phase1Missing();
    error Phase1CoreMissing();
    error Phase1StateMismatch();
    error InvalidWeight();
    error V3PoolMissing();
    error MissingInitialSqrtPriceX96();
    error AuctionAlreadyPending();
    // FIX: F-02 — per-token guard prevents version-replay bricking
    error AuctionAlreadyPendingForToken(address creatorToken, address owner);
    error NoPendingAuction();
    error AuctionShareOFTMismatch();
    error AuctionAmountMismatch();
    error Phase2Missing();
    error InvalidSolanaEid();
    error InvalidSolanaBridgeConfig();
    error Phase1ShareOFTMissing();
    // FIX: F-06 — cap symbol length to prevent gas griefing
    error SymbolTooLong();
    // FIX: F-15 — dedicated error for protocol treasury auth
    error NotProtocolTreasury();
    // FIX: F-26 — admin function to clear stuck Phase 1 state
    error Phase1StateNotStuck();
    error Phase1AlreadyFinalized();
    error InvalidCreatorTreasury(address provided);
    // Canonical terminology note (AGENTS.md): this error guards the
    // creatorCoinPayoutRecipient (external earnings) lane. The field name
    // `payoutRecipient` is retained for on-chain ABI compatibility; all new
    // code and docs must use the five mandated lane names.
    error InvalidCreatorCoinPayoutRecipient();
    error DeprecatedFinalizeSolanaParams();
    error WrapperOwnerMismatch(address wrapper, address owner);
    error ShareOftOwnerMismatch(address shareOft, address owner);
    error RegistryCreatorMismatch(address creatorToken, address registeredCreator, address requestedOwner);
    error RolePolicyOverrideRejected(uint256 requestedPolicyId, uint256 configuredPolicyId);
    error Phase3ManagementMismatch(address expected, address actual);
    error CharmFactoryGovernanceMismatch(address expected, address actual);
    error CharmFactoryProtocolFeeMismatch(uint256 expected, uint256 actual);
    error CharmVaultManagerMismatch(address expected, address actual);
    error InvalidTickSpacing();
    error InvalidPoolCurrencies();
    error InvalidRolePolicyManager();
    error InvalidPhase2Module();
    error InvalidPhase1Module();
    error ModuleCodehashMismatch(address module, bytes32 expected, bytes32 actual);
    /// @dev AUDIT-2026-07-08-H08: module must be pre-approved with a non-zero codehash.
    error PhaseModuleCodehashNotApproved(address module);
    /// @dev AUDIT-2026-07-08-NEW-H: deploy codeId not on the treasury allowlist.
    error CodeIdNotApproved(bytes32 codeId);
    /// @notice ODA-464-F02: live store bytecode no longer matches hash captured at approve time.
    error CodeIdBytecodeHashMismatch(bytes32 codeId, bytes32 expected, bytes32 actual);
    error CodeIdAllowlistFrozen();
    error GasLimitBelowDefault(uint128 provided, uint128 minimum);

    /// @dev AUDIT-2026-07-08-H08 — mandatory codehash allowlist for phase1/2 module hot-swap.
    mapping(address => bytes32) public approvedPhaseModuleCodehashes;
    /// @dev AUDIT-2026-07-08-NEW-H — bytecode codeIds permitted for CREATE2 deploys via this batcher.
    mapping(bytes32 => bool) public approvedCodeIds;
    /// @notice ODA-464-F02: keccak256(creationCode) snapshotted when a codeId is approved.
    /// @dev Zero means legacy approve (or store miss at approve time) — hash check skipped.
    mapping(bytes32 => bytes32) public approvedCodeIdBytecodeHash;
    /// @notice When true (default), every phase deploy codeId must be approved.
    bool public codeIdAllowlistEnabled = true;
    /// @notice When true, allowlist enabled flag and further disable attempts are frozen on.
    bool public codeIdAllowlistFrozen;
    error Phase1ModuleMissing();

    event PhaseModuleCodehashApproved(address indexed module, bytes32 codehash);
    event CodeIdApprovalUpdated(bytes32 indexed codeId, bool approved);
    event CodeIdAllowlistEnabledUpdated(bool enabled);
    event CodeIdAllowlistFrozenEvent();

    IRegistry4626 public immutable registry;
    IUniversalBytecodeStore public immutable bytecodeStore;
    IUniversalCreate2DeployerFromStore public immutable create2Deployer;

    address public immutable protocolTreasury;
    address public immutable poolManager;
    address public immutable taxHook;
    address public immutable chainlinkEthUsd;
    address public immutable vaultActivationBatcher;
    address public immutable lotteryManager;
    address public immutable permit2;
    address public immutable usdc;
    address public immutable uniswapV3Factory;
    address public immutable uniswapRouter;
    address public immutable ajnaFactory;
    address public vaultRolePolicyManager;
    uint256 public vaultRolePolicyId;

    // CreatorOVault delegatecall modules (shared logic contracts).
    address public immutable vaultCoreModule;
    address public immutable vaultStrategiesModule;
    address public vaultAdminModule;

    /// @notice Pending auction allocations keyed by creator/owner/version salt.
    mapping(bytes32 => PendingAuction) public pendingAuctions;
    // FIX: F-02 — per-token+owner pending auction guard (version-independent)
    mapping(bytes32 => bool) public hasActivePendingAuction;
    /// @notice Split phase-1 state keyed by creator/owner/version salt.
    mapping(bytes32 => Phase1SplitState) public phase1SplitStates;

    /// @notice Solana deployer/multisig wallet address (bytes32 pubkey) to receive LayerZero ShareOFT.
    bytes32 public solanaDestination;
    /// @notice OVault runtime wiring used for Solana compose orchestration.
    OVaultRuntimeConfig private ovaultRuntimeConfig;
    /// @notice Dedicated phase-3 execution helper to keep this contract under EIP-170 runtime limits.
    DeploymentBatcherPhase3Helper public phase3Helper;
    /// @notice Dedicated phase-2 execution helper (delegatecall) to keep this contract under EIP-170 runtime limits.
    DeploymentBatcherPhase2Module public phase2Module;
    /// @notice Dedicated phase-1 execution helper (delegatecall) to keep initcode under EIP-3860 limits.
    DeploymentBatcherPhase1Module public phase1Module;
    /// @notice Dedicated Share-mesh LP deploy helper to keep this contract under EIP-170 runtime limits.
    DeploymentBatcherShareMeshHelper public shareMeshHelper;
    /// @notice String/salt/hash helper contract to keep this contract under EIP-170 runtime limits.
    DeploymentBatcherUtilsHelper public utilsHelper;
    /// @notice Custody recipient for spoke EVM CCA inventory (RH/Arb/Eth/Uni). Zero → protocolTreasury.
    /// @dev Appended after helpers so a greenfield shell cut does not reshuffle prior slots vs v1.21/v1.22 shells.
    address public spokeInventoryRecipient;
    /// @notice Executor lzReceive gas for Pipe A ShareOFT → Solana. Owner may raise, not lower.
    uint128 public shareBridgeGasLimit = 200_000;

    event Phase1Deployed(
        address indexed creatorToken,
        address indexed owner,
        address oftBootstrapRegistry,
        address vault,
        address wrapper,
        address shareOFT
    );

    event Phase1CoreDeployed(
        address indexed creatorToken,
        address indexed owner,
        address oftBootstrapRegistry,
        address vault,
        address wrapper,
        bytes32 shareOftSalt
    );

    event Phase2DeployedAndLaunched(
        address indexed creatorToken,
        address indexed owner,
        address gaugeController,
        address ccaLaunchArm,
        address oracle,
        address auction
    );

    event Phase2CoreDeployed(
        address indexed creatorToken,
        address indexed owner,
        address gaugeController,
        address ccaLaunchArm,
        address oracle
    );

    event AuctionDeferred(
        address indexed creatorToken,
        address indexed owner,
        address indexed shareOFT,
        address ccaLaunchArm,
        uint256 amount,
        uint256 lpReserveAmount
    );

    event AuctionLaunchedDeferred(
        address indexed creatorToken,
        address indexed owner,
        address indexed shareOFT,
        address ccaLaunchArm,
        uint256 amount,
        address auction
    );

    event Phase3StrategiesDeployed(
        address indexed creatorToken,
        address indexed owner,
        address indexed vault,
        address v3Pool,
        address charmVault,
        address charmStrategy,
        address ajnaVaultAuth,
        address ajnaVault,
        address ajnaStrategy,
        address solanaStrategy,
        uint256 charmWeightBps,
        uint256 ajnaWeightBps,
        uint256 solanaWeightBps
    );

    event ShareMeshLpManagerDeployed(
        address indexed creatorToken,
        address indexed owner,
        address indexed vault,
        address ccaLaunchArm,
        address hookRegistry,
        address lpManager,
        address poolHook,
        address registryOwner
    );

    event CreatorShareVestingDeployed(
        address indexed shareOFT,
        address indexed beneficiary,
        address vesting,
        uint256 amount,
        uint64 startTimestamp,
        uint64 durationSeconds
    );

    event ShareAllocationBridgedToSolana(
        address indexed creatorToken,
        address indexed owner,
        address indexed shareOFT,
        uint256 amount,
        bytes32 solanaDestination
    );

    event SpokeCcaInventoryReserved(
        address indexed creatorToken,
        address indexed owner,
        address indexed shareOFT,
        address recipient,
        uint256 amount
    );

    event SpokeInventoryRecipientSet(address indexed recipient);

    event SolanaDestinationSet(bytes32 solanaDestination);
    event OVaultRuntimeConfigSet(address indexed hubComposer, uint32 indexed solanaEid, bool enabled);
    event ShareBridgeGasLimitSet(uint128 gasLimit);
    event VaultRolePolicyConfigSet(address indexed manager, uint256 indexed policyId);

    constructor(
        address _registry,
        address _bytecodeStore,
        address _create2Deployer,
        address _protocolTreasury,
        address _protocolAutomation,
        address _poolManager,
        address _taxHook,
        address _chainlinkEthUsd,
        address _vaultActivationBatcher,
        address _lotteryManager,
        address _permit2,
        address _usdc,
        address _uniswapV3Factory,
        address _uniswapRouter,
        address _ajnaFactory,
        address _vaultCoreModule,
        address _vaultStrategiesModule,
        address _vaultAdminModule,
        address _phase2Module,
        address _phase3Helper,
        address _shareMeshHelper,
        address _utilsHelper
    ) {
        // Stack-depth fix (fixup5f): interleave each param's zero-check immediately
        // before its assignment so the Yul optimizer lazy-loads each calldataload
        // value just before its first use rather than holding all 18 simultaneously
        // live at the first grouped check. Multi-use params are read from their state
        // vars in the helper deployments below (calldataload values freed above).
        if (_registry == address(0)) revert ZeroAddress();
        registry = IRegistry4626(_registry);

        if (_bytecodeStore == address(0)) revert ZeroAddress();
        bytecodeStore = IUniversalBytecodeStore(_bytecodeStore);

        if (_create2Deployer == address(0)) revert ZeroAddress();
        create2Deployer = IUniversalCreate2DeployerFromStore(_create2Deployer);

        if (_protocolTreasury == address(0)) revert ZeroAddress();
        protocolTreasury = _protocolTreasury;

        if (_protocolAutomation == address(0)) revert ZeroAddress();

        if (_poolManager == address(0)) revert ZeroAddress();
        poolManager = _poolManager;

        if (_taxHook == address(0)) revert ZeroAddress();
        taxHook = _taxHook;

        if (_chainlinkEthUsd == address(0)) revert ZeroAddress();
        chainlinkEthUsd = _chainlinkEthUsd;

        vaultActivationBatcher = _vaultActivationBatcher;
        lotteryManager = _lotteryManager;
        permit2 = _permit2;

        if (_usdc == address(0)) revert ZeroAddress();
        usdc = _usdc;

        if (_uniswapV3Factory == address(0)) revert ZeroAddress();
        uniswapV3Factory = _uniswapV3Factory;

        if (_uniswapRouter == address(0)) revert ZeroAddress();
        uniswapRouter = _uniswapRouter;

        if (_ajnaFactory == address(0)) revert ZeroAddress();
        ajnaFactory = _ajnaFactory;

        if (_vaultCoreModule == address(0)) revert ZeroAddress();
        vaultCoreModule = _vaultCoreModule;

        if (_vaultStrategiesModule == address(0)) revert ZeroAddress();
        vaultStrategiesModule = _vaultStrategiesModule;

        if (_vaultAdminModule == address(0)) revert ZeroAddress();
        vaultAdminModule = _vaultAdminModule;

        // CREATE2 shell path: pass zero for all helper slots and wire post-deploy via
        // wireDeploymentHelpers + setPhase1Module (Safe). Non-shell paths must pass
        // pre-deployed helper addresses (no inline `new` — keeps initcode under EIP-3860).
        bool shellMode = _phase2Module == address(0) && _phase3Helper == address(0) && _shareMeshHelper == address(0)
            && _utilsHelper == address(0);

        if (!shellMode) {
            if (
                _phase2Module == address(0) || _phase3Helper == address(0) || _shareMeshHelper == address(0)
                    || _utilsHelper == address(0)
            ) {
                revert ZeroAddress();
            }
            phase2Module = DeploymentBatcherPhase2Module(_phase2Module);
            phase3Helper = DeploymentBatcherPhase3Helper(_phase3Helper);
            shareMeshHelper = DeploymentBatcherShareMeshHelper(_shareMeshHelper);
            utilsHelper = DeploymentBatcherUtilsHelper(_utilsHelper);
        }

        require(block.chainid == 8453, "DeploymentBatcher: Base only");
    }

    // ================================
    // PHASE 1
    // ================================

    /**
     * @notice Deploy Phase-1 core with optional ShareOFT salt confirmation.
     * @param shareOftSaltOverride Zero uses the derived CREATE2 salt. Nonzero must equal
     *        `deriveShareOftSalt(creatorToken, owner, toLower(shareSymbol), version)` —
     *        free-form salts are rejected (`InvalidShareOftSaltOverride`).
     */
    function deployPhase1CoreWithSalt(
        Phase1Params calldata params,
        CodeIds calldata codeIds,
        bytes32 shareOftSaltOverride
    ) external nonReentrant returns (Phase1Result memory out) {
        return _deployPhase1CoreInternal(params, codeIds, shareOftSaltOverride);
    }

    /**
     * @notice Finalize Phase-1 with optional ShareOFT salt confirmation.
     * @param shareOftSaltOverride Zero uses the derived CREATE2 salt. Nonzero must equal
     *        `deriveShareOftSalt(creatorToken, owner, toLower(shareSymbol), version)` —
     *        free-form salts are rejected (`InvalidShareOftSaltOverride`).
     */
    function finalizePhase1WithSalt(
        Phase1Params calldata params,
        CodeIds calldata codeIds,
        bytes32 shareOftSaltOverride
    ) external nonReentrant returns (Phase1Result memory out) {
        return _finalizePhase1InternalSplit(params, codeIds, shareOftSaltOverride);
    }

    function _deployPhase1CoreInternal(
        Phase1Params calldata params,
        CodeIds calldata codeIds,
        bytes32 shareOftSaltOverride
    ) internal returns (Phase1Result memory out) {
        _requireOwner(params.owner);
        if (address(phase1Module) == address(0)) revert Phase1ModuleMissing();

        bytes32 baseSalt = utilsHelper.deriveBaseSalt(params.creatorToken, params.owner, block.chainid, params.version);
        Phase1SplitState memory existing = phase1SplitStates[baseSalt];
        bool wasCoreDone = existing.coreDone;
        bytes memory moduleOut = _delegatePhase1(
            abi.encodeWithSelector(
                DeploymentBatcherPhase1Module.deployPhase1Core.selector, params, codeIds, existing, shareOftSaltOverride
            )
        );
        Phase1SplitState memory newState;
        (out, newState) = abi.decode(moduleOut, (Phase1Result, Phase1SplitState));
        phase1SplitStates[baseSalt] = newState;

        if (!wasCoreDone && newState.coreDone) {
            emit Phase1CoreDeployed(
                params.creatorToken,
                params.owner,
                out.oftBootstrapRegistry,
                out.vault,
                out.wrapper,
                newState.shareOftSalt
            );
        }
    }

    function _finalizePhase1InternalSplit(
        Phase1Params calldata params,
        CodeIds calldata codeIds,
        bytes32 shareOftSaltOverride
    ) internal returns (Phase1Result memory out) {
        _requireOwner(params.owner);
        if (address(phase1Module) == address(0)) revert Phase1ModuleMissing();

        bytes32 baseSalt = utilsHelper.deriveBaseSalt(params.creatorToken, params.owner, block.chainid, params.version);
        Phase1SplitState memory existing = phase1SplitStates[baseSalt];
        bool wasFinalized = existing.finalized;
        bytes memory moduleOut = _delegatePhase1(
            abi.encodeWithSelector(
                DeploymentBatcherPhase1Module.finalizePhase1Split.selector,
                params,
                codeIds,
                existing,
                shareOftSaltOverride
            )
        );
        Phase1SplitState memory newState;
        (out, newState) = abi.decode(moduleOut, (Phase1Result, Phase1SplitState));
        phase1SplitStates[baseSalt] = newState;

        if (!wasFinalized && newState.finalized) {
            emit Phase1Deployed(
                params.creatorToken, params.owner, out.oftBootstrapRegistry, out.vault, out.wrapper, out.shareOFT
            );
        }
    }

    // ================================
    // PHASE 2
    // ================================

    function deployPhase2Core(Phase2CoreParams calldata params, CodeIds calldata codeIds)
        external
        nonReentrant
        returns (Phase2Result memory out)
    {
        out = _deployPhase2CoreInternal(params, codeIds, vaultRolePolicyId);
        emit Phase2CoreDeployed(params.creatorToken, params.owner, out.gaugeController, out.ccaLaunchArm, out.oracle);
    }

    /**
     * @notice Optional policy-aware variant for deploy-session guarded flows.
     * @dev Existing `deployPhase2Core` behavior remains unchanged and uses the
     *      globally configured `vaultRolePolicyId`.
     */
    function deployPhase2CoreWithRolePolicy(
        Phase2CoreParams calldata params,
        CodeIds calldata codeIds,
        uint256 rolePolicyId
    ) external nonReentrant returns (Phase2Result memory out) {
        out = _deployPhase2CoreInternal(params, codeIds, rolePolicyId);
        emit Phase2CoreDeployed(params.creatorToken, params.owner, out.gaugeController, out.ccaLaunchArm, out.oracle);
    }

    function _deployPhase2CoreInternal(Phase2CoreParams calldata params, CodeIds calldata codeIds, uint256 rolePolicyId)
        internal
        returns (Phase2Result memory out)
    {
        _requireOwner(params.owner);
        uint256 activeRolePolicyId = rolePolicyId;
        if (vaultRolePolicyManager != address(0)) {
            activeRolePolicyId = vaultRolePolicyId;
            if (rolePolicyId != activeRolePolicyId) {
                revert RolePolicyOverrideRejected(rolePolicyId, activeRolePolicyId);
            }
        }
        bytes32 baseSalt = utilsHelper.deriveBaseSalt(params.creatorToken, params.owner, block.chainid, params.version);
        Phase1SplitState memory p1state = phase1SplitStates[baseSalt];
        string memory shareSymbolLower = utilsHelper.toLower(params.shareSymbol);
        bytes memory outData = _delegatePhase2(
            abi.encodeWithSelector(
                DeploymentBatcherPhase2Module.deployPhase2CoreOrchestrator.selector,
                params,
                codeIds,
                baseSalt,
                shareSymbolLower,
                p1state,
                vaultRolePolicyManager,
                activeRolePolicyId
            )
        );
        out = abi.decode(outData, (Phase2Result));
    }

    /// @notice Whitelist the payout router on the wrapper while the batcher still owns it.
    /// @dev Must run after payout router CREATE2 deploy and before finalizePhase2 ownership transfer.
    function whitelistPayoutRouterOnWrapper(address wrapper, address payoutRouter) external onlyProtocolTreasury {
        if (wrapper == address(0) || payoutRouter == address(0)) revert ZeroAddress();
        address wrapperOwner = IOwnableView(wrapper).owner();
        if (wrapperOwner != address(this)) revert WrapperOwnerMismatch(wrapper, wrapperOwner);
        IOVaultWrapper4626(wrapper).setWhitelist(payoutRouter, true);
    }

    /// @notice Mark the payout router ShareOFT fee-exempt while the batcher still owns ShareOFT.
    /// @dev OperationType.NoFees = 2. Must run before finalizePhase2 transfers ShareOFT to treasury.
    function setPayoutRouterShareOftNoFees(address shareOFT, address payoutRouter) external onlyProtocolTreasury {
        if (shareOFT == address(0) || payoutRouter == address(0)) revert ZeroAddress();
        address shareOwner = IOwnableView(shareOFT).owner();
        if (shareOwner != address(this)) revert ShareOftOwnerMismatch(shareOFT, shareOwner);
        IShareOFT4626(shareOFT).setAddressType(payoutRouter, 2);
    }

    function finalizePhase2(Phase2FinalizeParams calldata params)
        external
        payable
        nonReentrant
        returns (Phase2Result memory out)
    {
        _requireOwner(params.owner);
        bytes32 baseSalt = utilsHelper.deriveBaseSalt(params.creatorToken, params.owner, block.chainid, params.version);
        Phase1SplitState memory p1state = phase1SplitStates[baseSalt];
        bytes memory moduleOut = _delegatePhase2(
            abi.encodeWithSelector(
                DeploymentBatcherPhase2Module.finalizePhase2Entry.selector, params, p1state, baseSalt
            )
        );
        DeploymentBatcherPhase2Module.FinalizeEntryResult memory result =
            abi.decode(moduleOut, (DeploymentBatcherPhase2Module.FinalizeEntryResult));
        _recordFinalizePhase2Effects(params, baseSalt, result.phase2, result.execution);
        return result.phase2;
    }

    function finalizePhase2WithPermit2(
        Phase2FinalizeParams calldata params,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) external payable nonReentrant returns (Phase2Result memory out) {
        _requireOwner(params.owner);
        bytes32 baseSalt = utilsHelper.deriveBaseSalt(params.creatorToken, params.owner, block.chainid, params.version);
        Phase1SplitState memory p1state = phase1SplitStates[baseSalt];
        bytes memory moduleOut = _delegatePhase2(
            abi.encodeWithSelector(
                DeploymentBatcherPhase2Module.finalizePhase2EntryWithPermit2.selector,
                params,
                p1state,
                baseSalt,
                permit2,
                permit,
                signature
            )
        );
        DeploymentBatcherPhase2Module.FinalizeEntryResult memory result =
            abi.decode(moduleOut, (DeploymentBatcherPhase2Module.FinalizeEntryResult));
        _recordFinalizePhase2Effects(params, baseSalt, result.phase2, result.execution);
        return result.phase2;
    }

    function _recordFinalizePhase2Effects(
        Phase2FinalizeParams calldata params,
        bytes32 baseSalt,
        Phase2Result memory out,
        DeploymentBatcherPhase2Module.FinalizeExecutionResult memory execution
    ) internal {
        if (execution.auctionAmount > 0) {
            PendingAuction storage pending = pendingAuctions[baseSalt];
            if (pending.amount != 0) revert AuctionAlreadyPending();
            bytes32 tokenOwnerKey = keccak256(abi.encodePacked(params.creatorToken, params.owner));
            if (hasActivePendingAuction[tokenOwnerKey]) {
                revert AuctionAlreadyPendingForToken(params.creatorToken, params.owner);
            }
            hasActivePendingAuction[tokenOwnerKey] = true;
            pendingAuctions[baseSalt] = PendingAuction({
                shareOFT: params.shareOFT,
                ccaLaunchArm: params.ccaLaunchArm,
                amount: execution.auctionAmount,
                lpReserveAmount: execution.lpReserveAmount
            });
            emit AuctionDeferred(
                params.creatorToken,
                params.owner,
                params.shareOFT,
                params.ccaLaunchArm,
                execution.auctionAmount,
                execution.lpReserveAmount
            );
        }

        if (execution.vestingAmount > 0) {
            emit CreatorShareVestingDeployed(
                params.shareOFT,
                params.owner,
                execution.vestingAddress,
                execution.vestingAmount,
                execution.vestingStartTimestamp,
                execution.vestingDurationSeconds
            );
        }

        if (execution.solanaAmount > 0) {
            emit ShareAllocationBridgedToSolana(
                params.creatorToken, params.owner, params.shareOFT, execution.solanaAmount, solanaDestination
            );
        }

        if (execution.spokeInventoryAmount > 0) {
            emit SpokeCcaInventoryReserved(
                params.creatorToken,
                params.owner,
                params.shareOFT,
                execution.spokeInventoryRecipient,
                execution.spokeInventoryAmount
            );
        }

        emit Phase2DeployedAndLaunched(
            params.creatorToken, params.owner, params.gaugeController, params.ccaLaunchArm, params.oracle, out.auction
        );
    }

    function launchDeferredAuction(DeferredAuctionParams calldata params)
        external
        nonReentrant
        returns (address auction)
    {
        _requireOwner(params.owner);
        if (params.creatorToken == address(0) || params.owner == address(0) || params.shareOFT == address(0)) {
            revert ZeroAddress();
        }

        bytes32 baseSalt = utilsHelper.deriveBaseSalt(params.creatorToken, params.owner, block.chainid, params.version);
        PendingAuction memory pending = pendingAuctions[baseSalt];
        if (pending.amount == 0) revert NoPendingAuction();
        if (pending.shareOFT != params.shareOFT) revert AuctionShareOFTMismatch();

        bytes memory moduleOut = _delegatePhase2(
            abi.encodeWithSelector(
                DeploymentBatcherPhase2Module.launchDeferredAuctionExecution.selector,
                params.shareOFT,
                pending.ccaLaunchArm,
                pending.amount,
                pending.lpReserveAmount,
                params.floorPriceQ96,
                params.requiredRaise,
                params.auctionSteps
            )
        );
        auction = abi.decode(moduleOut, (address));

        delete pendingAuctions[baseSalt];
        bytes32 tokenOwnerKey = keccak256(abi.encodePacked(params.creatorToken, params.owner));
        hasActivePendingAuction[tokenOwnerKey] = false;

        emit AuctionLaunchedDeferred(
            params.creatorToken, params.owner, params.shareOFT, pending.ccaLaunchArm, pending.amount, auction
        );
    }

    // ================================
    // PHASE 3 (STRATEGIES)
    // ================================

    /**
     * @notice Deploy + register initial yield strategies (Charm + Ajna).
     * @dev Solana share liquidity is seeded at finalizePhase2 via ShareOFT auto-bridge.
     */
    function deployPhase3Strategies(Phase3Params calldata params, StrategyCodeIds calldata codeIds)
        external
        nonReentrant
        returns (Phase3Result memory out)
    {
        _requireOwner(params.owner);
        // ODA-429-F2: per-call weight caps are insufficient — repeated Phase 3
        // calls could previously push vault allocation past 100%.
        uint256 addedWeight = params.charmWeightBps + params.ajnaWeightBps;
        uint256 newTotal = phase3AllocatedWeightBps[params.vault] + addedWeight;
        if (addedWeight == 0 || newTotal > 10_000) revert InvalidWeight();

        bytes32 baseSalt = utilsHelper.deriveBaseSalt(params.creatorToken, params.owner, block.chainid, params.version);
        out = phase3Helper.deployPhase3Strategies(params, codeIds, baseSalt);

        // Vault management stays on the batcher shell after finalizePhase2 ownership
        // transfer; Phase 3 helper is an external module so it must not call addStrategy.
        if (params.charmWeightBps != 0) {
            ICreatorOVaultStrategyManager(params.vault).addStrategy(out.charmStrategy, params.charmWeightBps);
        }
        if (params.ajnaWeightBps != 0) {
            ICreatorOVaultStrategyManager(params.vault).addStrategy(out.ajnaStrategy, params.ajnaWeightBps);
        }
        phase3AllocatedWeightBps[params.vault] = newTotal;
        if (params.enableAutoAllocate) {
            ICreatorOVaultStrategyManager(params.vault).setAutoAllocate(true);
        }

        emit Phase3StrategiesDeployed(
            params.creatorToken,
            params.owner,
            params.vault,
            out.v3Pool,
            out.charmVault,
            out.charmStrategy,
            out.ajnaVaultAuth,
            out.ajnaVault,
            out.ajnaStrategy,
            out.solanaStrategy,
            params.charmWeightBps,
            params.ajnaWeightBps,
            params.solanaWeightBps
        );
    }

    /**
     * @notice Deploy + configure the post-auction ShareOFT mesh LP manager.
     * @dev Requires a graduated, swept, migrated CCA. Not a vault strategy sleeve.
     */
    function deployShareMeshLpManager(ShareMeshDeployParams calldata params, ShareMeshCodeIds calldata codeIds)
        external
        nonReentrant
        returns (ShareMeshDeployResult memory out)
    {
        _requireOwner(params.owner);
        bytes32 baseSalt = utilsHelper.deriveBaseSalt(params.creatorToken, params.owner, block.chainid, params.version);
        out = shareMeshHelper.deployShareMeshLpManager(params, codeIds, baseSalt);

        emit ShareMeshLpManagerDeployed(
            params.creatorToken,
            params.owner,
            params.vault,
            params.ccaLaunchArm,
            out.hookRegistry,
            out.lpManager,
            params.poolHook,
            params.registryOwner
        );
    }

    // ================================
    // SOLANA CONFIG (ADMIN)
    // ================================

    /**
     * @notice Set the LayerZero ShareOFT recipient on Solana.
     * @dev `solanaDestination` is the LayerZero recipient for the 30% share allocation
     *      auto-bridge executed during finalizePhase2 (Solana seed wallet / mesh custody).
     */
    function setSolanaDestination(bytes32 _destination) external onlyProtocolTreasury {
        solanaDestination = _destination;
        emit SolanaDestinationSet(_destination);
    }

    /// @notice Set custody recipient for spoke EVM CCA inventory after finalize. Zero → protocolTreasury.
    function setSpokeInventoryRecipient(address recipient) external onlyProtocolTreasury {
        spokeInventoryRecipient = recipient;
        emit SpokeInventoryRecipientSet(recipient);
    }

    /// @notice Resolved spoke inventory custody address (never zero while protocolTreasury is set).
    function resolveSpokeInventoryRecipient() public view returns (address) {
        return spokeInventoryRecipient == address(0) ? protocolTreasury : spokeInventoryRecipient;
    }

    /**
     * @notice Wire CREATE2-deployed helper modules after the batcher shell is live.
     * @dev One-shot Safe batch for initial cutover; `setPhase2Module` remains for hot-swap.
     */
    function wireDeploymentHelpers(
        address _phase2Module,
        address _phase3Helper,
        address _shareMeshHelper,
        address _utilsHelper
    ) external onlyProtocolTreasury {
        if (
            _phase2Module == address(0) || _phase3Helper == address(0) || _shareMeshHelper == address(0)
                || _utilsHelper == address(0)
        ) {
            revert ZeroAddress();
        }
        // AUDIT-2026-07-08-H08: phase2 is delegatecall authority — require approved codehash.
        _validatePhaseModuleCodehash(_phase2Module);
        if (DeploymentBatcherPhase2Module(_phase2Module).batcher() != address(this)) revert InvalidPhase2Module();
        phase2Module = DeploymentBatcherPhase2Module(_phase2Module);
        phase3Helper = DeploymentBatcherPhase3Helper(_phase3Helper);
        shareMeshHelper = DeploymentBatcherShareMeshHelper(_shareMeshHelper);
        utilsHelper = DeploymentBatcherUtilsHelper(_utilsHelper);
    }

    /**
     * @notice Hot-swap the Phase 2 delegatecall module after deploying a replacement `DeploymentBatcherPhase2Module`.
     * @dev The replacement module must declare this batcher as its immutable `batcher` context.
     */
    function setPhase2Module(address _phase2Module) external onlyProtocolTreasury {
        if (_phase2Module == address(0)) revert ZeroAddress();
        _validatePhaseModuleCodehash(_phase2Module);
        if (DeploymentBatcherPhase2Module(_phase2Module).batcher() != address(this)) revert InvalidPhase2Module();
        phase2Module = DeploymentBatcherPhase2Module(_phase2Module);
    }

    function setPhase1Module(address _phase1Module) external onlyProtocolTreasury {
        if (_phase1Module == address(0)) revert ZeroAddress();
        _validatePhaseModuleCodehash(_phase1Module);
        if (DeploymentBatcherPhase1Module(_phase1Module).batcher() != address(this)) revert InvalidPhase1Module();
        phase1Module = DeploymentBatcherPhase1Module(_phase1Module);
    }

    function approvePhaseModuleCodehash(address module, bytes32 codehash) external onlyProtocolTreasury {
        if (module == address(0)) revert ZeroAddress();
        if (codehash == bytes32(0)) revert PhaseModuleCodehashNotApproved(module);
        approvedPhaseModuleCodehashes[module] = codehash;
        emit PhaseModuleCodehashApproved(module, codehash);
    }

    /// @notice Approve or revoke a bytecode-store codeId for phase CREATE2 deploys.
    /// @dev ODA-464-F02: on approve, snapshot keccak256(store.get(codeId)) so later store
    ///      repoints cannot silently satisfy the label allowlist.
    function setApprovedCodeId(bytes32 codeId, bool approved) external onlyProtocolTreasury {
        if (codeId == bytes32(0)) revert InvalidCodeId();
        approvedCodeIds[codeId] = approved;
        approvedCodeIdBytecodeHash[codeId] = approved ? _snapshotCodeIdBytecodeHash(codeId) : bytes32(0);
        emit CodeIdApprovalUpdated(codeId, approved);
    }

    function setApprovedCodeIds(bytes32[] calldata codeIds, bool approved) external onlyProtocolTreasury {
        uint256 len = codeIds.length;
        for (uint256 i = 0; i < len; i++) {
            bytes32 codeId = codeIds[i];
            if (codeId == bytes32(0)) revert InvalidCodeId();
            approvedCodeIds[codeId] = approved;
            approvedCodeIdBytecodeHash[codeId] = approved ? _snapshotCodeIdBytecodeHash(codeId) : bytes32(0);
            emit CodeIdApprovalUpdated(codeId, approved);
        }
    }

    function _snapshotCodeIdBytecodeHash(bytes32 codeId) internal view returns (bytes32) {
        try bytecodeStore.get(codeId) returns (bytes memory creationCode) {
            if (creationCode.length == 0) return bytes32(0);
            return keccak256(creationCode);
        } catch {
            return bytes32(0);
        }
    }

    /// @notice Enable/disable codeId allowlist enforcement (must be true in production).
    function setCodeIdAllowlistEnabled(bool enabled) external onlyProtocolTreasury {
        if (codeIdAllowlistFrozen) revert CodeIdAllowlistFrozen();
        codeIdAllowlistEnabled = enabled;
        emit CodeIdAllowlistEnabledUpdated(enabled);
    }

    /// @notice Permanently keep the allowlist enforced (cannot disable afterward).
    function freezeCodeIdAllowlist() external onlyProtocolTreasury {
        codeIdAllowlistEnabled = true;
        codeIdAllowlistFrozen = true;
        emit CodeIdAllowlistFrozenEvent();
    }

    /// @notice View helper for phase modules: reverts when allowlist is on and codeId is not approved.
    /// @dev ODA-464-F02: when a bytecode hash was snapshotted at approve time, also require
    ///      the live store contents still match (blocks label→bytecode repoint).
    function requireApprovedCodeId(bytes32 codeId) external view {
        if (!codeIdAllowlistEnabled) return;
        if (!approvedCodeIds[codeId]) revert CodeIdNotApproved(codeId);
        bytes32 expected = approvedCodeIdBytecodeHash[codeId];
        if (expected == bytes32(0)) return;
        bytes32 actual = _snapshotCodeIdBytecodeHash(codeId);
        if (actual != expected) revert CodeIdBytecodeHashMismatch(codeId, expected, actual);
    }

    function _validatePhaseModuleCodehash(address module) internal view {
        bytes32 expected = approvedPhaseModuleCodehashes[module];
        // AUDIT-2026-07-08-H08: zero approval is no longer a pass-through.
        if (expected == bytes32(0)) revert PhaseModuleCodehashNotApproved(module);
        bytes32 actual;
        assembly {
            actual := extcodehash(module)
        }
        if (actual != expected) revert ModuleCodehashMismatch(module, expected, actual);
    }

    /**
     * @notice Configure OVault runtime composer + Solana EID.
     * @dev Enabled configs require a non-zero composer and EID.
     */
    function setOVaultRuntimeConfig(address _hubComposer, uint32 _solanaEid, bool _enabled)
        external
        onlyProtocolTreasury
    {
        if (_enabled) {
            if (_hubComposer == address(0)) revert ZeroAddress();
            if (_solanaEid == 0) revert InvalidSolanaEid();
        }
        ovaultRuntimeConfig = OVaultRuntimeConfig({hubComposer: _hubComposer, solanaEid: _solanaEid, enabled: _enabled});
    }

    function getOVaultRuntimeConfig() external view returns (OVaultRuntimeConfig memory) {
        return ovaultRuntimeConfig;
    }

    function setShareBridgeGasLimit(uint128 gasLimit) external onlyProtocolTreasury {
        if (gasLimit < 200_000) revert GasLimitBelowDefault(gasLimit, 200_000);
        shareBridgeGasLimit = gasLimit;
        emit ShareBridgeGasLimitSet(gasLimit);
    }

    /**
     * @notice Configure optional role-policy validation for phase-2 deployment.
     * @dev Set `manager = address(0)` to disable policy checks entirely.
     */
    function setVaultRolePolicyConfig(address manager, uint256 policyId) external onlyProtocolTreasury {
        if (manager != address(0) && manager.code.length == 0) revert InvalidRolePolicyManager();
        vaultRolePolicyManager = manager;
        vaultRolePolicyId = policyId;
        emit VaultRolePolicyConfigSet(manager, policyId);
    }

    // FIX: F-26 — admin function to clear stuck Phase 1 state so (creatorToken, owner, version)
    // tuples are not permanently blocked by stale/abandoned deployments.
    // The reset must be tuple-scoped so callers cannot accidentally clear an
    // unrelated deployment state.
    function resetPhase1State(address creatorToken, address owner, string calldata version)
        external
        onlyProtocolTreasury
    {
        if (creatorToken == address(0) || owner == address(0)) revert ZeroAddress();
        bytes32 baseSalt = utilsHelper.deriveBaseSalt(creatorToken, owner, block.chainid, version);
        Phase1SplitState storage state = phase1SplitStates[baseSalt];
        // Only allow reset if Phase 1 was started but not finalized, and Phase 2 has
        // not consumed it (no pending auction). Finalized Phase 1 is live deploy truth
        // and must not be wiped (audit M-15 / L2-01).
        if (state.vault == address(0)) revert Phase1StateNotStuck();
        if (state.finalized) revert Phase1AlreadyFinalized();
        PendingAuction storage pending = pendingAuctions[baseSalt];
        if (pending.amount != 0) revert AuctionAlreadyPending();
        delete phase1SplitStates[baseSalt];
    }

    // ================================
    // HELPERS
    // ================================

    /// @notice Callers allowed to run phase deploys on behalf of `params.owner` (e.g. OVaultFactory4626).
    mapping(address => bool) public authorizedPhaseCallers;

    /// @notice Cumulative Charm+Ajna strategy weight registered via Phase 3 (ODA-429-F2).
    mapping(address => uint256) public phase3AllocatedWeightBps;

    event AuthorizedPhaseCallerUpdated(address indexed caller, bool authorized);

    function setAuthorizedPhaseCaller(address caller, bool authorized) external onlyProtocolTreasury {
        if (caller == address(0)) revert ZeroAddress();
        authorizedPhaseCallers[caller] = authorized;
        emit AuthorizedPhaseCallerUpdated(caller, authorized);
    }

    function _requireOwner(address owner) internal view {
        if (msg.sender != owner && !authorizedPhaseCallers[msg.sender]) revert NotOwner();
    }

    function _delegatePhase1(bytes memory callData) internal returns (bytes memory result) {
        // slither-disable-next-line controlled-delegatecall
        (bool ok, bytes memory outData) = address(phase1Module).delegatecall(callData);
        if (!ok) {
            assembly {
                revert(add(outData, 0x20), mload(outData))
            }
        }
        return outData;
    }

    function _delegatePhase2(bytes memory callData) internal returns (bytes memory result) {
        // slither-disable-next-line controlled-delegatecall
        (bool ok, bytes memory outData) = address(phase2Module).delegatecall(callData);
        if (!ok) {
            assembly {
                revert(add(outData, 0x20), mload(outData))
            }
        }
        return outData;
    }
}
