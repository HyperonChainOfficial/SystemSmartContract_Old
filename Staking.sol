// SPDX-License-Identifier: MIT
pragma solidity 0.8.14;

contract Params {
    bool public initialized;
    // Validator have to wait StakingLockPeriod blocks to withdraw staking
    uint64 public constant StakingLockPeriod = 864000; //10 days
    // Stakers have to wait UnstakeLockPeriod blocks to withdraw staking
    uint64 public constant UnstakeLockPeriod = 604800;//7 days

    uint256 public constant MinimalStakingCoin = 32 ether;

    modifier onlyInitialized() {
        require(initialized, "Not init yet");
        _;
    }
    modifier onlyNotInitialized() {
        require(!initialized, "Already initialized");
        _;
    }
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

interface IHPN {
    function mint(address _user) external payable;
    function lastTransfer(address _user) external view returns(uint256);
}

interface IValidator
{
    function getValidatorInfo(address _val) external view returns(address payable, uint status,
            uint256,
            uint256,
            uint256,
            uint256,
            address[] memory);
    function getTopValidators() external view returns(address[] memory);
    function getWHPN() external view returns(address);
    function WithdrawProfitPeriod() external view returns(uint64);
}

contract Staking is Params, Ownership {
    struct Validator {
        uint256 coins;
        address[] stakers;
        address[] masterArray;
        uint256 masterCoins;
        uint256 masterStakerCoins;
        uint256 hbIncoming;
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

    // staker => validator => lastRewardTime
    mapping(address => mapping(address => uint)) private stakeTime;
    //validator => LastRewardtime
    mapping( address => uint) private lastRewardTime;
    //validator => lastRewardTime => reflectionMasterPerent
    mapping(address => mapping( uint => uint )) public reflectionMasterPerent;
    uint256 public profitPerShare_ ;
    mapping(address => uint256) public payoutsTo_;
    //validator of a staker
    mapping(address => address) public stakeValidator;
    //pricepershare of unstaked mastervoter
    mapping(address => uint256) public unstakedMasterperShare;
    //unstaker => bool
    mapping(address => bool) public isUnstaker;
    // *****************************
    // staker => validator => info
    mapping(address => mapping(address => StakingInfo)) public staked;

    IValidator public validatorContract;
    IHPN public WHPN ;

    uint256 private constant maxReward = 12000000 ether ; // 12 Million HPN
    uint256 private constant rewardhalftime = 7776000 ; //3 months
    struct RewardInfo
    {
        uint rewardDuration ;
        uint256 rewardAmount ; // 0.25 HPN
        uint256  totalRewardOut ;
    }
    RewardInfo public rewardInfo;
    uint256 startingTime;

    event LogUnstake(
        address indexed staker,
        address indexed val,
        uint256 amount,
        uint256 time
    );

    event LogWithdrawStaking(
        address indexed staker,
        address indexed val,
        uint256 amount,
        uint256 time
    );


    event LogStake(
        address indexed staker,
        address indexed val,
        address indexed _masterVoter,
        uint256 staking,
        uint256 payout,
        uint256 priceperShare,
        uint256 time
    );

    event withdrawStakingRewardEv(address user,address validator,uint reward,uint timeStamp, bool isValidatorWithdraw);

    //this sets WHPN contract address. It can be called only once.
    bool check;
    function setWHPN(address a) external{
        require(!check);
        WHPN = IHPN(a);
        check=true;
    }
    function setValidator(address _valContract) onlyOwner external{
        validatorContract = IValidator(_valContract);
    }
    //initialize the contract
    function initialize() external onlyNotInitialized {
        initialized = true;
        rewardInfo.rewardAmount = 25 * 1e16; //1 HPN
        rewardInfo.rewardDuration  = 1;
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
        (, uint status, uint256 vcoins, , , ,) = validatorContract.getValidatorInfo(validator);

        require(
            status == 1 || status == 2,
            "Can't stake to a validator in abnormal status"
        );

        bool isMaster;
        if(staking >= masterVoterlimit || masterVoterInfo[staker].validator !=address(0))
       {
	     if(isUnstaker[staker])
        {
            unstake(validator);
        }
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
            (valInfo.coins + staking + vcoins) >= MinimalStakingCoin,
            "Staking coins not enough"
        );

        // stake at first time to this valiadtor
        if (staked[staker][validator].coins == 0) {
          // add staker to validator's record list
          staked[staker][validator].index = valInfo.stakers.length;
          valInfo.stakers.push(staker);
        }
        if(lastRewardTime[validator] == 0)
        {
            lastRewardTime[validator] = block.timestamp;
        }
        if(stakeTime[staker][validator]==0)
        {
          stakeTime[staker][validator] = lastRewardTime[validator] ;
        }

        valInfo.coins += staking;

        // record staker's info
        staked[staker][validator].coins += staking ;
        staked[staker][validator].stakeTime = block.timestamp;

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
          isUnstaker[staker] = true;
          //mint wrapped token to user
          WHPN.mint{value:staking}(staker);
          payoutsTo_[staker] += profitPerShare_* staking ;
          stakeValidator[staker] = validator;
        }
        emit LogStake(staker, validator, address(0), staking, payoutsTo_[staker], profitPerShare_,  block.timestamp);
    }

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
        (, uint status, uint256 vcoins, , , ,) = validatorContract.getValidatorInfo(validator);
        require(
            status == 1 || status == 2,
            "Can't stake to a validator in abnormal status"
        );

        require(
            stakedMaster[staker][_masterVoter].unstakeBlock == 0,
            "Can't stake when you are unstaking"
        );

        Validator storage valInfo = validatorInfo[validator];
        // The staked coins of validator must >= MinimalStakingCoin
        require(
            (valInfo.coins + staking + vcoins) >= MinimalStakingCoin,
            "Staking coins not enough"
        );
        MasterVoter storage masterInfo = masterVoterInfo[_masterVoter];
        // stake at first time to this valiadtor
        if (stakedMaster[staker][_masterVoter].coins == 0) {
            // add staker to validator's record list
            stakedMaster[staker][_masterVoter].index = masterInfo.stakers.length;
            masterInfo.stakers.push(staker);
            stakeValidator[staker] = _masterVoter;
        }
        if(lastRewardTime[validator] == 0)
        {
            lastRewardTime[validator] = block.timestamp;
        }
        if(stakeTime[staker][_masterVoter]==0)
        {
          stakeTime[staker][_masterVoter] = lastRewardTime[validator];
        }

        payoutsTo_[staker] += profitPerShare_* 3 * staking ;
        stakedMaster[staker][_masterVoter].coins +=  staking;
        masterInfo.stakerCoins += staking;
        valInfo.coins += staking;
        valInfo.masterStakerCoins += staking;

        // record staker's info
        staked[_masterVoter][validator].coins += staking;
        stakedMaster[staker][_masterVoter].stakeTime = block.timestamp;

        emit LogStake(staker, _masterVoter, validator, staking, payoutsTo_[staker], profitPerShare_,  block.timestamp);
    }



    function unstake(address validator)
        public
        onlyInitialized
    {
        address staker = msg.sender;
        StakingInfo storage stakingInfo = staked[staker][validator];
        Validator storage valInfo = validatorInfo[validator];
        bool isMaster;
        bool isStaker;
        uint256 unstakeAmount = stakingInfo.coins;
        if(unstakeAmount > 0){
            (, uint status, , , , ,) = validatorContract.getValidatorInfo(validator);
          require(
              status != 0,
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
            (, uint status, , , , ,) = validatorContract.getValidatorInfo(masterVoterInfo[validator].validator);
          require(
              status != 0,
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
        if(withdrawableReward(validator,staker)>0){
            withdrawStakingReward(validator);
        }
        if(isStaker)
        {
          MasterVoter storage masterInfo = masterVoterInfo[validator];
          // try to remove this staker out of validator stakers list.
          if (stakingInfo.index != masterInfo.stakers.length - 1) {
              masterInfo.stakers[stakingInfo.index] = masterInfo.stakers[masterInfo
                  .stakers
                  .length - 1];
              // update index of the changed staker.
              stakedMaster[masterInfo.stakers[stakingInfo.index]][validator]
                  .index = stakingInfo.index;
          }
          masterInfo.stakers.pop();
          //masterInfo.coins -= unstakeAmount ;
          valInfo.masterStakerCoins -= unstakeAmount;
          masterInfo.stakerCoins -= unstakeAmount;
        }
        else{
          if(isMaster)
          {
            if(masterVoterInfo[staker].stakers.length > 1){
                unstakedMasterperShare[staker] = profitPerShare_;
            }
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
            MasterVoter storage masterInfo = masterVoterInfo[staker];
            stakedMaster[staker][staker].coins = 0;
            valInfo.masterArray.pop();
            valInfo.coins -= masterInfo.stakerCoins;
            valInfo.masterCoins -= unstakeAmount;
            valInfo.masterStakerCoins -= masterInfo.stakerCoins;
            delete masterVoterInfo[staker].stakers ;
            masterInfo.validator = address(0);
            masterInfo.coins = 0;
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



        stakeTime[staker][validator] = 0 ;
		if(isUnstaker[staker])
          {
               stakingInfo.coins = 0;
               stakingInfo.unstakeBlock = 0;
               stakeValidator[staker]=address(0);
               isUnstaker[staker] = false;
          }
        else{
            stakingInfo.unstakeBlock = block.timestamp;
        }

        stakingInfo.index = 0;
        payoutsTo_[staker] = 0;
        emit LogUnstake(staker, validator, unstakeAmount, block.timestamp);
    }

    function withdrawStakingReward(address validatorOrMastervoter) public
  {
      address payable staker = payable(msg.sender);
      bool success;
      StakingInfo storage stakingInfo = staked[staker][validatorOrMastervoter];
      uint256 _lastTransferTime =  WHPN.lastTransfer(staker);
      uint256 reward ;
      if(validatorInfo[staker].hbIncoming > 0)
       {
           reward = validatorInfo[staker].hbIncoming;
           validatorInfo[staker].hbIncoming = 0;
       }
        (address feeAddr, uint status, ,uint256 vhbIncoming , ,uint256 lastWithdrawProfitsBlock , ) = validatorContract.getValidatorInfo(validatorOrMastervoter);
       if(vhbIncoming > 0 && status != 0 && feeAddr == address(this) && (lastWithdrawProfitsBlock + validatorContract.WithdrawProfitPeriod() <= block.timestamp)){
        reward += vhbIncoming;
        (success, ) = address(validatorContract).call(
            abi.encodeWithSignature("withdrawProfits(address)", staker)
        );
       }
      if(masterVoterInfo[staker].coins>0)
       {
           if(stakingInfo.unstakeBlock==0){
               require(stakeTime[staker][validatorOrMastervoter] > 0 , "nothing staked");
               reward += dividendsOf(staker, masterVoterInfo[staker].coins * 3) /1e18 ;
               if(stakeTime[staker][validatorOrMastervoter] < lastRewardTime[validatorOrMastervoter]){
                   uint256 validPercent = reflectionMasterPerent[validatorOrMastervoter][lastRewardTime[validatorOrMastervoter]] - reflectionMasterPerent[validatorOrMastervoter][stakeTime[staker][validatorOrMastervoter]];
                   reward += stakingInfo.coins * validPercent / 100  ;
               }
           }
       }
      else if(stakingInfo.coins == 0 && stakedMaster[staker][validatorOrMastervoter].coins>0)
      {
           if(stakedMaster[staker][validatorOrMastervoter].unstakeBlock==0){
               reward += dividendsOf(staker, stakedMaster[staker][validatorOrMastervoter].coins * 3) /1e18;
           }
      }
       else if(_lastTransferTime < stakingInfo.stakeTime && isUnstaker[staker])
       {
           if(stakingInfo.unstakeBlock==0){
               reward += dividendsOf(staker, stakingInfo.coins) /1e18 ;
           }
       }

      require(reward >0, "still no reward");
      payoutsTo_[staker] += reward * 1e18 ;
      stakeTime[staker][validatorOrMastervoter] = lastRewardTime[validatorOrMastervoter];
      staker.transfer(reward);
      emit withdrawStakingRewardEv(staker, validatorOrMastervoter, reward, block.timestamp, success);
  }
   function withdrawEmergency(address masterVoter) external  {
         address payable staker = payable(msg.sender);
         StakingInfo storage stakingInfo = stakedMaster[staker][masterVoter];
         require(stakingInfo.coins > 0 && masterVoterInfo[masterVoter].validator == address(0), "You don't have any stake");
         uint256 withdrawAmt = stakingInfo.coins;
         stakingInfo.coins = 0;
         stakingInfo.unstakeBlock = 0;
         stakingInfo.index = 0;
         payoutsTo_[staker] = 0;
         stakeValidator[staker]=address(0);
         if(unstakedMasterperShare[masterVoter] > 0)
         {
             withdrawAmt += (unstakedMasterperShare[masterVoter] * withdrawAmt * 3) / 1e18 ;
         }
         // send stake back to staker
         staker.transfer(withdrawAmt);
         emit LogWithdrawStaking(staker, address(0), withdrawAmt, block.timestamp);
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
	    require(stakingInfo.coins > 0, "You don't have any stake");
        (, uint status, , , , , ) = validatorContract.getValidatorInfo(validator);
        require(
            status != 0,
            "validator not exist"
        );
        require(stakingInfo.unstakeBlock != 0, "You have to unstake first");
        // Ensure staker can withdraw his staking back
        require(
            stakingInfo.unstakeBlock + StakingLockPeriod <= block.timestamp,
            "Your staking haven't unlocked yet"
        );

        uint256 staking = stakingInfo.coins;
        stakingInfo.coins = 0;
        stakingInfo.unstakeBlock = 0;
        stakeValidator[staker]=address(0);

        // send stake back to staker
        staker.transfer(staking);

        emit LogWithdrawStaking(staker, validator, staking, block.timestamp);

    }

    function withdrawableReward(address validator, address _user) public view returns(uint256)
    {
        StakingInfo memory stakingInfo = staked[_user][validator];

        uint256 _lastTransferTime =  WHPN.lastTransfer(_user);
        uint256 reward ;

        if(masterVoterInfo[_user].coins>0)
        {
             if(stakingInfo.unstakeBlock==0){
                uint256 validPercent  = reflectionMasterPerent[validator][lastRewardTime[validator]] - reflectionMasterPerent[validator][stakeTime[_user][validator]];
                reward = dividendsOf(_user, masterVoterInfo[_user].coins * 3) / 1e18 ;
                if(validPercent >  0){
                    reward += stakingInfo.coins * validPercent / 100 ;
                }
             }
        }
        else if(stakingInfo.coins == 0 && stakedMaster[_user][validator].coins>0)
        {
             if(stakedMaster[_user][validator].unstakeBlock==0){
                reward = dividendsOf(_user, stakedMaster[_user][validator].coins * 3) / 1e18  ;
             }
        }
        else if(_lastTransferTime < stakingInfo.stakeTime)
        {
            if(stakingInfo.unstakeBlock==0){
                reward = dividendsOf(_user, stakingInfo.coins) / 1e18 ;
            }
        }

        //check if user is a validator
        if(validatorInfo[_user].hbIncoming > 0)
        {
            reward += validatorInfo[_user].hbIncoming;
        }
        (address feeAddr, uint status, ,uint256 vhbIncoming , ,uint256 lastWithdrawProfitsBlock , ) = validatorContract.getValidatorInfo(_user);
        if(vhbIncoming > 0 && status != 0 && feeAddr == address(this) && (lastWithdrawProfitsBlock + validatorContract.WithdrawProfitPeriod() <= block.timestamp)){
            reward += vhbIncoming;
       }
        return reward;
    }

    function calculateReflectionPercent(uint256 _totalAmount, uint256 _rewardAmount) public pure returns(uint){
        return (_rewardAmount * 100000000000000000000/_totalAmount)/(1000000000000000000);
    }

    // distributeBlockReward distributes block reward to all active validators
    function distributeBlockReward() external payable
    {
        require(msg.sender == address(validatorContract) || msg.sender == owner(), "Invalid caller");
        uint256 reward = msg.value;
        // Jailed validator can't get profits.
        if(rewardInfo.totalRewardOut < maxReward){
            uint256 modDuration = (block.timestamp - startingTime) / rewardhalftime;
            if(modDuration != rewardInfo.rewardDuration && modDuration >= 1)
            {
              rewardInfo.rewardDuration = rewardInfo.rewardDuration + 1;
              rewardInfo.rewardAmount = rewardInfo.rewardAmount/2;
            }
            reward += rewardInfo.rewardAmount;
            rewardInfo.totalRewardOut += rewardInfo.rewardAmount;
        }
        addProfitsToActiveValidatorsByStakePercentExcept(reward);

    }

    function setValidators(address[] memory vals) external
    {
        require(msg.sender == address(validatorContract) || msg.sender == owner(), "Invalid caller");
        for (uint256 i = 0; i < vals.length; i++) {
            lastRewardTime[vals[i]] = block.timestamp;
            reflectionMasterPerent[vals[i]][lastRewardTime[vals[i]]] = 0;
        }
    }

    // add profits to all validators by stake percent except the punished validator or jailed validator
    function addProfitsToActiveValidatorsByStakePercentExcept(
        uint256 totalReward
    ) private {
        if (totalReward > 0) {
        uint256 totalRewardStake;
        uint256 rewardValsLen;
        (
            totalRewardStake,
            rewardValsLen
        ) = getTotalStakeOfHighestValidatorsExcept();

            if (rewardValsLen > 0) {
                address[] memory highestValidatorsSet= validatorContract.getTopValidators();

                if (totalRewardStake == 0) {
                    uint256 per = totalReward/rewardValsLen;
                    uint256 remain = totalReward - (per*rewardValsLen);
                    address last;
                    for (uint256 i = 0; i < highestValidatorsSet.length; i++) {
                        address val = highestValidatorsSet[i];
                        (, uint status, , , , ,) = validatorContract.getValidatorInfo(val);
                        if (
                            status != 5 && validatorInfo[val].coins > 0
                        ) {
                            validatorInfo[val].hbIncoming = validatorInfo[val]
                                .hbIncoming + (per*15/100);
                            uint256 lastRewardMasterHold = reflectionMasterPerent[val][lastRewardTime[val]];
                            lastRewardTime[val] = block.timestamp;

                            uint256 unstakedvotercoins = validatorInfo[val].coins - (validatorInfo[val].masterStakerCoins + validatorInfo[val].masterCoins);
                            if(validatorInfo[val].masterCoins>0){
                                reflectionMasterPerent[val][lastRewardTime[val]] = lastRewardMasterHold + calculateReflectionPercent(validatorInfo[val].masterCoins, per * 15 / 100);
                            }
                            profitPerShare_ += (((per * 70 / 100) * 1e18) / (((validatorInfo[val].masterStakerCoins + validatorInfo[val].masterCoins) * 3) + unstakedvotercoins))  ;
                            last = val;
                        }
                    }

                    if (remain > 0 && last != address(0)) {
                        validatorInfo[last].hbIncoming = validatorInfo[last]
                            .hbIncoming + remain;
                    }
                }
                else{
                    for (uint256 i = 0; i < highestValidatorsSet.length; i++) {
                        address val = highestValidatorsSet[i];
                        (, uint status, uint256 vcoins, , , ,) = validatorContract.getValidatorInfo(val);
                        if (
                            status != 5 && validatorInfo[val].coins > 0
                        ) {
                            uint256 reward = totalReward * (validatorInfo[val].coins + vcoins) / totalRewardStake;
                            validatorInfo[val].hbIncoming = validatorInfo[val]
                                .hbIncoming + (reward*15/100);
                            uint256 lastRewardMasterHold = reflectionMasterPerent[val][lastRewardTime[val]];
                            lastRewardTime[val] = block.timestamp;

                            uint256 unstakedvotercoins = validatorInfo[val].coins - (validatorInfo[val].masterStakerCoins + validatorInfo[val].masterCoins);
                            if(validatorInfo[val].masterCoins>0){
                                reflectionMasterPerent[val][lastRewardTime[val]] = lastRewardMasterHold + calculateReflectionPercent(validatorInfo[val].masterCoins, reward * 15 / 100);
                            }
                            profitPerShare_ += (((reward * 70 / 100) * 1e18) / (((validatorInfo[val].masterStakerCoins + validatorInfo[val].masterCoins) * 3) + unstakedvotercoins))  ;
                        }

                    }
                }
            }
        }
    }


    function dividendsOf(address _user, uint256 coins)
        view
        public
        returns(uint256)
    {
         return (uint256) (((profitPerShare_) * coins)-(payoutsTo_[_user])) ;
    }
    function getValidatorInfo(address val) public view returns (
            address[] memory, address[] memory
        )
    {
        return (validatorInfo[val].masterArray, validatorInfo[val].stakers);
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
    function getTotalStakeOfHighestValidatorsExcept()
        public
        view
        returns (uint256 total, uint256 len)
    {
        address[] memory highestValidatorsSet= validatorContract.getTopValidators();
        for (uint256 i = 0; i < highestValidatorsSet.length; i++) {
            (, uint status, uint256 vcoins, , , ,) = validatorContract.getValidatorInfo(highestValidatorsSet[i]);
            if ( status != 5 ) {
                total += vcoins + validatorInfo[highestValidatorsSet[i]].coins;
                len++;
            }
        }

        return (total, len);
    }

    function emrgencyWithdrawFund() external onlyOwner {
        payable(msg.sender).transfer(address(this).balance);
    }

    receive() external payable {}
}
