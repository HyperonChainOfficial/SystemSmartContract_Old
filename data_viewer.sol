// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.14;



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
    function validatorInfo(address val) external view returns(address payable, Status, uint256, Description memory,uint256 ,uint256 ,uint256  ,uint256 ,uint256);
    function getValidatorInfo(address val)external view returns(address[]memory);
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





contract ValidatorData {

    InterfaceValidator public valContract = InterfaceValidator(0x10075Fbe6f6c807C13b417913b617aBA55e2b88E);
    
  

    function getAllValidatorInfo() external view returns (uint256 totalValidatorCount,uint256 totalStakedCoins,address[] memory,InterfaceValidator.Status[] memory,uint256[] memory,string[] memory,string[] memory)
    {
        address[] memory highestValidatorsSet = valContract.getTopValidators();
       
        uint256 totalValidators = highestValidatorsSet.length;
        InterfaceValidator.Status[] memory statusArray = new InterfaceValidator.Status[](totalValidators);
        uint256[] memory coinsArray = new uint256[](totalValidators);
        string[] memory identityArray = new string[](totalValidators);
        string[] memory websiteArray = new string[](totalValidators);
        
        for(uint8 i=0; i < totalValidators; i++){
            (, InterfaceValidator.Status status, uint256 coins, InterfaceValidator.Description memory description, , , , , ) = valContract.validatorInfo(highestValidatorsSet[i]);
            
            
            statusArray[i] = status;
            coinsArray[i] = coins;
            identityArray[i] = description.identity;
            websiteArray[i] = description.website;
            
        }
        return(totalValidators, valContract.totalStake(), highestValidatorsSet, statusArray, coinsArray, identityArray, websiteArray);
    
    
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

        for(uint8 i=0; i<highestValidatorsSet.length; i++){
             masterVoters = valContract.getValidatorInfo(highestValidatorsSet[i]);
            
            for(uint8 j=0; j<masterVoters.length; j++){
                ( validatorAddress,  stakedCoins, ) = valContract.masterVoterInfo(masterVoters[j]);

                masterVotersArray[counter] = masterVoters[j];
                validatorArray[counter] = validatorAddress;
                stakedCoinsArray[counter] = stakedCoins;
                
                counter++;
            }
        }
        
        return (counter, masterVotersArray, validatorArray, stakedCoinsArray);

    }



    function validatorSpecificInfo1(address validatorAddress, address user) external view returns(string memory identityName, string memory website, string memory otherDetails, uint256 withdrawableRewards, uint256 stakedCoins, uint256 waitingBlocksForUnstake ){
        
        (, , , InterfaceValidator.Description memory description, , , , , ) = valContract.validatorInfo(validatorAddress);
                
        
        uint256 unstakeBlock;

        (stakedCoins, unstakeBlock, , ) = valContract.staked(user,validatorAddress);
        

        if(unstakeBlock + valContract.StakingLockPeriod() > block.timestamp){
            waitingBlocksForUnstake = (unstakeBlock + valContract.StakingLockPeriod()) - block.timestamp;
        }
        else{
            waitingBlocksForUnstake=0;
        }

        uint256 yy=0;
         yy = valContract.withdrawableReward(validatorAddress,user);

        return(description.identity, description.website, description.details, yy, stakedCoins, waitingBlocksForUnstake) ;
    }


    function validatorSpecificInfo2(address validatorAddress, address user) external view returns(uint256 totalStakedCoins, InterfaceValidator.Status status, uint256 selfStakedCoins, uint256 masterVoters, uint256 stakers, address){
        address[] memory stakersArray;
        address[] memory masterVotersArray  = valContract.getValidatorInfo(validatorAddress);
        (, status, totalStakedCoins, , , , , ,) = valContract.validatorInfo(validatorAddress);

        (selfStakedCoins, , , ) = valContract.staked(validatorAddress,validatorAddress);

        return (totalStakedCoins, status, selfStakedCoins, masterVotersArray.length, stakersArray.length, user);
    }


    function masterVoterSpecificInfo(address masterVoter, address user) external view returns( uint256 withdrawableRewards, uint256 stakedCoins, uint256 waitingBlocksForUnstake, uint256 totalStakedCoins, uint256 totalStakers, uint256 selfStakedMaster ){
        
         
        uint256 unstakeBlock;

        (stakedCoins, unstakeBlock, , ) = valContract.stakedMaster(user,masterVoter);
        

        if(unstakeBlock + valContract.StakingLockPeriod() > block.timestamp){
            waitingBlocksForUnstake = (unstakeBlock + valContract.StakingLockPeriod()) - block.timestamp;
        }
        else{
            waitingBlocksForUnstake=0;
        }

        ( ,  totalStakedCoins, ) = valContract.masterVoterInfo(masterVoter);

        totalStakers = valContract.getMasterVoterInfo(masterVoter).length;

        (selfStakedMaster, , , ) = valContract.stakedMaster(masterVoter,masterVoter);



        return( valContract.withdrawableReward(masterVoter,user), stakedCoins, waitingBlocksForUnstake, totalStakedCoins, totalStakers, selfStakedMaster) ;
    }

    
    function waitingWithdrawProfit(address user, address validatorOrMaster) external view returns(uint256){
        //only validator will have waiting 
        if(user== validatorOrMaster && valContract.isTopValidator(validatorOrMaster)){
            (, , , , , , uint256 lastWithdrawProfitsBlock , , ) = valContract.validatorInfo(validatorOrMaster);
            
            if(lastWithdrawProfitsBlock + valContract.WithdrawProfitPeriod() > block.timestamp){
                return (lastWithdrawProfitsBlock + valContract.WithdrawProfitPeriod()) - block.timestamp;
            }
        }
        
       return 0;
    }

    function waitingUnstaking(address user, address validatorOrMaster) external view returns(uint256){
        
        (uint256 stakedCoins, , , uint256 stakeTime ) = valContract.staked(user,validatorOrMaster);
        if(stakedCoins > 0){

            if(stakeTime + valContract.UnstakeLockPeriod() > block.timestamp){
                return (stakeTime + valContract.UnstakeLockPeriod()) - block.timestamp;
            }
        }
        else{
            (, , , uint256 stakeTimeMaster) = valContract.stakedMaster(user,validatorOrMaster);
            if(stakeTimeMaster+valContract.UnstakeLockPeriod() > block.timestamp){
                return (stakeTimeMaster + valContract.UnstakeLockPeriod()) - block.timestamp;
            }
        }

        return 0;
    }

    function waitingWithdrawStaking(address user, address validatorOrMaster) external view returns(uint256){
        (uint256 stakedCoins, uint256 unstakeBlock, ,  ) = valContract.staked(user,validatorOrMaster);
        if(stakedCoins > 0){

            if(unstakeBlock + valContract.StakingLockPeriod() > block.timestamp){
                return (unstakeBlock + valContract.StakingLockPeriod()) - block.timestamp;
            }
        }
        else{
            (, uint256 unstakeBlockMaster, , ) = valContract.stakedMaster(user,validatorOrMaster);
            if(unstakeBlockMaster+valContract.StakingLockPeriod() > block.timestamp){
                return (unstakeBlockMaster + valContract.StakingLockPeriod()) - block.timestamp;
            }
        }

        return 0;
    }

    function minimumStakingAmount() external view returns(uint256){
        return valContract.MinimalStakingCoin();
    }


}
