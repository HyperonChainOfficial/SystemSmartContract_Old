// SPDX-License-Identifier: MIT
pragma solidity 0.8.14;

import "./Params.sol";

interface IPunish
{
    function cleanPunishRecord(address _validator) external returns (bool);
}

contract Ownership {

    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    constructor() {
        _transferOwnership(msg.sender);
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if the sender is not the owner.
     */
    function _checkOwner() internal view virtual {
        require(owner() == msg.sender, "Ownable: caller is not the owner");
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions anymore. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby removing any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
        _transferOwnership(address(0));
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        _transferOwnership(newOwner);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Internal function without access restriction.
     */
    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

contract Validators is Params, Ownership {

    enum Status {
        // validator not exist, default status
        NotExist,
        // validator created
        Created,
        // anyone has staked for the validator
        Staked,
        // validator's staked coins < MinimalStakingCoin
        Unstaked,
        // validator is jailed by system(validator have to repropose)
        Jailed
    }

    struct Description {
        string moniker;
        string identity;
        string website;
        string email;
        string details;
    }

    struct Validator {
        address payable feeAddr;
        Status status;
        uint256 coins;
        Description description;
        uint256 hbIncoming;
        uint256 totalJailedHB;
        uint256 lastWithdrawProfitsBlock;
        // Address list of user who has staked for this validator
        address[] stakers;
    }

    struct StakingInfo {
        uint256 coins;
        // unstakeBlock != 0 means that you are unstaking your stake, so you can't
        // stake or unstake
        uint256 unstakeBlock;
        // index of the staker list in validator
        uint256 index;
        uint256 stakeTime;
    }

    mapping(address => Validator) public validatorInfo;

    uint256 private constant maxReward = 12000000 ether ; // 12 Million HPN
    uint256 private constant rewardhalftime = 15552000 ; //6 months
    struct RewardInfo
    {
        uint rewardDuration ;
        uint256 rewardAmount ; // 1 HPN
        uint256  totalRewardOut ;
    }
    RewardInfo public rewardInfo;
    uint256 startingTime;


    // *****************************
    // staker => validator => info
    mapping(address => mapping(address => StakingInfo)) public staked;
    // current validator set used by chain
    // only changed at block epoch
    address[] public currentValidatorSet;
    // highest validator set(dynamic changed)
    address[] public highestValidatorsSet;
    // total stake of all validators
    uint256 public totalStake;
    // total jailed hb
    uint256 public totalJailedHB;

    // System contracts
    IPunish  private punish;

    enum Operations {Distribute, UpdateValidators}
    // Record the operations is done or not.
    mapping(uint256 => mapping(uint8 => bool)) operationsDone;

    event LogCreateValidator(
        address indexed val,
        address indexed fee,
        uint256 time
    );
    event LogEditValidator(
        address indexed val,
        address indexed fee,
        uint256 time
    );
    event LogReactive(address indexed val, uint256 time);
    event LogAddToTopValidators(address indexed val, uint256 time);
    event LogRemoveFromTopValidators(address indexed val, uint256 time);
    event LogUnstake(
        address indexed staker,
        address indexed val,
        uint256 amount,
        uint256 time
    );
    event LogWithdrawProfits(
        address indexed val,
        address indexed fee,
        uint256 hb,
        uint256 time
    );
    event LogWithdrawStaking(
        address indexed staker,
        address indexed val,
        uint256 amount,
        uint256 time
    );

    event LogRemoveValidator(address indexed val, uint256 hb, uint256 time);
    event LogRemoveValidatorIncoming(
        address indexed val,
        uint256 hb,
        uint256 time
    );
    event LogDistributeBlockReward(
          address indexed coinbase,
          uint256 blockReward,
          bool isStakingRewards,
          uint256 time
      );
    event LogUpdateValidator(address[] newSet);
    event LogStake(
        address indexed staker,
        address indexed val,
        uint256 staking,
        uint256 time
        );  

    modifier onlyNotRewarded() {
        require(
            operationsDone[block.number][uint8(Operations.Distribute)] == false,
            "Block is already rewarded"
        );
        _;
    }

    modifier onlyNotUpdated() {
        require(
            operationsDone[block.number][uint8(Operations.UpdateValidators)] ==
                false,
            "Validators already updated"
        );
        _;
    }



    address public StakingContract;
    //this sets Staking contract address.
    //this should set after the contract is initialized.

    function setStakingContract(address _StakingContract) onlyOwner external returns(bool){
        StakingContract = _StakingContract;
        (bool success, ) = _StakingContract.call(
            abi.encodeWithSignature("setValidators(address[])", currentValidatorSet)
        );
        return success;
    }
    // this is initialized by the blockchain itself.
    // so no need to initialize separately.
    function initialize(address[] calldata vals) external onlyNotInitialized {

        punish = IPunish(PunishContractAddr);

        for (uint256 i = 0; i < vals.length; i++) {
            require(vals[i] != address(0), "err1");

            if (!isActiveValidator(vals[i])) {
                currentValidatorSet.push(vals[i]);
            }
            if (!isTopValidator(vals[i])) {
                highestValidatorsSet.push(vals[i]);
            }
            if (validatorInfo[vals[i]].feeAddr == address(0)) {
                validatorInfo[vals[i]].feeAddr = payable(vals[i]);
            }
            // Important: NotExist validator can't get profits
            if (validatorInfo[vals[i]].status == Status.NotExist) {
                validatorInfo[vals[i]].status = Status.Staked;
            }

        }
        if(owner() == address(0))
        {
            _transferOwnership(msg.sender);
        }
        rewardInfo.rewardAmount = 1 ether; //1 HPN
        rewardInfo.rewardDuration  = 1;
        initialized = true;
        startingTime = block.timestamp ;
    }

    // stake for the validator
    function stake(address validator)
          public
          payable
          onlyInitialized
          returns (bool)
      {
          address payable staker = payable(msg.sender);
          uint256 staking = msg.value;

          require(
              validatorInfo[validator].status == Status.Created ||
                  validatorInfo[validator].status == Status.Staked,
              "Can't stake to a validator in abnormal status"
          );
          require(
              staked[staker][validator].unstakeBlock == 0,
              "Can't stake when you are unstaking"
          );

          Validator storage valInfo = validatorInfo[validator];
          // The staked coins of validator must >= MinimalStakingCoin
          require(
              valInfo.coins + staking >= MinimalStakingCoin,
              "Staking coins not enough"
          );

          // stake at first time to this validator
          if (staked[staker][validator].coins == 0) {
              // add staker to validator's record list
              staked[staker][validator].index = valInfo.stakers.length;
              valInfo.stakers.push(staker);
          }

          valInfo.coins = valInfo.coins + staking ;
          if (valInfo.status != Status.Staked) {
              valInfo.status = Status.Staked;
          }
          tryAddValidatorToHighestSet(validator, valInfo.coins);

          // record staker's info
          staked[staker][validator].coins = staked[staker][validator].coins + staking;
          totalStake = totalStake + staking;

          emit LogStake(staker, validator, staking, block.timestamp);
          return true;
      }

    function createOrEditValidator(
        address payable feeAddr,
        string calldata moniker,
        string calldata identity,
        string calldata website,
        string calldata email,
        string calldata details
    ) payable external onlyInitialized  {
        require(feeAddr != address(0), "Invalid fee address");
        require(
            validateDescription(moniker, identity, website, email, details),
           "Invalid description"
        );
        address payable validator = payable(msg.sender);
        bool isCreate ;
        if (validatorInfo[validator].status == Status.NotExist) {
            validatorInfo[validator].status = Status.Created;
            isCreate = true;
        }

        if (validatorInfo[validator].feeAddr != feeAddr) {
            validatorInfo[validator].feeAddr = feeAddr;
        }

        validatorInfo[validator].description = Description(
            moniker,
            identity,
            website,
            email,
            details
        );

        if (isCreate) {
            //for the first time, validator has to stake 0.5% of the totalsupply which is 500,000 coins
            require(msg.value >= 500000 ether,"Insufficient Value");
            stake(validator);
            emit LogCreateValidator(validator, feeAddr, block.timestamp);
        } else {
            //for edit transaction, no value is desired
            require(msg.value == 0, "Value not needed");
            emit LogEditValidator(validator, feeAddr, block.timestamp);
        }
    }

    function tryReactive(address validator)
        external
        onlyProposalContract
        onlyInitialized
        returns (bool)
    {
        // Only update validator status if Unstaked/Jailed
        if (
            validatorInfo[validator].status != Status.Unstaked &&
            validatorInfo[validator].status != Status.Jailed
        ) {
            return true;
        }

        if (validatorInfo[validator].status == Status.Jailed) {
            require(punish.cleanPunishRecord(validator), "clean failed");
        }
        validatorInfo[validator].status = Status.Created;

        emit LogReactive(validator, block.timestamp);
        return true;
    }

    function unstake(address validator)
      external
      onlyInitialized
      returns (bool)
  {
      address staker = msg.sender;
      require(
          validatorInfo[validator].status != Status.NotExist,
          "Validator not exist"
      );

      StakingInfo storage stakingInfo = staked[staker][validator];
      Validator storage valInfo = validatorInfo[validator];
      uint256 unstakeAmount = stakingInfo.coins;

      require(
          stakingInfo.unstakeBlock == 0,
          "You are already in unstaking status"
      );
      require(unstakeAmount > 0, "You don't have any stake");
      // You can't unstake if the validator is the only one top validator and
      // this unstake operation will cause staked coins of validator < MinimalStakingCoin
      require(
          !(highestValidatorsSet.length == 1 &&
              isTopValidator(validator) &&
              valInfo.coins - unstakeAmount < MinimalStakingCoin),
          "You can't unstake, validator list will be empty after this operation!"
      );

      // try to remove this staker out of validator stakers list.
      if (stakingInfo.index != valInfo.stakers.length - 1) {
          valInfo.stakers[stakingInfo.index] = valInfo.stakers[valInfo
              .stakers
              .length - 1];
          // update index of the changed staker.
          staked[valInfo.stakers[stakingInfo.index]][validator]
              .index = stakingInfo.index;
      }
      valInfo.stakers.pop();

      valInfo.coins = valInfo.coins - unstakeAmount;
      stakingInfo.unstakeBlock = block.number;
      stakingInfo.index = 0;
      totalStake = totalStake - unstakeAmount ;

      // try to remove it out of active validator set if validator's coins < MinimalStakingCoin
      if (valInfo.coins < MinimalStakingCoin) {
          valInfo.status = Status.Unstaked;
          // it's ok if validator not in highest set
          tryRemoveValidatorInHighestSet(validator);
      }

      emit LogUnstake(staker, validator, unstakeAmount, block.timestamp);
      return true;
  }


   function withdrawStaking(address validator) external {
        address payable staker = payable(msg.sender);
        StakingInfo storage stakingInfo = staked[staker][validator];
        require(
            validatorInfo[validator].status != Status.NotExist,
            "validator not exist"
        );
        require(stakingInfo.unstakeBlock != 0, "You have to unstake first");
        // Ensure staker can withdraw his staking back
        require(
            stakingInfo.unstakeBlock + StakingLockPeriod <= block.timestamp,
            "Your staking haven't unlocked yet"
        );
        require(stakingInfo.coins > 0, "You don't have any stake");

        uint256 staking = stakingInfo.coins;
        stakingInfo.coins = 0;
        stakingInfo.unstakeBlock = 0;
        // send stake back to staker
        staker.transfer(staking);

        emit LogWithdrawStaking(staker, validator, staking, block.timestamp);

    }


    // feeAddr can withdraw profits of it's validator
    function withdrawProfits(address validator) external  {
        address payable feeAddr = payable(msg.sender);
        require(
            validatorInfo[validator].status != Status.NotExist,
            "Validator not exist"
        );
        require(
            validatorInfo[validator].feeAddr == feeAddr,
            "You are not the fee receiver of this validator"
        );
        require(
            validatorInfo[validator].lastWithdrawProfitsBlock +
                WithdrawProfitPeriod <=
                block.timestamp,
            "You must wait enough blocks to withdraw your profits after latest withdraw of this validator"
        );
        uint256 hbIncoming = validatorInfo[validator].hbIncoming;
        require(hbIncoming > 0, "You don't have any profits");

        // update info
        validatorInfo[validator].hbIncoming = 0;
        validatorInfo[validator].lastWithdrawProfitsBlock = block.timestamp;

        // send profits to fee address
        if (hbIncoming > 0) {
            feeAddr.transfer(hbIncoming);
        }

        emit LogWithdrawProfits(
            validator,
            feeAddr,
            hbIncoming,
            block.timestamp
        );

    }

    // distributeBlockReward distributes block reward to all active validators
    function distributeBlockReward()
        external
        payable
        onlyMiner
        onlyNotRewarded
        onlyInitialized
    {
        address val = payable(msg.sender);
        // never reach this
        if (validatorInfo[val].status == Status.NotExist) {
            return;
        }
        uint256 reward = msg.value;
        operationsDone[block.number][uint8(Operations.Distribute)] = true;
        if(rewardInfo.totalRewardOut < maxReward){
            uint256 modDuration = block.timestamp - (startingTime % rewardhalftime);
            if(modDuration != rewardInfo.rewardDuration)
            {
              rewardInfo.rewardDuration = rewardInfo.rewardDuration + 1;
              rewardInfo.rewardAmount = rewardInfo.rewardAmount/2;
            }
            reward += rewardInfo.rewardAmount;
            rewardInfo.totalRewardOut += rewardInfo.rewardAmount;
        }
        // Jailed validator can't get profits.
        uint256 stakingrew = reward * 85/100;
        reward = reward - stakingrew;
        addProfitsToActiveValidatorsByStakePercentExcept(reward , address(0));
        (bool success, ) = StakingContract.call{value: stakingrew}(
            abi.encodeWithSignature("distributeBlockReward()")
        );
        emit LogDistributeBlockReward(val, reward, success, block.timestamp);
    }

    function updateActiveValidatorSet(address[] memory newSet, uint256 epoch)
        public
        onlyMiner
        onlyNotUpdated
        onlyInitialized
        onlyBlockEpoch(epoch)
    {
        operationsDone[block.number][uint8(Operations.UpdateValidators)] = true;
        require(newSet.length > 0, "Validator set empty!");

        currentValidatorSet = newSet;

        emit LogUpdateValidator(newSet);
    }

    function removeValidator(address val) external onlyPunishContract {
        uint256 hb = validatorInfo[val].hbIncoming;

        tryRemoveValidatorIncoming(val);

        // remove the validator out of active set
        // Note: the jailed validator may in active set if there is only one validator exists
        if (highestValidatorsSet.length > 1) {
            tryJailValidator(val);

            emit LogRemoveValidator(val, hb, block.timestamp);
        }
    }

    function removeValidatorIncoming(address val) external onlyPunishContract {
        tryRemoveValidatorIncoming(val);
    }

     function tryAddValidatorToHighestSet(address val, uint256 staking)
        internal
    {
        // do nothing if you are already in highestValidatorsSet set
        for (uint256 i = 0; i < highestValidatorsSet.length; i++) {
            if (highestValidatorsSet[i] == val) {
                return;
            }
        }

        if (highestValidatorsSet.length < MaxValidators) {
            highestValidatorsSet.push(val);
            emit LogAddToTopValidators(val, block.timestamp);
            return;
        }

        // find lowest validator index in current validator set
        uint256 lowest = validatorInfo[highestValidatorsSet[0]].coins;
        uint256 lowestIndex = 0;
        for (uint256 i = 1; i < highestValidatorsSet.length; i++) {
            if (validatorInfo[highestValidatorsSet[i]].coins < lowest) {
                lowest = validatorInfo[highestValidatorsSet[i]].coins;
                lowestIndex = i;
            }
        }

        // do nothing if staking amount isn't bigger than current lowest
        if (staking <= lowest) {
            return;
        }

        // replace the lowest validator
        emit LogAddToTopValidators(val, block.timestamp);
        emit LogRemoveFromTopValidators(
            highestValidatorsSet[lowestIndex],
            block.timestamp
        );
        highestValidatorsSet[lowestIndex] = val;
    }

    function tryRemoveValidatorIncoming(address val) private {
        // do nothing if validator not exist(impossible)
        if (
            validatorInfo[val].status == Status.NotExist ||
            currentValidatorSet.length <= 1
        ) {
            return;
        }

        uint256 hb = validatorInfo[val].hbIncoming;
        if (hb > 0) {
            addProfitsToActiveValidatorsByStakePercentExcept(hb, val);
            // for display purpose
            totalJailedHB = totalJailedHB + hb;
            validatorInfo[val].totalJailedHB = validatorInfo[val]
                .totalJailedHB
                + hb;

            validatorInfo[val].hbIncoming = 0;
        }

        emit LogRemoveValidatorIncoming(val, hb, block.timestamp);
    }

    // add profits to all validators by stake percent except the punished validator or jailed validator
    function addProfitsToActiveValidatorsByStakePercentExcept(
        uint256 totalReward,
        address punishedVal
    ) private {
        if (totalReward == 0) {
            return;
        }

        uint256 totalRewardStake;
        uint256 rewardValsLen;
        (
            totalRewardStake,
            rewardValsLen
        ) = getTotalStakeOfHighestValidatorsExcept(punishedVal);

        if (rewardValsLen == 0) {
            return;
        }


        uint256 remain;
        address last;

        // no stake(at genesis period)
        if (totalRewardStake == 0) {
            uint256 per = totalReward/rewardValsLen;
            remain = totalReward - (per*rewardValsLen);

            for (uint256 i = 0; i < highestValidatorsSet.length; i++) {
                address val = highestValidatorsSet[i];
                if (
                    validatorInfo[val].status != Status.Jailed &&
                    val != punishedVal
                ) {
                    validatorInfo[val].hbIncoming = validatorInfo[val]
                        .hbIncoming + per;

                    last = val;
                }
            }

            if (remain > 0 && last != address(0)) {
                validatorInfo[last].hbIncoming = validatorInfo[last]
                    .hbIncoming + remain;
            }
            return;
        }

        uint256 added;
        for (uint256 i = 0; i < highestValidatorsSet.length; i++) {
            address val = highestValidatorsSet[i];
            if (
                validatorInfo[val].status != Status.Jailed && val != punishedVal && validatorInfo[val].coins > 0
            ) {
                uint256 reward = totalReward * validatorInfo[val].coins / totalRewardStake;
                added += reward;
                last = val;
                validatorInfo[val].hbIncoming = validatorInfo[val]
                    .hbIncoming
                    + reward;
            }
        }

        remain = totalReward - added;
        if (remain > 0 && last != address(0)) {
            validatorInfo[last].hbIncoming = validatorInfo[last].hbIncoming +  remain  ;
        }
    }

    function tryJailValidator(address val) private {
        // do nothing if validator not exist
        if (validatorInfo[val].status == Status.NotExist) {
            return;
        }

        // set validator status to jailed
        validatorInfo[val].status = Status.Jailed;

        // try to remove if it's in active validator set
        tryRemoveValidatorInHighestSet(val);
    }

    function tryRemoveValidatorInHighestSet(address val) private {
        for (
            uint256 i = 0;
            // ensure at least one validator exist
            i < highestValidatorsSet.length && highestValidatorsSet.length > 1;
            i++
        ) {
            if (val == highestValidatorsSet[i]) {
                // remove it
                if (i != highestValidatorsSet.length - 1) {
                    highestValidatorsSet[i] = highestValidatorsSet[highestValidatorsSet
                        .length - 1];
                }

                highestValidatorsSet.pop();
                emit LogRemoveFromTopValidators(val, block.timestamp);

                break;
            }
        }
    }
    function getValidatorInfo(address val)
        public
        view
        returns (
            address payable,
            Status,
            uint256,
            uint256,
            uint256,
            uint256,
            address[] memory
        )
    {
        Validator memory v = validatorInfo[val];

        return (
            v.feeAddr,
            v.status,
            v.coins,
            v.hbIncoming,
            v.totalJailedHB,
            v.lastWithdrawProfitsBlock,
            v.stakers
        );
    }

    function getStakingInfo(address staker, address val)
        public
        view
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        return (
            staked[staker][val].coins,
            staked[staker][val].unstakeBlock,
            staked[staker][val].index
        );
    }
      function getActiveValidators() public view returns (address[] memory) {
        return currentValidatorSet;
    }

    function getTotalStakeOfActiveValidators()
        public
        view
        returns (uint256 total, uint256 len)
    {
        return getTotalStakeOfActiveValidatorsExcept(address(0));
    }

    function getTotalStakeOfActiveValidatorsExcept(address val)
        private
        view
        returns (uint256 total, uint256 len)
    {
        for (uint256 i = 0; i < currentValidatorSet.length; i++) {
            if (
                validatorInfo[currentValidatorSet[i]].status != Status.Jailed &&
                val != currentValidatorSet[i]
            ) {
                total = total + validatorInfo[currentValidatorSet[i]].coins;
                len++;
            }
        }

        return (total, len);
    }

    function isActiveValidator(address who) public view returns (bool) {
        for (uint256 i = 0; i < currentValidatorSet.length; i++) {
            if (currentValidatorSet[i] == who) {
                return true;
            }
        }

        return false;
    }

    function isTopValidator(address who) public view returns (bool) {
        for (uint256 i = 0; i < highestValidatorsSet.length; i++) {
            if (highestValidatorsSet[i] == who) {
                return true;
            }
        }

        return false;
    }

    function getTopValidators() public view returns (address[] memory) {
        return highestValidatorsSet;
    }

    function validateDescription(
        string memory moniker,
        string memory identity,
        string memory website,
        string memory email,
        string memory details
    ) public pure returns (bool) {
        require(bytes(moniker).length <= 70, "Invalid moniker length");
        require(bytes(identity).length <= 3000, "Invalid identity length");
        require(bytes(website).length <= 140, "Invalid website length");
        require(bytes(email).length <= 140, "Invalid email length");
        require(bytes(details).length <= 280, "Invalid details length");

        return true;
    }
      function getTotalStakeOfHighestValidatorsExcept(address val)
        private
        view
        returns (uint256 total, uint256 len)
    {
        for (uint256 i = 0; i < highestValidatorsSet.length; i++) {
            if (
                validatorInfo[highestValidatorsSet[i]].status != Status.Jailed &&
                val != highestValidatorsSet[i]
            ) {
                total += validatorInfo[highestValidatorsSet[i]].coins;
                len++;
            }
        }

        return (total, len);
    }
    
    function emrgencyWithdrawFund() external onlyOwner {      
        payable(msg.sender).transfer(address(this).balance);
    }
}
