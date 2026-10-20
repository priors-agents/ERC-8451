// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {IRepayFirstCreditor} from "../../src/IRepayFirstPayee.sol";

/// @notice An ERC-721-shaped identity registry reduced to what the tests need.
contract MockRegistry {
    mapping(uint256 => address) private _owners;

    function mint(address to, uint256 id) external {
        _owners[id] = to;
    }

    function transfer(uint256 id, address to) external {
        require(_owners[id] == msg.sender, "not owner");
        _owners[id] = to;
    }

    function burn(uint256 id) external {
        require(_owners[id] == msg.sender, "not owner");
        delete _owners[id];
    }

    function ownerOf(uint256 id) external view returns (address o) {
        o = _owners[id];
        require(o != address(0), "no token");
    }
}

/// @notice A plain ERC-20 with a public mint.
contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice A creditor that is owed a set amount per agent and pulls what it is given, up to that amount.
contract MockCreditor is IRepayFirstCreditor {
    mapping(uint256 => uint256) public owed;
    uint256 public takeBps = 10_000; // how much of what it is given it actually takes

    function setOwed(uint256 agentId, uint256 amount) external {
        owed[agentId] = amount;
    }

    function setTakeBps(uint256 bps) external {
        takeBps = bps;
    }

    function amountOwed(uint256 agentId, address) external view returns (uint256) {
        return owed[agentId];
    }

    function hasClaim(uint256 agentId) external view returns (bool) {
        return owed[agentId] > 0;
    }

    function collect(uint256 agentId, address token, uint256 amount) external returns (uint256 applied) {
        applied = amount * takeBps / 10_000;
        if (applied > owed[agentId]) applied = owed[agentId];
        owed[agentId] -= applied;
        require(MockToken(token).transferFrom(msg.sender, address(this), applied), "pull failed");
    }
}

/// @notice A creditor whose every call reverts.
contract RevertingCreditor is IRepayFirstCreditor {
    function amountOwed(uint256, address) external pure returns (uint256) {
        revert("down");
    }

    function hasClaim(uint256) external pure returns (bool) {
        revert("down");
    }

    function collect(uint256, address, uint256) external pure returns (uint256) {
        revert("down");
    }
}

/// @notice A creditor that claims a large debt and tries to pull more than it was approved for.
contract GreedyCreditor is IRepayFirstCreditor {
    function amountOwed(uint256, address) external pure returns (uint256) {
        return type(uint128).max;
    }

    function hasClaim(uint256) external pure returns (bool) {
        return true;
    }

    function collect(uint256, address token, uint256 amount) external returns (uint256) {
        require(MockToken(token).transferFrom(msg.sender, address(this), amount + 1), "pull failed");
        return amount + 1;
    }
}

/// @notice A creditor that burns all the gas it is given.
contract GasBurningCreditor is IRepayFirstCreditor {
    function amountOwed(uint256, address) external pure returns (uint256) {
        return 1e6;
    }

    function hasClaim(uint256) external pure returns (bool) {
        return true;
    }

    function collect(uint256, address, uint256) external pure returns (uint256) {
        while (true) {}
        return 0;
    }
}
