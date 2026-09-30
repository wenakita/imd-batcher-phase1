// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Two-step ownership helpers that do not insert a storage slot after Ownable.
/// @dev M-23: inherit Ownable and append `address public pendingOwner` at the end of
///      the concrete contract (and matching module storage). Do not inherit OZ
///      Ownable2Step on storage-aligned or already-deployed money-path contracts.
library Ownable2StepAppend {
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);

    function nominate(address currentOwner, address newOwner) internal returns (address pending) {
        if (newOwner == address(0)) revert Ownable.OwnableInvalidOwner(address(0));
        emit OwnershipTransferStarted(currentOwner, newOwner);
        pending = newOwner;
    }

    /// @notice Clear a nomination without changing the current owner.
    /// @dev Zero must not be passed to `Ownable._transferOwnership` — that would renounce.
    function cancelNomination(address currentOwner) internal returns (address pending) {
        emit OwnershipTransferStarted(currentOwner, address(0));
        pending = address(0);
    }

    function consumePending(address pending, address sender) internal pure {
        if (pending != sender) revert Ownable.OwnableUnauthorizedAccount(sender);
    }
}
