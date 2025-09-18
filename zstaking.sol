// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*
  ZStakingFactory + ZStakingPoolV2
  - Factory creates staking pools (clones) with auto-initialize
  - Each pool supports:
      * staking / withdrawing
      * dynamic APR calculation based on rewardPool, rewardRate, totalStaked
      * penalties on early withdraw (sent to a penaltyCollector, e.g. multisig)
      * compound if stakingToken == rewardToken
      * emergency unstake
      * pause / unpause
  - Factory keeps registry of created pools
*/

import "@openzeppelin/contracts/proxy/Clones.sol";

/// ---------------------------------------------
/// Minimal SafeERC20 (inline, no OZ dependency)
/// ---------------------------------------------
library SafeERC20 {
    function _callOptionalReturn(address token, bytes memory data) private {
        (bool success, bytes memory returndata) = token.call(data);
        require(success, "SafeERC20: low-level call failed");
        if (returndata.length > 0) {
            require(abi.decode(returndata, (bool)), "SafeERC20: ERC20 op failed");
        }
    }
    function safeTransfer(address token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(0xa9059cbb, to, value));
    }
    function safeTransferFrom(address token, address from, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(0x23b872dd, from, to, value));
    }
}

/// ---------------------------------------------
/// Ownable + ReentrancyGuard (inline)
/// ---------------------------------------------
abstract contract ReentrancyGuard {
    uint256 private _status;
    constructor(){ _status = 1; }
    modifier nonReentrant() {
        require(_status == 1, "Reentrant");
        _status = 2;
        _;
        _status = 1;
    }
}

contract Ownable {
    address public owner;
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    constructor() { owner = msg.sender; emit OwnershipTransferred(address(0), msg.sender); }
    modifier onlyOwner() { require(msg.sender == owner, "Not owner"); _; }
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}

/// ---------------------------------------------
/// ZStakingPoolV2
/// ---------------------------------------------
contract ZStakingPoolV2 is ReentrancyGuard, Ownable {
    using SafeERC20 for address;

    // Tokens
    address public stakingToken;
    address public rewardToken;

    // Accounting
    uint256 public totalStaked;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public depositTime;

    uint256 public rewardPerTokenStored;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    uint256 public rewardRate; // tokens/sec
    uint256 public lastUpdateTime;
    uint256 public periodFinish;

    // Params
    uint256 public lockDuration; 
    uint256 public penaltyBps;
    uint256 public rewardPool;
    address public penaltyCollector; // destination for penalties

    bool public initialized;
    bool public paused;
    bool public autoCompoundEnabled;

    // Events
    event Initialized(address stakingToken, address rewardToken, uint256 lockDuration, uint256 penaltyBps, bool autoCompound, address penaltyCollector);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 principal, uint256 reward, uint256 penalty);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardAdded(uint256 reward, uint256 duration);
    event AutoCompoundSet(bool enabled);
    event Paused(address by);
    event Unpaused(address by);
    event EmergencyUnstaked(address indexed user, uint256 principal);
    event PenaltySent(uint256 amount);

    modifier notPaused() {
        require(!paused, "Paused");
        _;
    }

    constructor() { initialized = true; } // protect impl

    function initialize(
        address _stakingToken,
        address _rewardToken,
        uint256 _lockDuration,
        uint256 _penaltyBps,
        address _owner,
        bool _autoCompoundEnabled,
        address _penaltyCollector
    ) external {
        require(!initialized, "Already initialized");
        require(_stakingToken != address(0) && _rewardToken != address(0), "Zero token");
        require(_owner != address(0), "Zero owner");
        require(_penaltyCollector != address(0), "Zero penaltyCollector");
        require(_penaltyBps <= 10000, "Penalty>100%");
        stakingToken = _stakingToken;
        rewardToken = _rewardToken;
        lockDuration = _lockDuration;
        penaltyBps = _penaltyBps;
        owner = _owner;
        autoCompoundEnabled = _autoCompoundEnabled;
        penaltyCollector = _penaltyCollector;

        lastUpdateTime = block.timestamp;
        initialized = true;
        paused = false;

        emit Initialized(stakingToken, rewardToken, lockDuration, penaltyBps, autoCompoundEnabled, penaltyCollector);
    }

    // ---------------- Reward math ----------------
    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) return rewardPerTokenStored;
        uint256 dt = lastTimeRewardApplicable() - lastUpdateTime;
        if (dt == 0) return rewardPerTokenStored;
        return rewardPerTokenStored + (dt * rewardRate * 1e18 / totalStaked);
    }

    function earned(address account) public view returns (uint256) {
        return (balanceOf[account] * (rewardPerToken() - userRewardPerTokenPaid[account])) / 1e18 + rewards[account];
    }

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    // ---------------- Owner funcs ----------------
    function addReward(uint256 reward, uint256 duration) external onlyOwner updateReward(address(0)) {
        require(reward > 0 && duration > 0, "Invalid");
        rewardToken.safeTransferFrom(msg.sender, address(this), reward);
        rewardPool += reward;

        if (block.timestamp >= periodFinish) {
            rewardRate = reward / duration;
        } else {
            uint256 remaining = (periodFinish - block.timestamp) * rewardRate;
            rewardRate = (reward + remaining) / duration;
        }
        periodFinish = block.timestamp + duration;
        emit RewardAdded(reward, duration);
    }

    function setAutoCompoundEnabled(bool v) external onlyOwner {
        require(!v || rewardToken == stakingToken, "Compound needs same token");
        autoCompoundEnabled = v;
        emit AutoCompoundSet(v);
    }

    function setLockDuration(uint256 d) external onlyOwner { lockDuration = d; }
    function setPenaltyBps(uint256 bps) external onlyOwner { require(bps <= 10000, "Too high"); penaltyBps = bps; }
    function setPenaltyCollector(address c) external onlyOwner { require(c != address(0), "Zero"); penaltyCollector = c; }

    function pause() external onlyOwner { paused = true; emit Paused(msg.sender); }
    function unpause() external onlyOwner { paused = false; emit Unpaused(msg.sender); }

    // ---------------- User funcs ----------------
    function stake(uint256 amount) external nonReentrant notPaused updateReward(msg.sender) {
        require(amount > 0, "Zero");
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        balanceOf[msg.sender] += amount;
        totalStaked += amount;
        depositTime[msg.sender] = block.timestamp;
        emit Staked(msg.sender, amount);
    }

    function claim() public nonReentrant notPaused updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward == 0) return;
        if (reward > rewardPool) reward = rewardPool;
        rewards[msg.sender] -= reward;
        rewardPool -= reward;
        rewardToken.safeTransfer(msg.sender, reward);
        emit RewardPaid(msg.sender, reward);
    }

    function withdraw(uint256 amount) public nonReentrant notPaused updateReward(msg.sender) {
        require(amount > 0 && balanceOf[msg.sender] >= amount, "Invalid");
        uint256 penalty;
        if (block.timestamp < depositTime[msg.sender] + lockDuration) {
            penalty = (amount * penaltyBps) / 10000;
        }
        uint256 returnAmount = amount - penalty;
        balanceOf[msg.sender] -= amount;
        totalStaked -= amount;

        uint256 reward = rewards[msg.sender];
        if (reward > rewardPool) reward = rewardPool;
        if (reward > 0) {
            rewards[msg.sender] -= reward;
            rewardPool -= reward;
            rewardToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }

        if (penalty > 0) {
            stakingToken.safeTransfer(penaltyCollector, penalty);
            emit PenaltySent(penalty);
        }

        if (returnAmount > 0) stakingToken.safeTransfer(msg.sender, returnAmount);

        emit Withdrawn(msg.sender, returnAmount, reward, penalty);
    }

    function exit() external { withdraw(balanceOf[msg.sender]); }

    function emergencyUnstake() external nonReentrant {
        uint256 bal = balanceOf[msg.sender];
        require(bal > 0, "No balance");
        balanceOf[msg.sender] = 0;
        totalStaked -= bal;
        stakingToken.safeTransfer(msg.sender, bal);
        emit EmergencyUnstaked(msg.sender, bal);
    }

    function compound() external nonReentrant notPaused updateReward(msg.sender) {
        require(autoCompoundEnabled && rewardToken == stakingToken, "Disabled");
        uint256 reward = rewards[msg.sender];
        require(reward > 0, "No reward");
        if (reward > rewardPool) reward = rewardPool;
        rewards[msg.sender] -= reward;
        rewardPool -= reward;
        balanceOf[msg.sender] += reward;
        totalStaked += reward;
        depositTime[msg.sender] = block.timestamp;
        emit RewardPaid(msg.sender, reward);
        emit Staked(msg.sender, reward);
    }

    // ---------------- Views ----------------
    function getUserInfo(address user) external view returns (uint256 bal, uint256 pending, uint256 depositAt) {
        return (balanceOf[user], earned(user), depositTime[user]);
    }

    function getPoolInfo() external view returns (
        address _stakingToken,
        address _rewardToken,
        uint256 _totalStaked,
        uint256 _rewardPool,
        uint256 _rewardRate,
        uint256 _periodFinish,
        uint256 _lockDuration,
        uint256 _penaltyBps,
        bool _autoCompound,
        bool _paused,
        address _penaltyCollector
    ) {
        return (stakingToken, rewardToken, totalStaked, rewardPool, rewardRate, periodFinish,
                lockDuration, penaltyBps, autoCompoundEnabled, paused, penaltyCollector);
    }

    // APR in basis points (10000 = 100%)
    function getAPR() external view returns (uint256 aprBps) {
        if (totalStaked == 0 || block.timestamp >= periodFinish) return 0;
        uint256 yearlyReward = rewardRate * 365 days;
        aprBps = (yearlyReward * 10000) / totalStaked;
    }
}

/// ---------------------------------------------
/// Factory
/// ---------------------------------------------
contract ZStakingFactory is Ownable {
    using Clones for address;

    address public implementation;
    address[] public allPools;

    event PoolCreated(address indexed pool, address stakingToken, address rewardToken, address owner);

    constructor(address _implementation) {
        require(_implementation != address(0), "Zero impl");
        implementation = _implementation;
    }

    function createPool(
        address stakingToken,
        address rewardToken,
        uint256 lockDuration,
        uint256 penaltyBps,
        address poolOwner,
        bool autoCompound,
        address penaltyCollector
    ) external onlyOwner returns (address pool) {
        pool = implementation.clone();
        ZStakingPoolV2(pool).initialize(stakingToken, rewardToken, lockDuration, penaltyBps, poolOwner, autoCompound, penaltyCollector);
        allPools.push(pool);
        emit PoolCreated(pool, stakingToken, rewardToken, poolOwner);
    }

    function allPoolsLength() external view returns (uint256) { return allPools.length; }
}

