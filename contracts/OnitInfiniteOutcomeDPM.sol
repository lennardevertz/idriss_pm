// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {convert, convert, div, mul} from "@prb/math/src/SD59x18.sol";

import {OnitInfiniteOutcomeDPMMechanism} from "./mechanisms/infinite-outcome-DPM/OnitInfiniteOutcomeDPMMechanism.sol";
import {OnitMarketResolver} from "./resolvers/OnitMarketResolver.sol";

/**
 * @title Onit Infinite Outcome Dynamic Parimutual Market
 *
 * @author Onit Labs (https://github.com/onit-labs)
 *
 * @notice Decentralized prediction market for continuous outcomes
 *
 * @dev Notes on the market:
 * - See OnitInfiniteOutcomeDPMMechanism for explanation of the mechanism
 * - See OnitInfiniteOutcomeDPMOutcomeDomain for explanation of the outcome domain and token tracking
 */
contract OnitInfiniteOutcomeDPM is
    OnitInfiniteOutcomeDPMMechanism,
    OnitMarketResolver
{
    // ----------------------------------------------------------------
    // Errors
    // ----------------------------------------------------------------

    /// Configuration Errors
    error AlreadyInitialized();
    error BettingCutoffOutOfBounds();
    error MarketCreatorCommissionBpOutOfBounds();
    /// Trading Errors
    error BettingCutoffPassedOrMarketNotOpen();
    error BetValueOutOfBounds();
    error IncorrectBetValue(int256 expected, uint256 actual);
    error InvalidSharesValue();
    /// Payment/Withdrawal Errors
    error NothingToPay();
    error RejectFunds();
    error TransferFailed();
    error WithdrawalDelayPeriodNotPassed();

    // ----------------------------------------------------------------
    // Events
    // ----------------------------------------------------------------

    /// Market Lifecycle Events
    event MarketInitialized(address indexed initiator, uint256 initialBacking);
    event BettingCutoffUpdated(uint256 bettingCutoff);
    /// Admin Events
    event CollectedProtocolFee(address indexed receiver, uint256 protocolFee);
    event CollectedMarketCreatorFee(
        address indexed receiver,
        uint256 marketCreatorFee
    );
    /// Trading Events
    event BoughtShares(
        address indexed trader, // Changed from predictor to trader for clarity with actualUser
        int256 costDiff,
        int256 newTotalQSquared
    );
    event SoldShares(
        address indexed trader, // Changed from predictor to trader
        int256 costDiff,
        int256 newTotalQSquared
    );
    event CollectedPayout(address indexed predictor, uint256 payout);
    event CollectedVoidedFunds(
        address indexed predictor,
        uint256 totalRepayment
    );

    // ----------------------------------------------------------------
    // State
    // ----------------------------------------------------------------

    /**
     * TraderStake is the amount they have put into the market
     * Traders can:
     * - Sell their position and leave the market (which makes sense if the traders position is worth more than their
     * stake)
     * - Redeem their position when the market closes
     * - Reclaim their stake if the market is void
     * - Lose their stake if their prediction generates no return
     */
    struct TraderStake {
        uint256 totalStake;
    }

    // Total amount the trader has bet across all predictions
    mapping(address trader => TraderStake stake) public tradersStake;

    /// Timestamp after which no more bets can be placed (0 = no cutoff)
    uint256 public bettingCutoff;
    /// Total payout pool when the market is resolved
    uint256 public totalPayout;
    /// Number of shares at the resolved outcome
    int256 public winningBucketSharesAtClose;

    /// Protocol fee collected, set at market close
    uint256 public protocolFee;
    /// The receiver of the market creator fees
    address public marketCreatorFeeReceiver;
    /// The (optional) market creator commission rate in basis points of 10000 (400 = 4%)
    uint256 public marketCreatorCommissionBp;
    /// The market creator fee, set at market close
    uint256 public marketCreatorFee;

    /// The question traders are predicting
    string public marketQuestion;

    /// Protocol commission rate in basis points of 10000 (400 = 4%) - Will be re-evaluated if DPM holds no tokens
    uint256 public constant PROTOCOL_COMMISSION_BP = 400;
    /// Maximum market creator commission rate (4%) - Note: docs.txt says no market creator fee
    uint256 public constant MAX_MARKET_CREATOR_COMMISSION_BP = 400;
    /// The minimum bet size (ETH denominated, will be removed/ignored for virtual ABC)
    uint256 public constant MIN_BET_SIZE = 1 ether; // To be removed or adapted
    /// The maximum bet size (ETH denominated, will be removed/ignored for virtual ABC)
    uint256 public constant MAX_BET_SIZE = 1_000_000 ether; // To be removed or adapted
    /// The version of the market
    string public constant VERSION = "0.0.2";

    address votinContractAddress;

    /// Market configuration params passed to initialize the market
    struct MarketConfig {
        address marketCreatorFeeReceiver;
        uint256 marketCreatorCommissionBp;
        uint256 bettingCutoff;
        uint256 withdrawlDelayPeriod;
        int256 outcomeUnit;
        string marketQuestion;
        string marketUri;
        address[] resolvers;
    }

    /// Market initialization data
    struct MarketInitData {
        /// Onit factory contract with the Onit admin address
        address onitFactory;
        /// Address that gets the initial prediction
        address initiator;
        /// Seeded funds to initialize the market pot
        uint256 seededFunds;
        /// Market configuration
        MarketConfig config;
        /// Bucket ids for the initial prediction
        int256[] initialBucketIds;
        /// Shares for the initial prediction
        int256[] initialShares;
    }

    // ----------------------------------------------------------------
    // Constructor
    // ----------------------------------------------------------------

    /**
     * @notice Construct the implementation of the market
     *
     * @dev Initialize owner to a dummy address to prevent implementation from being initialized
     */
    constructor() {
        // Used as flag to prevent implementation from being initialized, and to prevent bets
        marketVoided = true;
    }

    /**
     * @notice Initialize the market contract
     *
     * @dev This function can only be called once when the proxy is first deployed
     *
     * @param initData The market initialization data
     */
    function initialize(MarketInitData memory initData) external payable {
        // For virtual ABC model, msg.value will be 0. initData.seededFunds is also 0 from VotingV2.
        // The true "initial value" comes from initialLiquidityABC managed by VotingV2.
        // uint256 initialBetValue = msg.value - initData.seededFunds; // This becomes 0

        // Prevents the implementation from being initialized
        if (marketVoided) revert AlreadyInitialized();
        // If cutoff is set, it must be greater than now
        if (
            initData.config.bettingCutoff != 0 &&
            initData.config.bettingCutoff <= block.timestamp
        ) {
            revert BettingCutoffOutOfBounds();
        }
        if (
            initData.config.marketCreatorCommissionBp >
            MAX_MARKET_CREATOR_COMMISSION_BP
        ) {
            revert MarketCreatorCommissionBpOutOfBounds();
        }

        // Initialize Onit admin and resolvers
        _initializeOnitMarketResolver(
            initData.config.withdrawlDelayPeriod,
            initData.onitFactory,
            initData.config.resolvers
        );

        // Calculate the cost of initial shares, if any. This cost is what VotingV2's initialLiquidityABC covers.
        int256 costOfInitialShares = 0;
        if (initData.initialBucketIds.length > 0) {
            // This calculation should ideally use the DPM's own mechanism state (kappa)
            // For now, assuming calculateCostOfTrade can be called statically or on an uninitialized state
            // if it only depends on kappa (which is constant in OnitInfiniteOutcomeDPMMechanism)
            // and the provided shares/buckets.
            (costOfInitialShares, ) = calculateCostOfTrade(
                initData.initialBucketIds,
                initData.initialShares
            );
            // VotingV2 already validates that initialLiquidityABC == uint256(costOfInitialShares)
        }

        // Initialize Infinite Outcome DPM
        _initializeInfiniteOutcomeDPM(
            initData.initiator,
            initData.config.outcomeUnit,
            costOfInitialShares, // The "initial bet value" is the cost of the initial shares for the mechanism.
            initData.initialShares,
            initData.initialBucketIds
        );

        // Set market description
        marketQuestion = initData.config.marketQuestion;
        // Set time limit for betting
        bettingCutoff = initData.config.bettingCutoff;
        // Set market creator
        marketCreatorFeeReceiver = initData.config.marketCreatorFeeReceiver;
        // Set market creator commission rate
        marketCreatorCommissionBp = initData.config.marketCreatorCommissionBp;

        // Update the traders stake with the virtual ABC amount (cost of initial shares)
        tradersStake[initData.initiator] = TraderStake({
            totalStake: uint256(costOfInitialShares) // This is in virtual ABC units
        });

        emit MarketInitialized(initData.initiator, msg.value);
    }

    // ----------------------------------------------------------------
    // Admin functions
    // ----------------------------------------------------------------

    /// @notice initialize the voting contract address
    function initializeVotinContract(
        address newVotinContractAddress
    ) external onlyResolver {
        require(newVotinContractAddress != address(0), "Zero address");
        require(votinContractAddress == address(0), "Already initialized");
        votinContractAddress = newVotinContractAddress;
    }

    /**
     * @notice Set the resolved outcome, closing the market
     *
     * @param _resolvedOutcome The resolved value of the market
     */
    function resolveMarket(int256 _resolvedOutcome) external onlyResolver {
        _setResolvedOutcome(_resolvedOutcome, getBucketId(_resolvedOutcome));

        uint256 finalBalance = address(this).balance;

        // Calculate market maker fee
        uint256 _protocolFee = (finalBalance * PROTOCOL_COMMISSION_BP) / 10_000;
        protocolFee = _protocolFee;

        uint256 _marketCreatorFee = (finalBalance * marketCreatorCommissionBp) /
            10_000;
        marketCreatorFee = _marketCreatorFee;

        // Calculate total payout pool
        totalPayout = finalBalance - protocolFee - marketCreatorFee;

        /**
         * Set the total shares at the resolved outcome, traders payouts are:
         * totalPayout * tradersSharesAtOutcome/totalSharesAtOutcome
         */
        winningBucketSharesAtClose = getBucketOutstandingShares(
            resolvedBucketId
        );

        emit MarketResolved(
            _resolvedOutcome,
            winningBucketSharesAtClose,
            totalPayout
        );
    }

    /**
     * @notice Update the resolved outcome
     *
     * @param _resolvedOutcome The new resolved outcome
     *
     * @dev This is used to update the resolved outcome after the market has been resolved
     *      It is designed to real with disputes about the outcome.
     *      Can only be called:
     *      - By the owner
     *      - If the market is resolved
     *      - If the withdrawl delay period is open
     */
    function updateResolution(
        int256 _resolvedOutcome
    ) external onlyOnitFactoryOwner {
        _updateResolvedOutcome(_resolvedOutcome, getBucketId(_resolvedOutcome));
    }

    /**
     * @notice Update the betting cutoff
     *
     * @param _bettingCutoff The new betting cutoff
     *
     * @dev Can only be called by the Onit factory owner
     * @dev This enables the owner to extend the betting period, or close betting early without resolving the market
     * - It allows for handling unexpected events that delay the market resolution criteria being confirmed
     * - This function should be made more robust in future versions
     */
    function updateBettingCutoff(
        uint256 _bettingCutoff
    ) external onlyOnitFactoryOwner {
        bettingCutoff = _bettingCutoff;

        emit BettingCutoffUpdated(_bettingCutoff);
    }

    /**
     * @notice Withdraw protocol fees from the contract
     *
     * @param receiver The address to receive the fees
     */
    function withdrawFees(address receiver) external onlyOnitFactoryOwner {
        if (marketVoided) revert MarketIsVoided();
        if (resolvedAtTimestamp == 0) revert MarketIsOpen();
        if (block.timestamp < resolvedAtTimestamp + withdrawlDelayPeriod)
            revert WithdrawalDelayPeriodNotPassed();

        uint256 _protocolFee = protocolFee;
        protocolFee = 0;

        (bool success, ) = receiver.call{value: _protocolFee}("");
        if (!success) revert TransferFailed();

        emit CollectedProtocolFee(receiver, _protocolFee);
    }

    /**
     * @notice Withdraw the market creator fees
     *
     * @dev Can only be called if the market is resolved and the withdrawal delay period has passed
     * @dev Not guarded since all parameters are pre-set, enabling automatic fee distribution to creators
     */
    function withdrawMarketCreatorFees() external {
        if (marketVoided) revert MarketIsVoided();
        if (resolvedAtTimestamp == 0) revert MarketIsOpen();
        if (block.timestamp < resolvedAtTimestamp + withdrawlDelayPeriod)
            revert WithdrawalDelayPeriodNotPassed();

        uint256 _marketCreatorFee = marketCreatorFee;
        marketCreatorFee = 0;

        (bool success, ) = marketCreatorFeeReceiver.call{
            value: _marketCreatorFee
        }("");
        if (!success) revert TransferFailed();

        emit CollectedMarketCreatorFee(
            marketCreatorFeeReceiver,
            _marketCreatorFee
        );
    }

    /**
     * @notice Withdraw all remaining funds from the contract
     * @dev This is a backup function in case of an unforeseen error
     *      - Can not be called if market is open
     *      - Can not be called if 2 x withdrawal delay period has not passed
     * !!! REMOVE THIS FROM LATER VERSIONS !!!
     */
    function withdraw() external onlyOnitFactoryOwner {
        if (resolvedAtTimestamp == 0) revert MarketIsOpen();
        if (block.timestamp < resolvedAtTimestamp + 2 * withdrawlDelayPeriod) {
            revert WithdrawalDelayPeriodNotPassed();
        }
        if (marketVoided) revert MarketIsVoided();
        (bool success, ) = onitFactoryOwner().call{
            value: address(this).balance
        }("");
        if (!success) revert TransferFailed();
    }

    // ----------------------------------------------------------------
    // Public market functions
    // ----------------------------------------------------------------

    /**
     * @notice Executes a trade (buy/sell shares) for a user, funded by virtual ABC tokens.
     * @dev Called by `VotingV2` (the `votinContractAddress`). `VotingV2` is responsible for
     *      validating that `costABC` matches the DPM's calculated cost for the trade and
     *      that the `actualUser` has sufficient backing stake in `VotingV2`.
     * @param actualUser The end-user performing the trade.
     * @param costABC The amount of virtual ABC tokens representing the cost of this trade.
     * @param bucketIds The bucket IDs for the trade.
     * @param shares The shares for the trade (positive for buy, negative for sell).
     */
    function executeTradeForUser(
        // Renamed from vote
        address actualUser,
        uint256 costABC,
        int256[] memory bucketIds,
        int256[] memory shares
    ) external onlyVotingContract {
        if (bettingCutoff != 0 && block.timestamp > bettingCutoff)
            revert BettingCutoffPassedOrMarketNotOpen(); // Adjusted error name
        if (resolvedAtTimestamp != 0) revert MarketIsResolved();
        if (marketVoided) revert MarketIsVoided();
        // MIN_BET_SIZE and MAX_BET_SIZE checks are removed as they are ETH-based and
        // costABC validation is handled by VotingV2.

        // Calculate the cost difference for the trade.
        (int256 costDiff, int256 newTotalQSquared) = calculateCostOfTrade(
            bucketIds,
            shares
        );

        /**
         * Sanity check: VotingV2 should have already verified that costABC matches costDiff.
         * This is a defense-in-depth check within the DPM.
         * costDiff can be negative for sells, but costABC (representing payment/receipt) should be positive.
         * For buys, costDiff is positive. For sells, costDiff is negative (representing payout).
         * The `costABC` parameter from VotingV2 should always be the absolute value of the economic impact.
         */
        if (costABC != uint256(costDiff)) {
            revert IncorrectBetValue(costDiff, costABC); // Error indicates DPM calculated cost vs. provided costABC
        }

        // Track the latest totalQSquared so we don't need to recalculate it
        totalQSquared = newTotalQSquared;
        // Update the markets outcome token holdings
        _updateHoldings(actualUser, bucketIds, shares); // Use actualUser

        // Update the actualUser's total virtual stake in this market
        // If costDiff is positive (buy), stake increases. If negative (sell), stake decreases.
        // This assumes costABC is always positive and represents the magnitude of the change.
        tradersStake[actualUser].totalStake += costABC;

        emit BoughtShares(actualUser, costDiff, newTotalQSquared);
    }

    function collectPayout(address trader) external onlyVotingContract {
        if (resolvedAtTimestamp == 0) revert MarketIsOpen();
        if (block.timestamp < resolvedAtTimestamp + withdrawlDelayPeriod)
            revert WithdrawalDelayPeriodNotPassed();
        if (marketVoided) revert MarketIsVoided();

        // Calculate payout (TODO: change implementation later)
        uint256 payout = _calculatePayout(trader);

        // If caller has no stake, has already claimed, revert
        if (tradersStake[trader].totalStake == 0) revert NothingToPay();

        // Set stake to 0, preventing multiple payouts
        tradersStake[trader].totalStake = 0;

        // Send payout to prediction owner
        (bool success, ) = trader.call{value: payout}("");
        if (!success) revert TransferFailed();

        emit CollectedPayout(trader, payout);
    }

    function collectVoidedFunds(address trader) external {
        if (!marketVoided) revert MarketIsOpen();

        // Get the total repayment, then set totalStake storage to 0 to prevent multiple payouts
        uint256 totalRepayment = tradersStake[trader].totalStake;
        tradersStake[trader].totalStake = 0;

        if (totalRepayment == 0) revert NothingToPay();

        (bool success, ) = trader.call{value: totalRepayment}("");
        if (!success) revert TransferFailed();

        emit CollectedVoidedFunds(trader, totalRepayment);
    }

    /**
     * @notice Calculate the payout for a trader
     *
     * @param trader The address of the trader
     *
     * @return payout The payout amount
     */
    function calculatePayout(address trader) external view returns (uint256) {
        return _calculatePayout(trader);
    }

    // ----------------------------------------------------------------
    // Internal functions
    // ----------------------------------------------------------------

    /**
     * @notice Calculate the payout for a prediction
     *
     * @param trader The address of the trader
     *
     * @return payout The payout amount, TODO: adjust on new system
     */
    function _calculatePayout(address trader) internal view returns (uint256) {
        // Get total shares in winning bucket
        int256 totalBucketShares = getBucketOutstandingShares(resolvedBucketId);
        if (totalBucketShares == 0) return 0;

        // Get traders balance of the winning bucket
        uint256 traderShares = getBalanceOfShares(trader, resolvedBucketId);

        // Calculate payout based on share of winning bucket
        return
            uint256(
                convert(
                    convert(int256(traderShares))
                        .mul(convert(int256(totalPayout)))
                        .div(convert(totalBucketShares))
                )
            );
    }

    // ----------------------------------------------------------------
    // Modifier
    // ----------------------------------------------------------------

    modifier onlyVotingContract() {
        require(msg.sender == votinContractAddress, "Only voting contract");
        _;
    }

    // ----------------------------------------------------------------
    // Fallback functions
    // ----------------------------------------------------------------

    // TODO add functions for accepting or rejecting tokens when we move away from native payments

    /**
     * @dev Reject any funds sent to the contract
     * - We dont't want funds not accounted for in the market to effect the expected outcome for traders
     */
    fallback() external payable {
        revert RejectFunds();
    }

    /**
     * @dev Reject any funds sent to the contract
     * - We dont't want funds not accounted for in the market to effect the expected outcome for traders
     */
    receive() external payable {
        revert RejectFunds();
    }
}
