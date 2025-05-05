// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {convert, convert, div, mul} from "@prb/math/src/SD59x18.sol";

import {OnitInfiniteOutcomeDPMMechanism} from "./mechanisms/infinite-outcome-DPM/OnitInfiniteOutcomeDPMMechanism.sol";
import {OnitMarketResolver} from "./resolvers/OnitMarketResolver.sol";

import "./UMA/common/implementation/Lockable.sol";
import "./UMA/common/implementation/MultiCaller.sol";
import "./UMA/data-verification-mechanism/implementation/Staker.sol";

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
    OnitMarketResolver,
    Staker
{
    // ----------------------------------------------------------------
    // Errors
    // ----------------------------------------------------------------

    /// Configuration Errors
    error AlreadyInitialized();
    error BettingCutoffOutOfBounds();
    error MarketCreatorCommissionBpOutOfBounds();
    /// Trading Errors
    error BettingCutoffPassed();
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
        address indexed predictor,
        int256 costDiff,
        int256 newTotalQSquared
    );
    event SoldShares(
        address indexed predictor,
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

    /// @notice Amount of ABC‐stake each address has committed to this market
    mapping(address => uint256) public committedStake;

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

    /// The name of the market
    string public name = "Onit Prediction Market";
    /// The symbol of the market
    string public symbol = "ONIT";
    /// The question traders are predicting
    string public marketQuestion;

    /// Protocol commission rate in basis points of 10000 (400 = 4%)
    uint256 public constant PROTOCOL_COMMISSION_BP = 400;
    /// Maximum market creator commission rate (4%)
    uint256 public constant MAX_MARKET_CREATOR_COMMISSION_BP = 400;
    /// The minimum bet size
    uint256 public constant MIN_BET_SIZE = 0.0001 ether;
    /// The maximum bet size
    uint256 public constant MAX_BET_SIZE = 1 ether;
    /// The version of the market
    string public constant VERSION = "0.0.2";

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
    constructor(
        address _abcToken,
        uint128 _emissionRate,
        _unstakeCollDown
    ) Staker(_emissionRate, _unstakeCollDown, _abcToken) {
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
        uint256 initialBetValue = msg.value - initData.seededFunds;

        // Prevents the implementation from being initialized
        if (marketVoided) revert AlreadyInitialized();
        if (initialBetValue < MIN_BET_SIZE || initialBetValue > MAX_BET_SIZE)
            revert BetValueOutOfBounds();
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

        // Initialize Infinite Outcome DPM
        _initializeInfiniteOutcomeDPM(
            initData.initiator,
            initData.config.outcomeUnit,
            int256(initialBetValue),
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

        // Update the traders stake
        tradersStake[initData.initiator] = TraderStake({
            totalStake: initialBetValue
        });

        emit MarketInitialized(initData.initiator, msg.value);
    }

    // ----------------------------------------------------------------
    // Admin functions
    // ----------------------------------------------------------------

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
     * @notice Buy shares in the market for a given outcomes
     *
     * @dev Trader specifies the outcome outcome tokens they want exposure to, and if they provided a sufficent value we
     * mint them
     *
     * @param bucketIds The bucket IDs for the trader's prediction
     * @param shares The shares for the trader's prediction
     */
    function buyShares(
        int256[] memory bucketIds,
        int256[] memory shares
    ) external payable {
        if (bettingCutoff != 0 && block.timestamp > bettingCutoff)
            revert BettingCutoffPassed();
        if (resolvedAtTimestamp != 0) revert MarketIsResolved();
        if (marketVoided) revert MarketIsVoided();
        //  remove msg.value dependency?
        if (msg.value < MIN_BET_SIZE || msg.value > MAX_BET_SIZE)
            revert BetValueOutOfBounds();

        // Calculate shares for each bucket
        (int256 costDiff, int256 newTotalQSquared) = calculateCostOfTrade(
            bucketIds,
            shares
        );

        /**
         * If the trader has not sent the exact amount to cover the cost of the bet, revert.
         * costDiff may be negative, but we know the msg.value is positive and that casting a negative number to
         * uint256 would result in a number larger than they would ever need to send, so the casting is safe for this
         * check
         */
        //   Add check if staked amount is bigger (equal to) the costDiff?
        require(costDiff > 0, "Cost must be positive");
        uint256 voteAmt = uint256(costDiff);
        uint256 freeStake = voterStakes[msg.sender].stake -
            committedStake[msg.sender];
        require(voteAmt <= freeStake, "Insufficient stake power");
        ommittedStake[msg.sender] += voteAmt;

        // Track the latest totalQSquared so we don't need to recalculate it
        totalQSquared = newTotalQSquared;
        // Update the markets outcome token holdings
        _updateHoldings(msg.sender, bucketIds, shares);

        // Update the traders total stake
        tradersStake[msg.sender].totalStake += voteAmt;

        emit BoughtShares(msg.sender, costDiff, newTotalQSquared);
    }

    function collectPayout(address trader) external {
        if (resolvedAtTimestamp == 0) revert MarketIsOpen();
        if (block.timestamp < resolvedAtTimestamp + withdrawlDelayPeriod)
            revert WithdrawalDelayPeriodNotPassed();
        if (marketVoided) revert MarketIsVoided();

        // Calculate payout
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
     * @return payout The payout amount
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
}
