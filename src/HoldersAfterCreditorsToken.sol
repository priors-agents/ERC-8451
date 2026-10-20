// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {IHoldersAfterCreditors} from "./IHoldersAfterCreditors.sol";
import {IERC165} from "./RepayFirstPayee.sol";

/// @notice The holder side of ERC-7254 (Token Revenue Sharing), on top of ERC-20. Its specification names
///         `getReward(address[])`; its reference interface names `getReward(address[], address)`. Both are here.
interface IERC7254 {
    struct UserInformation {
        uint256 inReward;
        uint256 outReward;
        uint256 withdraw;
    }

    event UpdateReward(address indexed contributor, uint256 value);
    event GetReward(address indexed owner, address indexed to, uint256 value);
    event Add(address token);

    function maxTokenReward() external view returns (uint256);
    function informationOf(address token, address account) external view returns (UserInformation memory);
    function informationOfBatch(address account) external view returns (UserInformation[] memory);
    function tokenReward() external view returns (address[] memory);
    function updateReward(address[] memory token, uint256[] memory amount) external;
    function viewReward(address account) external view returns (uint256[] memory);
    function getReward(address[] memory token) external;
    function getReward(address[] memory token, address to) external;
    function getRewardPerShare(address token) external view returns (uint256);
    function existsTokenReward(address token) external view returns (bool);
}

interface IERC20Asset {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title HoldersAfterCreditorsToken
/// @notice Reference token for the optional "paying holders after creditors" part of the Agent Repay-First Payees
///         draft. An ERC-20 whose holders share, through ERC-7254, what the agent's payee forwards to it as its
///         beneficiary, which is what the agent's creditors left. A sweep is a plain transfer, so what arrives is booked
///         by `syncFromPayee`. Its reward assets are fixed when it is deployed.
/// @dev Not audited. A reference for the interface.
contract HoldersAfterCreditorsToken is IERC7254, IHoldersAfterCreditors, IERC165 {
    /// @notice ERC-7254's scale for reward per share and for the figures in `UserInformation`.
    uint256 public constant MAX = 2 ** 128;
    uint256 private constant MAX_TOKEN_REWARD = 8;

    string public name;
    string public symbol;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address private immutable _payee;
    address[] private _tokenReward;
    mapping(address => bool) private _isTokenReward;
    mapping(address => uint256) private _rewardPerShare;
    mapping(address => mapping(address => UserInformation)) private _info; // reward asset => account
    /// @dev Per reward asset: what has been booked (by a sync or `updateReward`) and not yet paid out. Any balance above
    ///      it has arrived without being booked.
    mapping(address => uint256) private _held;
    bool private _locked;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error NotARewardAsset();
    error BadRewardAssets();
    error LengthMismatch();
    error ZeroAddress();
    error Reentrant();
    error TransferFailed();

    modifier lock() {
        if (_locked) revert Reentrant();
        _locked = true;
        _;
        _locked = false;
    }

    /// @param payee_ The agent's `IRepayFirstPayee`. Its owner points the payee's beneficiary at this token.
    /// @param rewardAssets The assets holders are paid in, at most `maxTokenReward()`.
    /// @param holder Receives `supply`, the whole supply.
    constructor(
        string memory name_,
        string memory symbol_,
        address payee_,
        address[] memory rewardAssets,
        address holder,
        uint256 supply
    ) {
        if (rewardAssets.length == 0 || rewardAssets.length > MAX_TOKEN_REWARD) {
            revert BadRewardAssets();
        }
        name = name_;
        symbol = symbol_;
        _payee = payee_;
        for (uint256 i; i < rewardAssets.length; ++i) {
            address r = rewardAssets[i];
            if (r == address(0) || r == address(this) || _isTokenReward[r]) revert BadRewardAssets();
            _tokenReward.push(r);
            _isTokenReward[r] = true;
            emit Add(r);
        }
        if (supply > 0) _mint(holder, supply);
    }

    // ---------------------------------------------------------------- ERC-20

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }

    // ---------------------------------------------------------------- IHoldersAfterCreditors

    function payee() external view returns (address) {
        return _payee;
    }

    /// @dev Books the balance above `_held`, so each unit is booked once, whether a sweep or any other plain transfer
    ///      brought it. It does not ask whether the token is still the payee's beneficiary: what arrived while it was
    ///      is still owed to the holders.
    function syncFromPayee(address asset) external lock returns (uint256 booked) {
        if (!_isTokenReward[asset]) revert NotARewardAsset();
        uint256 supply = totalSupply;
        if (supply == 0) return 0; // no holders: the balance stays unbooked until there are some
        uint256 balance = IERC20Asset(asset).balanceOf(address(this));
        uint256 held = _held[asset];
        if (balance <= held) return 0;
        booked = balance - held;
        _held[asset] = balance;
        _rewardPerShare[asset] += booked * MAX / supply;
        emit RevenueFromPayee(_payee, asset, booked);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IHoldersAfterCreditors).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    // ---------------------------------------------------------------- ERC-7254

    function maxTokenReward() external pure returns (uint256) {
        return MAX_TOKEN_REWARD;
    }

    function informationOf(address token, address account) external view returns (UserInformation memory) {
        return _info[token][account];
    }

    function informationOfBatch(address account) external view returns (UserInformation[] memory infos) {
        uint256 n = _tokenReward.length;
        infos = new UserInformation[](n);
        for (uint256 i; i < n; ++i) {
            infos[i] = _info[_tokenReward[i]][account];
        }
    }

    function tokenReward() external view returns (address[] memory) {
        return _tokenReward;
    }

    function getRewardPerShare(address token) external view returns (uint256) {
        return _rewardPerShare[token];
    }

    function existsTokenReward(address token) external view returns (bool) {
        return _isTokenReward[token];
    }

    function viewReward(address account) external view returns (uint256[] memory rewards) {
        uint256 n = _tokenReward.length;
        rewards = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            rewards[i] = _accrued(_tokenReward[i], account) / MAX;
        }
    }

    /// @dev As in ERC-7254's reference: anyone may add rewards, pulled from the caller, for registered assets only, and
    ///      nothing is pulled while the supply is zero. What is booked is the measured rise in balance. Never marked as
    ///      revenue from the payee.
    function updateReward(address[] memory token, uint256[] memory amount) external lock {
        if (token.length != amount.length) revert LengthMismatch();
        uint256 supply = totalSupply;
        if (supply == 0) return;
        for (uint256 i; i < token.length; ++i) {
            IERC20Asset r = IERC20Asset(token[i]);
            if (!_isTokenReward[address(r)]) revert NotARewardAsset();
            uint256 before = r.balanceOf(address(this));
            if (!r.transferFrom(msg.sender, address(this), amount[i])) revert TransferFailed();
            uint256 received = r.balanceOf(address(this)) - before;
            _held[address(r)] += received;
            _rewardPerShare[address(r)] += received * MAX / supply;
            emit UpdateReward(msg.sender, received);
        }
    }

    function getReward(address[] memory token) external lock {
        _getReward(token, msg.sender);
    }

    function getReward(address[] memory token, address to) external lock {
        _getReward(token, to);
    }

    // ---------------------------------------------------------------- internals

    /// @dev Counts as withdrawn only what is paid, so the remainder below one unit stays with the holder and is paid
    ///      once it adds up. ERC-7254's reference counts the whole accrued figure as withdrawn and loses the remainder.
    function _getReward(address[] memory token, address to) private {
        for (uint256 i; i < token.length; ++i) {
            address r = token[i];
            uint256 paid = _accrued(r, msg.sender) / MAX;
            if (paid > 0) {
                _info[r][msg.sender].withdraw += paid * MAX;
                _held[r] -= paid;
                if (!IERC20Asset(r).transfer(to, paid)) revert TransferFailed();
            }
            emit GetReward(msg.sender, to, paid);
        }
    }

    function _accrued(address r, address account) private view returns (uint256) {
        UserInformation storage u = _info[r][account];
        return balanceOf[account] * _rewardPerShare[r] + u.inReward - u.withdraw - u.outReward;
    }

    function _mint(address to, uint256 amount) internal {
        _move(address(0), to, amount);
    }

    /// @dev A transfer, or a mint when `from` is the zero address. ERC-7254's rule: tokens that leave keep what they
    ///      accrued with the sender; tokens that arrive earn only rewards booked afterwards.
    function _move(address from, address to, uint256 amount) private {
        if (to == address(0)) revert ZeroAddress();
        uint256 n = _tokenReward.length;
        for (uint256 i; i < n; ++i) {
            address r = _tokenReward[i];
            uint256 scaled = amount * _rewardPerShare[r];
            if (from != address(0)) _info[r][from].inReward += scaled;
            _info[r][to].outReward += scaled;
        }
        if (from == address(0)) {
            totalSupply += amount;
        } else {
            balanceOf[from] -= amount;
        }
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
