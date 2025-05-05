// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "../../common/implementation/ExpandedERC20.sol";

/**
 * @title Ownership of this token allows a voter to respond to price requests.
 * @dev Supports snapshotting and allows the Oracle to mint new tokens as rewards.
 */
contract VotingToken is ExpandedERC20 {
    /**
     * @notice Constructs the VotingToken.
     */
    constructor() ExpandedERC20("UMA Voting Token v1", "UMA", 18) {}

    function decimals()
        public
        view
        virtual
        override(ExpandedERC20)
        returns (uint8)
    {
        return super.decimals();
    }

    // _transfer, _mint and _burn are ERC20 internal methods that are overridden by ERC20Snapshot,
    // therefore the compiler will complain that VotingToken must override these methods
    // because the two base classes (ERC20 and ERC20Snapshot) both define the same functions

    function _transfer(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20) {
        super._transfer(from, to, value);
    }

    function _mint(
        address account,
        uint256 value
    ) internal virtual override(ERC20) {
        super._mint(account, value);
    }

    function _burn(
        address account,
        uint256 value
    ) internal virtual override(ERC20) {
        super._burn(account, value);
    }
}
