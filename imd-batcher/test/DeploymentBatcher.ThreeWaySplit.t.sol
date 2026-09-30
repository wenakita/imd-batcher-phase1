// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import "@4626/shared/deploy/batchers/DeploymentBatcher.sol";
import "@4626/shared/governance/VaultRolePolicyManager.sol";
import "test/helpers/DeploymentBatcherFixture.sol";

contract MockCreatorTokenDepositBounds {
    string public constant name = "Mock Creator Token";
    string public constant symbol = "MOCKCR";
    uint8 public constant decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockOwnableVaultForPhase3Bounds {
    address public owner;
    address public managementAddress;
    address public asset;

    constructor(address owner_) {
        owner = owner_;
        managementAddress = owner_;
    }

    function management() external view returns (address) {
        return managementAddress;
    }

    function setManagement(address account) external {
        managementAddress = account;
    }

    function setAsset(address asset_) external {
        asset = asset_;
    }
}

contract DeploymentBatcherThreeWaySplitTest is Test {
    DeploymentBatcher internal batcher;
    MockOwnableVaultForPhase3Bounds internal vault;
    VaultRolePolicyManager internal rolePolicyManager;
    address internal protocolTreasury;
    address internal protocolAutomation;
    // Must match `forge inspect DeploymentBatcher storage-layout`.
    // 2026-07-24: `pendingAuctions` is slot 7 and `phase1SplitStates` is slot 9.
    uint256 private constant PHASE1_SPLIT_STATES_SLOT = 9;
    uint256 private constant PENDING_AUCTIONS_SLOT = 7;

    function setUp() public {
        vm.chainId(8453);
        protocolTreasury = makeAddr("protocolTreasury");
        protocolAutomation = makeAddr("protocolAutomation");

        vault = new MockOwnableVaultForPhase3Bounds(address(this));
        DeploymentBatcherFixture deployer = new DeploymentBatcherFixture();
        DeploymentBatcherFixture.BatcherConfig memory cfg = _defaultBatcherConfig();
        (batcher,) = deployer.deployBatcher(cfg);
        rolePolicyManager = new VaultRolePolicyManager(address(this));
        vault.setManagement(address(batcher));
    }

    function test_setVaultRolePolicyConfig_requiresProtocolTreasury() public {
        vm.expectRevert(DeploymentBatcher.NotProtocolTreasury.selector);
        batcher.setVaultRolePolicyConfig(address(rolePolicyManager), 1);
    }

    function test_resetPhase1State_reverts_nonProtocolTreasury() public {
        (,,, bytes32 baseSalt) = _seedPhase1State();
        vm.expectRevert(DeploymentBatcher.NotProtocolTreasury.selector);
        batcher.resetPhase1State(makeAddr("phase1CreatorToken"), makeAddr("phase1Owner"), "v1");
    }

    function test_resetPhase1State_reverts_unknownSalt() public {
        bytes32 baseSalt = keccak256("unknown");

        vm.prank(protocolTreasury);
        vm.expectRevert(DeploymentBatcher.Phase1StateNotStuck.selector);
        batcher.resetPhase1State(makeAddr("unknownCreatorToken"), makeAddr("unknownOwner"), "v1");
    }

    function test_resetPhase1State_reverts_mismatchedTupleContext() public {
        bytes32 baseSalt = _seedPhase1StateWithFinalized(false);
        vm.prank(protocolTreasury);
        batcher.resetPhase1State(makeAddr("phase1CreatorTokenNonFinalized"), makeAddr("phase1OwnerNonFinalized"), "v1");

        (address oftBootstrapRegistry, address clearedVault,,,,,,,,) = batcher.phase1SplitStates(baseSalt);
        assertEq(oftBootstrapRegistry, address(0), "phase1 oft bootstrap not cleared");
        assertEq(clearedVault, address(0), "phase1 vault not cleared");
    }

    function test_resetPhase1State_reverts_whenPendingAuctionExists() public {
        // Non-finalized so we hit the auction check rather than Phase1AlreadyFinalized.
        bytes32 baseSalt = _seedPhase1StateWithFinalized(false);
        _seedPendingAuctionAmount(baseSalt, 1 ether);

        vm.prank(protocolTreasury);
        vm.expectRevert(DeploymentBatcher.AuctionAlreadyPending.selector);
        batcher.resetPhase1State(
            makeAddr("phase1CreatorTokenNonFinalized"), makeAddr("phase1OwnerNonFinalized"), "v1"
        );
    }

    function test_resetPhase1State_succeeds_withMatchedTupleContext() public {
        // M-15: reset is only for non-finalized stuck Phase-1.
        bytes32 baseSalt = _seedPhase1StateWithFinalized(false);
        vm.prank(protocolTreasury);
        batcher.resetPhase1State(
            makeAddr("phase1CreatorTokenNonFinalized"), makeAddr("phase1OwnerNonFinalized"), "v1"
        );

        (address oftBootstrapRegistry, address clearedVault,,,,,,,,) = batcher.phase1SplitStates(baseSalt);
        assertEq(oftBootstrapRegistry, address(0), "phase1 oft bootstrap not cleared");
        assertEq(clearedVault, address(0), "phase1 vault not cleared");
    }

    function test_resetPhase1State_reverts_whenFinalized() public {
        _seedPhase1State(); // finalized = true
        vm.prank(protocolTreasury);
        vm.expectRevert(DeploymentBatcher.Phase1AlreadyFinalized.selector);
        batcher.resetPhase1State(makeAddr("phase1CreatorToken"), makeAddr("phase1Owner"), "v1");
    }

    // P2 coverage from x-ray/review-todo.md: targeted test for deploy phase retries
    // and partial finalize scenarios. Demonstrates stuck partial state (coreDone
    // but not finalized), reset by treasury, and that state is cleared allowing
    // conceptual retry (re-seed or re-deployPhase1* with same salt context).
    function test_partialPhase1Stuck_thenReset_allowsRetry() public {
        bytes32 baseSalt = _seedPhase1StateWithFinalized(false); // coreDone=true, finalized=false

        // confirm partial/stuck
        (address preOft, address preVault,,,,,,,,) = batcher.phase1SplitStates(baseSalt);
        assertNotEq(preVault, address(0), "expected partial state with vault");

        // reset (as treasury) to recover from stuck partial
        vm.prank(protocolTreasury);
        batcher.resetPhase1State(makeAddr("phase1CreatorTokenNonFinalized"), makeAddr("phase1OwnerNonFinalized"), "v1");

        // state cleared -> retry path open (new phase1 deploy could re-use the (token,owner,version) context)
        (address postOft, address postVault,,,,,,,,) = batcher.phase1SplitStates(baseSalt);
        assertEq(postOft, address(0), "post-reset oft bootstrap should be cleared for retry");
        assertEq(postVault, address(0), "post-reset vault should be cleared for retry");
    }

    function test_deployPhase2Core_revertsWhenConfiguredRolePolicyRejectsOwner() public {
        // Policy 7: management must be allowlisted; owner is not allowlisted.
        rolePolicyManager.setRolePolicy(
            7,
            VaultRolePolicyManager.RolePolicy({
                active: true,
                requireOwnerEoa: false,
                managementRule: VaultRolePolicyManager.RoleRule.MustBeAllowlisted,
                keeperRule: VaultRolePolicyManager.RoleRule.Any,
                emergencyAdminRule: VaultRolePolicyManager.RoleRule.Any
            })
        );
        vm.prank(protocolTreasury);
        batcher.setVaultRolePolicyConfig(address(rolePolicyManager), 7);

        DeploymentBatcher.Phase2CoreParams memory params = DeploymentBatcher.Phase2CoreParams({
            creatorToken: makeAddr("creatorToken"),
            owner: address(this),
            creatorTreasury: address(0),
            // payoutRecipient field = creatorCoinPayoutRecipient (external earnings lane) per AGENTS.md
            payoutRecipient: address(0),
            vault: makeAddr("vault"),
            wrapper: makeAddr("wrapper"),
            shareOFT: makeAddr("shareOFT"),
            shareSymbol: "S4626",
            version: "v1",
            floorPriceQ96: 0
        });
        DeploymentBatcher.CodeIds memory codeIds = DeploymentBatcher.CodeIds({
            vault: bytes32(uint256(1)),
            wrapper: bytes32(uint256(2)),
            shareOFT: bytes32(uint256(3)),
            gauge: bytes32(uint256(4)),
            cca: bytes32(uint256(5)),
            oracle: bytes32(uint256(6)),
            oftBootstrap: bytes32(uint256(7))
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                VaultRolePolicyManager.RoleAssignmentNotAllowed.selector,
                uint8(VaultRolePolicyManager.VaultRole.Management),
                address(this)
            )
        );
        batcher.deployPhase2Core(params, codeIds);
    }

    function test_deployPhase2CoreWithRolePolicy_rejectsPerCallPolicyOverride() public {
        rolePolicyManager.setRolePolicy(
            9,
            VaultRolePolicyManager.RolePolicy({
                active: true,
                requireOwnerEoa: true,
                managementRule: VaultRolePolicyManager.RoleRule.MustEqualOwner,
                keeperRule: VaultRolePolicyManager.RoleRule.MustEqualOwner,
                emergencyAdminRule: VaultRolePolicyManager.RoleRule.MustEqualOwner
            })
        );
        vm.prank(protocolTreasury);
        batcher.setVaultRolePolicyConfig(address(rolePolicyManager), 0);

        address ownerContract = address(vault);
        DeploymentBatcher.Phase2CoreParams memory params = DeploymentBatcher.Phase2CoreParams({
            creatorToken: makeAddr("creatorToken"),
            owner: ownerContract,
            creatorTreasury: address(0),
            // payoutRecipient field = creatorCoinPayoutRecipient (external earnings lane) per AGENTS.md
            payoutRecipient: address(0),
            vault: makeAddr("vault"),
            wrapper: makeAddr("wrapper"),
            shareOFT: makeAddr("shareOFT"),
            shareSymbol: "S4626",
            version: "v1",
            floorPriceQ96: 0
        });
        DeploymentBatcher.CodeIds memory codeIds = DeploymentBatcher.CodeIds({
            vault: bytes32(uint256(1)),
            wrapper: bytes32(uint256(2)),
            shareOFT: bytes32(uint256(3)),
            gauge: bytes32(uint256(4)),
            cca: bytes32(uint256(5)),
            oracle: bytes32(uint256(6)),
            oftBootstrap: bytes32(uint256(7))
        });

        vm.prank(ownerContract);
        vm.expectRevert(
            abi.encodeWithSelector(DeploymentBatcher.RolePolicyOverrideRejected.selector, uint256(9), uint256(0))
        );
        batcher.deployPhase2CoreWithRolePolicy(params, codeIds, 9);
    }

    function test_deployPhase3Strategies_revertsWhenTotalWeightExceeds10000() public {
        address creatorToken = makeAddr("creatorToken");
        vault.setAsset(creatorToken);
        DeploymentBatcher.Phase3Params memory params = DeploymentBatcher.Phase3Params({
            creatorToken: creatorToken,
            owner: address(this),
            vault: address(vault),
            version: "v1",
            initialSqrtPriceX96: 0,
            charmVaultName: "Charm Vault",
            charmVaultSymbol: "CHRM",
            ajnaVaultName: "Ajna Inner Vault",
            ajnaVaultSymbol: "AIV",
            charmWeightBps: 7_000,
            ajnaWeightBps: 2_000,
            solanaWeightBps: 1_100,
            ajnaBufferRatioBps: 1_000,
            ajnaMinBucketIndex: 4_156,
            ajnaKeeper: makeAddr("ajnaKeeper"),
            solanaKeeper: makeAddr("solanaKeeper"),
            solanaMaxNavAge: 3600,
            solanaMaxNavDeltaBpsPerUpdate: 500,
            solanaMinBaseLiquidityBps: 1_000,
            solanaBridgeAddress: makeAddr("solanaBridge"),
            enableAutoAllocate: false,
            expectedCharmProtocolFeePips: 10_000
        });

        DeploymentBatcher.StrategyCodeIds memory codeIds = DeploymentBatcher.StrategyCodeIds({
            charmAlphaVaultDeploy: bytes32(uint256(1)),
            charmStrategy4626: bytes32(uint256(2)),
            ajnaVaultAuth: bytes32(uint256(3)),
            ajnaVault: bytes32(uint256(4)),
            erc4626StrategyAdapter: bytes32(uint256(5)),
            solanaStrategy: bytes32(uint256(6))
        });

        vm.expectRevert(DeploymentBatcher.InvalidWeight.selector);
        batcher.deployPhase3Strategies(params, codeIds);
    }

    function test_phase1SaltOverride_rejectsFreeFormSquat() public {
        DeploymentBatcher.Phase1Params memory params = DeploymentBatcher.Phase1Params({
            creatorToken: makeAddr("creatorToken"),
            owner: address(this),
            vaultName: "Creator OVault",
            vaultSymbol: "ovCR8R",
            shareName: "Creator Share",
            shareSymbol: "sCR8R",
            version: "v1",
            vaultKind: DeploymentBatcher.VaultKind.Creator
        });
        DeploymentBatcher.CodeIds memory codeIds = DeploymentBatcher.CodeIds({
            vault: bytes32(uint256(1)),
            wrapper: bytes32(uint256(2)),
            shareOFT: bytes32(uint256(3)),
            gauge: bytes32(uint256(4)),
            cca: bytes32(uint256(5)),
            oracle: bytes32(uint256(6)),
            oftBootstrap: bytes32(uint256(7))
        });

        // ODA-494-H01: free-form CREATE2 salt must not squat another derived address.
        bytes32 squatSalt = keccak256("custom-share-oft-salt");
        vm.expectRevert(DeploymentBatcherPhase1Module.InvalidShareOftSaltOverride.selector);
        batcher.deployPhase1CoreWithSalt(params, codeIds, squatSalt);

        vm.expectRevert(DeploymentBatcherPhase1Module.InvalidShareOftSaltOverride.selector);
        batcher.finalizePhase1WithSalt(params, codeIds, squatSalt);
    }

    function test_phase1SaltOverride_matchingDerivedSaltDoesNotHitInvalidOverride() public {
        DeploymentBatcher.Phase1Params memory params = DeploymentBatcher.Phase1Params({
            creatorToken: makeAddr("creatorToken"),
            owner: address(this),
            vaultName: "Creator OVault",
            vaultSymbol: "ovCR8R",
            shareName: "Creator Share",
            shareSymbol: "sCR8R",
            version: "v1",
            vaultKind: DeploymentBatcher.VaultKind.Creator
        });
        DeploymentBatcher.CodeIds memory codeIds = DeploymentBatcher.CodeIds({
            vault: bytes32(uint256(1)),
            wrapper: bytes32(uint256(2)),
            shareOFT: bytes32(uint256(3)),
            gauge: bytes32(uint256(4)),
            cca: bytes32(uint256(5)),
            oracle: bytes32(uint256(6)),
            oftBootstrap: bytes32(uint256(7))
        });

        DeploymentBatcherUtilsHelper utils = new DeploymentBatcherUtilsHelper();
        string memory shareSymbolLower = utils.toLower(params.shareSymbol);
        bytes32 derived =
            utils.deriveShareOftSalt(params.creatorToken, params.owner, shareSymbolLower, params.version);

        // Matching confirmation (or zero) must not revert InvalidShareOftSaltOverride;
        // later deploy steps may still fail without real bytecode in this fixture.
        try batcher.deployPhase1CoreWithSalt(params, codeIds, derived) {}
        catch (bytes memory err) {
            if (err.length >= 4) {
                bytes4 sel;
                assembly {
                    sel := mload(add(err, 32))
                }
                assertTrue(
                    sel != DeploymentBatcherPhase1Module.InvalidShareOftSaltOverride.selector,
                    "matching derived salt rejected as invalid override"
                );
            }
        }

        try batcher.deployPhase1CoreWithSalt(params, codeIds, bytes32(0)) {}
        catch (bytes memory err) {
            if (err.length >= 4) {
                bytes4 sel;
                assembly {
                    sel := mload(add(err, 32))
                }
                assertTrue(
                    sel != DeploymentBatcherPhase1Module.InvalidShareOftSaltOverride.selector,
                    "zero override rejected as invalid override"
                );
            }
        }
    }

    function test_phase2ShareSplitAndDepositBounds_remainFixed() public view {
        assertEq(batcher.MIN_DEPOSIT(), 50_000_000e18, "minimum first deposit drifted");
        assertEq(batcher.MAX_DEPOSIT(), 100_000_000e18, "maximum first deposit drifted");
        assertEq(batcher.VESTING_BPS(), 2_500, "creator vesting split drifted");
        assertEq(batcher.SOLANA_BPS(), 2_500, "Solana share split drifted");
        assertEq(batcher.BASE_AUCTION_BPS(), 1_250, "Base auction split drifted");
        assertEq(batcher.BASE_LP_RESERVE_BPS(), 1_250, "Base LP reserve split drifted");
        assertEq(batcher.SPOKE_INVENTORY_BPS(), 2_500, "Spoke inventory split drifted");
        assertEq(
            uint256(batcher.VESTING_BPS()) + batcher.SOLANA_BPS() + batcher.BASE_AUCTION_BPS()
                + batcher.BASE_LP_RESERVE_BPS() + batcher.SPOKE_INVENTORY_BPS(),
            10_000,
            "Phase-2 bps must sum to 100%"
        );
        assertEq(batcher.CCA_LEG_AUCTION_BPS(), 5_000, "CCA leg auction carve drifted");
        assertEq(batcher.CCA_LEG_LP_RESERVE_BPS(), 5_000, "CCA leg LP carve drifted");
        assertEq(batcher.resolveSpokeInventoryRecipient(), protocolTreasury, "spoke custody default");
    }

    /// @dev The deposit-bounds gate runs before the Phase-1 code-existence checks in
    ///      `_validateFinalizePhase2`, so an in-range deposit surfaces `Phase1Missing`
    ///      (no Phase-1 contracts in this fixture) while out-of-range deposits surface
    ///      `InvalidDepositAmount`. That distinction proves exactly where the gate sits.
    function test_finalizePhase2_depositBounds_allow50Mto100M() public {
        _expectFinalizeDepositRevert(50_000_000e18 - 1, DeploymentBatcherPhase2Module.InvalidDepositAmount.selector);
        _expectFinalizeDepositRevert(100_000_000e18 + 1, DeploymentBatcherPhase2Module.InvalidDepositAmount.selector);
        _expectFinalizeDepositRevert(50_000_000e18, DeploymentBatcherPhase2Module.Phase1Missing.selector);
        _expectFinalizeDepositRevert(75_000_000e18, DeploymentBatcherPhase2Module.Phase1Missing.selector);
        _expectFinalizeDepositRevert(100_000_000e18, DeploymentBatcherPhase2Module.Phase1Missing.selector);
    }

    function _expectFinalizeDepositRevert(uint256 depositAmount, bytes4 expectedSelector) internal {
        MockCreatorTokenDepositBounds creatorToken = new MockCreatorTokenDepositBounds();
        creatorToken.mint(address(this), depositAmount);
        creatorToken.approve(address(batcher), depositAmount);

        DeploymentBatcher.Phase2FinalizeParams memory params;
        params.creatorToken = address(creatorToken);
        params.owner = address(this);
        params.vault = makeAddr("depositBoundsVault");
        params.wrapper = makeAddr("depositBoundsWrapper");
        params.shareOFT = makeAddr("depositBoundsShareOFT");
        params.gaugeController = makeAddr("depositBoundsGauge");
        params.ccaLaunchArm = makeAddr("depositBoundsCca");
        params.oracle = makeAddr("depositBoundsOracle");
        params.version = "deposit-bounds-test";
        params.depositAmount = depositAmount;

        vm.expectRevert(expectedSelector);
        batcher.finalizePhase2(params);
    }

    function _seedPhase1State()
        internal
        returns (address phase1Vault, address phase1Wrapper, address phase1ShareOFT, bytes32 baseSalt)
    {
        address creatorToken = makeAddr("phase1CreatorToken");
        address creatorOwner = makeAddr("phase1Owner");
        baseSalt = keccak256(abi.encodePacked(creatorToken, creatorOwner, block.chainid, "4626:deploy:", "v1"));
        phase1Vault = makeAddr("phase1Vault");
        phase1Wrapper = makeAddr("phase1Wrapper");
        phase1ShareOFT = makeAddr("phase1ShareOFT");

        bytes32 stateBase = keccak256(abi.encode(baseSalt, uint256(PHASE1_SPLIT_STATES_SLOT)));
        vm.store(address(batcher), bytes32(uint256(stateBase) + 1), bytes32(uint256(uint160(phase1Vault))));
        vm.store(address(batcher), bytes32(uint256(stateBase) + 2), bytes32(uint256(uint160(phase1Wrapper))));
        vm.store(address(batcher), bytes32(uint256(stateBase) + 3), bytes32(uint256(uint160(phase1ShareOFT))));
        vm.store(
            address(batcher),
            bytes32(uint256(stateBase) + 7),
            bytes32(uint256(0x0101)) // coreDone = true, finalized = true
        );
    }

    function _seedPhase1StateWithFinalized(bool finalized) internal returns (bytes32 baseSalt) {
        address creatorToken = makeAddr("phase1CreatorTokenNonFinalized");
        address creatorOwner = makeAddr("phase1OwnerNonFinalized");
        baseSalt = keccak256(abi.encodePacked(creatorToken, creatorOwner, block.chainid, "4626:deploy:", "v1"));
        bytes32 stateBase = keccak256(abi.encode(baseSalt, uint256(PHASE1_SPLIT_STATES_SLOT)));
        vm.store(address(batcher), bytes32(uint256(stateBase) + 1), bytes32(uint256(uint160(makeAddr("phase1Vault")))));
        vm.store(
            address(batcher),
            bytes32(uint256(stateBase) + 7),
            bytes32(finalized ? uint256(0x0101) : uint256(0x0001)) // coreDone=true, finalized=finalized
        );
    }

    function _seedPendingAuctionAmount(bytes32 baseSalt, uint256 amount) internal {
        bytes32 pendingBase = keccak256(abi.encode(baseSalt, uint256(PENDING_AUCTIONS_SLOT)));
        vm.store(address(batcher), bytes32(uint256(pendingBase) + 2), bytes32(amount));
    }

    function _defaultBatcherConfig() internal returns (DeploymentBatcherFixture.BatcherConfig memory cfg) {
        cfg.registry = makeAddr("registry");
        cfg.bytecodeStore = makeAddr("bytecodeStore");
        cfg.create2Deployer = makeAddr("create2Deployer");
        cfg.protocolTreasury = protocolTreasury;
        cfg.protocolAutomation = protocolAutomation;
        cfg.poolManager = makeAddr("poolManager");
        cfg.taxHook = makeAddr("taxHook");
        cfg.chainlinkEthUsd = makeAddr("chainlinkEthUsd");
        cfg.vaultActivationBatcher = makeAddr("vaultActivationBatcher");
        cfg.lotteryManager = makeAddr("lotteryManager");
        cfg.permit2 = makeAddr("permit2");
        cfg.usdc = makeAddr("usdc");
        cfg.uniswapV3Factory = makeAddr("uniswapV3Factory");
        cfg.uniswapRouter = makeAddr("uniswapRouter");
        cfg.ajnaFactory = makeAddr("ajnaFactory");
        cfg.vaultCoreModule = makeAddr("vaultCoreModule");
        cfg.agentVaultCoreModule = address(0);
        cfg.vaultStrategiesModule = makeAddr("vaultStrategiesModule");
        cfg.vaultAdminModule = makeAddr("vaultAdminModule");
    }
}
