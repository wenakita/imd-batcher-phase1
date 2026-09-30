// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2StepAppend} from "@4626/shared/access/Ownable2StepAppend.sol";

/**
 * @title VaultRolePolicyManager
 * @notice Yearn-inspired role policy templates for vault deployment lanes.
 * @dev DeploymentBatcher can call `validateRoleAssignments` before phase-2 wiring.
 *      Policy id 0 is reserved as the no-op default for backwards compatibility.
 */
contract VaultRolePolicyManager is Ownable {
    enum RoleRule {
        Any,
        MustEqualOwner,
        MustBeAllowlisted
    }

    enum VaultRole {
        Management,
        Keeper,
        EmergencyAdmin
    }

    struct RolePolicy {
        bool active;
        bool requireOwnerEoa;
        RoleRule managementRule;
        RoleRule keeperRule;
        RoleRule emergencyAdminRule;
    }

    error PolicyNotActive(uint256 policyId);
    error OwnerMustBeEoa(address owner);
    error InvalidRole(uint8 role);
    error RoleAssignmentNotAllowed(uint8 role, address account);

    mapping(uint256 => RolePolicy) public policies;
    mapping(uint256 => mapping(uint8 => mapping(address => bool))) public allowlistedAccounts;

    /// @notice M-23: nominated owner. Empty until `transferOwnership`; cleared on accept.
    address public pendingOwner;

    event RolePolicySet(
        uint256 indexed policyId,
        bool active,
        bool requireOwnerEoa,
        RoleRule managementRule,
        RoleRule keeperRule,
        RoleRule emergencyAdminRule
    );
    event RoleAllowlistSet(uint256 indexed policyId, VaultRole indexed role, address indexed account, bool allowed);

    constructor(address initialOwner) Ownable(initialOwner) {}

    function setRolePolicy(uint256 policyId, RolePolicy calldata policy) external onlyOwner {
        policies[policyId] = policy;
        emit RolePolicySet(
            policyId,
            policy.active,
            policy.requireOwnerEoa,
            policy.managementRule,
            policy.keeperRule,
            policy.emergencyAdminRule
        );
    }

    function setRoleAllowlistedAccount(uint256 policyId, VaultRole role, address account, bool allowed) external onlyOwner {
        if (account == address(0)) revert RoleAssignmentNotAllowed(uint8(role), account);
        allowlistedAccounts[policyId][uint8(role)][account] = allowed;
        emit RoleAllowlistSet(policyId, role, account, allowed);
    }

    /**
     * @notice Validate owner/role tuple against a configured policy template.
     * @dev Policy id 0 is intentionally treated as permissive so existing deploy
     *      flows continue to work when no policy is configured.
     */
    function validateRoleAssignments(
        uint256 policyId,
        address owner,
        address management,
        address keeper,
        address emergencyAdmin
    ) external view {
        if (policyId == 0) return;

        RolePolicy memory policy = policies[policyId];
        if (!policy.active) revert PolicyNotActive(policyId);
        if (policy.requireOwnerEoa && owner.code.length != 0) revert OwnerMustBeEoa(owner);

        _validateRoleRule(policyId, policy.managementRule, VaultRole.Management, owner, management);
        _validateRoleRule(policyId, policy.keeperRule, VaultRole.Keeper, owner, keeper);
        _validateRoleRule(policyId, policy.emergencyAdminRule, VaultRole.EmergencyAdmin, owner, emergencyAdmin);
    }

    function _validateRoleRule(
        uint256 policyId,
        RoleRule rule,
        VaultRole role,
        address owner,
        address account
    ) internal view {
        if (rule == RoleRule.Any) return;
        if (rule == RoleRule.MustEqualOwner) {
            if (account != owner) revert RoleAssignmentNotAllowed(uint8(role), account);
            return;
        }
        if (rule != RoleRule.MustBeAllowlisted) revert InvalidRole(uint8(role));
        if (!allowlistedAccounts[policyId][uint8(role)][account]) revert RoleAssignmentNotAllowed(uint8(role), account);
    }

    /// @notice M-23: nominate a new owner. Current owner stays until `acceptOwnership`.
    function transferOwnership(address newOwner) public override onlyOwner {
        pendingOwner = Ownable2StepAppend.nominate(owner(), newOwner);
    }

    function acceptOwnership() public {
        address sender = _msgSender();
        Ownable2StepAppend.consumePending(pendingOwner, sender);
        pendingOwner = address(0);
        _transferOwnership(sender);
    }

}
