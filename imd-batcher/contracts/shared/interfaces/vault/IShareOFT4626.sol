// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IShareOFT4626
 * @notice Lane-neutral integration surface for 4626 ShareOFT mesh tokens.
 * @dev CreatorShareOFT and AgentShareOFT expose this common configuration,
 *      trade-fee, and lottery-coverage ABI. Lane-specific normalization and
 *      wrapper cooldown behavior intentionally remain outside this interface.
 *
 *      Semantics callers must not assume are identical across lanes:
 *      - `tradeFeeCollector()` returns `gaugeController` when set, otherwise
 *        falls back to `owner()` before gauge wiring.
 *      - `setHubConfig` third argument is the hub gauge receiver address, not a
 *        hub token. On non-Base chains the remote protocol wire authority may
 *        also call this setter.
 *      - Address-type values are ABI-encoded as `uint8` even though concrete
 *        contracts use an `OperationType` enum.
 */
interface IShareOFT4626 {
    function registry() external view returns (address);
    function vault() external view returns (address);
    function wrapper() external view returns (address);
    function gaugeController() external view returns (address);
    /// @notice Gauge controller when configured; otherwise the token owner.
    function tradeFeeCollector() external view returns (address);

    function setRegistry(address registry_) external;
    function setVault(address vault_) external;
    function setWrapper(address wrapper_) external;
    function setMinter(address minter, bool status) external;
    function setGaugeController(address gaugeController_) external;
    /// @param hubGaugeReceiver_ Destination gauge that receives remote fee flushes.
    function setHubConfig(bool isHub_, uint32 hubEid_, address hubGaugeReceiver_) external;
    function setAddressType(address account, uint8 operationType) external;
    function setAddressTypes(address[] calldata accounts, uint8 operationType) external;
    function transferOwnership(address newOwner) external;

    function flushPendingFeesToGauge() external;
    function balanceEligibleForLotteryCoverage(address account) external view returns (uint256);
}
