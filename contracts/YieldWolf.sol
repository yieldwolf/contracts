// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/utils/Address.sol';
import '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';

import './interfaces/IYieldWolfStrategy.sol';
import './interfaces/IYieldWolfCondition.sol';
import './interfaces/IYieldWolfAction.sol';

/**
 * @title YieldWolf Staking Contract
 * @notice handles deposits, withdraws, strategy execution and bounty rewards
 * @author YieldWolf
 */
contract YieldWolf is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    struct Rule {
        address condition; // address of the rule condition
        uint256[] conditionIntInputs; // numeric inputs sent to the rule condition
        address[] conditionAddrInputs; // address inputs sent to the rule condition
        address action; // address of the rule action
        uint256[] actionIntInputs; // numeric inputs sent to the rule action
        address[] actionAddrInputs; // address inputs sent to the rule action
    }

    struct UserInfo {
        uint256 shares; // total of shares the user has on the pool
        Rule[] rules; // list of rules applied to the pool
    }

    struct PoolInfo {
        IERC20 stakeToken; // address of the token staked on the underlying farm
        IYieldWolfStrategy strategy; // address of the strategy for the pool
    }

    PoolInfo[] public poolInfo; // info of each pool
    mapping(uint256 => mapping(address => UserInfo)) public userInfo; // info of each user that stakes tokens
    mapping(address => EnumerableSet.UintSet) private userStakedPools; // all pools in which a user has tokens staked
    mapping(address => bool) public strategyExists; // map used to ensure strategies cannot be added twice

    uint256 constant DEPOSIT_FEE_CAP = 500;
    uint256 public depositFee = 0;

    uint256 constant WITHDRAW_FEE_CAP = 500;
    uint256 public withdrawFee = 50;

    uint256 constant PERFORMANCE_FEE_CAP = 500;
    uint256 public performanceFee = 100;
    uint256 public performanceFeeBountyPct = 1000;

    uint256 constant RULE_EXECUTION_FEE_CAP = 500;
    uint256 public ruleFee = 20;
    uint256 public ruleFeeBountyPct = 5000;

    uint256 constant MAX_USER_RULES_PER_POOL = 50;

    address public feeAddress;
    address public feeAddressSetter;

    bool private executeRuleLocked;

    // addresses allowed to operate the strategy, including pausing and unpausing it in case of emergency
    mapping(address => bool) public operators;

    event Add(IERC20 stakeToken, IYieldWolfStrategy strategy);
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, address indexed to, uint256 indexed pid, uint256 amount);
    event AddRule(address indexed user, uint256 indexed pid);
    event RemoveRule(address indexed user, uint256 indexed pid, uint256 ruleIndex);
    event Earn(address indexed user, uint256 indexed pid, uint256 bountyReward);
    event ExecuteRule(uint256 indexed pid, address indexed user, uint256 ruleIndex);
    event SetOperator(address addr, bool isOperator);
    event SetDepositFee(uint256 depositFee);
    event SetWithdrawFee(uint256 withdrawFee);
    event SetPerformanceFee(uint256 performanceFee);
    event SetPerformanceFeeBountyPct(uint256 performanceFeeBountyPct);
    event SetRuleFee(uint256 ruleFee);
    event SetRuleFeeBountyPct(uint256 ruleFeeBountyPct);
    event SetStrategyRouter(IYieldWolfStrategy strategy, address router);
    event SetStrategySwapRouterEnabled(IYieldWolfStrategy strategy, bool enabled);
    event SetStrategySwapPath(IYieldWolfStrategy _strategy, address _token0, address _token1, address[] _path);
    event SetStrategyExtraEarnTokens(IYieldWolfStrategy _strategy, address[] _extraEarnTokens);
    event SetFeeAddress(address feeAddress);
    event SetFeeAddressSetter(address feeAddressSetter);

    modifier onlyOperator() {
        require(operators[msg.sender], 'onlyOperator: NOT_ALLOWED');
        _;
    }

    modifier onlyEndUser() {
        require(!Address.isContract(msg.sender) && tx.origin == msg.sender);
        _;
    }

    constructor(address _feeAddress) {
        operators[msg.sender] = true;
        feeAddressSetter = msg.sender;
        feeAddress = _feeAddress;
    }

    /**
     * @notice returns how many pools have been added
     */
    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    /**
     * @notice returns in how many pools a user has tokens staked
     * @param _user address of the user
     */
    function userStakedPoolLength(address _user) external view returns (uint256) {
        return userStakedPools[_user].length();
    }

    /**
     * @notice returns the pid of a pool in which the user has tokens staked
     * @dev helper for iterating over the array of user staked pools
     * @param _user address of the user
     * @param _index the index in the array of user staked pools
     */
    function userStakedPoolAt(address _user, uint256 _index) external view returns (uint256) {
        return userStakedPools[_user].at(_index);
    }

    /**
     * @notice returns a rule by pid, user and index
     * @dev helper for iterating over all the rules
     * @param _pid the pool id
     * @param _user address of the user
     * @param _ruleIndex the index of the rule
     */
    function userPoolRule(
        uint256 _pid,
        address _user,
        uint256 _ruleIndex
    ) external view returns (Rule memory rule) {
        rule = userInfo[_pid][_user].rules[_ruleIndex];
    }

    /**
     * @notice returns the number of rule a user has for a given pool
     * @param _pid the pool id
     * @param _user address of the user
     */
    function userRuleLength(uint256 _pid, address _user) external view returns (uint256) {
        return userInfo[_pid][_user].rules.length;
    }

    /**
     * @notice returns the amount of staked tokens by a user
     * @param _pid the pool id
     * @param _user address of the user
     */
    function stakedTokens(uint256 _pid, address _user) public view returns (uint256) {
        PoolInfo memory pool = poolInfo[_pid];
        UserInfo memory user = userInfo[_pid][_user];
        IYieldWolfStrategy strategy = pool.strategy;

        uint256 sharesTotal = strategy.sharesTotal();
        return sharesTotal > 0 ? (user.shares * strategy.totalStakeTokens()) / sharesTotal : 0;
    }

    /**
     * @notice adds a new pool with a given strategy
     * @dev can only be called by an operator
     * @param _strategy address of the strategy
     */
    function add(IYieldWolfStrategy _strategy) public onlyOperator {
        require(!strategyExists[address(_strategy)], 'add: STRATEGY_ALREADY_EXISTS');
        IERC20 stakeToken = IERC20(_strategy.stakeToken());
        poolInfo.push(PoolInfo({stakeToken: stakeToken, strategy: _strategy}));
        strategyExists[address(_strategy)] = true;
        emit Add(stakeToken, _strategy);
    }

    /**
     * @notice adds multiple new pools
     * @dev helper to add many pools at once
     * @param _strategies array of strategy addresses
     */
    function addMany(IYieldWolfStrategy[] calldata _strategies) external onlyOperator {
        for (uint256 i; i < _strategies.length; i++) {
            add(_strategies[i]);
        }
    }

    /**
     * @notice transfers tokens from the user and stakes them in the underlying farm
     * @dev tokens are transferred from msg.sender directly to the strategy
     * @param _pid the pool id
     * @param _depositAmount amount of tokens to transfer from msg.sender
     */
    function deposit(uint256 _pid, uint256 _depositAmount) external nonReentrant {
        _deposit(_pid, _depositAmount, msg.sender);
    }

    /**
     * @notice deposits stake tokens on behalf of another user
     * @param _pid the pool id
     * @param _depositAmount amount of tokens to transfer from msg.sender
     * @param _to address of the beneficiary
     */
    function depositTo(
        uint256 _pid,
        uint256 _depositAmount,
        address _to
    ) external nonReentrant {
        _deposit(_pid, _depositAmount, _to);
    }

    /**
     * @notice unstakes tokens from the underlying farm and transfers them to the user
     * @dev tokens are transferred directly from the strategy to the user
     * @param _pid the pool id
     * @param _withdrawAmount maximum amount of tokens to transfer to msg.sender
     */
    function withdraw(uint256 _pid, uint256 _withdrawAmount) external nonReentrant {
        _withdrawFrom(msg.sender, msg.sender, _pid, _withdrawAmount, address(0), 0, false);
    }

    /**
     * @notice withdraws all the token from msg.sender without harvesting first
     * @dev only for emergencies
     * @param _pid the pool id
     */
    function emergencyWithdraw(uint256 _pid) external nonReentrant {
        _withdrawFrom(msg.sender, msg.sender, _pid, type(uint256).max, address(0), 0, true);
    }

    /**
     * @notice adds a new rule
     * @dev each user can have multiple rules for each pool
     * @param _pid the pool id
     * @param _condition address of the condition contract
     * @param _conditionIntInputs array of integer inputs to be sent to the condition
     * @param _conditionAddrInputs array of address inputs to be sent to the condition
     * @param _action address of the action contract
     * @param _actionIntInputs array of integer inputs to be sent to the action
     * @param _actionAddrInputs array of address inputs to be sent to the action
     */
    function addRule(
        uint256 _pid,
        address _condition,
        uint256[] calldata _conditionIntInputs,
        address[] calldata _conditionAddrInputs,
        address _action,
        uint256[] calldata _actionIntInputs,
        address[] calldata _actionAddrInputs
    ) external {
        UserInfo storage user = userInfo[_pid][msg.sender];

        require(user.rules.length <= MAX_USER_RULES_PER_POOL, 'addRule: CAP_EXCEEDED');
        require(IYieldWolfCondition(_condition).isCondition(), 'addRule: BAD_CONDITION');
        require(IYieldWolfAction(_action).isAction(), 'addRule: BAD_ACTION');

        Rule memory rule;
        rule.condition = _condition;
        rule.conditionIntInputs = _conditionIntInputs;
        rule.conditionAddrInputs = _conditionAddrInputs;
        rule.action = _action;
        rule.actionIntInputs = _actionIntInputs;
        rule.actionAddrInputs = _actionAddrInputs;
        user.rules.push(rule);
        emit AddRule(msg.sender, _pid);
    }

    /**
     * @notice removes a given rule
     * @param _pid the pool id
     * @param _ruleIndex the index of the rule in the user info for the given pool
     */
    function removeRule(uint256 _pid, uint256 _ruleIndex) external {
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(_ruleIndex < user.rules.length, 'removeRule: BAD_INDEX');
        user.rules[_ruleIndex] = user.rules[user.rules.length - 1];
        user.rules.pop();
        emit RemoveRule(msg.sender, _pid, _ruleIndex);
    }

    /**
     * @notice runs the strategy and pays the bounty reward
     * @param _pid the pool id
     */
    function earn(uint256 _pid) external nonReentrant returns (uint256) {
        return _earn(_pid);
    }

    /**
     * @notice runs multiple strategies and pays multiple rewards
     * @param _pids array of pool ids
     */
    function earnMany(uint256[] calldata _pids) external nonReentrant {
        for (uint256 i; i < _pids.length; i++) {
            _earn(_pids[i]);
        }
    }

    /**
     * @notice checks wheter a rule passes its condition
     * @param _pid the pool id
     * @param _user address of the user
     * @param _ruleIndex the index of the rule
     */
    function checkRule(
        uint256 _pid,
        address _user,
        uint256 _ruleIndex
    ) external view returns (bool) {
        Rule memory rule = userInfo[_pid][_user].rules[_ruleIndex];
        return
            IYieldWolfCondition(rule.condition).check(
                address(this),
                address(poolInfo[_pid].strategy),
                _user,
                _pid,
                rule.conditionIntInputs,
                rule.conditionAddrInputs
            );
    }

    /**
     * @notice executes the rule action if the condition passes and sends the bounty reward to msg.sender
     * @param _pid the pool id
     * @param _user address of the user
     * @param _ruleIndex the index of the rule
     */
    function executeRule(
        uint256 _pid,
        address _user,
        uint256 _ruleIndex
    ) external onlyEndUser {
        require(!executeRuleLocked, 'executeRule: LOCKED');
        executeRuleLocked = true;
        UserInfo memory user = userInfo[_pid][_user];
        Rule memory rule = user.rules[_ruleIndex];
        IYieldWolfStrategy strategy = poolInfo[_pid].strategy;

        require(
            IYieldWolfCondition(rule.condition).check(
                address(this),
                address(strategy),
                _user,
                _pid,
                rule.conditionIntInputs,
                rule.conditionAddrInputs
            ),
            'executeAction: CONDITION_NOT_MET'
        );

        _tryEarn(strategy);
        IYieldWolfAction action = IYieldWolfAction(rule.action);
        (uint256 withdrawAmount, address withdrawTo) = action.execute(
            address(this),
            address(strategy),
            _user,
            _pid,
            rule.actionIntInputs,
            rule.actionAddrInputs
        );

        uint256 staked = stakedTokens(_pid, _user);
        if (withdrawAmount > staked) {
            withdrawAmount = staked;
        }

        if (withdrawAmount > 0) {
            uint256 ruleFeeAmount = (withdrawAmount * ruleFee) / 10000;
            _withdrawFrom(_user, withdrawTo, _pid, withdrawAmount, msg.sender, ruleFeeAmount, true);
        }
        action.callback(address(this), address(strategy), _user, _pid, rule.actionIntInputs, rule.actionAddrInputs);
        executeRuleLocked = false;
        emit ExecuteRule(_pid, _user, _ruleIndex);
    }

    /**
     * @notice adds or removes an operator
     * @dev can only be called by the owner
     * @param _addr address of the operator
     * @param _isOperator whether the given address will be set as an operator
     */
    function setOperator(address _addr, bool _isOperator) external onlyOwner {
        operators[_addr] = _isOperator;
        emit SetOperator(_addr, _isOperator);
    }

    /**
     * @notice updates the deposit fee
     * @dev can only be called by the owner
     * @param _depositFee new deposit fee in basis points
     */
    function setDepositFee(uint256 _depositFee) external onlyOwner {
        require(_depositFee <= DEPOSIT_FEE_CAP, 'setDepositFee: CAP_EXCEEDED');
        depositFee = _depositFee;
        emit SetDepositFee(_depositFee);
    }

    /**
     * @notice updates the withdraw fee
     * @dev can only be called by the owner
     * @param _withdrawFee new withdraw fee in basis points
     */
    function setWithdrawFee(uint256 _withdrawFee) external onlyOwner {
        require(_withdrawFee <= WITHDRAW_FEE_CAP, 'setWithdrawFee: CAP_EXCEEDED');
        withdrawFee = _withdrawFee;
        emit SetWithdrawFee(_withdrawFee);
    }

    /**
     * @notice updates the performance fee
     * @dev can only be called by the owner
     * @param _performanceFee new performance fee fee in basis points
     */
    function setPerformanceFee(uint256 _performanceFee) external onlyOwner {
        require(_performanceFee <= PERFORMANCE_FEE_CAP, 'setPerformanceFee: CAP_EXCEEDED');
        performanceFee = _performanceFee;
        emit SetPerformanceFee(_performanceFee);
    }

    /**
     * @notice updates the percentage of the performance fee sent to the bounty hunter
     * @dev can only be called by the owner
     * @param _performanceFeeBountyPct percentage of the performance fee for the bounty hunter in basis points
     */
    function setPerformanceFeeBountyPct(uint256 _performanceFeeBountyPct) external onlyOwner {
        require(_performanceFeeBountyPct <= 10000, 'setPerformanceFeeBountyPct: CAP_EXCEEDED');
        performanceFeeBountyPct = _performanceFeeBountyPct;
        emit SetPerformanceFeeBountyPct(_performanceFeeBountyPct);
    }

    /**
     * @notice updates the rule execution fee
     * @dev can only be called by the owner
     * @param _ruleFee new rule fee fee in basis points
     */
    function setRuleFee(uint256 _ruleFee) external onlyOwner {
        require(_ruleFee <= RULE_EXECUTION_FEE_CAP, 'setRuleFee: CAP_EXCEEDED');
        ruleFee = _ruleFee;
        emit SetRuleFee(_ruleFee);
    }

    /**
     * @notice updates the percentage of the rule execution fee sent to the bounty hunter
     * @dev can only be called by the owner
     * @param _ruleFeeBountyPct percentage of the rule execution fee for the bounty hunter in basis points
     */
    function setRuleFeeBountyPct(uint256 _ruleFeeBountyPct) external onlyOwner {
        require(_ruleFeeBountyPct <= 10000, 'setRuleFeeBountyPct: CAP_EXCEEDED');
        ruleFeeBountyPct = _ruleFeeBountyPct;
        emit SetRuleFeeBountyPct(_ruleFeeBountyPct);
    }

    /**
     * @notice updates the swap router used by a given strategy
     * @dev can only be called by the owner
     * @param _strategy address of the strategy
     * @param _enabled whether to enable or disable the swap router
     */
    function setStrategySwapRouterEnabled(IYieldWolfStrategy _strategy, bool _enabled) external onlyOwner {
        _strategy.setSwapRouterEnabled(_enabled);
        emit SetStrategySwapRouterEnabled(_strategy, _enabled);
    }

    /**
     * @notice updates the swap path for a given pair
     * @dev can only be called by the owner
     * @param _strategy address of the strategy
     * @param _token0 address of token swap from
     * @param _token1 address of token swap to
     * @param _path swap path from token0 to token1
     */
    function setStrategySwapPath(
        IYieldWolfStrategy _strategy,
        address _token0,
        address _token1,
        address[] calldata _path
    ) external onlyOwner {
        require(_path.length != 1, 'setStrategySwapPath: INVALID_PATH');
        if (_path.length > 0) {
            // the first element must be token0 and the last one token1
            require(_path[0] == _token0 && _path[_path.length - 1] == _token1, 'setStrategySwapPath: INVALID_PATH');
        }
        _strategy.setSwapPath(_token0, _token1, _path);
        emit SetStrategySwapPath(_strategy, _token0, _token1, _path);
    }

    /**
     * @notice updates the swap path for a given pair
     * @dev can only be called by the owner
     * @param _strategy address of the strategy
     * @param _extraEarnTokens list of extra earn tokens for farms rewarding more than one token
     */
    function setStrategyExtraEarnTokens(IYieldWolfStrategy _strategy, address[] calldata _extraEarnTokens)
        external
        onlyOwner
    {
        require(_extraEarnTokens.length <= 5, 'setStrategyExtraEarnTokens: CAP_EXCEEDED');

        // tokens sanity check
        for (uint256 i; i < _extraEarnTokens.length; i++) {
            IERC20(_extraEarnTokens[i]).balanceOf(address(this));
        }

        _strategy.setExtraEarnTokens(_extraEarnTokens);
        emit SetStrategyExtraEarnTokens(_strategy, _extraEarnTokens);
    }

    /**
     * @notice updates the fee address
     * @dev can only be called by the fee address setter
     * @param _feeAddress new fee address
     */
    function setFeeAddress(address _feeAddress) external {
        require(msg.sender == feeAddressSetter && _feeAddress != address(0), 'setFeeAddress: NOT_ALLOWED');
        feeAddress = _feeAddress;
        emit SetFeeAddress(_feeAddress);
    }

    /**
     * @notice updates the fee address setter
     * @dev can only be called by the previous fee address setter
     * @param _feeAddressSetter new fee address setter
     */
    function setFeeAddressSetter(address _feeAddressSetter) external {
        require(msg.sender == feeAddressSetter && _feeAddressSetter != address(0), 'setFeeAddressSetter: NOT_ALLOWED');
        feeAddressSetter = _feeAddressSetter;
        emit SetFeeAddressSetter(_feeAddressSetter);
    }

    function _deposit(
        uint256 _pid,
        uint256 _depositAmount,
        address _to
    ) internal {
        require(_depositAmount > 0, 'deposit: MUST_BE_GREATER_THAN_ZERO');
        PoolInfo memory pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_to];

        if (pool.strategy.sharesTotal() > 0) {
            _tryEarn(pool.strategy);
        }

        // calculate deposit amount from balance before and after the transfer in order to support tokens with tax
        uint256 balanceBefore = pool.stakeToken.balanceOf(address(pool.strategy));
        pool.stakeToken.safeTransferFrom(address(msg.sender), address(pool.strategy), _depositAmount);
        _depositAmount = pool.stakeToken.balanceOf(address(pool.strategy)) - balanceBefore;

        uint256 sharesAdded = pool.strategy.deposit(_depositAmount);
        user.shares = user.shares + sharesAdded;
        userStakedPools[_to].add(_pid);

        emit Deposit(_to, _pid, _depositAmount);
    }

    function _withdrawFrom(
        address _user,
        address _to,
        uint256 _pid,
        uint256 _withdrawAmount,
        address _bountyHunter,
        uint256 _ruleFeeAmount,
        bool _skipEarn
    ) internal {
        require(_withdrawAmount > 0, '_withdrawFrom: MUST_BE_GREATER_THAN_ZERO');
        UserInfo storage user = userInfo[_pid][_user];
        IYieldWolfStrategy strategy = poolInfo[_pid].strategy;

        if (!_skipEarn) {
            _tryEarn(strategy);
        }

        uint256 sharesTotal = strategy.sharesTotal();

        require(user.shares > 0 && sharesTotal > 0, 'withdraw: NO_SHARES');

        uint256 maxAmount = (user.shares * strategy.totalStakeTokens()) / sharesTotal;
        if (_withdrawAmount > maxAmount) {
            _withdrawAmount = maxAmount;
        }
        uint256 sharesRemoved = strategy.withdraw(_withdrawAmount, _to, _bountyHunter, _ruleFeeAmount);
        user.shares = user.shares > sharesRemoved ? user.shares - sharesRemoved : 0;
        if (user.shares == 0) {
            userStakedPools[_user].remove(_pid);
        }

        emit Withdraw(_user, _to, _pid, _withdrawAmount);
    }

    function _earn(uint256 _pid) internal returns (uint256 bountyRewarded) {
        bountyRewarded = poolInfo[_pid].strategy.earn(msg.sender);
        emit Earn(msg.sender, _pid, bountyRewarded);
    }

    function _tryEarn(IYieldWolfStrategy _strategy) internal {
        try _strategy.earn(address(0)) {} catch {}
    }
}
