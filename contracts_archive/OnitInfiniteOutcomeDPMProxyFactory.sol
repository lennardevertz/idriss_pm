// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OnitInfiniteOutcomeDPM} from "./OnitInfiniteOutcomeDPM.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/**
 * @title Onit Infinite Outcome Dynamic Parimutual Market Proxy Factory
 *
 * @author Onit Labs (https://github.com/onit-labs)
 *
 * @notice A factory contract for deploying OnitInfiniteOutcomeDPM markets.
 *
 * @dev This contract is used to deploy OnitInfiniteOutcomeDPM markets. It uses Solady's LibClone to clone the
 * implementation to save deployment gas.
 */
contract OnitInfiniteOutcomeDPMProxyFactory is Ownable {
    /// @notice Address of the implementation contract that will be cloned
    address public implementation;

    error FailedToDeployMarket();
    error FailedToInitializeMarket();

    event ImplementationSet(address marketImplementation);
    event MarketCreated(OnitInfiniteOutcomeDPM market);

    /**
     * @notice Set the implementation address of the OnitInfiniteOutcomeDPM contract to deploy
     *
     * @param onitFactoryOwner The address of the Onit factory owner
     * @param marketImplementation The address of the OnitInfiniteOutcomeDPM implementation which new markets will proxy
     * to.
     */
    constructor(
        address onitFactoryOwner,
        address marketImplementation
    ) payable Ownable() {
        _initializeOwner(onitFactoryOwner);
        implementation = marketImplementation;

        emit ImplementationSet(marketImplementation);
    }

    // ----------------------------------------------------------------
    // Owner functions
    // ----------------------------------------------------------------

    function setImplementation(
        address marketImplementation
    ) external onlyOwner {
        implementation = marketImplementation;

        emit ImplementationSet(marketImplementation);
    }

    // ----------------------------------------------------------------
    // Public functions
    // ----------------------------------------------------------------

    /**
     * @notice Create a new OnitInfiniteOutcomeDPM market
     *
     * @param marketConfig The configuration for the market
     * @param initiator The address of the market creator
     * @param initialBucketIds The initial bucket ids for the market
     * @param initialShares The initial shares for the market
     *
     * @return market The address of the newly created market
     */
    function createMarket(
        address initiator,
        uint256 seededFunds,
        OnitInfiniteOutcomeDPM.MarketConfig memory marketConfig,
        int256[] memory initialBucketIds,
        int256[] memory initialShares
    ) external payable returns (OnitInfiniteOutcomeDPM market) {
        // Create initialization data for the proxy
        bytes memory encodedInitData = abi.encodeWithSelector(
            OnitInfiniteOutcomeDPM.initialize.selector,
            OnitInfiniteOutcomeDPM.MarketInitData({
                onitFactory: address(this),
                initiator: initiator,
                seededFunds: seededFunds,
                config: marketConfig,
                initialBucketIds: initialBucketIds,
                initialShares: initialShares
            })
        );

        // Create salt based on the market parameters
        bytes32 salt = keccak256(
            abi.encode(
                address(this),
                initiator,
                marketConfig.bettingCutoff,
                marketConfig.marketQuestion
            )
        );

        // Deploy proxy using LibClone
        address marketAddress = LibClone.cloneDeterministic(
            implementation,
            salt
        );
        market = OnitInfiniteOutcomeDPM(payable(marketAddress));

        // Initialize the proxy
        (bool success, bytes memory returnData) = marketAddress.call{
            value: msg.value
        }(encodedInitData);
        if (!success) {
            // If there's return data it's one of the initialization revert messages, forward the revert message
            if (returnData.length > 0) {
                assembly {
                    let returnDataSize := mload(returnData)
                    revert(add(32, returnData), returnDataSize)
                }
            }
            revert FailedToDeployMarket();
        }

        // Verify initialization was successful
        address checkOnitFactory = market.onitFactory();
        if (checkOnitFactory != address(this))
            revert FailedToInitializeMarket();

        emit MarketCreated(market);
    }

    /// @notice Predicts the address where a market will be deployed
    function predictMarketAddress(
        address initiator,
        uint256 marketBettingCutoff,
        string memory marketQuestion
    ) external view returns (address) {
        bytes32 salt = keccak256(
            abi.encode(
                address(this),
                initiator,
                marketBettingCutoff,
                marketQuestion
            )
        );

        return
            LibClone.predictDeterministicAddress(
                implementation,
                salt,
                address(this)
            );
    }
}
