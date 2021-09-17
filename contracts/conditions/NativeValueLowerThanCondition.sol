// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import '../interfaces/IYieldWolfCondition.sol';
import '../interfaces/IYieldWolf.sol';
import '../interfaces/IYieldWolfStrategy.sol';

/**
 * @title Native Value Lower Than Condition
 * @notice the condition triggers if the value of an user's share in a pool is lower than
 *         a given value in native currency (e.g. ETH)
 * @author YieldWolf
 */
contract NativeValueLowerThanCondition is IYieldWolfCondition {
    function check(
        address _yieldWolf,
        address _strategy,
        address _user,
        uint256 _pid,
        uint256[] calldata _intInputs,
        address[] calldata _addrInputs
    ) external view override returns (bool) {
        uint256 minNativeValue = _intInputs[0];
        IYieldWolfStrategy strategy = IYieldWolfStrategy(_strategy);
        uint256 stakedTokens = IYieldWolf(_yieldWolf).stakedTokens(_pid, _user);
        uint256 totalNativeValue = strategy.totalValueLockedNative();
        uint256 userNativeValue = (totalNativeValue * stakedTokens) / strategy.totalStakeTokens();
        return userNativeValue < minNativeValue;
    }
}
