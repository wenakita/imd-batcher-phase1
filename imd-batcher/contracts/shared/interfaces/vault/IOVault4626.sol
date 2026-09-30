// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IOVault4626
 * @notice Lane-neutral vault wiring surface shared by CreatorOVault and AgentOVault.
 * @dev Asset-specific getters remain outside this interface. Shared consumers
 *      (DeploymentBatcher, ShareOFT view helpers) should type against this ABI.
 */
interface IOVault4626 {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function setModulesOnce(address coreModule, address strategiesModule, address adminModule) external;
    function coreModule() external view returns (address);
    function strategiesModule() external view returns (address);
    function adminModule() external view returns (address);
    function gaugeController() external view returns (address);
    function ccaLaunchArm() external view returns (address);
    function setGaugeController(address controller_) external;
    function setCcaLaunchArm(address ccaLaunchArm_) external;
    function setWhitelist(address account, bool status) external;
    function setTrustedAdapter(address account, bool status) external;
    function setProtocolRescue(address rescue) external;
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
    function convertToAssets(uint256 shares) external view returns (uint256);
}
