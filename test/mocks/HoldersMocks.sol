// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {HoldersAfterCreditorsToken} from "../../src/HoldersAfterCreditorsToken.sol";

/// @notice The reference token deployed with no supply, plus a public mint, to test what a sync does at zero supply.
contract MintableHoldersToken is HoldersAfterCreditorsToken {
    constructor(address payee_, address[] memory rewardAssets)
        HoldersAfterCreditorsToken("Agent", "AGT", payee_, rewardAssets, address(0), 0)
    {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
