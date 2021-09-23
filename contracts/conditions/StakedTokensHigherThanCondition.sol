// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import '../interfaces/IYieldWolfCondition.sol';
import '../interfaces/IYieldWolf.sol';
import '../interfaces/IYieldWolfStrategy.sol';

/**
 * @title Staked Tokens Higher Than Condition
 * @notice the condition triggers if the amount of staked tokens is higher than a given amount
 * @author YieldWolf
 */
contract StakedTokensHigherThanCondition is IYieldWolfCondition {
    bool public override isCondition = true;

    function check(
        address _yieldWolf,
        address _strategy,
        address _user,
        uint256 _pid,
        uint256[] calldata _intInputs,
        address[] calldata _addrInputs
    ) external view override returns (bool) {
        uint256 maxStakedTokens = _intInputs[0];
        IYieldWolfStrategy strategy = IYieldWolfStrategy(_strategy);
        uint256 stakedTokens = IYieldWolf(_yieldWolf).stakedTokens(_pid, _user);
        return stakedTokens > maxStakedTokens;
    }
}
