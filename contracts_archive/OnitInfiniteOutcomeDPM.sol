// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {convert, convert, div, mul} from "prb-math/SD59x18.sol";
import {ERC1155} from "solady/tokens/ERC1155.sol";

import {LibString} from "./utils/LibString.sol";

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
    OnitMarketResolver,
    ERC1155
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
     * TraderStake is the amount they have put into the market, and the NFT they were minted in return
     * Traders can:
     * - Sell their position and leave the market (which makes sense if the traders position is worth more than their
     * stake)
     * - Redeem their position when the market closes
     * - Reclaim their stake if the market is void
     * - Lose their stake if their prediction generates no return
     */
    struct TraderStake {
        uint256 totalStake;
        uint256 nftId;
    }

    // Total amount the trader has bet across all predictions and their NFT
    mapping(address trader => TraderStake stake) public tradersStake;

    /// Each predictor get 1 NFT per market, this variable tracks what tokenId that should be
    uint256 public nextNftTokenId;
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
    /// ERC1155 token uri
    string private _uri = "https://onit.fun/";

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
        // Set ERC1155 token uri
        _uri = initData.config.marketUri;
        // Set time limit for betting
        bettingCutoff = initData.config.bettingCutoff;
        // Set market creator
        marketCreatorFeeReceiver = initData.config.marketCreatorFeeReceiver;
        // Set market creator commission rate
        marketCreatorCommissionBp = initData.config.marketCreatorCommissionBp;

        // Mint the trader a prediction NFT
        _mint(initData.initiator, nextNftTokenId, 1, "");
        // Update the traders stake
        tradersStake[initData.initiator] = TraderStake({
            totalStake: initialBetValue,
            nftId: nextNftTokenId
        });

        // Update the prediction count for the next trader
        nextNftTokenId++;

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

    /**
     * @notice Set the URI for the market ERC1155 token
     *
     * @param newUri The new URI
     */
    function setUri(string memory newUri) external onlyOnitFactoryOwner {
        _uri = newUri;

        emit URI(newUri, 0);
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
        if (msg.value != uint256(costDiff))
            revert IncorrectBetValue(costDiff, msg.value);

        // Track the latest totalQSquared so we don't need to recalculate it
        totalQSquared = newTotalQSquared;
        // Update the markets outcome token holdings
        _updateHoldings(msg.sender, bucketIds, shares);

        // If the trader does not already have a stake, create one and mint them an NFT
        if (tradersStake[msg.sender].totalStake == 0) {
            _mint(msg.sender, nextNftTokenId, 1, "");
            tradersStake[msg.sender].nftId = nextNftTokenId++;
        }
        // Update the traders total stake
        tradersStake[msg.sender].totalStake += msg.value;

        emit BoughtShares(msg.sender, costDiff, newTotalQSquared);
    }

    /**
     * @notice Sell a set of shares
     *
     * @dev Burn the trader's outcome tokens in the buckets they want to sell in exchange for their market value
     * This corresponds to the difference in the cost function between where the market is, and where it will be after
     * they burn their shares
     * NOTE:
     * - This forfeits the trader's stake, so they should be sure they are selling for a profit
     *
     * @param bucketIds The bucket IDs for the trader's prediction
     * @param shares The shares for the trader's prediction
     */
    function sellShares(
        int256[] memory bucketIds,
        int256[] memory shares
    ) external {
        if (tradersStake[msg.sender].totalStake == 0) revert NothingToPay();
        if (resolvedAtTimestamp != 0) revert MarketIsResolved();
        if (marketVoided) revert MarketIsVoided();

        /**
         * We only allow negative share changes, so if any shares are positive, revert
         * This is because we don't want to allow traders to increase their position using this function
         * The function is not payable and we don't check they have provided enough funds to cover the cost of the
         * increase
         * TODO: move this to the calculateCostOfTrade function to avoid extra loop
         */
        for (uint256 i; i < shares.length; i++) {
            if (shares[i] > 0) revert InvalidSharesValue();
        }

        (int256 costDiff, int256 newTotalQSquared) = calculateCostOfTrade(
            bucketIds,
            shares
        );

        // If the cost difference is positive, revert
        // Otherwise this would mean they need to pay to sell their position
        if (costDiff > 0) revert NothingToPay();

        _updateHoldings(msg.sender, bucketIds, shares);

        // Set new market values
        totalQSquared = newTotalQSquared;

        // Trader sells position, so we burn their NFT and set their stake to 0
        tradersStake[msg.sender].totalStake = 0;
        tradersStake[msg.sender].nftId = 0;
        _burn(msg.sender, tradersStake[msg.sender].nftId, 1);

        // Transfer the trader's payout
        // We use -costDiff as the payout is the difference in cost between the trader's prediction and the existing
        // cost. We know this is negative as we checked for that above, so negating it will give a positive value which
        // corrosponds to how much the market should pay the trader
        (bool success, ) = msg.sender.call{value: uint256(-costDiff)}("");
        if (!success) revert TransferFailed();

        emit SoldShares(msg.sender, costDiff, newTotalQSquared);
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

        // Burn the trader's NFT and remove it from stake
        _burn(trader, tradersStake[trader].nftId, 1);
        tradersStake[trader].nftId = 0;

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

    // ----------------------------------------------------------------
    // ERC1155 functions
    // ----------------------------------------------------------------

    function uri(
        uint256 id
    ) public view virtual override returns (string memory) {
        return LibString.concat(_uri, LibString.toString(id));
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
