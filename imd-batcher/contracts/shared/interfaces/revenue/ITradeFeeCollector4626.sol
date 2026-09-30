// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ITradeFeeCollector4626
 * @notice Lane-neutral integration surface for 4626 tradeFeeCollector contracts.
 * @dev CreatorGaugeController and AgentGaugeController expose this shared ABI.
 *
 *      Intentionally outside this interface / not lane-identical:
 *      - Asset setters (`setCreatorCoin` vs `setAgentToken`).
 *      - Ongoing treasury getters (`creatorTreasury` vs `agentTreasury`) and BPS
 *        names (`creatorShareBps` vs `treasuryShareBps`). `getFeeSplit()` third
 *        return is the ongoing-treasury slice for both lanes.
 *      - `receiveFees` accounting: both lanes credit the observed balance delta
 *        (agent lane brought to parity, ODA-508-L2).
 *      - `setLotteryManager`: both lanes — first-ever non-zero set is immediate
 *        (one-way init flag, ODA-508-3); later non-zero updates are 1-day
 *        timelocked via `executeLotteryManagerUpdate()`; address(0) revokes
 *        immediately and cancels any pending update without re-arming the
 *        immediate path.
 *      - WETH fee path: both lanes fail closed only while `useOracleSlippage`
 *        is enabled (ODA-508-2); when disabled, the caller-supplied
 *        `minShareOftOut` is the sole floor (no unit-mismatched raw-input
 *        fallback).
 */
interface ITradeFeeCollector4626 {
    function vault() external view returns (address);
    function wrapper() external view returns (address);
    function shareOFT() external view returns (address);
    function oracle() external view returns (address);
    function lotteryManager() external view returns (address);

    function burnShareBps() external view returns (uint256);
    function lotteryShareBps() external view returns (uint256);
    function protocolShareBps() external view returns (uint256);

    function receiveFees(uint256 amount) external;
    function receiveBridgedFees() external;
    function receiveWETHFees(uint256 amount) external;
    function distribute() external;
    function forceDistribute() external;

    function payJackpot(address winner, uint256 amount) external;
    function availableJackpotReserve() external view returns (uint256);
    function getAvailableJackpotReserve() external view returns (uint256);
    function getJackpotReserve() external view returns (uint256);

    function getFeeSplit()
        external
        pure
        returns (uint256 burn, uint256 lottery, uint256 ongoingTreasury, uint256 protocol);

    function setVault(address vault_) external;
    function setWrapper(address wrapper_) external;
    function setLotteryManager(address lotteryManager_) external;
    function setOracle(address oracle_) external;
    function transferOwnership(address newOwner) external;
}
