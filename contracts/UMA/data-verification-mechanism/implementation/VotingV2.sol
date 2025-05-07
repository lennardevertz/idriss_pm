// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.16;

import {Ownable} from "solady/src/auth/Ownable.sol"; // Staker likely inherits Ownable
import {LibClone} from "solady/src/utils/LibClone.sol";

import "./Staker.sol"; // Assuming Staker.sol is in the same directory
import {OnitInfiniteOutcomeDPM, MarketConfig, MarketInitData} from "../../../OnitInfiniteOutcomeDPM.sol"; // Adjusted path

/**
 * @title VotingV2 contract - Refactored for Confidence-Based Prediction Market
 * @dev Handles staking ABC tokens and creating topics (Onit DPM markets).
 *      Manages user stakes, emissions, and will manage reward/slashing distribution
 *      based on confidence scores submitted to Onit DPM markets.
 */
contract VotingV2 is Staker {
    // TODO: Re-evaluate if UINT64_MAX is needed after full refactoring. Staker or new logic might use it.
    uint64 public constant UINT64_MAX = type(uint64).max;

    /****************************************
     *        MARKET/TOPIC STATE            *
     ****************************************/

    /// @notice Address of the OnitInfiniteOutcomeDPM implementation to be cloned for new topics.
    address public onitDPMImplementation;

    /// @notice Mapping from a topic ID (keccak256 of marketQuestion) to its DPM contract address.
    mapping(bytes32 => address) public topicsMarketAddress;

    /// @notice Mapping from a topic ID to its DPM market configuration.
    mapping(bytes32 => OnitInfiniteOutcomeDPM.MarketConfig) public topicConfigs;

    // TODO: Add state for tracking user submissions per topic, and topic states (Open, Closed, Resolved).
    // Example: mapping(bytes32 topicId => mapping(address user => UserSubmission)) public userSubmissions;
    // struct UserSubmission { uint256 score; uint256 stake; uint256 timestamp; bool claimed; }
    // enum TopicPhase { AcceptingSources, AcceptingConfidence, Aggregating, Settled }
    // mapping(bytes32 topicId => TopicPhase) public topicPhase;

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
    // TODO: Add events for SubmitConfidence, FinalizeTopic, ClaimRewards, ClaimSlashedRebate

    // UMA-specific VoterSlashApplied event is removed. New slashing/reward events will be needed.

    /****************************************
     *                ERRORS                *
     ****************************************/
    error OnitDPMImplementationNotSet();
    error FailedToDeployTopicMarket();
    error FailedToInitializeTopicMarket();
    error InsufficientCreatorStake();
    // TODO: Add other errors as needed for new logic (e.g., TopicNotFound, InvalidPhase, AlreadySubmitted)

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
     * @param initialLiquidityABC Total amount of ABC tokens the creator commits to this topic's initial state.
     * @param initialBucketIds Initial bucket IDs for seeding the market (DPM specific).
     * @param initialShares Corresponding initial shares for the bucket IDs (DPM specific).
     * @return marketAddress The address of the newly created Onit DPM market for the topic.
     */
    function createTopic(
        string memory marketQuestion,
        uint256 bettingCutoff,
        int256 outcomeUnit,
        string memory marketUri,
        uint256 initialLiquidityABC,
        int256[] memory initialBucketIds,
        int256[] memory initialShares
    ) external returns (address marketAddress) {
        if (onitDPMImplementation == address(0)) {
            revert OnitDPMImplementationNotSet();
        }

        address initiator = msg.sender;

        // TODO: Check if initiator has enough staked ABC tokens (`initialLiquidityABC`).
        if (initialLiquidityABC == 0) {
            revert InsufficientCreatorStake();
        }

        address[] memory dpmResolvers = new address[](1);
        dpmResolvers[0] = address(this);

        MarketConfig memory marketConfig = MarketConfig({
            marketCreatorFeeReceiver: address(0),
            marketCreatorCommissionBp: 0,
            bettingCutoff: bettingCutoff,
            withdrawlDelayPeriod: 0,
            outcomeUnit: outcomeUnit,
            marketQuestion: marketQuestion,
            marketUri: marketUri,
            resolvers: dpmResolvers
        });

        // CRITICAL: The DPM's initialize function calculates:
        // `initialBetValue = msg.value - initData.seededFunds;`
        // We are calling with `msg.value = 0`. This will be updated using some staked amount input from the market creator
        // so the initialization doesnt require msg.value.
        // We set `initData.seededFunds = 0`.
        // The OnitInfiniteOutcomeDPM contract needs modification to handle this.
        MarketInitData memory marketInitData = MarketInitData({
            onitFactory: address(this),
            initiator: initiator,
            seededFunds: 0, // DPM's ETH-based seededFunds.
            config: marketConfig,
            initialBucketIds: initialBucketIds,
            initialShares: initialShares
        });

        bytes memory encodedInitData = abi.encodeWithSelector(
            OnitInfiniteOutcomeDPM.initialize.selector,
            marketInitData
        );

        // Salt includes parameters that define the market's uniqueness.
        bytes32 salt = keccak256(
            abi.encode(
                address(this),
                initiator,
                marketConfig.bettingCutoff,
                marketConfig.marketQuestion,
                initialLiquidityABC // Creator's total ABC commitment
            )
        );

        address clonedMarketAddress = LibClone.cloneDeterministic(
            onitDPMImplementation,
            salt
        );

        // Call DPM initialize with value: 0.
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

        address checkOnitFactory = OnitInfiniteOutcomeDPM(
            payable(clonedMarketAddress)
        ).onitFactory();
        if (checkOnitFactory != address(this)) {
            revert FailedToInitializeTopicMarket();
        }

        marketAddress = clonedMarketAddress;
        // topicId should be unique based on defining parameters.
        bytes32 topicId = keccak256(
            abi.encodePacked(marketQuestion, initialLiquidityABC)
        );

        topicsMarketAddress[topicId] = marketAddress;
        topicConfigs[topicId] = marketConfig;

        OnitInfiniteOutcomeDPM(payable(marketAddress)).initializeVotinContract(
            address(this)
        );

        // TODO: Formally "lock" or account for `initialLiquidityABC` from `initiator`'s balance.

        emit TopicCreated(
            topicId,
            marketAddress,
            initiator,
            marketQuestion,
            marketConfig
        );

        return marketAddress;
    }

    /**
     * @notice Predicts the address where a topic's market will be deployed.
     * @param initiator The address that will initiate the topic creation.
     * @param marketQuestion The unique question or identifier for the topic.
     * @param marketBettingCutoff Timestamp when betting for the topic will close.
     * @param initialLiquidityABC Total amount of ABC tokens the creator commits.
     * @return address The predicted address of the Onit DPM market.
     */
    function predictTopicMarketAddress(
        address initiator,
        string memory marketQuestion,
        uint256 marketBettingCutoff,
        uint256 initialLiquidityABC // Added for consistency with createTopic salt
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

    // TODO: Add `submitConfidence(bytes32 topicId, uint256 score, uint256 stakeAmount)` function.
    // This function will:
    // 1. Check topic validity and phase.
    // 2. Interact with Staker logic to use/lock part of the user's stake.
    // 3. Call the DPM's `vote` (or equivalent `buyShares`) function.
    //    - This requires this contract (VotingV2) to be authorized as the `votinContractAddress` on the DPM.
    //    - The `costDiff` (value for `vote`) would be `stakeAmount`.
    // 4. Record submission details (score, stake, timestamp).

    // TODO: Add `finalizeTopic(bytes32 topicId)` function.
    // This function will be callable after topic's bettingCutoff.
    // 1. It should trigger aggregation logic on the DPM (if DPM needs explicit trigger) or read results.
    // 2. Store/mark the topic as resolved with final mean, std dev, etc.

    // TODO: Add `claimRewards(bytes32 topicId, address user)` or similar.
    // This function will:
    // 1. Check if topic is settled and user hasn't claimed.
    // 2. Calculate user's reward or slash based on their submission and final topic outcome.
    // 3. Transfer ABC tokens (rewards or return of unslashed stake).

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
        // 1. Iterate through topics `staker` participated in that are now resolved/settled.
        // 2. For each such topic, fetch the outcome (mean, std_dev) from the DPM.
        // 3. Fetch the staker's submission (score, stake amount at time of submission).
        // 4. Determine if in-band or out-of-band.
        // 5. Calculate rewards or slashes based on the new system's rules (e.g., fixed % slash, pro-rata rewards).
        // 6. This might involve calling a repurposed `_updateAccountTopicRewardsAndSlashes`.

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
        // - Identify topics the staker participated in which are now closed/settled and not yet processed for this staker.
        // - For each topic (up to maxTraversals):
        //   - Get topic result (mean, std_dev from DPM or stored in this contract).
        //   - Get staker's submission for that topic.
        //   - Calculate if in-band/out-of-band.
        //   - Calculate reward/slashing amount.
        //   - Update staker's claimable rewards or apply slashes using Staker's accounting functions.
        //   - Mark topic as processed for this staker to avoid double counting.
        // This will likely interact with Staker's internal accounting for rewards/slashes,
        // similar to how `_applySlashToVoter` worked but with the new rules.
    }

    // Note: _getStartingIndexForStaker() override from UMA VotingV2 is removed as it's UMA DVM specific.
    // The Staker contract itself might have a virtual _getStartingIndexForStaker,
    // if not, no override is needed or a new mechanism for tracking processed items will be used.
    // Staker.sol provides a default `return 0;` which is acceptable.

    // Note: _inActiveReveal() override from UMA VotingV2 is removed.
    // Staker.sol provides a default `return false;` which is suitable for this system.

    // Note: _applySlashToVoter and isNextRequestRoundDifferent are UMA DVM specific and removed.
    // New functions for applying rewards/slashes specific to this system will be part of Staker or this contract.

    /****************************************
     *    PRIVATE AND INTERNAL FUNCTIONS    *
     ****************************************/

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

    // Fallback and receive functions are inherited from Staker or its parents if defined there.
    // If not, consider if they are needed. The original VotingV2 did not have them.
}
