// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {DeploymentBatcher, DeploymentBatcherUtilsHelper, DeploymentBatcherPhase1Module, DeploymentBatcherPhase2Module, DeploymentBatcherPhase3Helper, DeploymentBatcherShareMeshHelper} from "@4626/shared/deploy/batchers/DeploymentBatcher.sol";
import {IRegistry4626} from "@4626/shared/interfaces/core/IRegistry4626.sol";

contract DeploymentBatcherFixture is Test {
    struct Helpers {
        DeploymentBatcherUtilsHelper utils;
        DeploymentBatcherPhase2Module phase2;
        DeploymentBatcherPhase3Helper phase3;
        DeploymentBatcherShareMeshHelper shareMesh;
        DeploymentBatcherPhase1Module phase1;
    }

    struct BatcherConfig {
        address registry;
        address bytecodeStore;
        address create2Deployer;
        address protocolTreasury;
        address protocolAutomation;
        address poolManager;
        address taxHook;
        address chainlinkEthUsd;
        address vaultActivationBatcher;
        address lotteryManager;
        address permit2;
        address usdc;
        address uniswapV3Factory;
        address uniswapRouter;
        address ajnaFactory;
        address vaultCoreModule;
        address agentVaultCoreModule;
        address vaultStrategiesModule;
        address vaultAdminModule;
    }

    function deployHelpers(BatcherConfig memory cfg, address predictedBatcher) public returns (Helpers memory h) {
        h.utils = new DeploymentBatcherUtilsHelper();
        h.phase2 = new DeploymentBatcherPhase2Module(
            cfg.create2Deployer,
            cfg.registry,
            cfg.chainlinkEthUsd,
            cfg.poolManager,
            cfg.taxHook,
            cfg.protocolTreasury,
            cfg.lotteryManager,
            cfg.vaultActivationBatcher,
            predictedBatcher
        );
        h.phase3 = new DeploymentBatcherPhase3Helper(
            cfg.create2Deployer,
            cfg.protocolTreasury,
            cfg.protocolAutomation,
            cfg.usdc,
            cfg.uniswapV3Factory,
            cfg.uniswapRouter,
            cfg.ajnaFactory,
            predictedBatcher
        );
        h.shareMesh = new DeploymentBatcherShareMeshHelper(cfg.create2Deployer, cfg.poolManager, cfg.permit2, predictedBatcher);
        h.phase1 = new DeploymentBatcherPhase1Module(
            cfg.create2Deployer,
            cfg.bytecodeStore,
            cfg.registry,
            cfg.vaultCoreModule,
            cfg.agentVaultCoreModule == address(0) ? cfg.vaultCoreModule : cfg.agentVaultCoreModule,
            cfg.vaultStrategiesModule,
            cfg.vaultAdminModule,
            cfg.vaultActivationBatcher,
            address(h.utils),
            predictedBatcher
        );
    }

    function deployBatcher(BatcherConfig memory cfg) public returns (DeploymentBatcher batcher, Helpers memory helpers) {
        uint256 startNonce = vm.getNonce(address(this));
        address predicted = vm.computeCreateAddress(address(this), startNonce + 5);
        helpers = deployHelpers(cfg, predicted);
        batcher = new DeploymentBatcher(
            cfg.registry,
            cfg.bytecodeStore,
            cfg.create2Deployer,
            cfg.protocolTreasury,
            cfg.protocolAutomation,
            cfg.poolManager,
            cfg.taxHook,
            cfg.chainlinkEthUsd,
            cfg.vaultActivationBatcher,
            cfg.lotteryManager,
            cfg.permit2,
            cfg.usdc,
            cfg.uniswapV3Factory,
            cfg.uniswapRouter,
            cfg.ajnaFactory,
            cfg.vaultCoreModule,
            cfg.vaultStrategiesModule,
            cfg.vaultAdminModule,
            address(helpers.phase2),
            address(helpers.phase3),
            address(helpers.shareMesh),
            address(helpers.utils)
        );
        require(address(batcher) == predicted, "DeploymentBatcherFixture: prediction mismatch");
        // AUDIT-2026-07-08-H08/NEW-H: approve phase module codehashes; tests use free codeIds.
        _wireSecurityDefaults(batcher, helpers, cfg.protocolTreasury);
        vm.prank(cfg.protocolTreasury);
        batcher.setPhase1Module(address(helpers.phase1));
    }

    function _extcodehash(address account) internal view returns (bytes32 h) {
        assembly {
            h := extcodehash(account)
        }
    }

    /// @dev Approve phase1/2 codehashes (mandatory H-08) and disable codeId allowlist for unit tests.
    function _wireSecurityDefaults(DeploymentBatcher batcher, Helpers memory helpers, address treasury) internal {
        vm.startPrank(treasury);
        batcher.approvePhaseModuleCodehash(address(helpers.phase1), _extcodehash(address(helpers.phase1)));
        batcher.approvePhaseModuleCodehash(address(helpers.phase2), _extcodehash(address(helpers.phase2)));
        batcher.setCodeIdAllowlistEnabled(false);
        vm.stopPrank();
    }

    function mockRegistryCreatorCoin(address registry, address creatorToken, address oracle) public {
        IRegistry4626.TokenInfo memory info;
        info.token = creatorToken;
        info.oracle = oracle;
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IRegistry4626.getTokenInfo.selector, creatorToken),
            abi.encode(info)
        );
    }

    function deployShell(BatcherConfig memory cfg) public returns (DeploymentBatcher batcher, Helpers memory helpers) {
        uint256 startNonce = vm.getNonce(address(this));
        address predicted = vm.computeCreateAddress(address(this), startNonce + 5);
        helpers = deployHelpers(cfg, predicted);
        batcher = new DeploymentBatcher(
            cfg.registry,
            cfg.bytecodeStore,
            cfg.create2Deployer,
            cfg.protocolTreasury,
            cfg.protocolAutomation,
            cfg.poolManager,
            cfg.taxHook,
            cfg.chainlinkEthUsd,
            cfg.vaultActivationBatcher,
            cfg.lotteryManager,
            cfg.permit2,
            cfg.usdc,
            cfg.uniswapV3Factory,
            cfg.uniswapRouter,
            cfg.ajnaFactory,
            cfg.vaultCoreModule,
            cfg.vaultStrategiesModule,
            cfg.vaultAdminModule,
            address(0),
            address(0),
            address(0),
            address(0)
        );
        require(address(batcher) == predicted, "DeploymentBatcherFixture: prediction mismatch");
        _wireSecurityDefaults(batcher, helpers, cfg.protocolTreasury);
        vm.prank(cfg.protocolTreasury);
        batcher.wireDeploymentHelpers(
            address(helpers.phase2), address(helpers.phase3), address(helpers.shareMesh), address(helpers.utils)
        );
        vm.prank(cfg.protocolTreasury);
        batcher.setPhase1Module(address(helpers.phase1));
    }
}
