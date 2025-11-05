// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOnitFactory} from "../interfaces/IOnitFactory.sol";

/**
 * @title Onit Market Resolver
 *
 * @author Onit Labs (https://github.com/onit-labs)
 *
 * @notice Contract storing resolution logic and admin addresses
 */
// TODO
// - consider reputation and staking
contract OnitMarketResolver {
    // ----------------------------------------------------------------
    // Errors
    // ----------------------------------------------------------------

    /// Initialisation Errors
    error OnitFactoryNotSet();
    error ResolversNotSet();
    /// Admin Errors
    error OnlyOnitFactoryOwner();
    error OnlyResolver();
    /// Market State Errors
    error DisputePeriodPassed();
    error MarketIsOpen();
    error MarketIsResolved();
    error MarketIsVoided();

    // ----------------------------------------------------------------
    // Events
    // ----------------------------------------------------------------

    /// Market Resolution Events
    event MarketResolved(
        int256 actualOutcome,
        int256 totalSharesAtOutcome,
        uint256 totalPayout
    );
    event MarketResolutionUpdated(int256 newResolution);
    event MarketVoided(uint256 timestamp);

    // ----------------------------------------------------------------
    // State
    // ----------------------------------------------------------------

    /// Address of the Onit factory where Onit owner address is stored
    address public onitFactory;

    /**
     * Withdrawal delay period after market is resolved
     * This serves multiple functions:
     * - Sets a dispute period within which the resolved outcome can be contested and changed
     * - Prevents traders from withdrawing their funds until the dispute period has passed
     * - Prevents the market creator from withdrawing funds before traders have had a chance to collect payouts
     *
     * @dev Measured in seconds (eg. 2 days = 172800)
     */
    uint256 public withdrawlDelayPeriod;

    /// Timestamp when the market is resolved
    uint256 public resolvedAtTimestamp;
    /// Final correct value resolved by the market owner
    int256 public resolvedOutcome;
    // The bucket ID the resolved outcome falls into (see OnitInfiniteOutcomeDPMOutcomeDomain for details about buckets)
    int256 public resolvedBucketId;
    /// Flag that market is voided, allowing for traders to collect their funds
    bool public marketVoided;

    /// Array of addresses who can resolve the market
    address[] private resolvers;

    // ----------------------------------------------------------------
    // Initialization
    // ----------------------------------------------------------------

    function _initializeOnitMarketResolver(
        uint256 initWithdrawlDelayPeriod,
        address initOnitFactory,
        address[] memory initResolvers
    ) internal {
        if (initOnitFactory == address(0)) revert OnitFactoryNotSet();
        if (initResolvers.length == 0 || initResolvers[0] == address(0))
            revert ResolversNotSet();

        withdrawlDelayPeriod = initWithdrawlDelayPeriod;

        onitFactory = initOnitFactory;

        resolvers = initResolvers;
    }

    // ----------------------------------------------------------------
    // Modifiers
    // ----------------------------------------------------------------

    modifier onlyOnitFactoryOwner() {
        if (msg.sender != onitFactoryOwner()) revert OnlyOnitFactoryOwner();
        _;
    }

    modifier onlyResolver() {
        if (!isResolver(msg.sender)) revert OnlyResolver();
        _;
    }

    // ----------------------------------------------------------------
    // OnitFactoryOwner functions
    // ----------------------------------------------------------------

    /**
     * @notice Void the market, allowing traders to collect their funds
     */
    function voidMarket() external onlyOnitFactoryOwner {
        marketVoided = true;

        emit MarketVoided(block.timestamp);
    }

    // ----------------------------------------------------------------
    // Getters
    // ----------------------------------------------------------------

    function getResolvers() external view returns (address[] memory) {
        return resolvers;
    }

    function isResolver(address _resolver) public view returns (bool) {
        /**
         * This is less efficient than a resolvers mapping, but:
         * - resolvers should never be a long array
         * - This function is rarely called
         * - Having the full resolvers address array in storage is good for other clients
         */
        for (uint256 i; i < resolvers.length; i++) {
            if (resolvers[i] == _resolver) return true;
        }
        return false;
    }

    function onitFactoryOwner() public view returns (address) {
        return IOnitFactory(onitFactory).owner();
    }

    // ----------------------------------------------------------------
    // Internal functions
    // ----------------------------------------------------------------

    function _setResolvedOutcome(
        int256 _resolvedOutcome,
        int256 _resolvedBucketId
    ) internal {
        if (resolvedAtTimestamp != 0) revert MarketIsResolved();
        if (marketVoided) revert MarketIsVoided();

        resolvedAtTimestamp = block.timestamp;
        resolvedOutcome = _resolvedOutcome;
        resolvedBucketId = _resolvedBucketId;
    }

    function _updateResolvedOutcome(
        int256 _resolvedOutcome,
        int256 _resolvedBucketId
    ) internal {
        if (resolvedAtTimestamp == 0) revert MarketIsOpen();
        if (block.timestamp > resolvedAtTimestamp + withdrawlDelayPeriod)
            revert DisputePeriodPassed();
        if (marketVoided) revert MarketIsVoided();

        resolvedOutcome = _resolvedOutcome;
        resolvedBucketId = _resolvedBucketId;

        emit MarketResolutionUpdated(_resolvedOutcome);
    }
}
