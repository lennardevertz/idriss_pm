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

    // User's submission for a specific topic
    struct UserSubmission {
        uint96 score; // e.g., 0-100 for percentage, or 0-10000 for basis points
        uint96 stakeAmount; // Amount of ABC staked for this submission
        uint64 timestamp;
        bool claimedRewards; // Has the user claimed rewards/slashes for this topic?
    }

    // Mapping: topicId -> userAddress -> UserSubmission
    mapping(bytes32 => mapping(address => UserSubmission))
        public userSubmissions;

    // Mapping: userAddress -> total ABC stake committed across all active topics (for confidence or DPM seeding)
    mapping(address => uint256) public totalCommittedStake;

    // Mapping: topicId -> total ABC stake committed by all users for confidence on this topic
    mapping(bytes32 => uint256) public totalConfidenceStakePerTopic;

    // Phases for a topic
    enum TopicPhase {
        Created, // Initial state, DPM might be uninitialized or pre-betting window
        AcceptingConfidence, // Betting window is open for confidence submissions
        AggregatingResults, // Betting cutoff passed, results being calculated/finalized
        Settled // Results finalized, rewards/slashes can be claimed
    }

    // Mapping: topicId -> current phase of the topic
    mapping(bytes32 => TopicPhase) public topicPhase;

    // Minimum stake amount for a confidence submission (in ABC token's smallest unit, e.g., wei)
    uint256 public minConfidenceStakeAmount;
    // Maximum score value (e.g., 100 for percentage, 10000 for basis points)
    uint256 public maxScoreValue;

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
        uint256 score,
        uint256 stakeAmount,
        uint256 timestamp
    );
    event TopicPhaseChanged(bytes32 indexed topicId, TopicPhase newPhase);
    event MinConfidenceStakeSet(uint256 newMinStake);
    event MaxScoreValueSet(uint256 newMaxScore);

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
    error StakeAmountTooSmall(uint256 actual, uint256 minimum);
    error AlreadySubmittedConfidence(bytes32 topicId, address user);
    error InvalidScore(uint256 score, uint256 maxScore);
    error MaxScoreValueNotSet();

    /**
     * @notice Construct the VotingV2 contract.
     * @param _emissionRate amount of voting tokens (ABC) that are emitted per second, split prorata between stakers.
     * @param _unstakeCoolDown time that a staker must wait to unstake after requesting to unstake.
     * @param _votingToken address of the ABC token contract used for staking.
     * @param _minConfidenceStake Minimum stake amount for a confidence submission.
     * @param _maxScore Maximum value for a confidence score (e.g., 100 or 10000).
     */
    constructor(
        uint128 _emissionRate,
        uint64 _unstakeCoolDown,
        address _votingToken,
        uint256 _minConfidenceStake,
        uint256 _maxScore
    ) Staker(_emissionRate, _unstakeCoolDown, _votingToken) {
        minConfidenceStakeAmount = _minConfidenceStake;
        require(_maxScore > 0, "Max score must be > 0");
        maxScoreValue = _maxScore;
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

    /**
     * @notice Sets the minimum stake amount required for a confidence submission.
     * @param _minStake The new minimum stake amount (in ABC token's smallest unit).
     */
    function setMinConfidenceStake(uint256 _minStake) external onlyOwner {
        minConfidenceStakeAmount = _minStake;
        emit MinConfidenceStakeSet(_minStake);
    }

    /**
     * @notice Sets the maximum value for a confidence score.
     * @param _maxScore The new maximum score value (e.g., 100 for percentage).
     */
    function setMaxScoreValue(uint256 _maxScore) external onlyOwner {
        require(_maxScore > 0, "Max score must be > 0");
        maxScoreValue = _maxScore;
        emit MaxScoreValueSet(_maxScore);
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

        // Commit initialLiquidityABC from creator's stake if provided
        if (initialLiquidityABC > 0) {
            uint256 availableStakeForCreator = _getAvailableStake(initiator);
            if (initialLiquidityABC > availableStakeForCreator) {
                revert InsufficientAvailableStake(
                    initialLiquidityABC,
                    availableStakeForCreator
                );
            }
            // This stake is for DPM initialization. It's committed from the user's global Staker balance.
            totalCommittedStake[initiator] += initialLiquidityABC;
        } else {
            // If initialLiquidityABC is 0, and initialShares are non-zero, DPM might not initialize correctly
            // if its cost calculation expects a non-zero initial bet value. This depends on DPM modifications.
            // For now, allow 0, but this is a critical point for DPM integration.
            if (initialShares.length > 0) {
                bool nonZeroShares = false;
                for (uint i = 0; i < initialShares.length; i++) {
                    if (initialShares[i] != 0) {
                        nonZeroShares = true;
                        break;
                    }
                }
                if (nonZeroShares) {
                    // This is a placeholder for a potential revert or warning.
                    // DPM might require initialLiquidityABC > 0 if initialShares are non-zero.
                    revert InsufficientCreatorStake(); // Or a more specific error
                }
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
     * @param score The confidence score (e.g., 0-100 or 0-10000).
     * @param stakeAmount The amount of ABC tokens to stake with this confidence score.
     */
    function submitConfidence(
        bytes32 topicId,
        uint256 score,
        uint256 stakeAmount
    ) external nonReentrant {
        address user = msg.sender;

        // 1. Check topic existence and phase
        if (topicsMarketAddress[topicId] == address(0)) {
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

        // 2. Check if user already submitted
        if (userSubmissions[topicId][user].timestamp != 0) {
            revert AlreadySubmittedConfidence(topicId, user);
        }

        // 3. Validate score
        if (maxScoreValue == 0) {
            // Should be set in constructor or by admin
            revert MaxScoreValueNotSet();
        }
        if (score > maxScoreValue) {
            revert InvalidScore(score, maxScoreValue);
        }

        // 4. Validate stakeAmount, check if we should allow restaking -> revoting with additional stake
        if (stakeAmount == 0 && minConfidenceStakeAmount > 0) {
            // If min is 0, stake of 0 might be allowed if desired
            revert StakeAmountTooSmall(stakeAmount, minConfidenceStakeAmount);
        }
        if (stakeAmount < minConfidenceStakeAmount) {
            revert StakeAmountTooSmall(stakeAmount, minConfidenceStakeAmount);
        }

        // 5. Check available stake
        uint256 availableStake = _getAvailableStake(user);
        if (stakeAmount > availableStake) {
            revert InsufficientAvailableStake(stakeAmount, availableStake);
        }

        // 6. Update VotingV2 state, check if score is needed at all, generally check types
        userSubmissions[topicId][user] = UserSubmission({
            score: SafeCast.toUint96(score),
            stakeAmount: SafeCast.toUint96(stakeAmount),
            timestamp: SafeCast.toUint64(block.timestamp),
            claimedRewards: false
        });

        totalCommittedStake[user] += stakeAmount;
        totalConfidenceStakePerTopic[topicId] += stakeAmount;

        // 7. Emit event
        emit ConfidenceSubmitted(
            topicId,
            user,
            score,
            stakeAmount,
            block.timestamp
        );

        // 8. Interact with the DPM (Conceptual - requires DPM changes)
        //    The DPM needs to be adapted to:
        //    a) Accept votes from VotingV2 on behalf of `user`.
        //    b) Use `stakeAmount` (ABC tokens) as the "cost" or "value" of the vote.
        //    c) Internally calculate shares based on this cost for the given score/bucket(s).
        //    d) Track these shares and the stake amount per `user` (not per VotingV2).
        //
        // Example of a *hypothetical* DPM function call:
        // OnitInfiniteOutcomeDPM dpm = OnitInfiniteOutcomeDPM(payable(topicsMarketAddress[topicId]));
        // int256 bucketIdForScore = dpm.getBucketId(int256(score)); // DPM needs getBucketId or similar helper accessible
        // dpm.voteWithABC(user, bucketIdForScore, stakeAmount);
        //
        // Or, if VotingV2 calculates shares (more complex):
        // int256[] memory bucketIds = ...; // derive from score
        // int256[] memory shares = ...;    // calculate from stakeAmount (cost) using DPM math
        // dpm.submitVoteForUser(user, bucketIds, shares, stakeAmount); // New DPM function
        //
        // This interaction is deferred until DPM is adapted. VotingV2 now records the submission,
        // which is the basis for later reward/slashing calculations using DPM's final aggregated outcome.
    }

    /**
     * @notice Advances the phase of a topic, e.g., from AcceptingConfidence to AggregatingResults.
     * @dev This is a basic version. Conditions for phase transitions need to be robustly defined,
     *      especially for AggregatingResults -> Settled, which depends on DPM outcome finalization.
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

        if (currentPhase == TopicPhase.AcceptingConfidence) {
            if (
                config.bettingCutoff != 0 &&
                block.timestamp >= config.bettingCutoff
            ) {
                topicPhase[topicId] = TopicPhase.AggregatingResults;
                emit TopicPhaseChanged(topicId, TopicPhase.AggregatingResults);
                // TODO: Trigger aggregation on DPM if needed.
                // This might involve calling a function on the DPM to resolve/finalize its state
                // based on all submitted (conceptual) shares. The DPM's `resolveMarket`
                // currently expects a single `_resolvedOutcome`. For confidence aggregation,
                // the DPM would need to calculate mean/std.dev from its own state.
            }
        } else if (currentPhase == TopicPhase.AggregatingResults) {
            // TODO: Define condition for moving to Settled.
            // This typically means the DPM has finalized its calculations (mean, std_dev)
            // and these results are available for VotingV2 to use for rewards/slashing.
            // Example:
            // bool dpmResultsAreFinal = OnitInfiniteOutcomeDPM(payable(topicsMarketAddress[topicId])).isAggregationComplete(); // Hypothetical
            // if (dpmResultsAreFinal) {
            //     topicPhase[topicId] = TopicPhase.Settled;
            //     emit TopicPhaseChanged(topicId, TopicPhase.Settled);
            // }
        }
        // Other phase transitions can be added as needed.
    }

    /****************************************
     *          STAKING FUNCTIONS           *
     * (Overrides and new logic for rewards/slashing) *
     ****************************************/

    /**
     * @notice Updates the staker's trackers for staking and applies rewards/slashing from closed topics.
     * @dev This function is intended to be repurposed from its UMA DVM functionality.
     *      The internal logic will need to iterate through topics the user participated in
     *      that have closed, determine if their confidence submission was in-band or out-of-band,
     *      and then apply rewards or slashes from the Staker contract's perspective.
     * @param staker address of the staker to update the trackers for.
     */
    function _updateTrackers(address staker) internal override {
        // TODO: Implement new tracker logic:
        // 1. Iterate through topics `staker` participated in that are now in `Settled` phase.
        // 2. For each such topic, fetch the outcome (mean, std_dev) from the DPM or this contract.
        // 3. Fetch the staker's submission (score, stake amount) from `userSubmissions`.
        // 4. Determine if in-band or out-of-band.
        // 5. Calculate rewards or slashes based on the new system's rules.
        // 6. Update Staker's accounting (e.g., `voterStake.outstandingRewards` or apply slashes).
        // 7. Mark submission as `claimedRewards = true` in `userSubmissions`.

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

    /**
     * @notice Updates a staker's rewards/slashes based on their participation in closed topics.
     * @dev This function is intended to be repurposed from UMA's `_updateAccountSlashingTrackers`.
     *      It will process a batch of closed topics for a given staker.
     * @param staker address of the staker.
     * @param maxTraversals maximum number of topics to process in this call (for gas management).
     */
    function _updateAccountRewardsAndSlashes(
        address staker,
        uint64 maxTraversals
    ) internal {
        // Silence unused variable warnings until implemented
        staker = staker;
        maxTraversals = maxTraversals;
        // TODO: Implement logic to iterate through relevant topics for the staker.
        // - Identify topics the staker participated in which are `Settled` and not yet `claimedRewards`.
        // - For each topic (up to maxTraversals):
        //   - Get topic result (mean, std_dev from DPM or stored in this contract).
        //   - Get staker's submission for that topic from `userSubmissions`.
        //   - Calculate if in-band/out-of-band.
        //   - Calculate reward/slashing amount.
        //   - Update staker's claimable rewards or apply slashes using Staker's accounting functions.
        //   - Mark `userSubmissions[topicId][staker].claimedRewards = true`.
    }

    /****************************************
     *    PRIVATE AND INTERNAL FUNCTIONS    *
     ****************************************/

    /**
     * @notice Calculates the amount of stake a user has available for new commitments.
     * @param user The address of the user.
     * @return uint256 The amount of available stake.
     */
    //todo: rework this, as it does not reflect the wanted functionality: Users can vote with their full stake on multiple markets, they dont "use up" their voting power.
    function _getAvailableStake(address user) internal view returns (uint256) {
        // voterStakes[user].stake is the user's total global stake in the Staker contract
        uint256 globalStake = uint256(voterStakes[user].stake);
        uint256 committedStake = totalCommittedStake[user];

        if (globalStake < committedStake) {
            // This case should ideally not happen if logic is correct elsewhere (e.g. no over-commitment).
            // It implies committed stake (tracked by VotingV2) exceeds global stake (tracked by Staker).
            // But it can happen if the user is getting slashed on one market with same commitedStake as on another market that is still running.
            // This is assumed to be fine, as the slashing amount will be calculated based on the submitted balance and worst case runs the user's stake to 0.
            return 0;
        }
        return globalStake - committedStake;
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
