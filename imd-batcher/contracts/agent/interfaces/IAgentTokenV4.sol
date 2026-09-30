// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IAgentTokenV4
 * @notice Minimal read/write surface for AgentTokenV4-style tokens (ABI-only integration).
 * @dev No upstream implementation dependency. Validate against mock + optional mainnet fork.
 */
interface IAgentTokenV4 {
    // ── Discovery / routing ──────────────────────────────────────────────
    function vault() external view returns (address);
    function projectTaxRecipient() external view returns (address);
    function taxAccountingAdapter() external view returns (address);

    // ── LP / pair surface ────────────────────────────────────────────────
    function pairToken() external view returns (address);
    function uniswapV2Pair() external view returns (address);
    function liquidityPools(uint256 index) external view returns (address);
    function isLiquidityPool(address account) external view returns (bool);

    // ── Tax configuration ────────────────────────────────────────────────
    function buyTaxBps() external view returns (uint16);
    function sellTaxBps() external view returns (uint16);
    function projectTaxPendingSwap() external view returns (uint256);

    // ── Owner-gated setters (cooperation path) ───────────────────────────
    function setProjectTaxRecipient(address recipient) external;
    function setTaxAccountingAdapter(address adapter) external;

    // ── Tax distribution (keeper / owner) ────────────────────────────────
    function distributeTaxTokens() external;
}
