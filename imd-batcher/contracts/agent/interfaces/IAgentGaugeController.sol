// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ITradeFeeCollector4626} from
    "@4626/shared/interfaces/revenue/ITradeFeeCollector4626.sol";

/**
 * @title IAgentGaugeController
 * @author 0xakita.eth
 * @notice Agent-lane gauge controller setup interface.
 * @dev Extends the shared tradeFeeCollector surface with the agent-token asset
 *      setter used by DeploymentBatcher phase 2.
 */
interface IAgentGaugeController is ITradeFeeCollector4626 {
    function setAgentToken(address agentToken_) external;
}
