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
    event CollectedPayout(address indexed predictor, uint256 payout);
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
        if (resolvedAtTimestamp != 0) revert MarketIsResolved();
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

    function collectPayout(address trader) external onlyVotingContract {
        if (resolvedAtTimestamp == 0) revert MarketIsOpen();
        if (block.timestamp < resolvedAtTimestamp + withdrawlDelayPeriod)
            revert WithdrawalDelayPeriodNotPassed();
        if (marketVoided) revert MarketIsVoided();

        // Calculate payout (TODO: change implementation later)
        uint256 payout = _calculatePayout(trader);

        // If participant has no virtual weight, or has already claimed, revert
        if (participantRecords[trader].totalSubmissionWeight == 0)
            revert NothingToPay(); // Using renamed mapping/field

        // Set virtual weight to 0, preventing multiple payouts (if DPM handles payout state)
        participantRecords[trader].totalSubmissionWeight = 0; // Using renamed mapping/field

        // Send payout to prediction owner
        (bool success, ) = trader.call{value: payout}("");
        if (!success) revert TransferFailed();

        emit CollectedPayout(trader, payout);
    }

    function collectVoidedFunds(address trader) external {
        if (!marketVoided) revert MarketIsOpen();

        // Get the total repayment, then set totalSubmissionWeight storage to 0 to prevent multiple payouts
        uint256 totalRepayment = participantRecords[trader]
            .totalSubmissionWeight; // Using renamed mapping/field
        participantRecords[trader].totalSubmissionWeight = 0; // Using renamed mapping/field

        if (totalRepayment == 0) revert NothingToPay();

        (bool success, ) = trader.call{value: totalRepayment}("");
        if (!success) revert TransferFailed();

        emit VoidedParticipationFundsNoted(trader, totalRepayment); // Using renamed event
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
