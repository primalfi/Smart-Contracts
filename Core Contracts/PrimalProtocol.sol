// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IPrimalApe {
    function mint(address to, uint256 amount) external;

    function burn(address from, uint256 amount) external;

    function totalSupply() external view returns (uint256);

    function balanceOf(address user) external view returns (uint256);
}

contract PrimalProtocol is Ownable, ReentrancyGuard {
    uint256 public constant PRECISION = 1e18;
    uint256 public constant FEE_DENOM = 10000;
    uint256 public constant MIN_QUEUE_TIME = 7 days;
    uint256 public constant MAX_TRANSFER_ITERATIONS = 50;

    // =====================================================
    // TOKEN
    // =====================================================

    IPrimalApe public immutable prAPE;
    address public treasury;

    // =====================================================
    // SYSTEM MODES
    // =====================================================

    enum ProtocolMode {
        Live,
        DepositsPaused,
        WithdrawalsPaused,
        EmergencyOnly
    }

    ProtocolMode public protocolMode;

    // =====================================================
    // FEES
    // =====================================================

    uint256 public protocolFee = 200;
    uint256 public earlyPenalty = 1500;
    uint256 public treasurySplit = 2500;

    // =====================================================
    // REWARD DISTRIBUTION
    // =====================================================

    uint256 public distributionBps = 7000;

    // =====================================================
    // ACCOUNTING
    // =====================================================

    uint256 public liquidityIndex = PRECISION;

    uint256 public totalUnderlying;

    uint256 public rewardReserve;

    // =====================================================
    // REWARD HISTORY
    // =====================================================

    struct RewardSnapshot {
        uint256 rewards;
        uint256 oldIndex;
        uint256 newIndex;
        uint256 timestamp;
    }

    RewardSnapshot[] public rewardsHistory;

    function getRewardsHistoryLength() external view returns (uint256) {
        return rewardsHistory.length;
    }

    function getRewardAt(
        uint256 i
    ) external view returns (RewardSnapshot memory) {
        return rewardsHistory[i];
    }

    // =====================================================
    // STAKES
    // =====================================================

    struct StakeInfo {
        address owner;
        uint256 deposited;
        uint256 scaledAmount;
        uint256 unlockTime;
        uint256 period;
        bool active;
    }

    StakeInfo[] public stakes;

    mapping(address => uint256[]) internal _userStakeIndexes;
    mapping(uint256 => uint256) internal _stakeIndexPosition;
    mapping(bytes32 => uint256[]) internal _mergeableStakeIds;
    mapping(uint256 => uint256) internal _mergeableIndex;

    // =====================================================
    // WITHDRAW QUEUE
    // =====================================================

    uint256 public constant QUEUE_SIZE = 100000;

    struct WithdrawRequest {
        uint256 id;
        address user;
        uint256 amount;
        uint256 requestTime;
        bool claimed;
    }

    WithdrawRequest[QUEUE_SIZE] public withdrawQueue;

    uint256 public withdrawHead;
    uint256 public withdrawTail;
    uint256 public nextWithdrawRequestId;

    // =====================================================
    // EVENTS
    // =====================================================

    event Staked(address indexed user, uint256 amount, uint256 period);

    event WithdrawRequested(address indexed user, uint256 amount);

    event WithdrawClaimed(address indexed user, uint256 amount);

    event RewardsDistributed(
        uint256 rewards,
        uint256 oldIndex,
        uint256 newIndex,
        uint256 timestamp
    );

    event RewardsInjected(
        address indexed from,
        uint256 amount,
        uint256 timestamp
    );

    event DistributionBpsUpdated(uint256 bps);

    event FeeUpdated(uint256 fee);

    event PenaltyUpdated(uint256 penalty);

    event TreasuryUpdated(address treasury);

    event StakePositionTransferred(
        address indexed from,
        address indexed to,
        uint256 indexed stakeIndex,
        uint256 scaledAmount
    );

    event StakePositionSplit(
        address indexed from,
        address indexed to,
        uint256 indexed oldStakeIndex,
        uint256 newStakeIndex,
        uint256 scaledAmount
    );

    event StakeUpdated(
        address indexed user,
        uint256 indexed stakeId,
        uint256 deposited,
        uint256 scaledAmount,
        bool isSplit
    );

    event WithdrawQueueUpdated(
        uint256 indexed index,
        address indexed user,
        uint256 amount,
        bool claimed
    );

    event LiquidityIndexUpdated(
        uint256 oldIndex,
        uint256 newIndex,
        uint256 rewardsAdded
    );

    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed stakeIndex,
        uint256 amount
    );

    // =====================================================
    // MODIFIERS
    // =====================================================

    modifier depositsAllowed() {
        require(
            protocolMode == ProtocolMode.Live ||
                protocolMode == ProtocolMode.WithdrawalsPaused,
            "DEPOSITS_DISABLED"
        );
        _;
    }

    modifier withdrawalsAllowed() {
        require(
            protocolMode == ProtocolMode.Live ||
                protocolMode == ProtocolMode.DepositsPaused,
            "WITHDRAWALS_DISABLED"
        );
        _;
    }

    modifier onlyEmergencyMode() {
        require(
            protocolMode == ProtocolMode.EmergencyOnly,
            "NOT_EMERGENCY_MODE"
        );
        _;
    }

    // =====================================================
    // CONSTRUCTOR
    // =====================================================

    constructor(address _prAPE, address _treasury) Ownable(msg.sender) {
        require(_prAPE != address(0), "INVALID_PRAPE");

        require(_treasury != address(0), "INVALID_TREASURY");

        prAPE = IPrimalApe(_prAPE);

        treasury = _treasury;

        protocolMode = ProtocolMode.Live;
    }

    // =====================================================
    // INDEX
    // =====================================================

    function getCurrentIndex() external view returns (uint256) {
        return liquidityIndex;
    }

    // =====================================================
    // STAKE
    // =====================================================

    function stake(
        uint256 period
    ) external payable nonReentrant depositsAllowed {
        require(msg.value > 0, "ZERO_AMOUNT");

        require(
            period == 30 days || period == 60 days || period == 90 days,
            "INVALID_PERIOD"
        );

        uint256 feeAmount = (msg.value * protocolFee) / FEE_DENOM;

        uint256 treasuryFee = (feeAmount * treasurySplit) / FEE_DENOM;

        uint256 rewardsFee = feeAmount - treasuryFee;

        uint256 depositAmount = msg.value - feeAmount;

        rewardReserve += rewardsFee;

        totalUnderlying += depositAmount;

        if (treasuryFee > 0) {
            (bool feeSent, ) = payable(treasury).call{value: treasuryFee}("");

            require(feeSent, "TREASURY_TRANSFER_FAILED");
        }

        require(liquidityIndex > 0, "INVALID_INDEX");
        uint256 scaledAmount = (depositAmount * PRECISION) / liquidityIndex;

        // =========================
        // NORMALIZED UNLOCK TIME
        // =========================

        uint256 unlockTime = ((block.timestamp + period) / 1 days) * 1 days;

        // =========================
        // AUTO MERGE
        // =========================

        (bool found, uint256 mergeId) = _findMergeableStake(
            msg.sender,
            unlockTime,
            period
        );

        if (found) {
            StakeInfo storage existing = stakes[mergeId];

            existing.deposited += depositAmount;
            existing.scaledAmount += scaledAmount;

            prAPE.mint(msg.sender, depositAmount);

            emit StakeUpdated(
                msg.sender,
                mergeId,
                existing.deposited,
                existing.scaledAmount,
                false
            );

            emit Staked(msg.sender, depositAmount, period);

            return;
        }

        // =========================
        // CREATE NEW STAKE
        // =========================

        stakes.push(
            StakeInfo({
                owner: msg.sender,
                deposited: depositAmount,
                scaledAmount: scaledAmount,
                unlockTime: unlockTime,
                period: period,
                active: true
            })
        );

        uint256 stakeIndex = stakes.length - 1;

        _userStakeIndexes[msg.sender].push(stakeIndex);

        _stakeIndexPosition[stakeIndex] =
            _userStakeIndexes[msg.sender].length - 1;

        bytes32 key = _getMergeKey(msg.sender, unlockTime, period);

        _mergeableStakeIds[key].push(stakeIndex);
        _mergeableIndex[stakeIndex] = _mergeableStakeIds[key].length - 1;

        prAPE.mint(msg.sender, depositAmount);

        emit Staked(msg.sender, depositAmount, period);
    }

    // =====================================================
    // HANDLE TOKEN TRANSFER
    // =====================================================
    function handleTransfer(
        address from,
        address to,
        uint256 scaledAmount
    ) external nonReentrant {
        require(msg.sender == address(prAPE), "ONLY_TOKEN");
        require(from != address(0) && to != address(0), "INVALID_ADDR");
        require(scaledAmount > 0, "ZERO_AMOUNT");

        uint256 remaining = scaledAmount;

        uint256[] storage indexes = _userStakeIndexes[from];

        uint256 i = 0;
        uint256 iterations = 0;

        while (i < indexes.length && remaining > 0) {
            if (iterations >= MAX_TRANSFER_ITERATIONS) {
                break;
            }

            iterations++;

            uint256 stakeId = indexes[i];
            StakeInfo storage s = stakes[stakeId];

            // skip invalid
            if (!s.active || s.owner != from) {
                i++;
                continue;
            }

            // =========================
            // FULL TRANSFER
            // =========================
            if (s.scaledAmount <= remaining) {
                remaining -= s.scaledAmount;

                _handleFullTransfer(from, to, stakeId, i);

                i++;

                continue;
            }

            // =========================
            // PARTIAL TRANSFER
            // =========================
            _handlePartialTransfer(from, to, stakeId, remaining);

            remaining = 0;

            // normal advance
            i++;
        }

        require(remaining == 0, "NOT_FULLY_CONSUMED");
    }

    function _handlePartialTransfer(
        address from,
        address to,
        uint256 stakeId,
        uint256 moveScaled
    ) internal {
        StakeInfo storage s = stakes[stakeId];

        require(moveScaled > 0, "ZERO_MOVE");
        require(s.scaledAmount >= moveScaled, "INSUFFICIENT_SCALED");

        uint256 moveDeposited = (s.deposited * moveScaled) / s.scaledAmount;

        // =========================
        // UPDATE ORIGINAL STAKE
        // =========================
        s.scaledAmount -= moveScaled;
        s.deposited -= moveDeposited;

        bytes32 originalKey = _getMergeKey(from, s.unlockTime, s.period);

        _removeMergeableStake(originalKey, stakeId);

        if (s.active && s.owner == from) {
            _mergeableStakeIds[originalKey].push(stakeId);
            _mergeableIndex[stakeId] =
                _mergeableStakeIds[originalKey].length - 1;
        }

        // =========================
        // TARGET MERGE
        // =========================
        bytes32 targetKey = _getMergeKey(to, s.unlockTime, s.period);

        (bool found, uint256 mergeId) = _findMergeableStake(
            to,
            s.unlockTime,
            s.period
        );

        if (found) {
            StakeInfo storage target = stakes[mergeId];

            target.scaledAmount += moveScaled;
            target.deposited += moveDeposited;

            emit StakeUpdated(
                to,
                mergeId,
                target.deposited,
                target.scaledAmount,
                false
            );
        } else {
            stakes.push(
                StakeInfo({
                    owner: to,
                    deposited: moveDeposited,
                    scaledAmount: moveScaled,
                    unlockTime: s.unlockTime,
                    period: s.period,
                    active: true
                })
            );

            uint256 newId = stakes.length - 1;

            _userStakeIndexes[to].push(newId);
            _stakeIndexPosition[newId] = _userStakeIndexes[to].length - 1;

            _mergeableStakeIds[targetKey].push(newId);
            _mergeableIndex[newId] = _mergeableStakeIds[targetKey].length - 1;

            emit StakePositionSplit(from, to, stakeId, newId, moveScaled);

            emit StakeUpdated(to, newId, moveDeposited, moveScaled, true);
        }

        emit StakeUpdated(from, stakeId, s.deposited, s.scaledAmount, true);
    }

    // =====================================================
    // WITHDRAW REQUEST
    // =====================================================

    function requestWithdraw(
        uint256 stakeIndex
    ) external nonReentrant withdrawalsAllowed {
        require(stakeIndex < stakes.length, "INVALID_INDEX");

        StakeInfo storage s = stakes[stakeIndex];

        require(s.active, "STAKE_INACTIVE");
        require(s.owner == msg.sender, "NOT_OWNER");

        uint256 fullAmount = (s.scaledAmount * liquidityIndex) / PRECISION;

        uint256 withdrawAmount = fullAmount;

        bool early = block.timestamp < s.unlockTime;

        if (early) {
            uint256 penalty = (fullAmount * earlyPenalty) / FEE_DENOM;

            rewardReserve += penalty;
            withdrawAmount = fullAmount - penalty;
        }

        prAPE.burn(msg.sender, fullAmount);
        totalUnderlying -= fullAmount;

        _removeUserStake(msg.sender, stakeIndex);

        s.active = false;
        s.owner = address(0);
        s.deposited = 0;
        s.scaledAmount = 0;

        // =========================
        // RING BUFFER WRITE
        // =========================

        uint256 nextTail = (withdrawTail + 1) % QUEUE_SIZE;
        require(nextTail != withdrawHead, "QUEUE_FULL");

        withdrawQueue[withdrawTail] = WithdrawRequest({
            id: nextWithdrawRequestId,
            user: msg.sender,
            amount: withdrawAmount,
            requestTime: block.timestamp,
            claimed: false
        });

        emit WithdrawQueueUpdated(
            withdrawTail,
            msg.sender,
            withdrawAmount,
            false
        );

        withdrawTail = nextTail;
        nextWithdrawRequestId++;

        _cleanupWithdrawQueue();

        emit WithdrawRequested(msg.sender, withdrawAmount);
    }

    // =====================================================
    // CLAIM
    // =====================================================

    function claimWithdraw(
        uint256 index,
        uint256 requestId
    ) external nonReentrant {
        require(index < QUEUE_SIZE, "INVALID_INDEX");

        WithdrawRequest storage r = withdrawQueue[index];
        require(r.id == requestId, "INVALID_REQUEST_ID");

        require(r.user == msg.sender, "NOT_OWNER");

        require(!r.claimed, "ALREADY_CLAIMED");

        require(
            block.timestamp >= r.requestTime + MIN_QUEUE_TIME,
            "QUEUE_TIME"
        );

        require(address(this).balance >= r.amount, "INSUFFICIENT_LIQUIDITY");

        r.claimed = true;

        (bool sent, ) = payable(msg.sender).call{value: r.amount}("");

        require(sent, "TRANSFER_FAILED");

        emit WithdrawQueueUpdated(index, r.user, r.amount, true);
        emit WithdrawClaimed(msg.sender, r.amount);

        // optional cleanup
        _cleanupWithdrawQueue();
    }

    // =====================================================
    // EMERGENCY WITHDRAW
    // =====================================================

    function emergencyWithdraw(
        uint256 stakeIndex
    ) external nonReentrant onlyEmergencyMode {
        require(stakeIndex < stakes.length, "INVALID_INDEX");

        StakeInfo storage s = stakes[stakeIndex];

        require(s.active, "STAKE_INACTIVE");
        require(s.owner == msg.sender, "NOT_OWNER");

        uint256 amount = (s.scaledAmount * liquidityIndex) / PRECISION;

        prAPE.burn(msg.sender, amount);

        totalUnderlying -= amount;

        _removeUserStake(msg.sender, stakeIndex);

        s.active = false;
        s.owner = address(0);
        s.deposited = 0;
        s.scaledAmount = 0;

        (bool sent, ) = payable(msg.sender).call{value: amount}("");
        require(sent, "TRANSFER_FAILED");

        emit EmergencyWithdraw(msg.sender, stakeIndex, amount);
    }

    // =====================================================
    // REWARDS
    // =====================================================

    function injectRewards() external payable onlyOwner {
        require(msg.value > 0, "ZERO_AMOUNT");

        rewardReserve += msg.value;

        emit RewardsInjected(msg.sender, msg.value, block.timestamp);
    }

    // =====================================================
    // DISTRIBUTE REWARDS
    // =====================================================

    function distributeRewards() external onlyOwner {
        require(rewardReserve > 0, "NO_REWARDS");

        require(totalUnderlying > 0, "NO_TVL");

        uint256 rewards = (rewardReserve * distributionBps) / FEE_DENOM;

        require(rewards > 0, "ZERO_DISTRIBUTION");

        rewardReserve -= rewards;

        // =========================
        // SAFETY CHECKS
        // =========================

        require(totalUnderlying > 1e6, "TVL_TOO_LOW");

        uint256 newTVL = totalUnderlying + rewards;

        require(newTVL > totalUnderlying, "OVERFLOW");

        // =========================
        // SAFE INDEX UPDATE
        // =========================

        uint256 oldIndex = liquidityIndex;

        liquidityIndex = (liquidityIndex * newTVL) / totalUnderlying;

        // =========================
        // ANTI DUST CLAMP
        // =========================

        if (liquidityIndex < PRECISION / 1e12) {
            liquidityIndex = PRECISION / 1e12;
        }

        uint256 newIndex = liquidityIndex;

        // UPDATE TVL ONLY ONCE
        totalUnderlying += rewards;

        rewardsHistory.push(
            RewardSnapshot({
                rewards: rewards,
                oldIndex: oldIndex,
                newIndex: newIndex,
                timestamp: block.timestamp
            })
        );

        emit LiquidityIndexUpdated(oldIndex, liquidityIndex, rewards);

        emit RewardsDistributed(rewards, oldIndex, newIndex, block.timestamp);
    }

    // =====================================================
    // DISTRIBUTE ALL REWARDS
    // =====================================================

    function distributeAllRewards() external onlyOwner {
        require(rewardReserve > 0, "NO_REWARDS");

        require(totalUnderlying > 0, "NO_TVL");

        uint256 rewards = rewardReserve;

        // FULL RESET
        rewardReserve = 0;

        // =========================
        // SAFETY CHECKS
        // =========================

        require(totalUnderlying > 1e6, "TVL_TOO_LOW");

        uint256 newTVL = totalUnderlying + rewards;

        require(newTVL > totalUnderlying, "OVERFLOW");

        // =========================
        // SAFE INDEX UPDATE
        // =========================

        uint256 oldIndex = liquidityIndex;

        liquidityIndex = (liquidityIndex * newTVL) / totalUnderlying;

        // =========================
        // ANTI DUST CLAMP
        // =========================

        if (liquidityIndex < PRECISION / 1e12) {
            liquidityIndex = PRECISION / 1e12;
        }

        uint256 newIndex = liquidityIndex;

        // UPDATE TVL ONLY ONCE
        totalUnderlying += rewards;

        rewardsHistory.push(
            RewardSnapshot({
                rewards: rewards,
                oldIndex: oldIndex,
                newIndex: newIndex,
                timestamp: block.timestamp
            })
        );

        emit LiquidityIndexUpdated(oldIndex, liquidityIndex, rewards);

        emit RewardsDistributed(rewards, oldIndex, newIndex, block.timestamp);
    }

    // =====================================================
    // VIEWS
    // =====================================================

    function exchangeRate() external view returns (uint256) {
        uint256 supply = prAPE.totalSupply();

        if (supply == 0) {
            return PRECISION;
        }

        return (totalUnderlying * PRECISION) / supply;
    }

    function getUserStakeCount(address user) external view returns (uint256) {
        return _userStakeIndexes[user].length;
    }

    function getUserStakeIndexes(
        address user
    ) external view returns (uint256[] memory) {
        return _userStakeIndexes[user];
    }

    function getStakeInfo(
        uint256 index
    )
        external
        view
        returns (
            address owner,
            uint256 deposited,
            uint256 scaledAmount,
            uint256 unlockTime,
            uint256 period,
            bool active
        )
    {
        StakeInfo memory s = stakes[index];

        return (
            s.owner,
            s.deposited,
            s.scaledAmount,
            s.unlockTime,
            s.period,
            s.active
        );
    }

    function getWithdrawQueueRealLength() external view returns (uint256) {
        if (withdrawTail >= withdrawHead) {
            return withdrawTail - withdrawHead;
        }

        return QUEUE_SIZE - withdrawHead + withdrawTail;
    }

    function canClaimWithdraw(uint256 index) public view returns (bool) {
        if (index >= QUEUE_SIZE) {
            return false;
        }

        WithdrawRequest memory r = withdrawQueue[index];

        return (!r.claimed &&
            block.timestamp >= r.requestTime + MIN_QUEUE_TIME);
    }

    function getStakeValue(uint256 index) external view returns (uint256) {
        StakeInfo memory s = stakes[index];

        if (!s.active) {
            return 0;
        }

        return (s.scaledAmount * liquidityIndex) / PRECISION;
    }

    // =====================================================
    // ADMIN
    // =====================================================

    function setDistributionBps(uint256 _bps) external onlyOwner {
        require(_bps <= FEE_DENOM, "INVALID_BPS");

        distributionBps = _bps;

        emit DistributionBpsUpdated(_bps);
    }

    event ProtocolModeUpdated(ProtocolMode mode);

    function setProtocolMode(ProtocolMode _mode) external onlyOwner {
        protocolMode = _mode;

        emit ProtocolModeUpdated(_mode);
    }

    function setFee(uint256 _fee) external onlyOwner {
        require(_fee <= 1000, "FEE_TOO_HIGH");

        protocolFee = _fee;

        emit FeeUpdated(_fee);
    }

    function setPenalty(uint256 _penalty) external onlyOwner {
        require(_penalty <= 3000, "PENALTY_TOO_HIGH");

        earlyPenalty = _penalty;

        emit PenaltyUpdated(_penalty);
    }

    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "INVALID_TREASURY");

        treasury = _treasury;

        emit TreasuryUpdated(_treasury);
    }

    // =====================================================
    // INTERNAL HELPERS
    // =====================================================
    function _removeMergeableStake(bytes32 key, uint256 stakeId) internal {
        uint256[] storage arr = _mergeableStakeIds[key];

        if (arr.length == 0) return;

        uint256 index = _mergeableIndex[stakeId];
        uint256 lastIndex = arr.length - 1;

        uint256 lastId = arr[lastIndex];

        if (index != lastIndex) {
            arr[index] = lastId;
            _mergeableIndex[lastId] = index;
        }

        arr.pop();
        delete _mergeableIndex[stakeId];
    }

    function _removeUserStake(address user, uint256 stakeIndex) internal {
        uint256[] storage arr = _userStakeIndexes[user];

        uint256 indexPosition = _stakeIndexPosition[stakeIndex];
        uint256 lastIndex = arr.length - 1;

        if (indexPosition != lastIndex) {
            uint256 lastStakeId = arr[lastIndex];

            arr[indexPosition] = lastStakeId;
            _stakeIndexPosition[lastStakeId] = indexPosition;
        }

        arr.pop();

        // =========================
        // CLEAN MERGEABLE INDEX
        // =========================

        StakeInfo storage s = stakes[stakeIndex];

        bytes32 key = _getMergeKey(user, s.unlockTime, s.period);

        _removeMergeableStake(key, stakeIndex);

        delete _stakeIndexPosition[stakeIndex];
    }

    function _findMergeableStake(
        address user,
        uint256 unlockTime,
        uint256 period
    ) internal view returns (bool found, uint256 stakeId) {
        bytes32 key = _getMergeKey(user, unlockTime, period);

        uint256[] storage list = _mergeableStakeIds[key];

        for (uint256 i = 0; i < list.length; i++) {
            uint256 id = list[i];
            StakeInfo storage s = stakes[id];

            if (s.active && s.owner == user) {
                return (true, id);
            }
        }

        return (false, 0);
    }

    function _getMergeKey(
        address user,
        uint256 unlockTime,
        uint256 period
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(user, unlockTime, period));
    }

    function _handleFullTransfer(
        address from,
        address to,
        uint256 stakeId,
        uint256 indexPosition
    ) internal {
        StakeInfo storage s = stakes[stakeId];

        // =========================
        // CLEAN OLD MERGE KEY (REMOVE FIRST)
        // =========================
        bytes32 oldKey = _getMergeKey(from, s.unlockTime, s.period);
        _removeMergeableStake(oldKey, stakeId);

        // =========================
        // REMOVE FROM OLD OWNER FIRST (CRÍTICO)
        // =========================
        uint256[] storage fromArr = _userStakeIndexes[from];

        uint256 lastIndex = fromArr.length - 1;
        uint256 lastStakeId = fromArr[lastIndex];

        if (lastIndex != indexPosition) {
            fromArr[indexPosition] = lastStakeId;
            _stakeIndexPosition[lastStakeId] = indexPosition;
        }

        fromArr.pop();

        // =========================
        // CHANGE OWNERSHIP
        // =========================
        s.owner = to;

        // =========================
        // ADD TO NEW OWNER
        // =========================
        _userStakeIndexes[to].push(stakeId);
        _stakeIndexPosition[stakeId] = _userStakeIndexes[to].length - 1;

        // =========================
        // ADD NEW MERGE KEY (CORRECT SYSTEM)
        // =========================
        bytes32 newKey = _getMergeKey(to, s.unlockTime, s.period);

        _mergeableStakeIds[newKey].push(stakeId);
        _mergeableIndex[stakeId] = _mergeableStakeIds[newKey].length - 1;

        // =========================
        // FINAL STATE SYNC
        // =========================
        _stakeIndexPosition[stakeId] = _userStakeIndexes[to].length - 1;

        emit StakePositionTransferred(from, to, stakeId, s.scaledAmount);

        emit StakeUpdated(to, stakeId, s.deposited, s.scaledAmount, false);
    }

    // =====================================================
    // INTERNAL CLEANUP
    // =====================================================

    function _cleanupWithdrawQueue() internal {
        while (
            withdrawHead != withdrawTail &&
            (withdrawQueue[withdrawHead].claimed ||
                block.timestamp >
                    withdrawQueue[withdrawHead].requestTime + 30 days)
        ) {
            delete withdrawQueue[withdrawHead];
            withdrawHead = (withdrawHead + 1) % QUEUE_SIZE;
        }
    }

    function getWithdrawRequest(
        uint256 index
    ) external view returns (WithdrawRequest memory) {
        require(index < QUEUE_SIZE, "INVALID_INDEX");
        return withdrawQueue[index];
    }

    receive() external payable {}
}