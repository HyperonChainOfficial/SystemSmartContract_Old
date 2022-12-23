// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;



interface InterfaceValidator {
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
    function getTopValidators() external view returns(address[] memory);
    function validatorInfo(address val) external view returns(address payable, Status, uint256, Description memory,uint256 ,uint256 ,uint256  );
    function getValidatorInfo(address val)external view returns(address payable,Status,uint256,uint256,uint256,uint256,address[] memory);
    function getMasterVoterInfo(address master)external view returns(address[]memory);
    function totalStake() external view returns(uint256);
    function masterVoterInfo(address masterVoter) external view returns(address,uint256,uint256);
    function withdrawableReward(address validator, address _user) external view returns(uint256);
    function staked(address staker, address validator) external view returns(uint256, uint256, uint256, uint256);
    function stakedMaster(address staker, address masterVoter) external view returns(uint256, uint256, uint256, uint256);
    function totalsupply() external view returns(uint256);
    function MinimalStakingCoin() external view returns(uint256);
    function isTopValidator(address who) external view returns (bool);
    function StakingLockPeriod() external view returns(uint64);
    function UnstakeLockPeriod() external view returns(uint64);
    function WithdrawProfitPeriod() external view returns(uint64);



}

interface InterfaceStaking {
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
    function getTopValidators() external view returns(address[] memory);
    function validatorInfo(address val) external view returns(uint256 ,uint256 ,uint256);
    function getValidatorInfo(address val)external view returns(address[]memory, address[] memory);
    function getMasterVoterInfo(address master)external view returns(address[]memory);
    function totalStake() external view returns(uint256);
    function masterVoterInfo(address masterVoter) external view returns(address,uint256,uint256, uint256);
    function withdrawableReward(address validator, address _user) external view returns(uint256);
    function staked(address staker, address validator) external view returns(uint256, uint256, uint256, uint256);
    function stakedMaster(address staker, address masterVoter) external view returns(uint256, uint256, uint256, uint256);
    function totalsupply() external view returns(uint256);
    function MinimalStakingCoin() external view returns(uint256);
    function isTopValidator(address who) external view returns (bool);
    function StakingLockPeriod() external view returns(uint64);
    function UnstakeLockPeriod() external view returns(uint64);
    function WithdrawProfitPeriod() external view returns(uint64);



}





contract ValidatorData {

    InterfaceValidator public valContract = InterfaceValidator(0x000000000000000000000000000000000000f000);
    InterfaceStaking public stakingContract = InterfaceStaking(0x6c9FC25f5ba4F295c167AF26F23633Af2ed0d488);
  

    function getAllValidatorInfo() external view returns (uint256 totalValidatorCount,uint256 totalStakedCoins,address[] memory,InterfaceValidator.Status[] memory,uint256[] memory,string[] memory,string[] memory)
    {
        address[] memory highestValidatorsSet = valContract.getTopValidators();
       
        uint256 totalValidators = highestValidatorsSet.length;
        InterfaceValidator.Status[] memory statusArray = new InterfaceValidator.Status[](totalValidators);
        uint256[] memory coinsArray = new uint256[](totalValidators);
        string[] memory identityArray = new string[](totalValidators);
        string[] memory websiteArray = new string[](totalValidators);
        uint256 totalValidatorStaked;
        
        for(uint8 i=0; i < totalValidators; i++){
            (, InterfaceValidator.Status status, uint256 coins, InterfaceValidator.Description memory description, , , ) = valContract.validatorInfo(highestValidatorsSet[i]);
            (uint256 totalStakedInStakingContract , , ) = stakingContract.validatorInfo(highestValidatorsSet[i]);

            // following condtions is only for the validator whose contracts has incorrect staking.
            // so just to adjust that we deducting this hard coded values
            if(highestValidatorsSet[i] == 0x7Ca2A67dA14B2c4b3355BC47e9726fBDf546EAC7){
                coins -= 2000032000000000000000000;
            }
            else if(highestValidatorsSet[i] == 0x906Bb16AF1f50d5fad3C6455808d43A06bf9639e){
                coins -= 20000000000000000000000000;
            }
            else if(highestValidatorsSet[i] == 0xF95B541D22a48F1a4B01f02F9De7ED95750eC6A0){
                coins -= 2000000000000000000000000;
            }
            
            
            
            statusArray[i] = status;
            coinsArray[i] = coins + totalStakedInStakingContract;
            identityArray[i] = description.identity;
            websiteArray[i] = description.website;

            totalValidatorStaked += coinsArray[i];
            
        }
        return(totalValidators, totalValidatorStaked, highestValidatorsSet, statusArray, coinsArray, identityArray, websiteArray);
    
    
    }

    function getAllMasterVotersInfo() external view returns(uint8 totalMasterVoters, address[] memory, address[] memory, uint256[]memory)
    {

        address[] memory highestValidatorsSet = valContract.getTopValidators();
        address[] memory masterVotersArray = new address[](25);
        address[] memory validatorArray = new address[](25);
        uint256[] memory stakedCoinsArray = new uint256[](25);
        address[] memory masterVoters;
        uint8 counter=0;
        address validatorAddress;
        uint256 stakedCoins;
        uint256 stakerCoins;

        for(uint8 i=0; i<highestValidatorsSet.length; i++){
             (masterVoters,) = stakingContract.getValidatorInfo(highestValidatorsSet[i]);
            
            for(uint8 j=0; j<masterVoters.length; j++){
                ( validatorAddress,  stakedCoins, , stakerCoins) = stakingContract.masterVoterInfo(masterVoters[j]);

                masterVotersArray[counter] = masterVoters[j];
                validatorArray[counter] = validatorAddress;
                stakedCoinsArray[counter] = stakedCoins + stakerCoins;
                
                counter++;
            }
        }
        
        return (counter, masterVotersArray, validatorArray, stakedCoinsArray);

    }



    function validatorSpecificInfo1(address validatorAddress, address user) external view returns(string memory identityName, string memory website, string memory otherDetails, uint256 withdrawableRewards, uint256 stakedCoins, uint256 waitingBlocksForUnstake ){
        
        (, , , InterfaceValidator.Description memory description, , , ) = valContract.validatorInfo(validatorAddress);
                
        
        uint256 unstakeBlock;

        (stakedCoins, unstakeBlock, , ) = stakingContract.staked(user,validatorAddress);

        if(unstakeBlock!=0){
            waitingBlocksForUnstake = stakedCoins;
            stakedCoins = 0;
        }
        
        uint256 availableReward;
        if(validatorAddress == user){
            (,,, availableReward ,,,) = valContract.getValidatorInfo(validatorAddress);
        }
        else{
            availableReward = stakingContract.withdrawableReward(validatorAddress,user);
        }

        return(description.identity, description.website, description.details, availableReward, stakedCoins, waitingBlocksForUnstake) ;
    }


    function validatorSpecificInfo2(address validatorAddress, address user) external view returns(uint256 totalStakedCoins, InterfaceValidator.Status status, uint256 selfStakedCoins, uint256 masterVoters, uint256 stakers, address){
        address[] memory stakersArray;
        address[] memory masterVotersArray;
        (masterVotersArray, stakersArray)  = stakingContract.getValidatorInfo(validatorAddress);
        (, status, totalStakedCoins, , ,  ,) = valContract.validatorInfo(validatorAddress);
        (uint256 totalStakedInStakingContract , , ) = stakingContract.validatorInfo(validatorAddress);
        (selfStakedCoins, , , ) = stakingContract.staked(validatorAddress,validatorAddress);


        // following condtions is only for the validator whose contracts has incorrect staking.
            // so just to adjust that we deducting this hard coded values
            if(validatorAddress == 0x7Ca2A67dA14B2c4b3355BC47e9726fBDf546EAC7){
                totalStakedCoins -= 2000032000000000000000000;
            }
            else if(validatorAddress == 0x906Bb16AF1f50d5fad3C6455808d43A06bf9639e){
                totalStakedCoins -= 20000000000000000000000000;
            }
            else if(validatorAddress == 0xF95B541D22a48F1a4B01f02F9De7ED95750eC6A0){
                totalStakedCoins -= 2000000000000000000000000;
            }


        return ((totalStakedCoins + totalStakedInStakingContract), status, (totalStakedCoins + selfStakedCoins), masterVotersArray.length, stakersArray.length, user);
    }


    function masterVoterSpecificInfo(address masterVoter, address user) external view returns( uint256 withdrawableRewards, uint256 stakedCoins, uint256 waitingBlocksForUnstake, uint256 totalStakedCoins, uint256 totalStakers, uint256 selfStakedMaster ){
        
         
        uint256 unstakeBlock;

        (stakedCoins, unstakeBlock, , ) = stakingContract.stakedMaster(user,masterVoter);
        

        if(unstakeBlock + stakingContract.StakingLockPeriod() > block.timestamp){
            waitingBlocksForUnstake = (unstakeBlock + stakingContract.StakingLockPeriod()) - block.timestamp;
        }
        else{
            waitingBlocksForUnstake=0;
        }

        ( ,,,  totalStakedCoins ) = stakingContract.masterVoterInfo(masterVoter);

        totalStakers = stakingContract.getMasterVoterInfo(masterVoter).length;

        (selfStakedMaster, , , ) = stakingContract.stakedMaster(masterVoter,masterVoter);



        return( stakingContract.withdrawableReward(masterVoter,user), stakedCoins, waitingBlocksForUnstake, totalStakedCoins, totalStakers, selfStakedMaster) ;
    }

    
    function waitingWithdrawProfit(address user, address validatorOrMaster) external view returns(uint256){
        //only validator will have waiting 
        if(user== validatorOrMaster && valContract.isTopValidator(validatorOrMaster)){
            (, , , , , , uint256 lastWithdrawProfitsBlock  ) = valContract.validatorInfo(validatorOrMaster);
            
            if(lastWithdrawProfitsBlock + valContract.WithdrawProfitPeriod() > block.timestamp){
                return (lastWithdrawProfitsBlock + valContract.WithdrawProfitPeriod()) - block.timestamp;
            }
        }
        
       return 0;
    }

    function waitingUnstaking(address user, address validatorOrMaster) external view returns(uint256){
        
        (uint256 stakedCoins, , , uint256 stakeTime ) = stakingContract.staked(user,validatorOrMaster);
        if(stakedCoins > 0){

            if(stakeTime + stakingContract.UnstakeLockPeriod() > block.timestamp){
                return (stakeTime + stakingContract.UnstakeLockPeriod()) - block.timestamp;
            }
        }
        else{
            (, , , uint256 stakeTimeMaster) = stakingContract.stakedMaster(user,validatorOrMaster);
            if(stakeTimeMaster+stakingContract.UnstakeLockPeriod() > block.timestamp){
                return (stakeTimeMaster + stakingContract.UnstakeLockPeriod()) - block.timestamp;
            }
        }

        return 0;
    }

    function waitingWithdrawStaking(address user, address validatorOrMaster) external view returns(uint256){
        (uint256 stakedCoins, uint256 unstakeBlock, ,  ) = stakingContract.staked(user,validatorOrMaster);
        if(stakedCoins > 0){

            if(unstakeBlock + stakingContract.StakingLockPeriod() > block.timestamp){
                return (unstakeBlock + stakingContract.StakingLockPeriod()) - block.timestamp;
            }
        }
        else{
            (, uint256 unstakeBlockMaster, , ) = stakingContract.stakedMaster(user,validatorOrMaster);
            if(unstakeBlockMaster+stakingContract.StakingLockPeriod() > block.timestamp){
                return (unstakeBlockMaster + stakingContract.StakingLockPeriod()) - block.timestamp;
            }
        }

        return 0;
    }

    function minimumStakingAmount() external view returns(uint256){
        return valContract.MinimalStakingCoin();
    }


}
