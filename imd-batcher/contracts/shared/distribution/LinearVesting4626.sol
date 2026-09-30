// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title LinearVesting4626
 * @notice Minimal linear vesting wallet for the creator’s ShareOFT allocation.
 * @dev Intentionally small/simple (no cliff, no revocation) to minimize deployment gas.
 */
contract LinearVesting4626 {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    address public immutable beneficiary;
    uint64 public immutable startTimestamp;
    uint64 public immutable durationSeconds;

    uint256 public released;
    // FIX: CLV-01 — fixed allocation recorded at seed time, not live balance
    uint256 public totalAllocation;
    bool public seeded;

    // FIX: CLV-03 — event for release tracking
    event Released(address indexed beneficiary, address indexed to, uint256 amount);
    event Seeded(uint256 totalAllocation);

    error ZeroAddress();
    error ZeroDuration();
    // FIX: CLV-02 — error for unauthorized release-to
    error NotBeneficiary();
    error NotSeeder();
    error AlreadySeeded();
    error NotSeeded();
    // FIX: I-4 (audit `docs/audits/aristotle/oracle`) — `seed()` on an empty balance
    // previously reverted with the misleading `ZeroDuration` error.
    error NothingToSeed();

    /// @notice Only this address may call `seed()` (typically the deployment batcher).
    address public immutable seeder;

    constructor(
        address token_,
        address beneficiary_,
        uint64 startTimestamp_,
        uint64 durationSeconds_,
        address seeder_
    ) {
        if (token_ == address(0) || beneficiary_ == address(0) || seeder_ == address(0)) revert ZeroAddress();
        if (durationSeconds_ == 0) revert ZeroDuration();
        token = IERC20(token_);
        beneficiary = beneficiary_;
        startTimestamp = startTimestamp_;
        durationSeconds = durationSeconds_;
        seeder = seeder_;
    }

    // FIX: CLV-01 — record total allocation from current balance (call once after funding)
    // FIX: L-5 (audit `docs/audits/aristotle/oracle`) — include `released` in the recorded
    // allocation. If `release()`/`release(to)` is ever called before `seed()` (vesting
    // against the live balance per `vestedAmount`'s pre-seed branch), using only the
    // live balance here would permanently drop the already-released portion from the
    // schedule denominator, under-allocating every subsequent vesting calculation.
    // FIX: I-4 — revert with `NothingToSeed` instead of the misleading `ZeroDuration`.
    function seed() external {
        if (msg.sender != seeder) revert NotSeeder();
        if (seeded) revert AlreadySeeded();
        uint256 bal = token.balanceOf(address(this));
        uint256 total = bal + released;
        if (total == 0) revert NothingToSeed();
        totalAllocation = total;
        seeded = true;
        emit Seeded(total);
    }

    function vestedAmount(uint64 timestamp) public view returns (uint256) {
        // FIX: CLV-01 — use fixed totalAllocation instead of live balance
        uint256 total = seeded ? totalAllocation : token.balanceOf(address(this)) + released;
        if (timestamp <= startTimestamp) return 0;

        uint256 elapsed = uint256(timestamp - startTimestamp);
        if (elapsed >= uint256(durationSeconds)) return total;

        return (total * elapsed) / uint256(durationSeconds);
    }

    function releasable() public view returns (uint256) {
        uint256 vested = vestedAmount(uint64(block.timestamp));
        return vested > released ? vested - released : 0;
    }

    function release() external returns (uint256 amount) {
        amount = releasable();
        if (amount == 0) return 0;
        released += amount;
        token.safeTransfer(beneficiary, amount);
        // FIX: CLV-03 — emit event on release
        emit Released(beneficiary, beneficiary, amount);
    }

    // FIX: CLV-02 — allow beneficiary to redirect tokens to a different address
    function release(address to) external returns (uint256 amount) {
        if (msg.sender != beneficiary) revert NotBeneficiary();
        if (to == address(0)) revert ZeroAddress();
        amount = releasable();
        if (amount == 0) return 0;
        released += amount;
        token.safeTransfer(to, amount);
        // FIX: CLV-03 — emit event on release
        emit Released(beneficiary, to, amount);
    }
}

