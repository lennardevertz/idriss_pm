// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {convert, div, mul} from "@prb/math/src/SD59x18.sol";

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
    error SubmissionCutoffOutOfBounds();
    error MarketCreatorCommissionBpOutOfBounds();
    /// Trading Errors
    error SubmissionPeriodClosedOrMarketNotOpen(); // Renamed
    error SubmissionWeightOutOfBounds(); // Renamed
    error IncorrectSubmissionWeight(int256 expected, uint256 actual); // Renamed
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
    event SubmissionCutoffUpdated(uint256 submissionCutoff);
    /// Admin Events
    event CollectedProtocolFee(address indexed receiver, uint256 protocolFee);
    event CollectedMarketCreatorFee(
        address indexed receiver,
        uint256 marketCreatorFee
    );
    /// Trading Events
    event BoughtShares(
        address indexed participant, // Renamed from trader
        int256 mechanismEffect, // Renamed from costDiff
        int256 newTotalQSquared
    );
    event SoldShares(
        address indexed participant, // Renamed from trader
        int256 mechanismEffect, // Renamed from costDiff
        int256 newTotalQSquared
    );
    // event CollectedPayout(address indexed predictor, uint256 payout); // Removed
    event VoidedParticipationFundsNoted(
        // Renamed, as DPM doesn't send funds
        address indexed predictor,
        uint256 totalRepayment
    );

    // ----------------------------------------------------------------
    // State
    // ----------------------------------------------------------------

    /**
     * ParticipantRecord stores the total virtual weight associated with a participant's submissions.
     */
    struct ParticipantRecord {
        // Renamed from TraderStake
        uint256 totalSubmissionWeight; // Renamed from totalStake
    }

    // Stores the record for each participant.
    mapping(address participant => ParticipantRecord record)
        public participantRecords; // Renamed from tradersStake

    /// Timestamp after which no more submissions can be made (0 = no cutoff)
    uint256 public submissionCutoff; // Renamed from bettingCutoff
    
    // --- Confidence Aggregation State ---
    int256 public aggregatedMeanSd59x18;
    int256 public aggregatedStdDevSd59x18;
    bool public confidenceAggregationComplete;
    uint256 public aggregationFinalizedTimestamp;
    // --- End Confidence Aggregation State ---

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
    uint256 public constant MAX_MARKET_CREATOR_COMMISSION_BP = 400; // To be removed if no market creator fee
    /// The minimum submission weight in ABC token units.
    uint256 public constant MIN_SUBMISSION_WEIGHT = 1 * 10 ** 18; // Renamed from MIN_BET_SIZE
    /// The maximum submission weight in ABC token units.
    uint256 public constant MAX_SUBMISSION_WEIGHT = 1_000_000 * 10 ** 18; // Renamed from MAX_BET_SIZE
    /// The version of the market
    string public constant VERSION = "0.0.2";

    address votinContractAddress;

    /// Market configuration params passed to initialize the market
    struct MarketConfig {
        address marketCreatorFeeReceiver;
        uint256 marketCreatorCommissionBp;
        uint256 submissionCutoff; // Renamed
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
        address initiator; // This is the first participant
        /// Initial virtual weight for the market (from VotingV2's initialLiquidityABC)
        uint256 initialVirtualWeight; // Renamed from seededFunds
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
        // For the virtual ABC model:
        // - msg.value will be 0 (as called by VotingV2).
        // - initData.initialVirtualWeight will be populated by VotingV2 with initialLiquidityABC.
        // This is the "initial submission weight" in virtual ABC terms.
        uint256 initialSubmissionWeightABC = initData.initialVirtualWeight; // Using renamed field

        // Prevents the implementation from being initialized
        if (marketVoided) revert AlreadyInitialized();

        // Apply MIN_SUBMISSION_WEIGHT and MAX_SUBMISSION_WEIGHT checks to the virtual initialSubmissionWeightABC.
        // These constants MUST be defined in ABC token units (e.g., considering ABC's decimals).
        if (
            initialSubmissionWeightABC < MIN_SUBMISSION_WEIGHT ||
            initialSubmissionWeightABC > MAX_SUBMISSION_WEIGHT
        ) revert SubmissionWeightOutOfBounds(); // Renamed error

        if (
            initData.config.submissionCutoff != 0 && // Using renamed field
            initData.config.submissionCutoff <= block.timestamp // Using renamed field
        ) {
            revert SubmissionCutoffOutOfBounds();
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

        // VotingV2 ensures that if initialBucketIds/initialShares are provided,
        // initialSubmissionWeightABC (i.e., initialLiquidityABC) correctly matches their calculated cost.
        // The DPM trusts this pre-validation by VotingV2.

        // Initialize Infinite Outcome DPM
        _initializeInfiniteOutcomeDPM(
            initData.initiator,
            initData.config.outcomeUnit,
            int256(initialSubmissionWeightABC), // Pass the virtual weight
            initData.initialShares,
            initData.initialBucketIds
        );

        // Set market description
        marketQuestion = initData.config.marketQuestion;
        // Set time limit for submissions
        submissionCutoff = initData.config.submissionCutoff; // Using renamed field
        // Set market creator
        marketCreatorFeeReceiver = initData.config.marketCreatorFeeReceiver;
        // Set market creator commission rate
        marketCreatorCommissionBp = initData.config.marketCreatorCommissionBp;

        // Update the participant's record with the virtual ABC amount
        participantRecords[initData.initiator] = ParticipantRecord({ // Using renamed mapping and struct
            totalSubmissionWeight: initialSubmissionWeightABC // Using renamed field
        });

        emit MarketInitialized(initData.initiator, msg.value); // msg.value will be 0
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
     * @notice Finalizes the confidence market by calculating aggregated metrics.
     * @dev Called by a resolver (e.g., VotingV2) after the submissionCutoff has passed.
     */
    function finalizeConfidenceMarket() external onlyResolver {
        if (submissionCutoff == 0 || block.timestamp < submissionCutoff) {
            revert SubmissionPeriodClosedOrMarketNotOpen();
        }
        if (confidenceAggregationComplete) {
            revert AlreadyInitialized(); // Or "AggregationAlreadyComplete"
        }
        if (marketVoided) {
            revert MarketIsVoided();
        }

        // --- Placeholder for Mean and Standard Deviation Calculation ---
        // This section will need to be replaced with actual logic to iterate
        // through participant submissions (their share distributions in _holdings)
        // and calculate the aggregated mean and standard deviation.
        // This is a complex and potentially gas-intensive operation.
        int256 placeholderMean = convert(100); 
        int256 placeholderStdDev = convert(10);
        aggregatedMeanSd59x18 = placeholderMean;
        aggregatedStdDevSd59x18 = placeholderStdDev;
        // --- End Placeholder ---

        confidenceAggregationComplete = true;
        aggregationFinalizedTimestamp = block.timestamp;

        // Use _setResolvedOutcome to set the resolvedAtTimestamp, which signals finalization.
        // Pass the mean as the "resolvedOutcome" for compatibility/information.
        // The bucketId is set to 0 as it's not a single winning bucket in this model.
        _setResolvedOutcome(aggregatedMeanSd59x18, 0); 

        // Emit an event indicating confidence market finalization
        // winningBucketSharesAtClose and totalPayout are 0 as they are not used in this model.
        emit MarketResolved(aggregatedMeanSd59x18, 0, 0); 
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
        // If this function is still needed, its interaction with confidenceAggregationComplete
        // and the aggregated metrics needs to be considered.
        // For now, it updates the base resolvedOutcome.
        _updateResolvedOutcome(_resolvedOutcome, getBucketId(_resolvedOutcome));
        // Potentially re-calculate or flag aggregated metrics for review if _resolvedOutcome changes.
    }

    /**
     * @notice Update the submission cutoff
     *
     * @param _submissionCutoff The new submission cutoff
     *
     * @dev Can only be called by the Onit factory owner
     * @dev This enables the owner to extend the submission period, or close submissions early without resolving the market
     * - It allows for handling unexpected events that delay the market resolution criteria being confirmed
     * - This function should be made more robust in future versions
     */
    function updateSubmissionCutoff(
        // Renamed
        uint256 _submissionCutoff // Renamed parameter
    ) external onlyOnitFactoryOwner {
        submissionCutoff = _submissionCutoff; // Corrected assignment

        emit SubmissionCutoffUpdated(_submissionCutoff); // Event name not changed in diff
    }

    /**
     * @notice Withdraw protocol fees from the contract
     *
     * @param receiver The address to receive the fees
     */
    function withdrawFees(address receiver) external onlyOnitFactoryOwner {
        if (marketVoided) revert MarketIsVoided();
        if (resolvedAtTimestamp == 0) revert MarketIsOpen(); // Checks if _setResolvedOutcome was called
        if (block.timestamp < resolvedAtTimestamp + withdrawlDelayPeriod)
            revert WithdrawalDelayPeriodNotPassed();

        // Note: Protocol fee calculation might need adjustment if it's not based on ETH balance.
        // For a virtual ABC system, the DPM might not hold actual funds for fees.
        // This logic is retained from the original contract but might be deprecated or changed.
        uint256 _protocolFee = protocolFee; // protocolFee would need to be set by finalizeConfidenceMarket if applicable
        protocolFee = 0;

        if (_protocolFee > 0) { // Only attempt transfer if there's a fee
            (bool success, ) = receiver.call{value: _protocolFee}("");
            if (!success) revert TransferFailed();
        }

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
        if (resolvedAtTimestamp == 0) revert MarketIsOpen(); // Checks if _setResolvedOutcome was called
        if (block.timestamp < resolvedAtTimestamp + withdrawlDelayPeriod)
            revert WithdrawalDelayPeriodNotPassed();

        // Similar to protocol fees, marketCreatorFee calculation and source might change.
        uint256 _marketCreatorFee = marketCreatorFee; // marketCreatorFee would need to be set by finalizeConfidenceMarket
        marketCreatorFee = 0;

        if (_marketCreatorFee > 0) { // Only attempt transfer if there's a fee
            (bool success, ) = marketCreatorFeeReceiver.call{
                value: _marketCreatorFee
            }("");
            if (!success) revert TransferFailed();
        }
        
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
        // This function implies the contract holds ETH. In a virtual ABC system, this might not be the case.
        (bool success, ) = onitFactoryOwner().call{
            value: address(this).balance
        }("");
        if (!success) revert TransferFailed();
    }

    // ----------------------------------------------------------------
    // Public market functions
    // ----------------------------------------------------------------

    /**
     * @notice Records a user's confidence submission (shares distribution) backed by virtual ABC weight.
     * @dev Called by `VotingV2` (the `votinContractAddress`). `VotingV2` is responsible for
     *      validating that `submissionWeightABC` matches the DPM's calculated mechanism effect for the submission and
     *      that the `participant` has sufficient backing stake in `VotingV2`.
     * @param participant The end-user making the submission.
     * @param submissionWeightABC The amount of virtual ABC tokens representing the weight of this submission.
     * @param bucketIds The bucket IDs for the submission.
     * @param shares The shares for the submission (positive for acquiring, negative for relinquishing).
     */
    function recordSubmission(
        // Renamed from executeTradeForUser
        address participant, // Renamed from actualUser
        uint256 submissionWeightABC, // Renamed from costABC
        int256[] memory bucketIds,
        int256[] memory shares
    ) external onlyVotingContract {
        if (submissionCutoff != 0 && block.timestamp > submissionCutoff)
            // Using renamed state var
            revert SubmissionPeriodClosedOrMarketNotOpen(); // Using renamed error
        if (resolvedAtTimestamp != 0) revert MarketIsResolved(); // Check against general resolution timestamp
        if (marketVoided) revert MarketIsVoided();
        // MIN_SUBMISSION_WEIGHT and MAX_SUBMISSION_WEIGHT checks are implicitly handled by VotingV2
        // ensuring submissionWeightABC is valid against the DPM's calculated mechanismEffect.

        // Calculate the mechanism's effect (e.g., cost to acquire/value from relinquishing shares).
        (
            int256 mechanismEffect,
            int256 newTotalQSquared
        ) = calculateCostOfTrade(bucketIds, shares); // Renamed internal var

        /**
         * Sanity check: VotingV2 should have already verified that submissionWeightABC matches mechanismEffect.
         * This is a defense-in-depth check within the DPM.
         * mechanismEffect can be negative for relinquishing shares, but submissionWeightABC should be positive.
         * For acquiring, mechanismEffect is positive. For relinquishing, mechanismEffect is negative.
         * The `submissionWeightABC` from VotingV2 should always be the absolute value of the economic impact.
         */
        if (
            submissionWeightABC !=
            (
                mechanismEffect > 0
                    ? uint256(mechanismEffect)
                    : uint256(-mechanismEffect)
            )
        ) {
            revert IncorrectSubmissionWeight(
                mechanismEffect,
                submissionWeightABC
            ); // Using renamed error
        }

        // Track the latest totalQSquared so we don't need to recalculate it
        totalQSquared = newTotalQSquared;
        // Update the markets outcome token holdings
        _updateHoldings(participant, bucketIds, shares); // Use renamed parameter

        // Update the participant's total virtual submission weight in this market
        participantRecords[participant]
            .totalSubmissionWeight += submissionWeightABC; // Using renamed mapping and field

        emit BoughtShares(participant, mechanismEffect, newTotalQSquared); // Using renamed event params
    }

    function collectVoidedFunds(address trader) external {
        if (!marketVoided) revert MarketIsOpen();

        // Get the total repayment, then set totalSubmissionWeight storage to 0 to prevent multiple payouts
        uint256 totalRepayment = participantRecords[trader]
            .totalSubmissionWeight; // Using renamed mapping/field
        participantRecords[trader].totalSubmissionWeight = 0; // Using renamed mapping/field

        if (totalRepayment == 0) revert NothingToPay();

        // In a virtual ABC system, the DPM doesn't hold funds to send back.
        // This function's purpose needs re-evaluation. VotingV2 would manage the "voided" stake.
        // For now, emitting an event might be sufficient for VotingV2 to react.
        // (bool success, ) = trader.call{value: totalRepayment}(""); // This line would fail if DPM holds no ETH
        // if (!success) revert TransferFailed();

        emit VoidedParticipationFundsNoted(trader, totalRepayment); // Using renamed event
    }

    // ----------------------------------------------------------------
    // View functions for VotingV2 / Aggregation
    // ----------------------------------------------------------------

    /**
     * @notice Returns the aggregated confidence metrics for the market.
     * @return mean The aggregated mean (SD59x18).
     * @return stdDev The aggregated standard deviation (SD59x18).
     * @return isComplete True if aggregation is complete, false otherwise.
     * @return finalizedTimestamp Timestamp of finalization.
     */
    function getAggregatedConfidenceMetrics()
        external
        view
        returns (
            int256 mean,
            int256 stdDev,
            bool isComplete,
            uint256 finalizedTimestamp
        )
    {
        return (
            aggregatedMeanSd59x18,
            aggregatedStdDevSd59x18,
            confidenceAggregationComplete,
            aggregationFinalizedTimestamp
        );
    }

    enum ParticipantPerformanceStatus { NotApplicable, InBand, OutOfBand }

    /**
     * @notice Determines if a participant's submission is within the confidence band.
     * @dev This is a placeholder. The actual logic requires deriving an "effective score"
     *      from the participant's share distribution (_holdings) and comparing it
     *      against the aggregated mean and standard deviation.
     * @param participant The address of the participant.
     * @param mean The aggregated mean of the market (Sd59x18).
     * @param stdDev The aggregated standard deviation of the market (Sd59x18).
     * @return status Enum indicating if InBand, OutOfBand, or NotApplicable (e.g., no submission).
     */
    function determineParticipantBandStatus(
        address participant,
        int256 mean,
        int256 stdDev
    ) external view returns (ParticipantPerformanceStatus status) {
        if (!confidenceAggregationComplete) {
            return ParticipantPerformanceStatus.NotApplicable; // Or revert: MarketNotYetAggregated
        }
        if (participantRecords[participant].totalSubmissionWeight == 0) {
            return ParticipantPerformanceStatus.NotApplicable; // No submission to evaluate
        }

        // --- Placeholder for deriving participant's effective score ---
        // This is the complex part:
        // 1. Access participant's share distribution from `_holdings` (e.g., using `getBalanceOfSharesInBucketRange`).
        // 2. Calculate a single "effective score" or "implied mean" from this distribution.
        //    For example, a weighted average of the centers of the buckets in which they hold shares.
        //    The weight for each bucket could be the number of shares they hold in that bucket.
        //
        // int256 participantEffectiveScore = _calculateParticipantEffectiveScore(participant); // Hypothetical internal function
        //
        // For now, as a simple placeholder, let's assume the participant's effective score
        // is the market mean if they participated. This is NOT realistic.
        int256 participantEffectiveScore = mean; // Simulate they voted exactly the mean for now
        // --- End Placeholder ---

        // Determine if in band (e.g., mean +/- 1 standard deviation)
        // Ensure stdDev is non-negative if it can be. PRBMath SD59x18 can be negative.
        // For band calculation, absolute stdDev might be intended, or ensure it's positive from aggregation.
        int256 lowerBound = mean - (stdDev > 0 ? stdDev : -stdDev); // Example: using absolute stdDev
        int256 upperBound = mean + (stdDev > 0 ? stdDev : -stdDev); // Example: using absolute stdDev

        if (
            participantEffectiveScore >= lowerBound &&
            participantEffectiveScore <= upperBound
        ) {
            return ParticipantPerformanceStatus.InBand;
        } else {
            return ParticipantPerformanceStatus.OutOfBand;
        }
    }

    // --- Hypothetical internal function to calculate effective score from shares ---
    // function _calculateParticipantEffectiveScore(address participant) internal view returns (int256 effectiveScore) {
    //     // Logic to iterate participant's shares in various buckets from `_holdings`
    //     // and compute a weighted average or similar metric.
    //     // This would use `getBalanceOfShares(participant, bucketId)` and `getBucketCenter(bucketId)`.
    //     // This is computationally intensive if the participant has shares in many buckets.
    //     // Example sketch:
    //     // int256 totalWeightedScore = 0;
    //     // int256 totalSharesConsidered = 0;
    //     // For each bucketId where participant has shares:
    //     //   int256 sharesInBucket = getBalanceOfShares(participant, bucketId);
    //     //   if (sharesInBucket > 0) {
    //     //     int256 bucketCenter = getBucketCenter(bucketId);
    //     //     totalWeightedScore = totalWeightedScore.add(bucketCenter.mul(sharesInBucket));
    //     //     totalSharesConsidered = totalSharesConsidered.add(sharesInBucket);
    //     //   }
    //     // if (totalSharesConsidered == 0) return convert(0); // Or handle as error/default
    //     // effectiveScore = totalWeightedScore.div(totalSharesConsidered);
    //     return convert(0); // Placeholder
    // }

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
