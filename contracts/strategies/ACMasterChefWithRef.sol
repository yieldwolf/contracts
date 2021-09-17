// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

import './AutoCompoundStrategy.sol';

interface IFarm {
    function deposit(
        uint256 _pid,
        uint256 _amount,
        address _referrer
    ) external;

    function withdraw(uint256 _pid, uint256 _amount) external;

    function userInfo(uint256 _pid, address _user) external view returns (uint256, uint256);

    function emergencyWithdraw(uint256 _pid) external;
}

/**
 * @title AutoCompound MasterChef with Referrals
 * @notice strategy for auto-compounding on pools using a MasterChef which requires a referrer on deposits and withdraws
 * @author YieldWolf
 */
contract ACMasterChefWithRef is AutoCompoundStrategy {
    using SafeERC20 for IERC20;
    address public referrer;

    function _farmDeposit(uint256 amount) internal override {
        IERC20(stakeToken).safeIncreaseAllowance(masterChef, amount);
        IFarm(masterChef).deposit(pid, amount, referrer);
    }

    function _farmWithdraw(uint256 amount) internal override {
        IFarm(masterChef).withdraw(pid, amount);
    }

    function _farmEmergencyWithdraw() internal override {
        IFarm(masterChef).emergencyWithdraw(pid);
    }

    function _totalStaked() internal view override returns (uint256 amount) {
        (amount, ) = IFarm(masterChef).userInfo(pid, address(this));
    }

    function setReferrer(address _referrer) external onlyOperator {
        referrer = _referrer;
    }
}
