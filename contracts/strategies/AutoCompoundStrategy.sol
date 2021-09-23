// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/security/Pausable.sol';
import '@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol';
import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol';
import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol';

import '../interfaces/IWETH.sol';
import '../interfaces/IYieldWolf.sol';

/**
 * @title Auto Compound Strategy
 * @notice handles deposits and withdraws on the underlying farm and auto-compound rewards
 * @author YieldWolf
 */
abstract contract AutoCompoundStrategy is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    IYieldWolf public yieldWolf; // address of the YieldWolf staking contract
    address public masterChef; // address of the farm staking contract
    uint256 public pid; // pid of pool in the farm staking contract
    IERC20 public stakeToken; // token staked on the underlying farm
    IERC20 public token0; // first token of the lp (or 0 if it's a single token)
    IERC20 public token1; // second token of the lp (or 0 if it's a single token)
    IERC20 public earnToken; // reward token paid by the underlying farm
    address[] public extraEarnTokens; // some underlying farms can give rewards in multiple tokens
    IUniswapV2Router02 public swapRouter; // router used for swapping tokens
    IUniswapV2Router02 public liquidityRouter; // router used for adding liquidity to the LP token
    address public WNATIVE; // address of the network's native currency (e.g. ETH)
    bool public swapRouterEnabled = true; // if true it will use swap router for token swaps, otherwise liquidity router

    mapping(address => mapping(address => address[])) public swapPath; // paths for swapping 2 given tokens

    uint256 public sharesTotal = 0;
    bool public initialized;
    bool public emergencyWithdrawn;

    event Initialize();
    event Farm();
    event Pause();
    event Unpause();
    event EmergencyWithdraw();
    event TokenToEarn(address token);
    event WrapNative();

    modifier onlyOperator() {
        require(IYieldWolf(yieldWolf).operators(msg.sender), 'onlyOperator: NOT_ALLOWED');
        _;
    }

    function _farmDeposit(uint256 depositAmount) internal virtual;

    function _farmWithdraw(uint256 withdrawAmount) internal virtual;

    function _farmEmergencyWithdraw() internal virtual;

    function _totalStaked() internal view virtual returns (uint256);

    receive() external payable {}

    /**
     * @notice initializes the strategy
     * @dev similar to constructor but makes it easier for inheritance and for creating strategies from contracts
     * @param _pid the id of the pool in the farm's staking contract
     * @param _isLpToken whether the given stake token is a lp or a single token
     * @param _addresses list of addresses
     * @param _earnToToken0Path swap path from earn token to token0
     * @param _earnToToken1Path swap path from earn token to token1
     * @param _token0ToEarnPath swap path from token0 to earn token
     * @param _token1ToEarnPath swap path from token1 to earn token
     */
    function initialize(
        uint256 _pid,
        bool _isLpToken,
        address[7] calldata _addresses,
        address[] calldata _earnToToken0Path,
        address[] calldata _earnToToken1Path,
        address[] calldata _token0ToEarnPath,
        address[] calldata _token1ToEarnPath
    ) external onlyOwner {
        require(!initialized, 'initialize: ALREADY_INITIALIZED');
        initialized = true;
        yieldWolf = IYieldWolf(_addresses[0]);
        stakeToken = IERC20(_addresses[1]);
        earnToken = IERC20(_addresses[2]);
        masterChef = _addresses[3];
        swapRouter = IUniswapV2Router02(_addresses[4]);
        liquidityRouter = IUniswapV2Router02(_addresses[5]);
        WNATIVE = _addresses[6];
        if (_isLpToken) {
            token0 = IERC20(IUniswapV2Pair(_addresses[1]).token0());
            token1 = IERC20(IUniswapV2Pair(_addresses[1]).token1());
            swapPath[address(earnToken)][address(token0)] = _earnToToken0Path;
            swapPath[address(earnToken)][address(token1)] = _earnToToken1Path;
            swapPath[address(token0)][address(earnToken)] = _token0ToEarnPath;
            swapPath[address(token1)][address(earnToken)] = _token1ToEarnPath;
        } else {
            swapPath[address(earnToken)][address(stakeToken)] = _earnToToken0Path;
            swapPath[address(stakeToken)][address(earnToken)] = _token0ToEarnPath;
        }
        pid = _pid;
        emit Initialize();
    }

    /**
     * @notice deposits stake tokens in the underlying farm
     * @dev can only be called by YieldWolf contract which performs the required validations and logging
     * @param _depositAmount amount deposited by the user
     */
    function deposit(uint256 _depositAmount) external virtual onlyOwner nonReentrant whenNotPaused returns (uint256) {
        uint256 depositFee = (_depositAmount * yieldWolf.depositFee()) / 10000;
        _depositAmount = _depositAmount - depositFee;
        if (depositFee > 0) {
            stakeToken.safeTransfer(yieldWolf.feeAddress(), depositFee);
        }

        uint256 totalStakedBefore = totalStakeTokens() - _depositAmount;
        _farm();
        uint256 totalStakedAfter = totalStakeTokens();

        // adjust for deposit fees on the underlying farm and token transfer fees
        _depositAmount = totalStakedAfter - totalStakedBefore;

        uint256 sharesAdded = _depositAmount;
        if (totalStakedBefore > 0 && sharesTotal > 0) {
            sharesAdded = (_depositAmount * sharesTotal) / totalStakedBefore;
        }
        sharesTotal = sharesTotal + sharesAdded;

        return sharesAdded;
    }

    /**
     * @notice unstake tokens from the underlying farm and transfers them to the given address
     * @dev can only be called by YieldWolf contract which performs the required validations and logging
     * @param _withdrawAmount maximum amount to withdraw
     * @param _withdrawTo address that will receive the stake tokens
     * @param _bountyHunter address of the bounty hunter who execute the rule or the zero address if it's not a rule execution
     * @param _ruleFeeAmount how much to pay in concept of rule execution fees
     */
    function withdraw(
        uint256 _withdrawAmount,
        address _withdrawTo,
        address _bountyHunter,
        uint256 _ruleFeeAmount
    ) external virtual onlyOwner nonReentrant returns (uint256) {
        uint256 totalStakedOnFarm = _totalStaked();
        uint256 totalStake = totalStakeTokens();

        // number of shares that the withdraw amount represents (rounded up)
        uint256 sharesRemoved = (_withdrawAmount * sharesTotal - 1) / totalStake + 1;

        if (sharesRemoved > sharesTotal) {
            sharesRemoved = sharesTotal;
        }
        sharesTotal = sharesTotal - sharesRemoved;

        if (totalStakedOnFarm > 0) {
            _farmWithdraw(_withdrawAmount);
        }

        uint256 stakeBalance = stakeToken.balanceOf(address(this));
        if (_withdrawAmount > stakeBalance) {
            _withdrawAmount = stakeBalance;
        }

        if (totalStake < _withdrawAmount) {
            _withdrawAmount = totalStake;
        }

        // apply rule execution fees
        if (_bountyHunter != address(0)) {
            uint256 bountyRuleFee = (_ruleFeeAmount * yieldWolf.ruleFeeBountyPct()) / 10000;
            uint256 platformRuleFee = _ruleFeeAmount - bountyRuleFee;
            if (bountyRuleFee > 0) {
                stakeToken.safeTransfer(_bountyHunter, bountyRuleFee);
            }
            if (platformRuleFee > 0) {
                stakeToken.safeTransfer(yieldWolf.feeAddress(), platformRuleFee);
            }
            _withdrawAmount -= _ruleFeeAmount;
        }

        // apply withdraw fees
        uint256 withdrawFee = (_withdrawAmount * yieldWolf.withdrawFee()) / 10000;
        if (withdrawFee > 0) {
            _withdrawAmount -= withdrawFee;
            stakeToken.safeTransfer(yieldWolf.feeAddress(), withdrawFee);
        }

        stakeToken.safeTransfer(_withdrawTo, _withdrawAmount);

        return sharesRemoved;
    }

    /**
     * @notice deposits the contract's balance of stake tokens in the underlying farm
     */
    function farm() external virtual nonReentrant {
        _farm();
        emit Farm();
    }

    /**
     * @notice harvests earn tokens and deposits stake tokens in the underlying farm
     * @dev can only be called by YieldWolf contract which performs the required validations and logging
     *      if the contract is paused, this function becomes a no-op
     * @param _bountyHunter address that will get paid the bounty reward
     */
    function earn(address _bountyHunter) external virtual onlyOwner returns (uint256 bountyReward) {
        if (paused()) {
            return 0;
        }

        // harvest earn tokens
        uint256 earnAmountBefore = earnToken.balanceOf(address(this));
        _farmHarvest();

        if (address(earnToken) == WNATIVE) {
            wrapNative();
        }

        for (uint256 i; i < extraEarnTokens.length; i++) {
            tokenToEarn(extraEarnTokens[i]);
        }

        uint256 harvestAmount = earnToken.balanceOf(address(this)) - earnAmountBefore;

        if (harvestAmount > 0) {
            bountyReward = _distributeFees(harvestAmount, _bountyHunter);
        }
        uint256 earnAmount = earnToken.balanceOf(address(this));

        // if no token0, then stake token is a single token: Swap earn token for stake token
        if (address(token0) == address(0)) {
            if (stakeToken != earnToken) {
                _safeSwap(earnAmount, swapPath[address(earnToken)][address(stakeToken)], address(this), false);
            }
            _farm();
            return bountyReward;
        }

        // stake token is a LP token: Swap earn token for token0 and token1 and add liquidity
        if (earnToken != token0) {
            _safeSwap(earnAmount / 2, swapPath[address(earnToken)][address(token0)], address(this), false);
        }
        if (earnToken != token1) {
            _safeSwap(earnAmount / 2, swapPath[address(earnToken)][address(token1)], address(this), false);
        }
        uint256 token0Amt = token0.balanceOf(address(this));
        uint256 token1Amt = token1.balanceOf(address(this));
        if (token0Amt > 0 && token1Amt > 0) {
            token0.safeIncreaseAllowance(address(liquidityRouter), token0Amt);
            token1.safeIncreaseAllowance(address(liquidityRouter), token1Amt);
            liquidityRouter.addLiquidity(
                address(token0),
                address(token1),
                token0Amt,
                token1Amt,
                0,
                0,
                address(this),
                block.timestamp
            );
        }

        _farm();
        return bountyReward;
    }

    /**
     * @notice pauses the strategy in case of emergency
     * @dev can only be called by the operator. Only in case of emergency.
     */
    function pause() external virtual onlyOperator {
        _pause();
        emit Pause();
    }

    /**
     * @notice unpauses the strategy
     * @dev can only be called by the operator
     */
    function unpause() external virtual onlyOperator {
        require(!emergencyWithdrawn, 'unpause: CANNOT_UNPAUSE_AFTER_EMERGENCY_WITHDRAW');
        _unpause();
        emit Unpause();
    }

    /**
     * @notice enables or disables the swap router used for swapping earn tokens to stake tokens
     * @dev can only be called by YieldWolf contract which already performs the required validations and logging
     */
    function setSwapRouterEnabled(bool _enabled) external virtual onlyOwner {
        swapRouterEnabled = _enabled;
    }

    /**
     * @notice updates the swap path for a given pair
     * @dev can only be called by YieldWolf contract which already performs the required validations and logging
     */
    function setSwapPath(
        address _token0,
        address _token1,
        address[] calldata _path
    ) external virtual onlyOwner {
        swapPath[_token0][_token1] = _path;
    }

    /**
     * @notice updates the list of extra earn tokens
     * @dev can only be called by YieldWolf contract which already performs the required validations and logging
     */
    function setExtraEarnTokens(address[] calldata _extraEarnTokens) external virtual onlyOwner {
        extraEarnTokens = _extraEarnTokens;
    }

    /**
     * @notice converts any token in the contract into earn tokens
     * @dev it uses the predefined path if it exists or defaults to use WNATIVE
     */
    function tokenToEarn(address _token) public virtual whenNotPaused {
        uint256 amount = IERC20(_token).balanceOf(address(this));
        if (amount > 0 && _token != address(earnToken) && _token != address(stakeToken)) {
            address[] memory path = swapPath[_token][address(earnToken)];
            if (path.length == 0) {
                if (_token == WNATIVE) {
                    path = new address[](2);
                    path[0] = _token;
                    path[1] = address(earnToken);
                } else {
                    path = new address[](3);
                    path[0] = _token;
                    path[1] = WNATIVE;
                    path[2] = address(earnToken);
                }
            }
            _safeSwap(amount, path, address(this), true);
            emit TokenToEarn(_token);
        }
    }

    /**
     * @notice converts NATIVE into WNATIVE (e.g. ETH -> WETH)
     */
    function wrapNative() public virtual {
        uint256 balance = address(this).balance;
        if (balance > 0) {
            IWETH(WNATIVE).deposit{value: balance}();
        }
        emit WrapNative();
    }

    function totalStakeTokens() public view virtual returns (uint256) {
        return _totalStaked() + stakeToken.balanceOf(address(this));
    }

    /**
     * @notice invokes the emergency withdraw function in the underlying farm
     * @dev can only be called by the operator. Only in case of emergency.
     */
    function emergencyWithdraw() external virtual onlyOperator {
        if (!paused()) {
            _pause();
        }
        _farmEmergencyWithdraw();
        emergencyWithdrawn = true;
        emit EmergencyWithdraw();
    }

    function _farm() internal virtual {
        uint256 depositAmount = stakeToken.balanceOf(address(this));
        _farmDeposit(depositAmount);
    }

    function _farmHarvest() internal virtual {
        _farmDeposit(0);
    }

    function _distributeFees(uint256 _amount, address _bountyHunter) internal virtual returns (uint256) {
        uint256 bountyReward = 0;
        uint256 bountyRewardPct = _bountyHunter == address(0) ? 0 : yieldWolf.performanceFeeBountyPct();
        uint256 performanceFee = (_amount * yieldWolf.performanceFee()) / 10000;
        bountyReward = (performanceFee * bountyRewardPct) / 10000;
        uint256 platformPerformanceFee = performanceFee - bountyReward;
        if (platformPerformanceFee > 0) {
            earnToken.safeTransfer(yieldWolf.feeAddress(), platformPerformanceFee);
        }
        if (bountyReward > 0) {
            earnToken.safeTransfer(_bountyHunter, bountyReward);
        }
        return bountyReward;
    }

    function _safeSwap(
        uint256 _amountIn,
        address[] memory _path,
        address _to,
        bool _ignoreErrors
    ) internal virtual {
        IUniswapV2Router02 router = swapRouterEnabled ? swapRouter : liquidityRouter;
        IERC20(_path[0]).safeIncreaseAllowance(address(router), _amountIn);
        if (_ignoreErrors) {
            try
                router.swapExactTokensForTokensSupportingFeeOnTransferTokens(_amountIn, 0, _path, _to, block.timestamp)
            {} catch {}
        } else {
            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(_amountIn, 0, _path, _to, block.timestamp);
        }
    }
}
