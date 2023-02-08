// SPDX-License-Identifier: None

pragma solidity 0.8.17;

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
        emit OwnershipTransferred(oldOwner,  newOwner);
    }
}

// Interface for validaator smart contract
interface IValidator
{
    function getValidatorInfo(address _val) external view returns(address payable, uint status,
            uint256,
            uint256,
            uint256,
            uint256,
            address[] memory);
    function getTopValidators() external view returns(address[] memory);
    function WithdrawProfitPeriod() external view returns(uint64);
}

contract HyperonChainStaking is Ownership {

    // Structure to store master settings of Staking Contract
    struct StakingSetting{
        uint startBlockReward;              // Starting Block Rewards for Per Block
        uint rewardsBlock;                  // Count of rewards distributed blocks
        uint halvingInterval;               // rewards decrement blocks time
        uint totalRewards;                  // totalRewards for distribution
        uint distributedBlockRewards;       // total distributed block rewards
        uint distributedNetworkRewards;     // total distributed network rewards(including validator rewards distributed from validator contract)
        uint minimumStaking;                // minimum nonmaster staking requirements
        uint minimumMasterStaking;          // minimum master staking requirements
        uint withdrawLockPeriod;            // withdrawal duration after unstaking of master & staked coins. Not applicable for nonstaked coins
    }

    // Nested Structure to store Master, Staked and Non-Staked Holding of Users
    struct BalanceMapping{
        uint stakedCoins;       // staked coins count
        uint unstakedCoins;     // unstaked coins count
        int payoutCoins;        // profit already paid to user. Can go negative on upgrade from unstaked to master or staked to master which is adjusted while rewards withdrawal
        uint unstakedTime;      // time of unstaking
    }

    struct WalletLedger{
        uint totalCoins;        // total coins staked by wallet
        uint totalMasterCoins;  // total coins staked by staked users unders this master wallet(applicable only if its master wallet)

        uint validatorRewards;  // validator rewards stored if this wallet is validator
        uint masterRewards;     // master rewards stored if this wallet is master

        address validator;      // validator of this wallet
        address master;         // master of this wallet. 0x if this wallet itself is master or 0x if this wallet in nonStaked voter

        BalanceMapping MasterBalance;       // store staked coins info for Master Staking
        BalanceMapping StakedBalance;       // store staked coins info for staked Staking
        BalanceMapping NonStakedBalance;    //  store staked coins info for NonStaked staking

        address[] stakers;           // List of stakers under this validator
    }

    struct Validator{
        uint totalCoins;            // store info of total coins under this validator(included master, staked and non staked voters)

        uint totalMasterCoins;      // store info of master coins under this validator
        uint totalStakedCoins;      // store info of staked coins under this validator
        uint totalNonStakedCoins;   // store info of non-staked coins under this validator

        uint rewardPerCoins;        // current rewardPerCoin of this validator

        address[] master;           // List of master under this validator

    }

    event LogRewardsAdded(address indexed _from, uint amount);
    event LogMaster(address indexed _from, address indexed validator, uint amount);
    event LogStaking(address indexed _from, address indexed validator, address indexed master, uint amount);
    event LogNonStaking(address indexed _from, address indexed validator, uint amount);
    event LogWithdrawReward(address indexed _from, uint amount);
    event LogUnstake(address indexed _from, address indexed validator, uint amount);
    event LogWithdraw(address indexed _from, uint amount);

    StakingSetting _stakingSettings;                    // variable for stakingsetting struct
    mapping (address => WalletLedger) _walletLedger;    // variable for walletledger struct
    mapping (address => Validator) _Validator;          // variable for validator struct
    mapping (uint => bool) _blockRewardDistributed;     // variable for block reward distribution status

    IValidator public validatorContract;                // interface for validator smart contract

    // contructor for smart contract
    constructor(address _valContract, uint startBlockReward, uint halvingInterval, uint minimumStaking, uint minimumMasterStaking, uint withdrawLock){
        _stakingSettings.startBlockReward = startBlockReward;           // setting first block rewards
        _stakingSettings.halvingInterval = halvingInterval;             // setting halving rewards
        _stakingSettings.minimumStaking = minimumStaking;               // setting minimum staking requirement
        _stakingSettings.minimumMasterStaking = minimumMasterStaking;   // setting minimum master requirement
        _stakingSettings.withdrawLockPeriod = withdrawLock;             // setting withdraw lock period after unstaking
        validatorContract = IValidator(_valContract);                   // setting validator contract in interface
    }

    // set validator smart contract address
    function setValidator(address _valContract) onlyOwner external{
        require(_valContract != address(0), "Wallet 0x cann't be set as validator address");
        validatorContract = IValidator(_valContract);
    }

    // set minimum master staking requirements
    function setMinimumMasterStaking(uint amount) external onlyOwner returns(bool success){
        require(amount>0, "Minimum Master Staking Requirement Can't Be Zero");
        _stakingSettings.minimumMasterStaking = amount;
        return true;
    }

    // set withdraw lock period after unstaking
    function setWithdrawLockPeriod(uint time) external onlyOwner returns(bool success){
        _stakingSettings.withdrawLockPeriod = time;
        return true;
    }

    // get current master setting
    function getSettings() public view returns(uint startBlockReward, uint rewardsBlock, uint halvingInterval, uint totalRewards, uint distributedBlockRewards, uint distributedNetworkRewards, uint minimumStaking, uint minimumMasterStaking, uint withdrawLockPeriod, uint _currentBlockReward){
        uint _currentBlockRewards = (_stakingSettings.startBlockReward / ((_stakingSettings.rewardsBlock/_stakingSettings.halvingInterval) + 1));

        if (_stakingSettings.totalRewards < (_stakingSettings.distributedBlockRewards + _currentBlockRewards)){
            _currentBlockRewards = 0;
        }

        return(_stakingSettings.startBlockReward, _stakingSettings.rewardsBlock, _stakingSettings.halvingInterval, _stakingSettings.totalRewards, _stakingSettings.distributedBlockRewards, _stakingSettings.distributedNetworkRewards, _stakingSettings.minimumStaking, _stakingSettings.minimumMasterStaking, _stakingSettings.withdrawLockPeriod, _currentBlockRewards);
    }

    // get validator details
    function getValidatorSummary(address _validatorAddress) public view returns(uint totalCoins, uint totalMasterCoins, uint totalStakedCoins, uint totalNonStakedCoins, uint rewardPerCoins, address[] memory master, address[] memory stakers){
        return(_Validator[_validatorAddress].totalCoins, _Validator[_validatorAddress].totalMasterCoins, _Validator[_validatorAddress].totalStakedCoins, _Validator[_validatorAddress].totalNonStakedCoins, _Validator[_validatorAddress].rewardPerCoins/1e18, _Validator[_validatorAddress].master, _walletLedger[_validatorAddress].stakers);
    }

    function getStakers(address _validatorAddress) public view returns(uint)
    {
        return _walletLedger[_validatorAddress].stakers.length;
    }
    // get wallet details
    function getWalletSummary(address walletAddress) public view returns(bool isMaster, address validator, address master, uint totalCoins, uint totalStakedCoinsInMasterWallet, int rewards){

        // check is coin is staked under master and if yes mark _isMaster=true
        bool _isMaster;
        if (_walletLedger[walletAddress].MasterBalance.stakedCoins > 0){
            _isMaster = true;
        }

        address _validatorOfUser = _walletLedger[walletAddress].validator;  // read validator under which user staked to get rewardPerCoins
        int _profit = 0;

        //Calculate Master Profit if staked under master
        if (_walletLedger[walletAddress].MasterBalance.stakedCoins > 0){
            _profit = _profit + ((int)(_walletLedger[walletAddress].MasterBalance.stakedCoins * (_Validator[_validatorOfUser].rewardPerCoins* 3)/1e18)  - _walletLedger[walletAddress].MasterBalance.payoutCoins);
        }
        //Calculate Master Profit if staked under staked
        if (_walletLedger[walletAddress].StakedBalance.stakedCoins > 0){
            _profit = _profit + ((int)(_walletLedger[walletAddress].StakedBalance.stakedCoins * (_Validator[_validatorOfUser].rewardPerCoins* 3)/1e18)  - _walletLedger[walletAddress].StakedBalance.payoutCoins);
        }
        //Calculate Master Profit if staked under nonstaked
        if (_walletLedger[walletAddress].NonStakedBalance.stakedCoins > 0){
            _profit = _profit + ((int)(_walletLedger[walletAddress].NonStakedBalance.stakedCoins * _Validator[_validatorOfUser].rewardPerCoins/1e18) - _walletLedger[walletAddress].NonStakedBalance.payoutCoins);
        }
        //add validator reward(if same wallet is validator
        _profit = _profit + (int) (_walletLedger[walletAddress].validatorRewards);
        //add master reward if wallet is master
        _profit = _profit + (int) (_walletLedger[walletAddress].masterRewards);

        return(_isMaster, _walletLedger[walletAddress].validator, _walletLedger[walletAddress].master, _walletLedger[walletAddress].totalCoins, _walletLedger[walletAddress].totalMasterCoins, _profit);
    }

    // get staking summary of wallet - staked coins details
    function getWalletStakingSummary(address walletAddress) public view returns(uint masterStakedCoins, uint stakedCoins, uint nonStakedCoins){
        return(_walletLedger[walletAddress].MasterBalance.stakedCoins, _walletLedger[walletAddress].StakedBalance.stakedCoins, _walletLedger[walletAddress].NonStakedBalance.stakedCoins);
    }

    // get details of unstaked coins along with time
    function unWalletStakingSummary(address walletAddress) public view returns(uint masterUnstakedCoins, uint stakedUnstakedCoins, uint nonStakedUnstakedCoins, uint masterUnstakedTime, uint stakedUnstakedTime, uint nonStakedUnstakedTime){
        return(_walletLedger[walletAddress].MasterBalance.unstakedCoins, _walletLedger[walletAddress].StakedBalance.unstakedCoins, _walletLedger[walletAddress].NonStakedBalance.stakedCoins, _walletLedger[walletAddress].MasterBalance.unstakedTime, _walletLedger[walletAddress].StakedBalance.unstakedTime, block.timestamp - _stakingSettings.withdrawLockPeriod);
    }

    // emergency withdraw coins
    function emergencyWithdraw() external onlyOwner {
        payable(msg.sender).transfer(address(this).balance);
    }

  
   // Master & Non-Staker
    function stake(address validator) public payable returns(bool success){      
        if(_walletLedger[msg.sender].totalCoins > 0){
            withdrawStakingReward(); // withdraw rewards if any - for unstaked coins
        }   
        (, uint status, , , , ,) = validatorContract.getValidatorInfo(validator); // get validator status
        require(_walletLedger[msg.sender].MasterBalance.unstakedCoins == 0 && _walletLedger[msg.sender].StakedBalance.unstakedCoins == 0 , "You are in unstake mode");
        require(status == 1 || status == 2, "Can't stake to a validator in abnormal status");
        require(_walletLedger[msg.sender].validator == address(0) || _walletLedger[msg.sender].validator == validator, "Wallet is part of other validator" );
        require(msg.value >= _stakingSettings.minimumStaking, "Minimum Staking Requirement Doesn't Meet");

        // If transaction value qualify for Master voter Add in Master Voter
        if (msg.value >= _stakingSettings.minimumMasterStaking && _walletLedger[msg.sender].validator == address(0)){
            _walletLedger[msg.sender].totalCoins = _walletLedger[msg.sender].totalCoins + msg.value;
            _walletLedger[msg.sender].totalMasterCoins = _walletLedger[msg.sender].totalMasterCoins + msg.value;
            //_walletLedger[msg.sender].validator = validator;
            _walletLedger[msg.sender].MasterBalance.stakedCoins = _walletLedger[msg.sender].MasterBalance.stakedCoins + msg.value;
            _walletLedger[msg.sender].MasterBalance.payoutCoins = _walletLedger[msg.sender].MasterBalance.payoutCoins + (int)(msg.value * (_Validator[validator].rewardPerCoins* 3)/1e18) ;
            _Validator[validator].totalCoins = _Validator[validator].totalCoins + msg.value;
            _Validator[validator].totalMasterCoins = _Validator[validator].totalMasterCoins + msg.value;

            //if (_walletLedger[msg.sender].validator == address(0)){
                _walletLedger[msg.sender].validator = validator;
                _Validator[validator].master.push(msg.sender);
                _walletLedger[validator].stakers.push(msg.sender);
           // }
            emit LogMaster(msg.sender, validator, msg.value);
            return true;
        }
        // Already part of Master and TopUp New Staked Coins to Master
        else if (_walletLedger[msg.sender].validator == validator && _walletLedger[msg.sender].MasterBalance.stakedCoins >= _stakingSettings.minimumMasterStaking){
            _walletLedger[msg.sender].totalCoins = _walletLedger[msg.sender].totalCoins + msg.value;
            _walletLedger[msg.sender].totalMasterCoins = _walletLedger[msg.sender].totalMasterCoins + msg.value;
            _walletLedger[msg.sender].MasterBalance.stakedCoins = _walletLedger[msg.sender].MasterBalance.stakedCoins + msg.value;
            _walletLedger[msg.sender].MasterBalance.payoutCoins = _walletLedger[msg.sender].MasterBalance.payoutCoins + (int)(msg.value * (_Validator[validator].rewardPerCoins* 3)/1e18) ;
            _Validator[validator].totalCoins = _Validator[validator].totalCoins + msg.value;
            _Validator[validator].totalMasterCoins = _Validator[validator].totalMasterCoins + msg.value;
            emit LogMaster(msg.sender, validator, msg.value);
            return true;
        }
        // If transaction value + previous non staked balance qualify for Master voter upgrade them to Master
        else if ((_walletLedger[msg.sender].totalCoins + msg.value) >= _stakingSettings.minimumMasterStaking){
            if (_walletLedger[msg.sender].NonStakedBalance.stakedCoins > 0){
                // Move NonStaked Balance to Master
                _walletLedger[msg.sender].MasterBalance.stakedCoins = _walletLedger[msg.sender].MasterBalance.stakedCoins + _walletLedger[msg.sender].NonStakedBalance.stakedCoins ;
                _walletLedger[msg.sender].MasterBalance.payoutCoins = _walletLedger[msg.sender].MasterBalance.payoutCoins + (int)((_walletLedger[msg.sender].NonStakedBalance.stakedCoins) * (_Validator[validator].rewardPerCoins* 3)/1e18) ;

                _walletLedger[msg.sender].totalMasterCoins = _walletLedger[msg.sender].totalMasterCoins + _walletLedger[msg.sender].NonStakedBalance.stakedCoins;
                _walletLedger[msg.sender].NonStakedBalance.payoutCoins = _walletLedger[msg.sender].NonStakedBalance.payoutCoins - (int)((_walletLedger[msg.sender].NonStakedBalance.stakedCoins * _Validator[validator].rewardPerCoins)/1e18);
                _Validator[validator].totalMasterCoins = _Validator[validator].totalMasterCoins + _walletLedger[msg.sender].NonStakedBalance.stakedCoins;
                _Validator[validator].totalNonStakedCoins = _Validator[validator].totalNonStakedCoins - _walletLedger[msg.sender].NonStakedBalance.stakedCoins;
                _walletLedger[msg.sender].NonStakedBalance.stakedCoins = 0;
            }
            else  if (_walletLedger[msg.sender].StakedBalance.stakedCoins > 0){
                // Move NonStaked Balance to Master
                _walletLedger[msg.sender].MasterBalance.stakedCoins = _walletLedger[msg.sender].MasterBalance.stakedCoins + _walletLedger[msg.sender].StakedBalance.stakedCoins ;
                _walletLedger[msg.sender].MasterBalance.payoutCoins = _walletLedger[msg.sender].MasterBalance.payoutCoins + (int)((_walletLedger[msg.sender].StakedBalance.stakedCoins) * (_Validator[validator].rewardPerCoins* 3)/1e18) ;

                _walletLedger[msg.sender].totalMasterCoins = _walletLedger[msg.sender].totalMasterCoins + _walletLedger[msg.sender].StakedBalance.stakedCoins;
                _walletLedger[msg.sender].StakedBalance.payoutCoins = _walletLedger[msg.sender].StakedBalance.payoutCoins - (int)((_walletLedger[msg.sender].StakedBalance.stakedCoins * _Validator[validator].rewardPerCoins* 3)/1e18);
                _Validator[validator].totalMasterCoins = _Validator[validator].totalMasterCoins + _walletLedger[msg.sender].StakedBalance.stakedCoins;
                _Validator[validator].totalStakedCoins = _Validator[validator].totalStakedCoins - _walletLedger[msg.sender].StakedBalance.stakedCoins;
                _walletLedger[msg.sender].StakedBalance.stakedCoins = 0;
            }

            // Add new balance to Master
            _walletLedger[msg.sender].totalCoins = _walletLedger[msg.sender].totalCoins + msg.value;
            _walletLedger[msg.sender].totalMasterCoins = _walletLedger[msg.sender].totalMasterCoins + msg.value;

            //_walletLedger[msg.sender].validator = validator;
            _walletLedger[msg.sender].MasterBalance.stakedCoins = _walletLedger[msg.sender].MasterBalance.stakedCoins + msg.value;
            _walletLedger[msg.sender].MasterBalance.payoutCoins = _walletLedger[msg.sender].MasterBalance.payoutCoins + (int)(msg.value * (_Validator[validator].rewardPerCoins* 3)/1e18) ;
            _Validator[validator].totalCoins = _Validator[validator].totalCoins + msg.value;
            _Validator[validator].totalMasterCoins = _Validator[validator].totalMasterCoins + msg.value;
            _Validator[validator].master.push(msg.sender);
            if (_walletLedger[msg.sender].validator == address(0)){                
                _walletLedger[msg.sender].validator = validator;                
                _walletLedger[validator].stakers.push(msg.sender);
            }
            if (_walletLedger[msg.sender].master != address(0)){                
               bool isDone= false;
                for (uint256 i = 0; i < _walletLedger[_walletLedger[msg.sender].master].stakers.length - 1; i++) {
                    if(_walletLedger[_walletLedger[msg.sender].master].stakers[i] == msg.sender)
                    {
                        isDone=true;
                    }
                    if(isDone)
                    {
                        _walletLedger[_walletLedger[msg.sender].master].stakers[i] = _walletLedger[_walletLedger[msg.sender].master].stakers[i+1];
                    }
                }
                _walletLedger[_walletLedger[msg.sender].master].stakers.pop();
                _walletLedger[msg.sender].master = address(0);
            }
            emit LogMaster(msg.sender, validator, msg.value);
            return true;
        }
        
        // Add to Non-Staked
        else{
            _walletLedger[msg.sender].totalCoins = _walletLedger[msg.sender].totalCoins + msg.value;
           // _walletLedger[msg.sender].validator = validator;
           if (_walletLedger[msg.sender].master != address(0)){
               _walletLedger[msg.sender].StakedBalance.stakedCoins = _walletLedger[msg.sender].StakedBalance.stakedCoins + msg.value;
               _walletLedger[msg.sender].StakedBalance.payoutCoins = _walletLedger[msg.sender].StakedBalance.payoutCoins + (int)((msg.value * _Validator[validator].rewardPerCoins * 3)/1e18);
               _Validator[validator].totalStakedCoins = _Validator[validator].totalStakedCoins + msg.value;               
               _walletLedger[_walletLedger[msg.sender].master].totalMasterCoins = _walletLedger[_walletLedger[msg.sender].master].totalMasterCoins + msg.value;
               emit LogStaking(msg.sender, validator, _walletLedger[msg.sender].master, msg.value);
           }
           else
           {
               _walletLedger[msg.sender].NonStakedBalance.stakedCoins = _walletLedger[msg.sender].NonStakedBalance.stakedCoins + msg.value;
               _walletLedger[msg.sender].NonStakedBalance.payoutCoins = _walletLedger[msg.sender].NonStakedBalance.payoutCoins + (int)(msg.value * _Validator[validator].rewardPerCoins/1e18);
               _Validator[validator].totalNonStakedCoins = _Validator[validator].totalNonStakedCoins + msg.value;
               emit LogNonStaking(msg.sender, validator, msg.value);
           }
            _Validator[validator].totalCoins = _Validator[validator].totalCoins + msg.value;
            
            if (_walletLedger[msg.sender].validator == address(0)){
                _walletLedger[msg.sender].validator = validator;
                _walletLedger[validator].stakers.push(msg.sender);
            }
            
            return true;
        }
    }

    // Master & Staker
    function stakeForMaster(address master) public payable returns(bool success){  
        if(_walletLedger[msg.sender].totalCoins > 0){
            withdrawStakingReward(); // withdraw rewards if any - for unstaked coins
        }     
        address _validatorOfMaster = _walletLedger[master].validator;
        (, uint status, , , , ,) = validatorContract.getValidatorInfo(_validatorOfMaster);
        require(_walletLedger[msg.sender].MasterBalance.unstakedCoins == 0 && _walletLedger[msg.sender].StakedBalance.unstakedCoins == 0 , "You are in unstake mode");
        require(_walletLedger[master].MasterBalance.stakedCoins >= _stakingSettings.minimumMasterStaking, "Can't stake to a Master in abnormal status");
        require(status == 1 || status == 2, "Can't stake to a validator in abnormal status");
        require((_walletLedger[msg.sender].master == address(0) && _walletLedger[msg.sender].validator == address(0)) || (_walletLedger[msg.sender].master == master && _walletLedger[msg.sender].validator == _validatorOfMaster), "Wallet is part of other master/validator" );        
        require(msg.value >= _stakingSettings.minimumStaking, "Minimum Staking Requirement Doesn't Meet");
        // Wallet is qualify for master and upgrade it
        if ((_walletLedger[msg.sender].StakedBalance.stakedCoins + msg.value) >= _stakingSettings.minimumMasterStaking){
            // move existing coin from other master to own
            _walletLedger[_walletLedger[msg.sender].master].totalMasterCoins = _walletLedger[_walletLedger[msg.sender].master].totalMasterCoins - _walletLedger[msg.sender].StakedBalance.stakedCoins;
            _walletLedger[msg.sender].totalMasterCoins = _walletLedger[msg.sender].totalMasterCoins + _walletLedger[msg.sender].StakedBalance.stakedCoins + msg.value;
            _Validator[_validatorOfMaster].totalStakedCoins = _Validator[_validatorOfMaster].totalStakedCoins - _walletLedger[msg.sender].StakedBalance.stakedCoins;


            _Validator[_validatorOfMaster].totalMasterCoins = _Validator[_validatorOfMaster].totalMasterCoins + _walletLedger[msg.sender].StakedBalance.stakedCoins + msg.value;
            _walletLedger[msg.sender].MasterBalance.stakedCoins = _walletLedger[msg.sender].MasterBalance.stakedCoins + _walletLedger[msg.sender].StakedBalance.stakedCoins + msg.value;
            _walletLedger[msg.sender].MasterBalance.payoutCoins = _walletLedger[msg.sender].MasterBalance.payoutCoins + (int)((msg.value + _walletLedger[msg.sender].StakedBalance.stakedCoins) * (_Validator[_validatorOfMaster].rewardPerCoins* 3)/1e18) ;

            _walletLedger[msg.sender].StakedBalance.payoutCoins = 0;//_walletLedger[msg.sender].StakedBalance.payoutCoins - (int)(_walletLedger[msg.sender].StakedBalance.stakedCoins * (_Validator[_validatorOfMaster].rewardPerCoins* 3)/1e18);
            _walletLedger[msg.sender].StakedBalance.stakedCoins = 0;
            _walletLedger[msg.sender].totalCoins = _walletLedger[msg.sender].totalCoins + msg.value;
            _Validator[_validatorOfMaster].totalCoins = _Validator[_validatorOfMaster].totalCoins + msg.value;            
            
            if (_walletLedger[msg.sender].master != address(0)){
                // add new coins to own master details
                //_walletLedger[msg.sender].totalMasterCoins = _walletLedger[msg.sender].totalMasterCoins + msg.value;
                //_walletLedger[msg.sender].MasterBalance.payoutCoins = _walletLedger[msg.sender].MasterBalance.payoutCoins + (int)(msg.value * (_Validator[_validatorOfMaster].rewardPerCoins* 3)/1e18) ;
                bool isDone= false;
                for (uint256 i = 0; i < _walletLedger[_walletLedger[msg.sender].master].stakers.length - 1; i++) {
                    if(_walletLedger[_walletLedger[msg.sender].master].stakers[i] == msg.sender)
                    {
                        isDone=true;
                    }
                    if(isDone)
                    {
                        _walletLedger[_walletLedger[msg.sender].master].stakers[i] = _walletLedger[_walletLedger[msg.sender].master].stakers[i+1];
                    }
                }
                _walletLedger[_walletLedger[msg.sender].master].stakers.pop();
                _walletLedger[msg.sender].master = address(0);      
                _Validator[_validatorOfMaster].master.push(msg.sender);
                _walletLedger[_validatorOfMaster].stakers.push(msg.sender);                        
            }
            if (_walletLedger[msg.sender].validator == address(0)){
                _walletLedger[msg.sender].validator = _validatorOfMaster;
                _Validator[_validatorOfMaster].master.push(msg.sender);
                _walletLedger[_validatorOfMaster].stakers.push(msg.sender);
            }
            emit LogMaster(msg.sender, _validatorOfMaster, msg.value);
            return true;
        }
        // add to staking under selected master
        else{
            _walletLedger[msg.sender].totalCoins = _walletLedger[msg.sender].totalCoins + msg.value;
            //_walletLedger[msg.sender].validator = _validatorOfMaster;
            _walletLedger[msg.sender].StakedBalance.stakedCoins = _walletLedger[msg.sender].StakedBalance.stakedCoins + msg.value;
            _walletLedger[msg.sender].StakedBalance.payoutCoins = _walletLedger[msg.sender].StakedBalance.payoutCoins + (int)(msg.value * (_Validator[_validatorOfMaster].rewardPerCoins* 3)/1e18) ;
            _Validator[_validatorOfMaster].totalCoins = _Validator[_validatorOfMaster].totalCoins + msg.value;
            _Validator[_validatorOfMaster].totalStakedCoins = _Validator[_validatorOfMaster].totalStakedCoins + msg.value;
            _walletLedger[master].totalMasterCoins = _walletLedger[master].totalMasterCoins + msg.value;

            if (_walletLedger[msg.sender].master == address(0)){
                _walletLedger[msg.sender].master = master;
                _walletLedger[msg.sender].validator = _validatorOfMaster;
                _walletLedger[master].stakers.push(msg.sender);
            }
            emit LogStaking(msg.sender, _validatorOfMaster, master, msg.value);
            return true;
        }
    }

    // withdraw only rewards
    function withdrawStakingReward() public returns(bool success){
        require(_walletLedger[msg.sender].totalCoins > 0 || _walletLedger[msg.sender].validatorRewards > 0, "User doesn't have any staking");
        address _validatorOfUser = _walletLedger[msg.sender].validator;
        int _profit = 0;

        //Calculate Master Profit if any

        // calculate master staking coins profit
        if (_walletLedger[msg.sender].MasterBalance.stakedCoins > 0){
            _profit = _profit + ((int)(_walletLedger[msg.sender].MasterBalance.stakedCoins * (_Validator[_validatorOfUser].rewardPerCoins* 3)/1e18)  - _walletLedger[msg.sender].MasterBalance.payoutCoins);
        }
        // calculate staked staking coins profit
        if (_walletLedger[msg.sender].StakedBalance.stakedCoins > 0){
            _profit = _profit + ((int)(_walletLedger[msg.sender].StakedBalance.stakedCoins * (_Validator[_validatorOfUser].rewardPerCoins* 3)/1e18)  - _walletLedger[msg.sender].StakedBalance.payoutCoins);
        }
        //calculate non staked coins profit
        if (_walletLedger[msg.sender].NonStakedBalance.stakedCoins > 0){
            _profit = _profit + ((int)(_walletLedger[msg.sender].NonStakedBalance.stakedCoins * _Validator[_validatorOfUser].rewardPerCoins/1e18) - _walletLedger[msg.sender].NonStakedBalance.payoutCoins);
        }

        // add master and validator rewards
        _profit = _profit + (int) (_walletLedger[msg.sender].validatorRewards);
        _profit = _profit + (int) (_walletLedger[msg.sender].masterRewards);

        if (_profit > 0){
            _walletLedger[msg.sender].MasterBalance.payoutCoins = (int)(_walletLedger[msg.sender].MasterBalance.stakedCoins * (_Validator[_validatorOfUser].rewardPerCoins* 3)/1e18) ;
            _walletLedger[msg.sender].StakedBalance.payoutCoins = (int)(_walletLedger[msg.sender].StakedBalance.stakedCoins * (_Validator[_validatorOfUser].rewardPerCoins* 3)/1e18) ;
            _walletLedger[msg.sender].NonStakedBalance.payoutCoins = (int)(_walletLedger[msg.sender].NonStakedBalance.stakedCoins * _Validator[_validatorOfUser].rewardPerCoins/1e18);

            _walletLedger[msg.sender].validatorRewards = 0;
            _walletLedger[msg.sender].masterRewards = 0;

            payable(msg.sender).transfer((uint) (_profit));
            emit LogWithdrawReward(msg.sender, (uint) (_profit));
        }
        return true;
    }

    // applicable only for master and staked coins. non staked can directly withdraw using withdraw button
     function unStake() public returns(bool success){
        require(_walletLedger[msg.sender].totalCoins > 0, "User don't have any staking");

        // withdraw rewards if any before unstaking
        withdrawStakingReward();

        address _validatorOfUser = _walletLedger[msg.sender].validator;
        bool isDone;
        uint amountunstaked;
        // unstake master coins if its master
        if (_walletLedger[msg.sender].MasterBalance.stakedCoins > 0){
            _walletLedger[msg.sender].MasterBalance.unstakedCoins = _walletLedger[msg.sender].MasterBalance.unstakedCoins + _walletLedger[msg.sender].MasterBalance.stakedCoins;
            _walletLedger[msg.sender].MasterBalance.unstakedTime = block.timestamp;

            _walletLedger[msg.sender].totalCoins = _walletLedger[msg.sender].totalCoins - _walletLedger[msg.sender].MasterBalance.stakedCoins;
            _walletLedger[msg.sender].totalMasterCoins = 0;//_walletLedger[msg.sender].totalMasterCoins - _walletLedger[msg.sender].MasterBalance.stakedCoins;

            _Validator[_validatorOfUser].totalCoins = _Validator[_validatorOfUser].totalCoins - _walletLedger[msg.sender].MasterBalance.stakedCoins;
            _Validator[_validatorOfUser].totalMasterCoins = _Validator[_validatorOfUser].totalMasterCoins - _walletLedger[msg.sender].MasterBalance.stakedCoins;

            amountunstaked = _walletLedger[msg.sender].MasterBalance.stakedCoins;
            _walletLedger[msg.sender].MasterBalance.stakedCoins = 0;
            _walletLedger[msg.sender].MasterBalance.payoutCoins = 0;
            _walletLedger[msg.sender].validator = address(0);
            _walletLedger[msg.sender].master = address(0);
            if(_walletLedger[msg.sender].stakers.length > 0){
                for (uint256 i = 0; i < _walletLedger[msg.sender].stakers.length - 1; i++) {
                    address staker = _walletLedger[msg.sender].stakers[i];
                    _walletLedger[staker].master = address(0);                
                }
              delete _walletLedger[msg.sender].stakers;
            }
            if(_Validator[_validatorOfUser].master.length > 0){
                for (uint256 i = 0; i < _Validator[_validatorOfUser].master.length - 1; i++) {
                    if(_Validator[_validatorOfUser].master[i] == msg.sender)
                    {
                        isDone=true;
                    }
                    if(isDone)
                    {
                        _Validator[_validatorOfUser].master[i] = _Validator[_validatorOfUser].master[i+1];
                    }
                }
                _Validator[_validatorOfUser].master.pop();
            }
            if(_walletLedger[_validatorOfUser].stakers.length > 0){
                isDone= false;
                for (uint256 i = 0; i < _walletLedger[_validatorOfUser].stakers.length - 1; i++) {
                    if(_walletLedger[_validatorOfUser].stakers[i] == msg.sender)
                    {
                        isDone=true;
                    }
                    if(isDone)
                    {
                        _walletLedger[_validatorOfUser].stakers[i] = _walletLedger[_validatorOfUser].stakers[i+1];
                    }
                }
                _walletLedger[_validatorOfUser].stakers.pop();
            }
           
        }

        // unstake staked coins if its under staked
        if (_walletLedger[msg.sender].StakedBalance.stakedCoins > 0){
            _walletLedger[msg.sender].StakedBalance.unstakedCoins = _walletLedger[msg.sender].StakedBalance.unstakedCoins + _walletLedger[msg.sender].StakedBalance.stakedCoins;
            _walletLedger[msg.sender].StakedBalance.unstakedTime = block.timestamp;

            _walletLedger[msg.sender].totalCoins = _walletLedger[msg.sender].totalCoins - _walletLedger[msg.sender].StakedBalance.stakedCoins;

            _Validator[_validatorOfUser].totalCoins = _Validator[_validatorOfUser].totalCoins - _walletLedger[msg.sender].StakedBalance.stakedCoins;
            _Validator[_validatorOfUser].totalStakedCoins = _Validator[_validatorOfUser].totalStakedCoins - _walletLedger[msg.sender].StakedBalance.stakedCoins;

            amountunstaked = _walletLedger[msg.sender].StakedBalance.stakedCoins;
            _walletLedger[msg.sender].StakedBalance.stakedCoins = 0;
            _walletLedger[msg.sender].StakedBalance.payoutCoins = 0;
            _walletLedger[msg.sender].validator = address(0);            
            
            if(_walletLedger[msg.sender].master != address(0) && _walletLedger[_walletLedger[msg.sender].master].MasterBalance.stakedCoins > 0){
                _walletLedger[_walletLedger[msg.sender].master].totalMasterCoins = _walletLedger[_walletLedger[msg.sender].master].totalMasterCoins - amountunstaked;
                isDone= false;
                for (uint256 i = 0; i < _walletLedger[_walletLedger[msg.sender].master].stakers.length - 1; i++) {
                    if(_walletLedger[_walletLedger[msg.sender].master].stakers[i] == msg.sender)
                    {
                        isDone=true;
                    }
                    if(isDone)
                    {
                        _walletLedger[_walletLedger[msg.sender].master].stakers[i] = _walletLedger[_walletLedger[msg.sender].master].stakers[i+1];
                    }
                }
                _walletLedger[_walletLedger[msg.sender].master].stakers.pop();
                _walletLedger[msg.sender].master = address(0);
            }
        }


        emit LogUnstake(msg.sender, _validatorOfUser, amountunstaked);
        return true;
    }

    // withdraw unstaked and non staked coins
    function withdrawStaking() public returns(bool success){
        //require(_walletLedger[msg.sender].totalCoins > 0 , "User don't have any staking");
        require(_walletLedger[msg.sender].MasterBalance.unstakedCoins > 0 || _walletLedger[msg.sender].StakedBalance.unstakedCoins > 0 || _walletLedger[msg.sender].NonStakedBalance.stakedCoins >0, "Please Unstake Before Withdraw");
        if (_walletLedger[msg.sender].MasterBalance.unstakedCoins > 0){
            require(block.timestamp - _walletLedger[msg.sender].MasterBalance.unstakedTime > _stakingSettings.withdrawLockPeriod, "Master Unstaking Withdrawal Lock Period Not Completed");
        }
        if (_walletLedger[msg.sender].StakedBalance.unstakedCoins > 0){
            require(block.timestamp - _walletLedger[msg.sender].StakedBalance.unstakedTime > _stakingSettings.withdrawLockPeriod, "StakedVoter Unstaking Withdrawal Lock Period Not Completed");
        }
        if(_walletLedger[msg.sender].totalCoins > 0){
            withdrawStakingReward(); // withdraw rewards if any - for unstaked coins
        }

        uint _coinsToSend = _walletLedger[msg.sender].MasterBalance.unstakedCoins;
        _coinsToSend = _coinsToSend + _walletLedger[msg.sender].StakedBalance.unstakedCoins;
        _coinsToSend = _coinsToSend + _walletLedger[msg.sender].NonStakedBalance.stakedCoins;

        // remove non staked coins count from walletLedger, validator
        if (_walletLedger[msg.sender].NonStakedBalance.stakedCoins > 0){
            address _validatorOfUser = _walletLedger[msg.sender].validator;
            _Validator[_validatorOfUser].totalCoins = _Validator[_validatorOfUser].totalCoins - _walletLedger[msg.sender].NonStakedBalance.stakedCoins;
            _Validator[_validatorOfUser].totalNonStakedCoins = _Validator[_validatorOfUser].totalNonStakedCoins - _walletLedger[msg.sender].NonStakedBalance.stakedCoins;
            _walletLedger[msg.sender].totalCoins = _walletLedger[msg.sender].totalCoins - _walletLedger[msg.sender].NonStakedBalance.stakedCoins;
            bool isDone;
            for (uint256 i = 0; i < _walletLedger[_validatorOfUser].stakers.length - 1; i++) {
                if(_walletLedger[_validatorOfUser].stakers[i] == msg.sender)
                {
                    isDone=true;
                }
                if(isDone)
                {
                    _walletLedger[_validatorOfUser].stakers[i] = _walletLedger[_validatorOfUser].stakers[i+1];
                }
            }
            _walletLedger[_validatorOfUser].stakers.pop();
        }

        _walletLedger[msg.sender].MasterBalance.unstakedCoins = 0;
        _walletLedger[msg.sender].MasterBalance.unstakedTime = 0;
        _walletLedger[msg.sender].StakedBalance.unstakedCoins = 0;
        _walletLedger[msg.sender].StakedBalance.unstakedTime = 0;

        _walletLedger[msg.sender].NonStakedBalance.stakedCoins = 0;
        _walletLedger[msg.sender].NonStakedBalance.unstakedCoins = 0;
        _walletLedger[msg.sender].NonStakedBalance.unstakedTime = 0;
        _walletLedger[msg.sender].NonStakedBalance.payoutCoins =0;

        payable(msg.sender).transfer(_coinsToSend);
        emit LogWithdraw(msg.sender, _coinsToSend);
        return true;
    }

    // distribute rewards
    function distributeBlockReward() external payable returns(bool success){
        require(_blockRewardDistributed[block.number] != true, "Block Rewards Already Distributed");
        require(msg.value > 0, "Block Doesn't Has Network Fees");

        // get current block fees
        uint _currentBlockRewards = (_stakingSettings.startBlockReward / ((_stakingSettings.rewardsBlock/_stakingSettings.halvingInterval) + 1));

        // if total rewards are already distributed set blockrewards zero and only distribute network fees
        if (_stakingSettings.totalRewards < (_stakingSettings.distributedBlockRewards + _currentBlockRewards)){
            _currentBlockRewards = 0;
        }

        uint _networkBlockRewards = ((msg.value * 100)/85); // calculate total block rewards including 15% validator distributed from validator contract
        uint _masterRewards = ((_currentBlockRewards + _networkBlockRewards) * 15 /100);
        uint _coinsRewards = ((_currentBlockRewards + _networkBlockRewards) * 70 /100);


        // set calidator rewards - only from block rewards
        _walletLedger[block.coinbase].validatorRewards = _walletLedger[block.coinbase].validatorRewards + ((_currentBlockRewards * 15) /100);

        // distribute master rewards for validator
        if (_Validator[block.coinbase].master.length > 0){
            for (uint i=0; i < _Validator[block.coinbase].master.length; i++ ){
                if (_walletLedger[_Validator[block.coinbase].master[i]].MasterBalance.stakedCoins > 0){
                    _walletLedger[_Validator[block.coinbase].master[i]].masterRewards = _walletLedger[_Validator[block.coinbase].master[i]].masterRewards + ((_walletLedger[_Validator[block.coinbase].master[i]].MasterBalance.stakedCoins * _masterRewards)/_Validator[block.coinbase].totalMasterCoins);
                }
            }
        }
        else{
            _coinsRewards = _coinsRewards + _masterRewards;
        }

        // distribute coins rewards
        if(_Validator[block.coinbase].totalMasterCoins + _Validator[block.coinbase].totalStakedCoins + _Validator[block.coinbase].totalNonStakedCoins > 0){
            _Validator[block.coinbase].rewardPerCoins = _Validator[block.coinbase].rewardPerCoins + (_coinsRewards*1e18/(((_Validator[block.coinbase].totalMasterCoins + _Validator[block.coinbase].totalStakedCoins) * 3) + _Validator[block.coinbase].totalNonStakedCoins));
        }

        _blockRewardDistributed[block.number] = true;
        _stakingSettings.rewardsBlock = _stakingSettings.rewardsBlock + 1;
        _stakingSettings.distributedBlockRewards = _stakingSettings.distributedBlockRewards + _currentBlockRewards;
        _stakingSettings.distributedNetworkRewards = _stakingSettings.distributedNetworkRewards + _networkBlockRewards;

        return true;
    }

    receive() external payable {
        _stakingSettings.totalRewards = _stakingSettings.totalRewards + msg.value;
        emit LogRewardsAdded(msg.sender, msg.value);
    }
}
