// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.16;

import {Ownable} from "solady/src/auth/Ownable.sol"; // Staker likely inherits Ownable
import {LibClone} from "solady/src/utils/LibClone.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "./Staker.sol"; // Assuming Staker.sol is in the same directory
import {OnitInfiniteOutcomeDPM, MarketConfig, MarketInitData} from "../../../OnitInfiniteOutcomeDPM.sol"; // Adjusted path

/**
 * @title VotingV2 contract - Refactored for Confidence-Based Prediction Market
 * @dev Handles staking ABC tokens and creating topics (Onit DPM markets).
 *      Manages user stakes, emissions, confidence submissions, and will manage
 *      reward/slashing distribution based on confidence scores submitted to Onit DPM markets.
 */
contract VotingV2 is Staker {
    // TODO: Re-evaluate if UINT64_MAX is needed after full refactoring. Staker or new logic might use it.
    uint64 public constant UINT64_MAX = type(uint64).max;

    /****************************************
     *        MARKET/TOPIC STATE            *
     ****************************************/

    /// @notice Address of the OnitInfiniteOutcomeDPM implementation to be cloned for new topics.
    address public onitDPMImplementation;

    /// @notice Mapping from a topic ID (keccak256 of marketQuestion + initialLiquidity) to its DPM contract address.
    mapping(bytes32 => address) public topicsMarketAddress;

    /// @notice Mapping from a topic ID to its DPM market configuration.
    mapping(bytes32 => OnitInfiniteOutcomeDPM.MarketConfig) public topicConfigs;

    // Struct to store a user's total participation details for a specific topic
    struct TopicParticipation {
        uint256 totalStakeAmountABC; // Total ABC staked by the user for this topic across all their submissions
        uint64 lastSubmissionTimestamp; // Timestamp of the latest submission by the user for this topic
        bool rewardClaimed; // To track if rewards/slashes have been processed
    }

    // Mapping: topicId -> userAddress -> participation details
    mapping(bytes32 => mapping(address => TopicParticipation))
        public userTopicParticipation;

    // Mapping to track all topic IDs a user has participated in.
    // Used by _updateTrackers to find relevant topics for a user.
    mapping(address => bytes32[]) public userParticipatedTopicIds;

    // Phases for a topic
    enum TopicPhase {
        Created, // Initial state, DPM might be uninitialized or pre-betting window
        AcceptingConfidence, // Betting window is open for confidence submissions
        AggregatingResults, // Betting cutoff passed, results being calculated/finalized
        Settled // Results finalized, rewards/slashes can be claimed
    }

    // Mapping: topicId -> current phase of the topic
    mapping(bytes32 => TopicPhase) public topicPhase;

    /****************************************
     *                EVENTS                *
     ****************************************/

    event OnitDPMImplementationSet(address indexed newImplementation);
    event TopicCreated(
        bytes32 indexed topicId,
        address indexed marketAddress,
        address indexed creator,
        string marketQuestion,
        OnitInfiniteOutcomeDPM.MarketConfig config
    );
    event ConfidenceSubmitted(
        bytes32 indexed topicId,
        address indexed user,
        uint256 additionalStakeAmountABC,
        uint256 timestamp,
        uint256 newTotalUserStakeForTopic // New field: user's new total stake for this topic
    );
    event TopicPhaseChanged(bytes32 indexed topicId, TopicPhase newPhase);
    event UserTopicRewardApplied(
        bytes32 indexed topicId,
        address indexed user,
        uint256 rewardAmount
    );
    event UserTopicSlashApplied(
        bytes32 indexed topicId,
        address indexed user,
        uint256 slashAmount
    );

    /****************************************
     *                ERRORS                *
     ****************************************/
    error OnitDPMImplementationNotSet();
    error FailedToDeployTopicMarket();
    error FailedToInitializeTopicMarket();
    error InsufficientCreatorStake(); // For createTopic initialLiquidityABC
    error TopicNotFound(bytes32 topicId);
    error InvalidTopicPhaseForConfidence(
        bytes32 topicId,
        TopicPhase currentPhase
    );
    error InsufficientAvailableStake(uint256 required, uint256 available);
    error StakeAmountMustBePositive();
    error InvalidBucketOrShareData();
    error DPMInteractionFailed();
    error StakeAmountMismatchWithDPMCost();
    error InitialLiquidityMismatchWithSharesCost();

    /**
     * @notice Construct the VotingV2 contract.
     * @param _emissionRate amount of voting tokens (ABC) that are emitted per second, split prorata between stakers.
     * @param _unstakeCoolDown time that a staker must wait to unstake after requesting to unstake.
     * @param _votingToken address of the ABC token contract used for staking.
     */
    constructor(
        uint128 _emissionRate,
        uint64 _unstakeCoolDown,
        address _votingToken
    ) Staker(_emissionRate, _unstakeCoolDown, _votingToken) {
        // Ownable constructor is called by Staker's parent (likely OwnableUpgradeable or Ownable)
    }

    /****************************************
     *         ADMIN CONFIG FUNCTIONS       *
     ****************************************/

    /**
     * @notice Sets the address of the Onit DPM implementation contract.
     * @dev Only callable by the owner.
     * @param _implementation The address of the OnitInfiniteOutcomeDPM implementation.
     */
    function setOnitDPMImplementation(
        address _implementation
    ) external onlyOwner {
        require(
            _implementation != address(0),
            "Implementation cannot be zero address"
        );
        onitDPMImplementation = _implementation;
        emit OnitDPMImplementationSet(_implementation);
    }

    /****************************************
     *        TOPIC MANAGEMENT FUNCTIONS    *
     ****************************************/

    /**
     * @notice Create a new topic, which deploys an OnitInfiniteOutcomeDPM market.
     * @param marketQuestion The unique question or identifier for the topic.
     * @param bettingCutoff Timestamp when betting for this topic closes.
     * @param outcomeUnit The unit size for outcome buckets in the DPM.
     * @param marketUri A URI pointing to additional metadata about the market/topic.
     * @param initialLiquidityABC Amount of ABC tokens the creator commits to this topic's DPM initial state.
     *                            This amount will be committed from the creator's staked ABC.
     * @param initialBucketIds Initial bucket IDs for seeding the market (DPM specific).
     * @param initialShares Corresponding initial shares for the bucket IDs (DPM specific).
     * @return marketAddress The address of the newly created Onit DPM market for the topic.
     * @return topicId The unique ID for the created topic.
     */
    function createTopic(
        string memory marketQuestion,
        uint256 bettingCutoff,
        int256 outcomeUnit,
        string memory marketUri,
        uint256 initialLiquidityABC,
        int256[] memory initialBucketIds,
        int256[] memory initialShares
    ) external returns (address marketAddress, bytes32 topicId) {
        if (onitDPMImplementation == address(0)) {
            revert OnitDPMImplementationNotSet();
        }

        address initiator = msg.sender;

        if (initialBucketIds.length > 0) {
            // Assuming if buckets are provided, shares are too and are meaningful
            if (initialBucketIds.length != initialShares.length) {
                revert InvalidBucketOrShareData();
            }
            if (initialLiquidityABC == 0) {
                // If providing initial shares, liquidity must cover their cost.
                revert InsufficientCreatorStake();
            }
            uint256 availableStakeForCreator = _getAvailableStake(initiator);
            if (initialLiquidityABC > availableStakeForCreator) {
                revert InsufficientAvailableStake(
                    initialLiquidityABC,
                    availableStakeForCreator
                );
            }

            // Verify initialLiquidityABC matches the DPM's cost for the initial shares.
            // This requires onitDPMImplementation to be set.
            if (onitDPMImplementation == address(0)) {
                revert OnitDPMImplementationNotSet(); // Should be caught earlier, but defensive
            }
            (int256 costDiffFromDPM, ) = OnitInfiniteOutcomeDPM(
                payable(onitDPMImplementation)
            ).calculateCostOfTrade(initialBucketIds, initialShares);
            if (initialLiquidityABC != uint256(costDiffFromDPM)) {
                revert InitialLiquidityMismatchWithSharesCost();
            }
            // Note: initialLiquidityABC is the creator's stake AT RISK for seeding the DPM.
            // It's recorded in userTopicParticipation when/if the creator also makes a formal "submission"
            // or if seeding itself is considered their first submission.
            // The DPM will need to be adapted to use this initialLiquidityABC.
        } else {
            // No initial shares, initialLiquidityABC should ideally be 0 unless DPM has other uses for it.
            if (initialLiquidityABC != 0) {
                // Or handle this case if DPM can use initialLiquidityABC without initial shares.
                revert("InitialLiquidityProvidedWithoutInitialShares");
            }
        }

        address[] memory dpmResolvers = new address[](1);
        dpmResolvers[0] = address(this); // VotingV2 can be a resolver for the DPM

        MarketConfig memory marketConfig = MarketConfig({
            marketCreatorFeeReceiver: address(0), // No market creator fee in this system
            marketCreatorCommissionBp: 0,
            bettingCutoff: bettingCutoff,
            withdrawlDelayPeriod: 0, // To be defined if needed for confidence market settlement
            outcomeUnit: outcomeUnit,
            marketQuestion: marketQuestion,
            marketUri: marketUri,
            resolvers: dpmResolvers
        });

        // CRITICAL DPM ADAPTATION REQUIRED:
        // The DPM's initialize function calculates: `initialBetValue = msg.value - initData.seededFunds;`
        // We are calling with `msg.value = 0`. `initData.seededFunds` is also 0.
        // The `initialLiquidityABC` should be used by the DPM to set its initial state.
        // This requires OnitInfiniteOutcomeDPM.initialize to be adapted to accept an ABC value,
        // or for VotingV2 to transfer ABC to the DPM if the DPM is modified to hold ABC.
        MarketInitData memory marketInitData = MarketInitData({
            onitFactory: address(this), // VotingV2 acts as the factory/admin for the DPM
            initiator: initiator,
            seededFunds: 0, // ETH-based seededFunds, not used for ABC liquidity.
            // A new field like `initialLiquidityValueABC: initialLiquidityABC` might be needed in MarketInitData
            // for the DPM to consume `initialLiquidityABC`.
            config: marketConfig,
            initialBucketIds: initialBucketIds,
            initialShares: initialShares
        });

        bytes memory encodedInitData = abi.encodeWithSelector(
            OnitInfiniteOutcomeDPM.initialize.selector,
            marketInitData
        );

        // Salt includes parameters that define the market's uniqueness.
        // Using initialLiquidityABC in salt ensures unique address if other params are same but liquidity differs.
        bytes32 salt = keccak256(
            abi.encode(
                address(this), // Deployer context
                initiator,
                marketConfig.bettingCutoff,
                marketConfig.marketQuestion,
                initialLiquidityABC // Creator's ABC commitment for DPM seeding
            )
        );

        address clonedMarketAddress = LibClone.cloneDeterministic(
            onitDPMImplementation,
            salt
        );

        // Call DPM initialize. msg.value is 0. DPM must be adapted for ABC liquidity.
        (bool success, bytes memory returnData) = clonedMarketAddress.call{
            value: 0
        }(encodedInitData);

        if (!success) {
            if (returnData.length > 0) {
                assembly {
                    let returnDataSize := mload(returnData)
                    revert(add(32, returnData), returnDataSize)
                }
            }
            revert FailedToDeployTopicMarket();
        }

        // Verify DPM initialization (e.g., factory address set correctly)
        address checkOnitFactory = OnitInfiniteOutcomeDPM(
            payable(clonedMarketAddress)
        ).onitFactory();
        if (checkOnitFactory != address(this)) {
            revert FailedToInitializeTopicMarket();
        }

        marketAddress = clonedMarketAddress;
        // topicId should be unique. Using the same elements as salt for consistency.
        topicId = salt; // Or re-calculate if salt has deployer-specific elements not part of topic identity

        topicsMarketAddress[topicId] = marketAddress;
        topicConfigs[topicId] = marketConfig;
        topicPhase[topicId] = TopicPhase.AcceptingConfidence; // Set initial phase

        // Authorize VotingV2 to call `vote` on the DPM
        OnitInfiniteOutcomeDPM(payable(marketAddress)).initializeVotinContract(
            address(this)
        );

        // If initial liquidity was provided by the creator, record it as their first participation/commitment for this topic.
        if (initialLiquidityABC > 0) {
            TopicParticipation storage participation = userTopicParticipation[
                topicId
            ][initiator];
            participation.totalStakeAmountABC = initialLiquidityABC;
            participation.lastSubmissionTimestamp = SafeCast.toUint64(
                block.timestamp
            );
            // Add topic to creator's list of participated topics if not already
            bool found = false;
            for (
                uint i = 0;
                i < userParticipatedTopicIds[initiator].length;
                i++
            ) {
                if (userParticipatedTopicIds[initiator][i] == topicId) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                userParticipatedTopicIds[initiator].push(topicId);
            }
            // Note: This initialLiquidityABC is now "at risk" for the creator on this topic.
        }

        emit TopicCreated(
            topicId,
            marketAddress,
            initiator,
            marketQuestion,
            marketConfig
        );
        emit TopicPhaseChanged(topicId, TopicPhase.AcceptingConfidence);

        return (marketAddress, topicId);
    }

    /**
     * @notice Predicts the address where a topic's market will be deployed.
     * @param initiator The address that will initiate the topic creation.
     * @param marketQuestion The unique question or identifier for the topic.
     * @param marketBettingCutoff Timestamp when betting for the topic will close.
     * @param initialLiquidityABC Total amount of ABC tokens the creator commits for DPM seeding.
     * @return address The predicted address of the Onit DPM market.
     */
    function predictTopicMarketAddress(
        address initiator,
        string memory marketQuestion,
        uint256 marketBettingCutoff,
        uint256 initialLiquidityABC
    ) public view returns (address) {
        if (onitDPMImplementation == address(0)) {
            revert OnitDPMImplementationNotSet();
        }

        bytes32 salt = keccak256(
            abi.encode(
                address(this),
                initiator,
                marketBettingCutoff,
                marketQuestion,
                initialLiquidityABC
            )
        );

        return
            LibClone.predictDeterministicAddress(
                onitDPMImplementation,
                salt,
                address(this) // Deployer of the clone is this contract
            );
    }

    /**
     * @notice Submits a confidence score for a given topic, staking a specified amount of ABC tokens.
     * @param topicId The ID of the topic to submit confidence for.
     * @param additionalStakeAmountABC The amount of ABC tokens to additionally stake with this submission.
     * @param bucketIds The bucket IDs for the DPM trade.
     * @param shares The shares for the DPM trade.
     */
    function submitConfidence(
        bytes32 topicId,
        uint256 additionalStakeAmountABC,
        int256[] memory bucketIds,
        int256[] memory shares
    ) external nonReentrant {
        address user = msg.sender;
        address marketAddress = topicsMarketAddress[topicId];

        // 1. Check topic existence and phase
        if (marketAddress == address(0)) {
            revert TopicNotFound(topicId);
        }
        if (topicPhase[topicId] != TopicPhase.AcceptingConfidence) {
            revert InvalidTopicPhaseForConfidence(topicId, topicPhase[topicId]);
        }
        // Redundant check if phase transition is robust, but good for defense:
        OnitInfiniteOutcomeDPM.MarketConfig storage config = topicConfigs[
            topicId
        ];
        if (
            config.bettingCutoff != 0 && block.timestamp >= config.bettingCutoff
        ) {
            // This should ideally be caught by phase management (tryAdvanceTopicPhase)
            revert InvalidTopicPhaseForConfidence(topicId, topicPhase[topicId]);
        }

        // 4. Validate additionalStakeAmountABC and bucket/share data
        if (additionalStakeAmountABC == 0) {
            revert StakeAmountMustBePositive();
        }
        if (bucketIds.length != shares.length || bucketIds.length == 0) {
            revert InvalidBucketOrShareData();
        }

        // 5. Check available stake for this specific topic
        uint256 availableForThisTopic = getAvailableStakeForTopic(
            topicId,
            user
        );
        if (additionalStakeAmountABC > availableForThisTopic) {
            revert InsufficientAvailableStake(
                additionalStakeAmountABC,
                availableForThisTopic
            );
        }

        // 6. DPM Interaction - Calculate cost and verify against user's intended stake
        // CRITICAL: This interaction assumes OnitInfiniteOutcomeDPM is adapted.
        OnitInfiniteOutcomeDPM dpm = OnitInfiniteOutcomeDPM(
            payable(marketAddress)
        );
        (int256 costDiffFromDPM, ) = dpm.calculateCostOfTrade(
            bucketIds,
            shares
        );

        if (additionalStakeAmountABC != uint256(costDiffFromDPM)) {
            revert StakeAmountMismatchWithDPMCost();
        }

        // Hypothetical DPM call:
        // This call is essential for the DPM to record the user's shares and use `additionalStakeAmountABC`.
        // The DPM's `vote` function needs to be adapted to be callable by VotingV2 on behalf of `user`,
        // accept `additionalStakeAmountABC` (as ABC tokens), and attribute shares to `user`.
        // For example, a new function `voteForUser(address user, uint256 abcAmount, int256[] memory bucketIds, int256[] memory shares)`
        // might be needed in the DPM.
        // For now, we assume this interaction would succeed and VotingV2 transfers the ABC tokens to the DPM.
        // The DPM would then use this amount in its internal accounting.
        // votingToken.transferFrom(user, marketAddress, additionalStakeAmountABC); // Example transfer if DPM holds ABC
        // try dpm.voteForUser(user, additionalStakeAmountABC, bucketIds, shares) { }
        // catch {
        //    revert DPMInteractionFailed();
        // }
        //
        // Given the current DPM structure, it expects msg.value for ETH or direct token transfers for ERC20s.
        // The `vote` function in DPM is `onlyVotingContract` and uses `votingPower[msg.sender]`.
        // This `votingPower` would need to be set by VotingV2 for the DPM before calling `dpm.vote()`.
        // This requires significant DPM adaptation.
        // For now, we proceed with VotingV2 state changes, assuming DPM call would succeed.

        // 7. Update VotingV2 participation state
        TopicParticipation storage participation = userTopicParticipation[
            topicId
        ][user];
        if (participation.lastSubmissionTimestamp == 0) {
            // First submission for this topic by this user, add to their list
            bool found = false;
            for (uint i = 0; i < userParticipatedTopicIds[user].length; i++) {
                if (userParticipatedTopicIds[user][i] == topicId) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                userParticipatedTopicIds[user].push(topicId);
            }
        }
        participation.totalStakeAmountABC += additionalStakeAmountABC;
        participation.lastSubmissionTimestamp = SafeCast.toUint64(
            block.timestamp
        );

        // Emit event
        emit ConfidenceSubmitted(
            topicId,
            user,
            additionalStakeAmountABC,
            block.timestamp,
            participation.totalStakeAmountABC // Emit new total for this user on this topic
        );

        // CRITICAL: If the DPM interaction (which is currently commented out/hypothetical) were to fail,
        // any state changes specific to this function call (like updates to `userTopicParticipation`) would need to be reverted.
        // The `totalCommittedStake` is no longer managed this way.
    }

    /**
     * @notice Advances the phase of a topic, e.g., from AcceptingConfidence to AggregatingResults.
     * @dev This is a basic version. Conditions for phase transitions need to be robustly defined,
     *      especially for AggregatingResults -> Settled, which depends on DPM outcome finalization.
     *      This function is expected to be called externally, e.g., by a keeper.
     * @param topicId The ID of the topic to advance.
     */
    function tryAdvanceTopicPhase(bytes32 topicId) external {
        if (topicsMarketAddress[topicId] == address(0)) {
            revert TopicNotFound(topicId);
        }
        TopicPhase currentPhase = topicPhase[topicId];
        OnitInfiniteOutcomeDPM.MarketConfig storage config = topicConfigs[
            topicId
        ];
        address marketAddress = topicsMarketAddress[topicId]; // Get market address

        if (currentPhase == TopicPhase.AcceptingConfidence) {
            if (
                config.bettingCutoff != 0 &&
                block.timestamp >= config.bettingCutoff
            ) {
                topicPhase[topicId] = TopicPhase.AggregatingResults;
                emit TopicPhaseChanged(topicId, TopicPhase.AggregatingResults);

                // HYPOTHETICAL: Tell DPM to finalize its internal calculations if needed.
                // This depends on DPM design. It might auto-finalize or need a trigger.
                // Example:
                // try OnitInfiniteOutcomeDPM(payable(marketAddress)).startAggregation() {}
                // catch { /* Handle error if DPM fails to start aggregation */ }
            }
        } else if (currentPhase == TopicPhase.AggregatingResults) {
            // Condition for moving to Settled: DPM aggregation is complete.
            // HYPOTHETICAL: Check if DPM has finished its calculations.
            bool dpmAggregationComplete = false; // Default to false
            // Example:
            // try OnitInfiniteOutcomeDPM(payable(marketAddress)).isAggregationComplete() returns (bool complete) {
            //     dpmAggregationComplete = complete;
            // } catch { /* Handle error if DPM check fails */ }

            // For now, let's assume if it's in AggregatingResults, and some time has passed,
            // or a DPM flag is set, it can move to Settled.
            // This is a placeholder for a real condition.
            // For testing, one might allow an owner to push it to Settled, or use a DPM flag.
            // If DPM emits an event "AggregationCompleted", an off-chain keeper could call this.

            // For the purpose of this exercise, let's assume a DPM view function.
            // If `OnitInfiniteOutcomeDPM` has a `resolvedAtTimestamp` which is set when its internal
            // aggregation is done (similar to its current `resolveMarket`), we could check that.
            // The current DPM's `resolvedAtTimestamp` is set by `resolveMarket`.
            // We need an equivalent for confidence aggregation.
            // Let's assume a hypothetical `aggregationFinalizedTimestamp` on the DPM.
            uint256 dpmFinalizedTime = OnitInfiniteOutcomeDPM(payable(marketAddress)).resolvedAtTimestamp(); // Using existing field as placeholder

            if (dpmFinalizedTime > 0 && dpmFinalizedTime >= config.bettingCutoff) { // Ensure it was finalized after betting
                dpmAggregationComplete = true; // Placeholder logic
            }

            if (dpmAggregationComplete) {
                topicPhase[topicId] = TopicPhase.Settled;
                emit TopicPhaseChanged(topicId, TopicPhase.Settled);
            }
        }
        // Other phase transitions can be added as needed.
    }

    /****************************************
     *          STAKING FUNCTIONS           *
     * (Overrides and new logic for rewards/slashing) *
     ****************************************/

    /* @notice Updates the voter's trackers for staking and slashing. Applies all unapplied slashing to given staker.
     * @dev Can be called by anyone, but it is not necessary for the contract to function is run the other functions.
     * @param voter address of the voter to update the trackers for.
     */
    function updateTrackers(address voter) external {
        _updateTrackers(voter);
    }

    /**
     * @notice Updates the staker's trackers for staking and applies rewards/slashing from closed topics.
     * @dev This function is intended to be repurposed from its UMA DVM functionality.
     *      The internal logic will need to iterate through topics the user participated in
     *      that have closed, determine if their confidence submission was in-band or out-of-band,
     *      and then apply rewards or slashes from the Staker contract's perspective.
     * @param staker address of the staker to update the trackers for.
     */
    function _updateTrackers(address staker) internal override {
        // Process settled topics for rewards/slashes before updating Staker's core rewards.
        // Use a reasonable default for maxTraversals, e.g., 5 or 10.
        // This could also be a configurable value.
        _updateUserTopicResults(staker, 5); // Process up to 5 topics

        // For now, just call super to maintain Staker's core accounting (emissions).
        super._updateTrackers(staker);
    }

    /**
     * @notice Computes pending stakes. In this refactored system, UMA-style round-based pending stakes
     * are not used. This function provides a no-op implementation to satisfy the Staker contract's
     * virtual function requirement.
     * @param voter The address of the voter (unused).
     * @param amount The amount being staked (unused).
     */
    function _computePendingStakes(
        address voter,
        uint128 amount
    ) internal override {
        // Silence unused parameter warnings
        voter = voter;
        amount = amount;
        // No operation, as round-based pending stakes are not part of this system.
        // Staker._incrementPendingStake is not called.
    }

    /****************************************
     *        SETTLEMENT LOGIC              *
     ****************************************/

    /**
     * @dev Processes settled topics for a user, applying rewards or slashes.
     * @param staker The address of the user.
     * @param maxTraversals The maximum number of topics to process in this call.
     */
    function _updateUserTopicResults(
        address staker,
        uint64 maxTraversals
    ) internal {
        uint256 topicsProcessed = 0;
        bytes32[] storage participatedTopics = userParticipatedTopicIds[staker];

        // Iterate backwards or manage an index to avoid issues if elements are removed/reordered (not the case here).
        // For simplicity, iterating forwards. Consider a separate index for `nextTopicToProcessForUser` if many topics.
        for (uint i = 0; i < participatedTopics.length; i++) {
            if (topicsProcessed >= maxTraversals) {
                break;
            }

            bytes32 topicId = participatedTopics[i];
            TopicParticipation storage participation = userTopicParticipation[
                topicId
            ][staker];

            // Check if topic is settled and not yet claimed by this user for this topic
            if (
                topicPhase[topicId] == TopicPhase.Settled &&
                !participation.rewardClaimed
            ) {
                // --- 1. Get DPM Aggregated Results ---
                // This is HYPOTHETICAL. DPM needs to expose this.
                // Example: (int256 mean, int256 stdDev) =
                //     OnitInfiniteOutcomeDPM(payable(topicsMarketAddress[topicId])).getAggregatedOutcome();
                // For now, we'll use placeholder values.
                bool wasInBand; // Placeholder for actual calculation

                // --- 2. Calculate User's "Score" / In-Band Status ---
                // This logic is complex and depends on how the DPM stores user positions
                // and how "in-band" is defined.
                // wasInBand = _calculateUserInBandStatus(topicId, staker, mean, stdDev); // Hypothetical

                // Placeholder logic: Randomly decide for now for structure
                // In a real scenario, this would be a deterministic calculation.
                if (block.timestamp % 2 == 0) {
                    // Replace with actual logic
                    wasInBand = true;
                } else {
                    wasInBand = false;
                }

                // --- 3. Determine Reward/Slashing ---
                uint256 userStakeForTopic = participation.totalStakeAmountABC;
                VoterStake storage vs = voterStakes[staker]; // Staker's global stake struct

                if (wasInBand) {
                    // Placeholder: Reward is 10% of their stake on this topic.
                    // Real reward logic is complex (pro-rata of slashed amounts).
                    uint256 rewardAmount = (userStakeForTopic * 10) / 100;
                    vs.outstandingRewards += SafeCast.toUint128(rewardAmount);
                    emit UserTopicRewardApplied(topicId, staker, rewardAmount);
                } else {
                    // Placeholder: Slash is 5% of their stake on this topic.
                    uint256 slashAmount = (userStakeForTopic * 5) / 100;
                    if (slashAmount > 0) {
                        if (SafeCast.toUint128(slashAmount) > vs.stake) {
                            // Cannot slash more than they have globally.
                            // This implies their stake on this topic was a significant portion of a now-reduced global stake.
                            slashAmount = vs.stake;
                        }

                        if (slashAmount > 0) {
                            // Re-check after potential cap
                            vs.stake -= SafeCast.toUint128(slashAmount);
                            // Also update cumulativeStake in the Staker contract
                            cumulativeStake -= SafeCast.toUint128(slashAmount);
                            emit UserTopicSlashApplied(
                                topicId,
                                staker,
                                slashAmount
                            );
                        }
                    }
                }

                participation.rewardClaimed = true;
                topicsProcessed++;
            }
        }
    }

    // --- Placeholder for actual in-band calculation ---
    // function _calculateUserInBandStatus(
    //     bytes32 topicId,
    //     address user,
    //     int256 topicMean,
    //     int256 topicStdDev
    // ) internal view returns (bool) {
    //     // 1. Get user's effective submission/position from the DPM for this topic.
    //     //    This is a major missing piece as VotingV2 doesn't store this, DPM does.
    //     //    DPM needs to expose `getUserPosition(topicId, user) -> (user_mean_vote, user_confidence_metric)`
    //
    //     // 2. Compare user's position with topicMean +/- topicStdDev.
    //     // Example:
    //     // int256 userEffectiveScore = IDPM(topicsMarketAddress[topicId]).getUserEffectiveScore(user);
    //     // return (userEffectiveScore >= topicMean - topicStdDev && userEffectiveScore <= topicMean + topicStdDev);
    //     return false; // Placeholder
    // }

    /****************************************
     *            VIEW FUNCTIONS            *
     ****************************************/

    /**
     * @notice Returns the remaining amount of ABC a user can additionally stake on a specific topic
     *         before their total stake on that topic reaches their global stake limit.
     * @param topicId The ID of the topic.
     * @param user The address of the user.
     * @return uint256 The available ABC amount that can still be staked on this topic by the user.
     */
    function getAvailableStakeForTopic(
        bytes32 topicId,
        address user
    ) public view returns (uint256) {
        uint256 globalStake = _getAvailableStake(user); // User's total global stake
        uint256 currentStakeOnTopic = userTopicParticipation[topicId][user]
            .totalStakeAmountABC;

        if (globalStake <= currentStakeOnTopic) {
            return 0; // Already staked up to or beyond global limit for this topic
        }
        return globalStake - currentStakeOnTopic;
    }

    /****************************************
     *    PRIVATE AND INTERNAL FUNCTIONS    *
     ****************************************/

    /**
     * @notice Calculates the amount of stake a user has available for new commitments.
     * @param user The address of the user.
     * @return uint256 The amount of available stake.
     */
    function _getAvailableStake(address user) internal view returns (uint256) {
        // voterStakes[user].stake is the user's total global stake in the Staker contract
        uint256 globalStake = uint256(voterStakes[user].stake);
        return globalStake;
    }

    // Gas optimized uint64 increment.
    function unsafe_inc_64(uint64 x) internal pure returns (uint64) {
        unchecked {
            return x + 1;
        }
    }

    // Gas optimized uint64 decrement.
    function unsafe_dec_64(uint64 x) internal pure returns (uint64) {
        unchecked {
            return x - 1;
        }
    }
}
