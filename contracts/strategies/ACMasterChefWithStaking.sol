// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

import './AutoCompoundStrategy.sol';

interface IFarm {
    function enterStaking(uint256 _amount) external;

    function leaveStaking(uint256 _amount) external;

    function userInfo(uint256 _pid, address _user) external view returns (uint256, uint256);

    function emergencyWithdraw(uint256 _pid) external;
}

/**
 * @title AutoCompound MasterChef with staking
 * @notice strategy for auto-compounding on pools using a MasterChef which users staking methods
 * @dev e.g. used by CAKE and BANANA pools on PancakeSwap and ApeSwap respectively
 * @author YieldWolf
 */
contract ACMasterChefWithStaking is AutoCompoundStrategy {
    using SafeERC20 for IERC20;

    function _farmDeposit(uint256 amount) internal override {
        IERC20(stakeToken).safeIncreaseAllowance(masterChef, amount);
        IFarm(masterChef).enterStaking(amount);
    }

    function _farmWithdraw(uint256 amount) internal override {
        IFarm(masterChef).leaveStaking(amount);
    }

    function _totalStaked() internal view override returns (uint256 amount) {
        (amount, ) = IFarm(masterChef).userInfo(pid, address(this));
    }

    function _farmEmergencyWithdraw() internal override {
        IFarm(masterChef).emergencyWithdraw(pid);
    }
}
