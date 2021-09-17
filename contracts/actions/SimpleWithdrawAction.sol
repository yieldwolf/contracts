// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import '../interfaces/IYieldWolfAction.sol';

/**
 * @title Simple Withdraw Action
 * @notice withdraws the entire balance of an account
 * @author YieldWolf
 */
contract SimpleWithdrawAction is IYieldWolfAction {
    function execute(
        address _yieldWolf,
        address _strategy,
        address _user,
        uint256 _pid,
        uint256[] calldata _intInputs,
        address[] calldata _addrInputs
    ) external view override returns (uint256, address) {
        return (type(uint256).max, _user);
    }

    function callback(
        address yieldWolf,
        address strategy,
        address user,
        uint256 pid,
        uint256[] calldata intInputs,
        address[] calldata addrInputs
    ) external override {}
}
