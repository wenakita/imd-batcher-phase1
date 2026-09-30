// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IOVaultWrapper4626
 * @notice Lane-neutral wrapper surface shared by CreatorOVaultWrapper and AgentOVaultWrapper.
 * @dev Cooldown-propagation hooks are intentionally excluded: Creator uses
 *      `(from, to)` while Agent uses `(from, to, amount)`. Asset getters also
 *      remain lane-specific (`creatorCoin` vs `agentToken`).
 */
interface IOVaultWrapper4626 {
    function vault() external view returns (address);
    function shareOFT() external view returns (address);
    function vaultToken() external view returns (address);
    function oftToken() external view returns (address);

    function setShareOFT(address shareOFT_) external;
    function setWhitelist(address user, bool status) external;
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;

    function deposit(uint256 amount) external returns (uint256 shareTokens);
    function wrap(uint256 amount) external returns (uint256 shareTokens);
    function unwrap(uint256 amount) external returns (uint256 amountOut);
}
