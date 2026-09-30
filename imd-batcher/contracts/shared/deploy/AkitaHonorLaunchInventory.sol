// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Exact ■ split for the AKITA honor remine. Greenfield 25/25/12.5/12.5/25
///         is unchanged. Re-read live AKos supply before broadcasting a new
///         Phase2 module — `HONOR_SHARE_AMOUNT` must stay 1:1 with circulating AKos.
library AkitaHonorLaunchInventory {
    address internal constant AKITA = 0x5b674196812451B7cEC024FE9d22D2c0b172fa75;

    /// @dev AKos raw (9 decimals) `29983573392879809` × 1e9 → 18-decimal ■.
    uint256 internal constant HONOR_SHARE_AMOUNT = 29_983_573_392_879_809 * 1e9;

    error HonorExceedsShares(uint256 shareTokens, uint256 honorAmount);

    function isHonorToken(address token) internal pure returns (bool) {
        return token == AKITA;
    }

    function honorShareAmount() internal pure returns (uint256) {
        return HONOR_SHARE_AMOUNT;
    }

    /// @return vestingAmount 25% of leftover
    /// @return auctionAmount 25% of leftover (Base CCA)
    /// @return lpReserveAmount 25% of leftover (Base LP)
    /// @return spokeInventoryAmount leftover remainder (Robinhood custody; 50/50 at RH launch)
    /// @return solanaAmount always 0 — do not Pipe A
    /// @return honorAmount exact AKos 1:1 backing, sent to owner for burn
    function splitShareTokens(uint256 shareTokens)
        internal
        pure
        returns (
            uint256 vestingAmount,
            uint256 auctionAmount,
            uint256 lpReserveAmount,
            uint256 spokeInventoryAmount,
            uint256 solanaAmount,
            uint256 honorAmount
        )
    {
        honorAmount = HONOR_SHARE_AMOUNT;
        if (shareTokens < honorAmount) revert HonorExceedsShares(shareTokens, honorAmount);

        uint256 leftover = shareTokens - honorAmount;
        vestingAmount = leftover / 4;
        auctionAmount = leftover / 4;
        lpReserveAmount = leftover / 4;
        spokeInventoryAmount = leftover - vestingAmount - auctionAmount - lpReserveAmount;
        solanaAmount = 0;
    }
}
