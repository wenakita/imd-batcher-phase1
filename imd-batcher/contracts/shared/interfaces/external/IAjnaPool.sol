// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IAjnaPool
 * @author Ajna Finance
 * @notice Interface for Ajna ERC20 lending pools.
 * @dev Used by Ajna strategy adapters.
 */
interface IAjnaPool {
    /**
     * @notice Add quote tokens to a lending bucket
     * @param amount Amount of quote tokens to add
     * @param index Bucket index (price point)
     * @param expiry Expiration timestamp for the transaction
     * @return bucketLP The amount of LP tokens received
     * @return addedAmount The actual amount of tokens added
     */
    function addQuoteToken(uint256 amount, uint256 index, uint256 expiry)
        external
        returns (uint256 bucketLP, uint256 addedAmount);

    /**
     * @notice Borrow quote token and/or pledge collateral.
     * @dev Amounts use Ajna WAD precision (1e18), even for non-18-decimal tokens.
     * @param borrowerAddress Borrower account to mutate
     * @param amountToBorrow Quote token amount to borrow (WAD)
     * @param limitIndex Lower bound on tolerated LUP move
     * @param collateralToPledge Collateral amount to pledge (WAD)
     */
    function drawDebt(address borrowerAddress, uint256 amountToBorrow, uint256 limitIndex, uint256 collateralToPledge)
        external;

    /**
     * @notice Repay quote token debt and optionally pull collateral.
     * @dev Amounts use Ajna WAD precision (1e18), even for non-18-decimal tokens.
     * @param borrowerAddress Borrower account to mutate
     * @param maxQuoteTokenAmountToRepay Maximum quote token to repay (WAD)
     * @param collateralAmountToPull Maximum collateral to pull (WAD)
     * @param recipient Recipient of pulled collateral
     * @param limitIndex Lower bound on tolerated LUP move while pulling collateral
     * @return amountRepaid Actual quote token repaid (WAD)
     */
    function repayDebt(
        address borrowerAddress,
        uint256 maxQuoteTokenAmountToRepay,
        uint256 collateralAmountToPull,
        address recipient,
        uint256 limitIndex
    ) external returns (uint256 amountRepaid);

    /**
     * @notice Remove quote tokens from a lending bucket
     * @dev Ajna `IPoolLenderActions`: `maxAmount_` is quote-token WAD (not LP). Use
     *      `type(uint256).max` to redeem the caller's full LP in the bucket.
     * @param amount Maximum quote tokens to remove (WAD)
     * @param index Bucket index
     * @return removedAmount The amount of quote tokens removed
     * @return redeemedLP The amount of LP tokens burned
     */
    function removeQuoteToken(uint256 amount, uint256 index)
        external
        returns (uint256 removedAmount, uint256 redeemedLP);

    /**
     * @notice Move quote tokens between buckets
     * @dev Ajna `IPoolLenderActions`: `maxAmount_` is quote-token WAD (not LP).
     * @param maxAmount Maximum quote tokens to move (WAD)
     * @param fromIndex Source bucket index
     * @param toIndex Destination bucket index
     * @param expiry Expiration timestamp
     * @return fromBucketLP LP tokens moved from source
     * @return toBucketLP LP tokens received in destination
     * @return movedAmount Amount of quote tokens moved
     */
    function moveQuoteToken(uint256 maxAmount, uint256 fromIndex, uint256 toIndex, uint256 expiry)
        external
        returns (uint256 fromBucketLP, uint256 toBucketLP, uint256 movedAmount);

    /**
     * @notice Get lender info for a specific bucket
     * @param index Bucket index
     * @param lender Lender address
     * @return lpBalance LP token balance in bucket
     * @return depositTime Timestamp of last deposit
     */
    function lenderInfo(uint256 index, address lender) external view returns (uint256 lpBalance, uint256 depositTime);

    /**
     * @notice Get bucket info
     * @param index Bucket index
     * @return lpBalance Total LP in bucket
     * @return collateral Total collateral in bucket
     * @return bankruptcyTime Bankruptcy timestamp
     * @return deposit Total quote tokens deposited
     * @return scale Scaling factor
     */
    function bucketInfo(uint256 index)
        external
        view
        returns (uint256 lpBalance, uint256 collateral, uint256 bankruptcyTime, uint256 deposit, uint256 scale);

    /**
     * @notice Get borrower debt and collateral state.
     * @dev Values are Ajna WAD precision.
     * @param borrower Borrower address
     * @return t0Debt Borrower t0 debt (WAD)
     * @return collateral Borrower pledged collateral (WAD)
     * @return npTpRatio Borrower neutral/threshold ratio (WAD)
     */
    function borrowerInfo(address borrower) external view returns (uint256 t0Debt, uint256 collateral, uint256 npTpRatio);

    /**
     * @notice Get pool inflator state used to transform t0Debt into current debt.
     * @return inflator Pool inflator (WAD)
     * @return lastUpdate Timestamp of inflator update
     */
    function inflatorInfo() external view returns (uint256 inflator, uint256 lastUpdate);

    /**
     * @notice Get the pool's quote token address
     * @return Quote token address
     */
    function quoteTokenAddress() external view returns (address);

    /**
     * @notice Get the pool's collateral token address
     * @return Collateral token address
     */
    function collateralAddress() external view returns (address);

    /**
     * @notice Get pool utilization rate
     * @return Utilization in WAD (1e18 = 100%)
     */
    function poolUtilization() external view returns (uint256);

    /**
     * @notice Get current pool interest rate
     * @return Interest rate in WAD (1e18 = 100% per year)
     */
    function interestRate() external view returns (uint256);
}

/// @notice Optional Ajna ERC20Pool surfaces used by the inner vault (scale + collateral claim).
/// @dev Kept separate so existing IAjnaPool mocks do not have to implement them.
interface IAjnaPoolQuoteScale {
    function quoteTokenScale() external view returns (uint256);
}

interface IAjnaPoolCollateralActions {
    function removeCollateral(uint256 maxAmount, uint256 index)
        external
        returns (uint256 removedAmount, uint256 redeemedLP);
}

/// @notice Optional Ajna auction surfaces so a keeper can unlock deposit-locked quote.
/// @dev Kept separate so existing IAjnaPool mocks do not have to implement them.
interface IAjnaPoolAuctionActions {
    function settle(address borrower, uint256 maxDepth) external;
    function bucketTake(address borrower, uint256 index, bool depositTake) external;
}

/**
 * @title IAjnaPoolFactory
 * @notice Interface for Ajna pool factory
 */
interface IAjnaPoolFactory {
    /**
     * @notice Deploy a new ERC20 pool
     * @param collateral Collateral token
     * @param quote Quote token
     * @param interestRate Initial interest rate
     * @return pool Address of deployed pool
     */
    function deployPool(address collateral, address quote, uint256 interestRate) external returns (address pool);

    /**
     * @notice Constant used for standard ERC20 pools (non-subset hash)
     */
    function ERC20_NON_SUBSET_HASH() external pure returns (bytes32);

    /**
     * @notice Get deployed pool for token pair
     * @param subsetHash Pool subset hash (use ERC20_NON_SUBSET_HASH for standard pools)
     * @param collateral Collateral token
     * @param quote Quote token
     * @return pool Pool address (address(0) if doesn't exist)
     */
    function deployedPools(bytes32 subsetHash, address collateral, address quote) external view returns (address pool);

    /**
     * @notice Minimum allowed interest rate (WAD)
     */
    function MIN_RATE() external pure returns (uint256);

    /**
     * @notice Maximum allowed interest rate (WAD)
     */
    function MAX_RATE() external pure returns (uint256);

    /**
     * @notice Get number of deployed pools
     */
    function getNumberOfDeployedPools() external view returns (uint256);

    /**
     * @notice Get deployed pool by index
     */
    function deployedPoolsList(uint256 index) external view returns (address pool);
}
