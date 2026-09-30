// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ITradeFeeCollector4626} from
    "@4626/shared/interfaces/revenue/ITradeFeeCollector4626.sol";

/**
 * @title ICreatorGaugeController
 * @author 0xakita.eth
 * @notice Creator-lane gauge controller setup interface.
 * @dev Extends the shared tradeFeeCollector surface with the creator-coin asset
 *      setter used by DeploymentBatcher phase 2.
 */
interface ICreatorGaugeController is ITradeFeeCollector4626 {
    function setCreatorCoin(address creatorCoin_) external;
}
