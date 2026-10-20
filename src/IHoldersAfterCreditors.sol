// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

/// @title Agent Repay-First Payees: paying holders after creditors (optional part of the draft ERC)
/// @notice A token that implements ERC-7254 for its holders and is the beneficiary of an agent's repay-first payee, so
///         its holders share only what the agent's creditors left.
/// @dev The ERC-165 identifier is `type(IHoldersAfterCreditors).interfaceId`.
interface IHoldersAfterCreditors {
    event RevenueFromPayee(address indexed payee, address indexed asset, uint256 amount);

    /// @notice The agent's `IRepayFirstPayee`, whose beneficiary this token is meant to be. Never changes.
    function payee() external view returns (address);

    /// @notice Books as ERC-7254 rewards of `asset` the rise in this token's balance of `asset` that is not booked yet:
    ///         what the payee forwarded since the last sync. Anyone may call it. Returns the amount booked.
    function syncFromPayee(address asset) external returns (uint256 booked);
}
