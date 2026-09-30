// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {DeploymentBatcher} from "@4626/shared/deploy/batchers/DeploymentBatcher.sol";
import "test/helpers/DeploymentBatcherFixture.sol";
import {OFTBootstrapRegistry} from "@4626/shared/deploy/infra/OFTBootstrapRegistry.sol";

interface IEndpointRegistryLike {
    function getLayerZeroEndpoint(uint256 chainId) external view returns (address);
}

contract MockBytecodeStore {
    mapping(bytes32 => bytes) internal bytecodes;

    function setCode(bytes32 codeId, bytes memory creationCode) external {
        bytecodes[codeId] = creationCode;
    }

    function get(bytes32 codeId) external view returns (bytes memory) {
        bytes memory creationCode = bytecodes[codeId];
        require(creationCode.length > 0, "missing code");
        return creationCode;
    }
}

contract MockRegistry4626 {
    address public endpoint;

    constructor(address _endpoint) {
        endpoint = _endpoint;
    }

    function setEndpoint(address _endpoint) external {
        endpoint = _endpoint;
    }

    function getLayerZeroEndpoint(uint256) external view returns (address) {
        return endpoint;
    }
}

contract MockVault {
    address public creatorToken;
    address public owner;
    string public vaultName;
    string public vaultSymbol;

    constructor(address _creatorToken, address _owner, string memory _vaultName, string memory _vaultSymbol) {
        creatorToken = _creatorToken;
        owner = _owner;
        vaultName = _vaultName;
        vaultSymbol = _vaultSymbol;
    }

    function setWhitelist(address, bool) external {}

    function setTrustedAdapter(address, bool) external {}

    function setModulesOnce(address, address, address) external {}
}

contract MockWrapper {
    address public creatorToken;
    address public vault;
    address public owner;
    address public shareOFT;

    constructor(address _creatorToken, address _vault, address _owner) {
        creatorToken = _creatorToken;
        vault = _vault;
        owner = _owner;
    }

    function setShareOFT(address _shareOFT) external {
        shareOFT = _shareOFT;
    }
}

contract MockShareOFT {
    address public constructorEndpoint;
    address public constructorRegistry;
    address public owner;
    string public shareName;
    string public shareSymbol;
    address public registry;
    address public vault;
    address public wrapper;

    constructor(string memory _name, string memory _symbol, address _registry, address _owner) {
        shareName = _name;
        shareSymbol = _symbol;
        constructorRegistry = _registry;
        owner = _owner;
        constructorEndpoint = IEndpointRegistryLike(_registry).getLayerZeroEndpoint(block.chainid);
    }

    function setRegistry(address _registry) external {
        registry = _registry;
    }

    function setVault(address _vault) external {
        vault = _vault;
    }

    function setWrapper(address _wrapper) external {
        wrapper = _wrapper;
    }

    function setMinter(address, bool) external {}

    function setHubConfig(bool, uint32, address) external {}
}

contract MockUniversalCreate2Deployer {
    bytes32 public bootstrapSalt;
    bytes32 public bootstrapInitCodeHash;
    address public bootstrapAddress;

    mapping(bytes32 => uint8) public codeKinds;
    mapping(bytes32 => address) public computedAddressOverrides;
    mapping(bytes32 => bool) public deployRevertOverrides;

    function configureBootstrap(bytes32 _bootstrapSalt, bytes32 _bootstrapInitCodeHash, address _bootstrapAddress) external {
        bootstrapSalt = _bootstrapSalt;
        bootstrapInitCodeHash = _bootstrapInitCodeHash;
        bootstrapAddress = _bootstrapAddress;
    }

    function setCodeKind(bytes32 codeId, uint8 kind) external {
        codeKinds[codeId] = kind;
    }

    function setComputedAddress(bytes32 salt, bytes32 initCodeHash, address computed) external {
        computedAddressOverrides[_computedKey(salt, initCodeHash)] = computed;
    }

    function setDeployRevert(bytes32 salt, bytes32 codeId, bool shouldRevert) external {
        deployRevertOverrides[_deployKey(salt, codeId)] = shouldRevert;
    }

    function computeAddress(bytes32 salt, bytes32 initCodeHash) external view returns (address) {
        if (salt == bootstrapSalt && initCodeHash == bootstrapInitCodeHash) {
            return bootstrapAddress;
        }
        address overrideAddr = computedAddressOverrides[_computedKey(salt, initCodeHash)];
        if (overrideAddr != address(0)) return overrideAddr;
        return address(uint160(uint256(keccak256(abi.encodePacked("mock-address", salt, initCodeHash)))));
    }

    function deploy(bytes32 salt, bytes32 codeId, bytes calldata constructorArgs) external returns (address addr) {
        if (deployRevertOverrides[_deployKey(salt, codeId)]) revert("already deployed");
        uint8 kind = codeKinds[codeId];
        if (kind == 1) {
            (address creatorToken, address owner, string memory vaultName, string memory vaultSymbol) =
                abi.decode(constructorArgs, (address, address, string, string));
            return address(new MockVault(creatorToken, owner, vaultName, vaultSymbol));
        }
        if (kind == 2) {
            (address creatorToken, address vault, address owner) =
                abi.decode(constructorArgs, (address, address, address));
            return address(new MockWrapper(creatorToken, vault, owner));
        }
        if (kind == 3) {
            (string memory name, string memory symbol, address registry, address owner) =
                abi.decode(constructorArgs, (string, string, address, address));
            return address(new MockShareOFT(name, symbol, registry, owner));
        }
        revert("unknown codeId");
    }

    function _computedKey(bytes32 salt, bytes32 initCodeHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(salt, initCodeHash));
    }

    function _deployKey(bytes32 salt, bytes32 codeId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(salt, codeId));
    }
}

contract DeploymentBatcherPhase1EndpointPoisoningTest is Test {
    bytes32 internal constant VAULT_CODE_ID = bytes32(uint256(1));
    bytes32 internal constant WRAPPER_CODE_ID = bytes32(uint256(2));
    bytes32 internal constant SHARE_OFT_CODE_ID = bytes32(uint256(3));
    bytes32 internal constant OFT_BOOTSTRAP_CODE_ID = bytes32(uint256(4));
    bytes32 internal constant GAUGE_CODE_ID = bytes32(uint256(5));
    bytes32 internal constant CCA_CODE_ID = bytes32(uint256(6));
    bytes32 internal constant ORACLE_CODE_ID = bytes32(uint256(7));

    // Canonical LayerZero v2 EndpointV2 address (CREATE2-deployed identically across EVM chains).
    // Must match `contracts/shared/deploy/infra/OFTBootstrapRegistry.sol`.
    address internal constant CANONICAL_ENDPOINT = address(0x1a44076050125825900e736c501f859c50fE728c);
    address internal constant ATTACKER_ENDPOINT = address(0x2222222222222222222222222222222222222222);
    address internal constant ATTACKER = address(0xBEEF);

    function _oftBootstrapSalt() internal pure returns (bytes32) {
        return keccak256("4626:OFTBootstrapRegistry:v1");
    }

    function _oftBootstrapCreationCode() internal pure returns (bytes memory) {
        return bytes("mock-oft-bootstrap");
    }

    function _shareOftCreationCode() internal pure returns (bytes memory) {
        return bytes("mock-share-oft");
    }

    function _codeIds() internal pure returns (DeploymentBatcher.CodeIds memory codeIds) {
        codeIds = DeploymentBatcher.CodeIds({
            vault: VAULT_CODE_ID,
            wrapper: WRAPPER_CODE_ID,
            shareOFT: SHARE_OFT_CODE_ID,
            gauge: GAUGE_CODE_ID,
            cca: CCA_CODE_ID,
            oracle: ORACLE_CODE_ID,
            oftBootstrap: OFT_BOOTSTRAP_CODE_ID
        });
    }

    function _phase1Params() internal view returns (DeploymentBatcher.Phase1Params memory params) {
        params = DeploymentBatcher.Phase1Params({
            creatorToken: address(0xCAFE),
            owner: address(this),
            vaultName: "Creator Vault",
            vaultSymbol: "cvTOKEN",
            shareName: "Creator Shares",
            shareSymbol: "sTOK",
            version: "v1",
            vaultKind: DeploymentBatcher.VaultKind.Creator
        });
    }

    function _deployFixture(address bootstrapAddress)
        internal
        returns (DeploymentBatcher deployer, MockRegistry4626 registry, MockUniversalCreate2Deployer create2)
    {
        vm.chainId(8453);

        registry = new MockRegistry4626(CANONICAL_ENDPOINT);
        MockBytecodeStore store = new MockBytecodeStore();
        create2 = new MockUniversalCreate2Deployer();
        store.setCode(VAULT_CODE_ID, bytes("mock-vault"));
        store.setCode(WRAPPER_CODE_ID, bytes("mock-wrapper"));
        store.setCode(OFT_BOOTSTRAP_CODE_ID, _oftBootstrapCreationCode());
        store.setCode(SHARE_OFT_CODE_ID, _shareOftCreationCode());
        create2.configureBootstrap(_oftBootstrapSalt(), OFT_BOOTSTRAP_CODE_ID, bootstrapAddress);
        create2.setCodeKind(VAULT_CODE_ID, 1);
        create2.setCodeKind(WRAPPER_CODE_ID, 2);
        create2.setCodeKind(SHARE_OFT_CODE_ID, 3);

        DeploymentBatcherFixture deployerLib = new DeploymentBatcherFixture();
        DeploymentBatcherFixture.BatcherConfig memory cfg = DeploymentBatcherFixture.BatcherConfig({
            registry: address(registry),
            bytecodeStore: address(store),
            create2Deployer: address(create2),
            protocolTreasury: address(this),
            protocolAutomation: makeAddr("protocolAutomation"),
            poolManager: address(0x1001),
            taxHook: address(0x1002),
            chainlinkEthUsd: address(0x1003),
            vaultActivationBatcher: address(0x1004),
            lotteryManager: address(0x1005),
            permit2: address(0x1006),
            usdc: address(0x1007),
            uniswapV3Factory: address(0x1008),
            uniswapRouter: address(0x1009),
            ajnaFactory: address(0x1010),
            vaultCoreModule: address(0x2001),
            agentVaultCoreModule: address(0),
            vaultStrategiesModule: address(0x2002),
            vaultAdminModule: address(0x2003)
        });
        (deployer,) = deployerLib.deployBatcher(cfg);
    }

    function test_deployPhase1Core_bootstrapReturnsCanonicalEndpoint() public {
        OFTBootstrapRegistry bootstrap = new OFTBootstrapRegistry();
        (DeploymentBatcher deployer,,) = _deployFixture(address(bootstrap));

        DeploymentBatcher.Phase1Result memory out =
            deployer.deployPhase1CoreWithSalt(_phase1Params(), _codeIds(), bytes32(0));

        // Bootstrap registry is intentionally write-free; it always returns the canonical LZ endpoint.
        assertEq(out.oftBootstrapRegistry, address(bootstrap));
        assertEq(
            bootstrap.getLayerZeroEndpoint(block.chainid),
            bootstrap.LZ_COMMON_ENDPOINT(),
            "bootstrap should return canonical common endpoint"
        );
    }

    function test_finalizePhase1_deploysShareOFTBoundToCanonicalEndpoint() public {
        OFTBootstrapRegistry bootstrap = new OFTBootstrapRegistry();
        (DeploymentBatcher deployer, MockRegistry4626 registry,) = _deployFixture(address(bootstrap));

        deployer.deployPhase1CoreWithSalt(_phase1Params(), _codeIds(), bytes32(0));

        // Even if the main registry endpoint is changed (\"poisoned\"), the ShareOFT constructor binds
        // the chain-global bootstrap registry endpoint, not the mutable registry endpoint.
        vm.prank(ATTACKER);
        registry.setEndpoint(ATTACKER_ENDPOINT);

        DeploymentBatcher.Phase1Result memory out =
            deployer.finalizePhase1WithSalt(_phase1Params(), _codeIds(), bytes32(0));

        assertEq(
            MockShareOFT(out.shareOFT).constructorEndpoint(),
            bootstrap.LZ_COMMON_ENDPOINT(),
            "shareOFT should bind canonical common endpoint"
        );
    }

    function test_finalizePhase1_ignoresRegistryEndpointPoisoning() public {
        OFTBootstrapRegistry bootstrap = new OFTBootstrapRegistry();
        (DeploymentBatcher deployer, MockRegistry4626 registry,) = _deployFixture(address(bootstrap));

        deployer.deployPhase1CoreWithSalt(_phase1Params(), _codeIds(), bytes32(0));

        registry.setEndpoint(ATTACKER_ENDPOINT);

        DeploymentBatcher.Phase1Result memory out =
            deployer.finalizePhase1WithSalt(_phase1Params(), _codeIds(), bytes32(0));
        assertEq(MockShareOFT(out.shareOFT).constructorEndpoint(), bootstrap.LZ_COMMON_ENDPOINT());
    }

    function test_finalizePhase1_reusesPredeployedShareOFTOnCreate2Collision() public {
        OFTBootstrapRegistry bootstrap = new OFTBootstrapRegistry();
        (DeploymentBatcher deployer,, MockUniversalCreate2Deployer create2) = _deployFixture(address(bootstrap));

        DeploymentBatcher.Phase1Params memory params = _phase1Params();
        DeploymentBatcher.CodeIds memory codeIds = _codeIds();
        deployer.deployPhase1CoreWithSalt(params, codeIds, bytes32(0));

        bytes32 baseSalt =
            keccak256(abi.encodePacked(params.creatorToken, params.owner, block.chainid, "4626:deploy:", params.version));
        (
            address oftBootstrapRegistry,
            address vaultAddr,
            address wrapperAddr,
            address shareAddr,
            bytes32 shareOftSalt,
            bytes32 paramsHash,
            bytes32 codeIdsHash,
            bool coreDone,
            bool finalized,
            DeploymentBatcher.VaultKind vaultKind
        ) = deployer.phase1SplitStates(baseSalt);
        vaultAddr;
        shareAddr;
        paramsHash;
        codeIdsHash;
        coreDone;
        finalized;
        vaultKind;

        bytes memory shareOftArgs = abi.encode(params.shareName, "STOK", oftBootstrapRegistry, address(deployer));
        bytes32 shareOftInitCodeHash = keccak256(bytes.concat(_shareOftCreationCode(), shareOftArgs));
        MockShareOFT squattedShareOFT = new MockShareOFT(params.shareName, "STOK", oftBootstrapRegistry, address(deployer));
        create2.setComputedAddress(shareOftSalt, shareOftInitCodeHash, address(squattedShareOFT));
        create2.setDeployRevert(shareOftSalt, SHARE_OFT_CODE_ID, true);

        DeploymentBatcher.Phase1Result memory out = deployer.finalizePhase1WithSalt(params, codeIds, bytes32(0));

        assertEq(out.shareOFT, address(squattedShareOFT), "should reuse existing deterministic ShareOFT");
        assertEq(MockWrapper(wrapperAddr).shareOFT(), address(squattedShareOFT), "wrapper should wire existing ShareOFT");
        assertEq(squattedShareOFT.wrapper(), wrapperAddr, "ShareOFT should wire existing wrapper");
    }
}

contract DeploymentBatcherOVaultRuntimeConfigTest is Test {
    DeploymentBatcher internal batcher;
    address internal constant PROTOCOL_TREASURY = address(0xBEEF);

    function setUp() public {
        vm.chainId(8453);

        DeploymentBatcherFixture deployerLib = new DeploymentBatcherFixture();
        DeploymentBatcherFixture.BatcherConfig memory cfg = DeploymentBatcherFixture.BatcherConfig({
            registry: address(0x1001),
            bytecodeStore: address(0x1002),
            create2Deployer: address(0x1003),
            protocolTreasury: PROTOCOL_TREASURY,
            protocolAutomation: makeAddr("protocolAutomation"),
            poolManager: address(0x1004),
            taxHook: address(0x1005),
            chainlinkEthUsd: address(0x1006),
            vaultActivationBatcher: address(0x1007),
            lotteryManager: address(0x1008),
            permit2: address(0x1009),
            usdc: address(0x1010),
            uniswapV3Factory: address(0x1011),
            uniswapRouter: address(0x1012),
            ajnaFactory: address(0x1013),
            vaultCoreModule: address(0x1014),
            agentVaultCoreModule: address(0),
            vaultStrategiesModule: address(0x1015),
            vaultAdminModule: address(0x1016)
        });
        (batcher,) = deployerLib.deployBatcher(cfg);
    }

    function test_SetOVaultRuntimeConfig_OnlyProtocolTreasury() public {
        vm.expectRevert(DeploymentBatcher.NotProtocolTreasury.selector);
        batcher.setOVaultRuntimeConfig(address(0x2001), 30168, true);
    }

    function test_SetOVaultRuntimeConfig_RevertWhenEnabledAndZeroComposer() public {
        vm.startPrank(PROTOCOL_TREASURY);
        vm.expectRevert(DeploymentBatcher.ZeroAddress.selector);
        batcher.setOVaultRuntimeConfig(address(0), 30168, true);
        vm.stopPrank();
    }

    function test_SetOVaultRuntimeConfig_RevertWhenEnabledAndZeroEid() public {
        vm.startPrank(PROTOCOL_TREASURY);
        vm.expectRevert(DeploymentBatcher.InvalidSolanaEid.selector);
        batcher.setOVaultRuntimeConfig(address(0x2001), 0, true);
        vm.stopPrank();
    }

    function test_SetAndGetOVaultRuntimeConfig() public {
        vm.prank(PROTOCOL_TREASURY);
        batcher.setOVaultRuntimeConfig(address(0x2001), 30168, true);

        DeploymentBatcher.OVaultRuntimeConfig memory cfg = batcher.getOVaultRuntimeConfig();
        assertEq(cfg.hubComposer, address(0x2001));
        assertEq(cfg.solanaEid, 30168);
        assertTrue(cfg.enabled);
    }

}
