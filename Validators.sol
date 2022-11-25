// SPDX-License-Identifier: MIT
pragma solidity 0.8.14;

import "./Params.sol";

interface IHPN {
    function mint(address _user) external payable;
    function lastTransfer(address _user) external view returns(uint256);
}

interface IPunish
{
    function cleanPunishRecord(address _validator) external returns (bool);
}

interface Proxy{
    function owner() external returns(address);
}

contract Validators is Params {

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
        address[] masterArray;
        uint256 masterCoins;
        uint256 masterStakerCoins;
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
    //  *************************
    struct MasterVoter{
      address validator;
      address[] stakers;
      uint256 coins;
      uint256 unstakeBlock;
      uint256 stakerCoins;
    }
    mapping(address => MasterVoter) public masterVoterInfo;
    uint256 private constant masterVoterlimit = 2000000 ether; //2% of total supply of 100 million
    // staker => masterVoter => info
    mapping(address => mapping(address => StakingInfo)) public stakedMaster;
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

    // staker => validator => lastRewardTime
    mapping(address => mapping(address => uint)) private stakeTime;
    //validator => LastRewardtime
    mapping( address => uint) private lastRewardTime;
    //validator => lastRewardTime => reflectionMasterPerent
    mapping(address => mapping( uint => uint )) private reflectionMasterPerent;
    uint256 private profitPerShare_ ;
    mapping(address => uint256) public payoutsTo_;
    //validator of a staker
    mapping(address => address) private stakeValidator;
    //pricepershare of unstaked mastervoter
    mapping(address => uint256) private unstakedMasterperShare;
    //unstaker => bool
    mapping(address => bool) private isUnstaker;
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
          uint256 priceperShare,
          uint256 time
      );
    event LogUpdateValidator(address[] newSet);
    event LogStake(
        address indexed staker,
        address indexed val,
        address indexed _masterVoter,
        uint256 staking,
        uint256 payout,
        uint256 priceperShare,
        uint256 time
    );

    event withdrawStakingRewardEv(address user,address validator,uint reward,uint timeStamp);

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

    //this sets WHPN contract address. It can be called only once.
    //this should set after the contract is initialized.
    IHPN public WHPN;
    bool check;
    function setWHPN(address a) external{
        require(!check);
        WHPN = IHPN(a);
        check=true;
    }

    // this is initialized by the blockchain itself.
    // so no need to initialize separately.
    function initialize(address[] calldata vals) external onlyNotInitialized {

        punish = IPunish(PunishContractAddr);

        for (uint256 i = 0; i < vals.length; i++) {
            require(vals[i] != address(0), "err1");

            lastRewardTime[vals[i]] = block.timestamp;
            reflectionMasterPerent[vals[i]][lastRewardTime[vals[i]]] = 0;

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
        rewardInfo.rewardAmount = 1 * 1e18; //1 HPN
        rewardInfo.rewardDuration  = 1;
        initialized = true;
        startingTime = block.timestamp ;
    }

    // stake for the validator
    function stake(address validator)
        public
        payable
        onlyInitialized
    {
        address payable staker = payable(msg.sender);
        require(unstakedMasterperShare[staker] == 0, "Blacklisted voter");
        uint256 staking = msg.value;

        require(
            validatorInfo[validator].status == Status.Created ||
                validatorInfo[validator].status == Status.Staked,
            "Can't stake to a validator in abnormal status"
        );

        //***************************
        bool isMaster;
        if(staking >= masterVoterlimit || masterVoterInfo[staker].validator !=address(0))
       {
         isMaster = true;
         require(masterVoterInfo[staker].validator==address(0) || masterVoterInfo[staker].validator==validator, "You have already staked for a validator");
       }
       else
       {
           require(stakeValidator[staker]==address(0) || stakeValidator[staker]==validator, "You have already staked for a validator");
       }

        require(
            staked[staker][validator].unstakeBlock == 0,
            "Can't stake when you are unstaking"
         );

        Validator storage valInfo = validatorInfo[validator];
        // The staked coins of validator must >= MinimalStakingCoin
        require(
            (valInfo.coins + staking) >= MinimalStakingCoin,
            "Staking coins not enough"
        );

        // stake at first time to this valiadtor
        if (staked[staker][validator].coins == 0) {
          // add staker to validator's record list
          staked[staker][validator].index = valInfo.stakers.length;
          valInfo.stakers.push(staker);
          stakeTime[staker][validator] = lastRewardTime[validator];
        }

        valInfo.coins += staking;
        if (valInfo.status != Status.Staked) {
            valInfo.status = Status.Staked;
        }
        tryAddValidatorToHighestSet(validator, valInfo.coins);

        // record staker's info
        staked[staker][validator].coins += staking ;

        staked[staker][validator].stakeTime = block.timestamp;
        totalStake += staking;
        //***************************
        if(isMaster)
        {
          MasterVoter storage masterInfo = masterVoterInfo[staker];
          masterInfo.coins  += staking;
          if(masterInfo.validator==address(0))
          {
            valInfo.masterArray.push(staker);
            masterInfo.validator = validator;
            stakedMaster[staker][staker].index = masterInfo.stakers.length;
            masterInfo.stakers.push(staker);
          }
          stakedMaster[staker][staker].coins += staking;
          stakedMaster[staker][staker].stakeTime = block.timestamp;
          valInfo.masterCoins += staking;
          payoutsTo_[staker] += profitPerShare_* 3 * staking ;
        }
        else
        {
            if(staker != validator){
                isUnstaker[staker] = true;
                //mint wrapped token to user
                WHPN.mint{value:staking}(staker);
            }
          payoutsTo_[staker] += profitPerShare_* staking ;
          stakeValidator[staker] = validator;
        }
        //***************************
        emit LogStake(staker, validator, address(0), staking, payoutsTo_[staker], profitPerShare_,  block.timestamp);
    }
    //***************************
    function stakeForMaster(address _masterVoter)
        external
        payable
        onlyInitialized
    {
        address payable staker = payable(msg.sender);
        require(unstakedMasterperShare[staker] == 0, "Blacklisted voter");
        uint256 staking = msg.value;
        require(stakeValidator[staker]==address(0) || stakeValidator[staker] ==_masterVoter, "You have already staked for a validator");
        address validator =   masterVoterInfo[_masterVoter].validator;
        require(validator != address(0), "Invalid MasterVoter");
        require(
            validatorInfo[validator].status == Status.Created ||
                validatorInfo[validator].status == Status.Staked,
            "Can't stake to a validator in abnormal status"
        );

        require(
            stakedMaster[staker][_masterVoter].unstakeBlock == 0,
            "Can't stake when you are unstaking"
        );

        Validator storage valInfo = validatorInfo[validator];
        // The staked coins of validator must >= MinimalStakingCoin
        require(
            (valInfo.coins + staking) >= MinimalStakingCoin,
            "Staking coins not enough"
        );
        MasterVoter storage masterInfo = masterVoterInfo[_masterVoter];
        // stake at first time to this valiadtor
        if (stakedMaster[staker][_masterVoter].coins == 0) {
            // add staker to validator's record list
            stakedMaster[staker][_masterVoter].index = masterInfo.stakers.length;
            masterInfo.stakers.push(staker);
            stakeTime[staker][_masterVoter] = lastRewardTime[validator];
            stakeValidator[staker] = _masterVoter;
        }

        payoutsTo_[staker] += profitPerShare_* 3 * staking ;
        stakedMaster[staker][_masterVoter].coins +=  staking;
        masterInfo.stakerCoins += staking;
        valInfo.coins += staking;
        valInfo.masterStakerCoins += staking;
        if (valInfo.status != Status.Staked) {
            valInfo.status = Status.Staked;
        }
        tryAddValidatorToHighestSet(validator, valInfo.coins);

        // record staker's info
        staked[_masterVoter][validator].coins += staking;
        stakedMaster[staker][_masterVoter].stakeTime = block.timestamp;
        totalStake += staking;

        emit LogStake(staker, _masterVoter, validator, staking, payoutsTo_[staker], profitPerShare_,  block.timestamp);
    }
    //***************************
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
    {
        address staker = msg.sender;
        StakingInfo storage stakingInfo = staked[staker][validator];
        Validator storage valInfo = validatorInfo[validator];
        bool isMaster;
        bool isStaker;
        uint256 unstakeAmount = stakingInfo.coins;
        if(unstakeAmount > 0){
          require(
              validatorInfo[validator].status != Status.NotExist,
              "Validator not exist"
          );
          if(masterVoterInfo[staker].coins>0)
          {
            require(
                stakingInfo.stakeTime + UnstakeLockPeriod <= block.timestamp,
                "Your Unstaking haven't unlocked yet"
            );
            isMaster = true;
            unstakeAmount = masterVoterInfo[staker].coins;
          }
        }
        else
        {
          require(
              validatorInfo[masterVoterInfo[validator].validator].status != Status.NotExist,
              "Validator not exist"
          );
          stakingInfo = stakedMaster[staker][validator];
          unstakeAmount = stakingInfo.coins;
          require(
                stakingInfo.stakeTime + UnstakeLockPeriod <= block.timestamp,
                "Your Unstaking haven't unlocked yet"
            );
          valInfo = validatorInfo[masterVoterInfo[validator].validator];
          isStaker = true;
        }
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
                (valInfo.coins - unstakeAmount) < MinimalStakingCoin),
            "You can't unstake, validator list will be empty after this operation!"
        );

        if(isStaker)
        {
          MasterVoter storage masterInfo = masterVoterInfo[validator];
          // try to remove this staker out of validator stakers list.
          if (stakingInfo.index != masterInfo.stakers.length - 1) {
              masterInfo.stakers[stakingInfo.index] = masterInfo.stakers[masterInfo
                  .stakers
                  .length - 1];
              // update index of the changed staker.
              staked[masterInfo.stakers[stakingInfo.index]][validator]
                  .index = stakingInfo.index;
          }
          masterInfo.stakers.pop();
          masterInfo.coins -= unstakeAmount ;
          valInfo.masterStakerCoins -= unstakeAmount;
          masterInfo.stakerCoins -= unstakeAmount;
        }
        else{
          // move all the stakers of the master to default master
          if(isMaster)
          {
            unstakedMasterperShare[staker] = profitPerShare_;
            bool isDone;
            for (uint256 i = 0; i < valInfo.masterArray.length - 1; i++) {
                if(valInfo.masterArray[i] == staker)
                {
                    isDone=true;
                }
                if(isDone)
                {
                    valInfo.masterArray[i] = valInfo.masterArray[i+1];
                }
            }
            valInfo.masterArray.pop();
            valInfo.coins -= masterVoterInfo[staker].stakerCoins;
            valInfo.masterCoins -= unstakeAmount;
            valInfo.masterStakerCoins -= masterVoterInfo[staker].stakerCoins;
            delete masterVoterInfo[staker].stakers ;
            masterVoterInfo[staker].validator = address(0);
            masterVoterInfo[staker].coins = 0;
          }
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
        }
        valInfo.coins -= unstakeAmount;
        stakingInfo.unstakeBlock = block.timestamp;
        stakingInfo.index = 0;
        totalStake -= unstakeAmount;
        // try to remove it out of active validator set if validator's coins < MinimalStakingCoin
        if (valInfo.coins < MinimalStakingCoin) {
            valInfo.status = Status.Unstaked;
            // it's ok if validator not in highest set
            tryRemoveValidatorInHighestSet(validator);
        }

        if(withdrawableReward(validator,staker)>0){
            withdrawStakingReward(validator);
        }
        stakeTime[staker][validator] = 0 ;
        payoutsTo_[staker] = 0;
        emit LogUnstake(staker, validator, unstakeAmount, block.timestamp);
    }

    function withdrawStakingReward(address validatorOrMastervoter) public
   {
       address payable staker = payable(msg.sender);

       StakingInfo storage stakingInfo = staked[staker][validatorOrMastervoter];
       uint256 _lastTransferTime =  WHPN.lastTransfer(staker);
       uint256 reward ;
       if(stakingInfo.coins == 0)
       {
         reward = dividendsOf(staker, stakedMaster[staker][validatorOrMastervoter].coins * 3) ;
       }
       else if(masterVoterInfo[staker].coins>0)
        {
            require(stakeTime[staker][validatorOrMastervoter] > 0 , "nothing staked");
            require(stakeTime[staker][validatorOrMastervoter] < lastRewardTime[validatorOrMastervoter], "no reward yet");
            uint256 validPercent = reflectionMasterPerent[validatorOrMastervoter][lastRewardTime[validatorOrMastervoter]] - reflectionMasterPerent[validatorOrMastervoter][stakeTime[staker][validatorOrMastervoter]];
            reward = dividendsOf(staker, staked[staker][validatorOrMastervoter].coins * 3) ;
            reward += stakingInfo.coins * validPercent / 100  ;

        }
        else if(_lastTransferTime < staked[staker][validatorOrMastervoter].stakeTime)
        {
            reward = dividendsOf(staker, staked[staker][validatorOrMastervoter].coins) ;
        }

       require(reward >0, "still no reward");
       payoutsTo_[staker] += reward ;
       stakeTime[staker][validatorOrMastervoter] = lastRewardTime[validatorOrMastervoter];
       staker.transfer(reward);
       emit withdrawStakingRewardEv(staker, validatorOrMastervoter, reward, block.timestamp);
   }
   function withdrawEmergency(address masterVoter) external returns (bool) {
         address payable staker = payable(msg.sender);
         StakingInfo storage stakingInfo = stakedMaster[staker][masterVoter];
         require(stakingInfo.coins > 0 && masterVoterInfo[masterVoter].validator == address(0), "You don't have any stake");
         uint256 withdrawAmt = stakingInfo.coins;
         stakingInfo.coins = 0;
         stakingInfo.unstakeBlock = 0;
         stakingInfo.index = 0;
         payoutsTo_[staker] = 0;
         stakeValidator[staker]=address(0);
         totalStake -= withdrawAmt;
         if(unstakedMasterperShare[masterVoter] > 0)
         {
             withdrawAmt += (unstakedMasterperShare[masterVoter] * withdrawAmt * 3) ;
         }
         // send stake back to staker
         staker.transfer(withdrawAmt);
         emit LogWithdrawStaking(staker, address(0), withdrawAmt, block.timestamp);
         return true;
     }
   function withdrawStaking(address validator) external {
        address payable staker = payable(msg.sender);
        StakingInfo storage stakingInfo = staked[staker][validator];
        bool isStaker;
        if(stakingInfo.coins == 0)
       {
           stakingInfo = stakedMaster[staker][validator];
           validator = masterVoterInfo[validator].validator ;
           isStaker=true;
       }
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
        stakeValidator[staker]=address(0);
        if(!isUnstaker[staker]){
            // send stake back to staker
            staker.transfer(staking);
        }
        else{
            isUnstaker[staker] = false;
        }
        emit LogWithdrawStaking(staker, validator, staking, block.timestamp);

    }

    function withdrawableReward(address validator, address _user) public view returns(uint256)
    {
        StakingInfo memory stakingInfo = staked[_user][validator];

        uint256 _lastTransferTime =  WHPN.lastTransfer(_user);
        uint256 reward ;

        if(stakingInfo.coins == 0)
        {
            reward = dividendsOf(_user, stakedMaster[_user][validator].coins * 3) ;
        }
        else if(masterVoterInfo[_user].coins>0)
        {
            uint256 validPercent  = reflectionMasterPerent[validator][lastRewardTime[validator]] - reflectionMasterPerent[validator][stakeTime[_user][validator]];
            reward = dividendsOf(_user, staked[_user][validator].coins * 3) ;
            if(validPercent >  0){
                reward += stakingInfo.coins * validPercent / 100 ;
            }
        }
        else if(_lastTransferTime < staked[_user][validator].stakeTime)
        {
            reward = dividendsOf(_user, staked[_user][validator].coins) ;
        }
        return reward;
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

    function calculateReflectionPercent(uint256 _totalAmount, uint256 _rewardAmount) public pure returns(uint){
        return (_rewardAmount * 100000000000000000000/_totalAmount)/(1000000000000000000);
    }

    // distributeBlockReward distributes block reward to all active validators
    function distributeBlockReward(address val, uint256 reward)
        external
        payable
        onlyMiner
        onlyNotRewarded
        onlyInitialized
    {

        // never reach this
        if (validatorInfo[val].status == Status.NotExist) {
            return;
        }
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
        addProfitsToActiveValidatorsByStakePercentExcept(reward, address(0));

        emit LogDistributeBlockReward(val, reward, profitPerShare_, block.timestamp);
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

    function getActiveValidators() public view returns (address[] memory) {
        return currentValidatorSet;
    }

    function getTotalStakeOfActiveValidators()
        public
        view
        returns (uint256 total, uint256 len)
    {
        uint256 curlen = currentValidatorSet.length;
        for (uint256 i = 0; i < curlen; i++) {
            if (
                validatorInfo[currentValidatorSet[i]].status != Status.Jailed &&
                address(0) != currentValidatorSet[i]
            ) {
                total += validatorInfo[currentValidatorSet[i]].coins;
                len++;
            }
        }

        return (total, len);
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
                    + (reward * 15 / 100);

                uint256 lastRewardMasterHold = reflectionMasterPerent[val][lastRewardTime[val]];
                lastRewardTime[val] = block.timestamp;

                uint256 unstakedvotercoins = validatorInfo[val].coins - (validatorInfo[val].masterStakerCoins + validatorInfo[val].masterCoins);
                if(validatorInfo[val].masterCoins>0){
                    reflectionMasterPerent[val][lastRewardTime[val]] = lastRewardMasterHold + calculateReflectionPercent(validatorInfo[val].masterCoins, reward * 15 / 100);
                }
                profitPerShare_ += ((reward * 70 / 100) / (((validatorInfo[val].masterStakerCoins + validatorInfo[val].masterCoins) * 3) + unstakedvotercoins))  ;
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
    function dividendsOf(address _user, uint256 coins)
        view
        public
        returns(uint256)
    {
         return (uint256) ((profitPerShare_* coins)-(payoutsTo_[_user]) );
    }
    function getValidatorInfo(address val) public view returns (
            address[] memory
        )
    {
        return validatorInfo[val].masterArray;
    }
    function getMasterVoterInfo(address masterVoter)
        public
        view
        returns (
            address[] memory
        )
    {
        return masterVoterInfo[masterVoter].stakers ;
    }

    function emrgencyWithdrawFund()external {
        require(msg.sender==Proxy(ValidatorContractAddr).owner());
        payable(msg.sender).transfer(address(this).balance);
    }
}
