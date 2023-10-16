// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ERC165Checker } from "contracts/libraries/ERC165Checker.sol";
import { SafeTransferLib } from "contracts/libraries/SafeTransferLib.sol";
import { ERC20 } from "contracts/libraries/ERC20.sol";
import { ReentrancyGuard } from "contracts/libraries/ReentrancyGuard.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { ICVELocker, RewardsData } from "contracts/interfaces/ICVELocker.sol";
import { IDelegateRegistry } from "contracts/interfaces/IDelegateRegistry.sol";

contract VeCVE is ERC20, ReentrancyGuard {
    /// TYPES ///

    struct Lock {
        uint216 amount;
        uint40 unlockTime;
    }

    /// CONSTANTS ///

    // Timestamp `unlockTime` will be set to when a lock is on continuous lock (CL) mode
    uint40 public constant CONTINUOUS_LOCK_VALUE = type(uint40).max;
    uint256 public constant EPOCH_DURATION = 2 weeks; // Protocol epoch length
    uint256 public constant LOCK_DURATION_EPOCHS = 26; // in epochs
    uint256 public constant LOCK_DURATION = 52 weeks; // in seconds
    uint256 public constant DENOMINATOR = 10000; // Scalar for math

    /// @dev `bytes4(keccak256(bytes("VeCVE__Unauthorized()")))`
    uint256 internal constant _UNAUTHORIZED_SELECTOR = 0x32c4d25d;
    /// @dev `bytes4(keccak256(bytes("VeCVE__InvalidLock()")))`
    uint256 internal constant _INVALID_LOCK_SELECTOR = 0x21d223d9;
    /// @dev `bytes4(keccak256(bytes("VeCVE__VeCVEShutdown()")))`
    uint256 internal constant _VECVE_SHUTDOWN_SELECTOR = 0x3ad2450b;

    bytes32 private immutable _name; // token name metadata
    bytes32 private immutable _symbol; // token symbol metadata
    address public immutable cve; // CVE contract address
    ICVELocker public immutable cveLocker; // CVE Locker contract address
    uint256 public immutable genesisEpoch; // Genesis Epoch timestamp
    uint256 public immutable clPointMultiplier; // Point multiplier for CL
    ICentralRegistry public immutable centralRegistry; // Curvance DAO hub

    /// STORAGE ///

    uint256 public isShutdown = 1; // 1 = active; 2 = shutdown

    // User => Array of VeCVE locks
    mapping(address => Lock[]) public userLocks;

    // User => Token Points
    mapping(address => uint256) public userPoints;

    // User => Epoch # => Tokens unlocked
    mapping(address => mapping(uint256 => uint256))
        public userUnlocksByEpoch;

    // Token Points on this chain
    uint256 public chainPoints;

    // Epoch # => Token unlocks on this chain
    mapping(uint256 => uint256) public chainUnlocksByEpoch;

    /// EVENTS ///

    event Locked(address indexed user, uint256 amount);
    event Unlocked(address indexed user, uint256 amount);
    event UnlockedWithPenalty(
        address indexed user,
        uint256 amount,
        uint256 penaltyAmount
    );

    /// ERRORS ///

    error VeCVE__Unauthorized();
    error VeCVE__NonTransferrable();
    error VeCVE__LockTypeMismatch();
    error VeCVE__InvalidLock();
    error VeCVE__VeCVEShutdown();
    error VeCVE__ParametersareInvalid();

    /// MODIFIERS ///

    modifier canLock(uint256 amount) {
        assembly {
            if iszero(amount) {
                mstore(0x0, _INVALID_LOCK_SELECTOR)
                // return bytes 29-32 for the selector
                revert(0x1c, 0x04)
            }
        }

        if (isShutdown == 2) {
            _revert(_VECVE_SHUTDOWN_SELECTOR);
        }

        _;
    }

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        uint256 clPointMultiplier_
    ) {
        _name = "Vote Escrowed CVE";
        _symbol = "VeCVE";

        if (!ERC165Checker.supportsInterface(
                address(centralRegistry_),
                type(ICentralRegistry).interfaceId
            )){
            revert VeCVE__ParametersareInvalid();
        }

        centralRegistry = centralRegistry_;
        genesisEpoch = centralRegistry.genesisEpoch();
        cve = centralRegistry.CVE();
        cveLocker = ICVELocker(centralRegistry.cveLocker());

        if (clPointMultiplier_ <= DENOMINATOR){
            revert VeCVE__ParametersareInvalid();
        }

        clPointMultiplier = clPointMultiplier_;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Rescue any token sent by mistake
    /// @param token token to rescue
    /// @param amount amount of `token` to rescue, 0 indicates to rescue all
    function rescueToken(
        address token,
        uint256 amount
    ) external {
        if (!centralRegistry.hasDaoPermissions(msg.sender)){
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        address daoOperator = centralRegistry.daoAddress();

        if (token == address(0)) {
            if (amount == 0){
                amount = address(this).balance;
            }

            SafeTransferLib.forceSafeTransferETH(daoOperator, amount);
        } else {
            if (token == address(cve)) {
                revert VeCVE__NonTransferrable();
            }

            if (amount == 0){
                amount = IERC20(token).balanceOf(address(this));
            }

            SafeTransferLib.safeTransfer(token, daoOperator, amount);
        }
    }

    /// @notice Shuts down the contract, unstakes all tokens,
    ///         and releases all locks
    function shutdown() external {
        if (!centralRegistry.hasElevatedPermissions(msg.sender)){
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        isShutdown = 2;
        cveLocker.notifyLockerShutdown();
    }

    /// @notice Locks a given amount of cve tokens and claims,
    ///         and processes any pending locker rewards
    /// @param amount The amount of tokens to lock
    /// @param continuousLock Indicator of whether the lock should be continuous
    /// @param rewardsData Rewards data for CVE rewards locker
    /// @param params Parameters for rewards claim function
    /// @param aux Auxiliary data
    function lock(
        uint256 amount,
        bool continuousLock,
        RewardsData calldata rewardsData,
        bytes calldata params,
        uint256 aux
    ) external canLock(amount) nonReentrant {
        SafeTransferLib.safeTransferFrom(
            cve,
            msg.sender,
            address(this),
            amount
        );

        // Claim pending locker rewards
        _claimRewards(msg.sender, msg.sender, rewardsData, params, aux);

        _lock(msg.sender, amount, continuousLock);

        emit Locked(msg.sender, amount);
    }

    /// @notice Locks a given amount of cve tokens on behalf of another user,
    ///         and processes any pending locker rewards
    /// @param recipient The address to lock tokens for
    /// @param amount The amount of tokens to lock
    /// @param continuousLock Indicator of whether the lock should be continuous
    /// @param rewardsData Rewards data for CVE rewards locker
    /// @param params Parameters for rewards claim function
    /// @param aux Auxiliary data
    function lockFor(
        address recipient,
        uint256 amount,
        bool continuousLock,
        RewardsData calldata rewardsData,
        bytes calldata params,
        uint256 aux
    ) external canLock(amount) nonReentrant {
        if (
            !centralRegistry.isVeCVELocker(msg.sender) &&
            !centralRegistry.isGaugeController(msg.sender)
        ) {
            _revert(_INVALID_LOCK_SELECTOR);
        }

        SafeTransferLib.safeTransferFrom(
            cve,
            msg.sender,
            address(this),
            amount
        );

        // Claim pending locker rewards
        _claimRewards(recipient, msg.sender, rewardsData, params, aux);

        _lock(recipient, amount, continuousLock);

        emit Locked(recipient, amount);
    }

    /// @notice Extends a lock of cve tokens by a given index,
    ///         and processes any pending locker rewards
    /// @param lockIndex The index of the lock to extend
    /// @param continuousLock Indicator of whether the lock should be continuous
    /// @param rewardsData Rewards data for CVE rewards locker
    /// @param params Parameters for rewards claim function
    /// @param aux Auxiliary data
    function extendLock(
        uint256 lockIndex,
        bool continuousLock,
        RewardsData calldata rewardsData,
        bytes calldata params,
        uint256 aux
    ) external nonReentrant {
        if (isShutdown == 2) {
            revert VeCVE__VeCVEShutdown();
        }

        Lock[] storage locks = userLocks[msg.sender];

        // Length is index + 1 so has to be less than array length
        if (lockIndex >= locks.length) {
            _revert(_INVALID_LOCK_SELECTOR);
        }

        uint40 unlockTimestamp = locks[lockIndex].unlockTime;

        if (unlockTimestamp < block.timestamp) {
            _revert(_INVALID_LOCK_SELECTOR);
        }
        if (unlockTimestamp == CONTINUOUS_LOCK_VALUE) {
            revert VeCVE__LockTypeMismatch();
        }

        // Claim pending locker rewards
        _claimRewards(msg.sender, msg.sender, rewardsData, params, aux);

        uint216 tokenAmount = locks[lockIndex].amount;
        uint256 unlockEpoch = freshLockEpoch();
        uint256 priorUnlockEpoch = currentEpoch(locks[lockIndex].unlockTime);

        if (continuousLock) {
            locks[lockIndex].unlockTime = CONTINUOUS_LOCK_VALUE;
            _updateDataToContinuousOn(
                msg.sender,
                priorUnlockEpoch,
                _getContinuousPointValue(tokenAmount) - tokenAmount,
                tokenAmount
            );
        } else {
            locks[lockIndex].unlockTime = freshLockTimestamp();
            // Updates unlock data for chain and user for new unlock time
            _updateUnlockDataToExtendedLock(
                msg.sender,
                priorUnlockEpoch,
                unlockEpoch,
                tokenAmount,
                tokenAmount
            );
        }
    }

    /// @notice Increases the locked amount and extends the lock
    ///         for the specified lock index, and processes any pending
    ///         locker rewards
    /// @param amount The amount to increase the lock by
    /// @param lockIndex The index of the lock to extend
    /// @param continuousLock Whether the lock should be continuous or not
    /// @param rewardsData Rewards data for CVE rewards locker
    /// @param params Parameters for rewards claim function
    /// @param aux Auxiliary data
    function increaseAmountAndExtendLock(
        uint256 amount,
        uint256 lockIndex,
        bool continuousLock,
        RewardsData calldata rewardsData,
        bytes calldata params,
        uint256 aux
    ) external canLock(amount) nonReentrant {
        SafeTransferLib.safeTransferFrom(
            cve,
            msg.sender,
            address(this),
            amount
        );

        // Claim pending locker rewards
        _claimRewards(msg.sender, msg.sender, rewardsData, params, aux);

        _increaseAmountAndExtendLockFor(
            msg.sender,
            amount,
            lockIndex,
            continuousLock
        );
    }

    /// @notice Increases the locked amount and extends the lock
    ///         for the specified lock index, and processes any pending
    ///         locker rewards
    /// @param recipient The address to lock and extend tokens for
    /// @param amount The amount to increase the lock by
    /// @param lockIndex The index of the lock to extend
    /// @param continuousLock Whether the lock should be continuous or not
    /// @param rewardsData Rewards data for CVE rewards locker
    /// @param params Parameters for rewards claim function
    /// @param aux Auxiliary data
    function increaseAmountAndExtendLockFor(
        address recipient,
        uint256 amount,
        uint256 lockIndex,
        bool continuousLock,
        RewardsData calldata rewardsData,
        bytes calldata params,
        uint256 aux
    ) external canLock(amount) nonReentrant {
        if (
            !centralRegistry.isVeCVELocker(msg.sender) &&
            !centralRegistry.isGaugeController(msg.sender)
        ) {
            _revert(_INVALID_LOCK_SELECTOR);
        }

        SafeTransferLib.safeTransferFrom(
            cve,
            msg.sender,
            address(this),
            amount
        );

        // Claim pending locker rewards
        _claimRewards(recipient, msg.sender, rewardsData, params, aux);

        _increaseAmountAndExtendLockFor(
            recipient,
            amount,
            lockIndex,
            continuousLock
        );
    }

    /// @notice Disables a continuous lock for the user at the specified
    ///         lock index, and processes any pending locker rewards
    /// @param lockIndex The index of the lock to be disabled
    /// @param rewardsData Rewards data for CVE rewards locker
    /// @param params Parameters for rewards claim function
    /// @param aux Auxiliary data
    function disableContinuousLock(
        uint256 lockIndex,
        RewardsData calldata rewardsData,
        bytes calldata params,
        uint256 aux
    ) external nonReentrant {
        Lock[] storage locks = userLocks[msg.sender];

        // Length is index + 1 so has to be less than array length
        if (lockIndex >= locks.length) {
            _revert(_INVALID_LOCK_SELECTOR);
        }
        if (locks[lockIndex].unlockTime != CONTINUOUS_LOCK_VALUE) {
            revert VeCVE__LockTypeMismatch();
        }

        // Claim pending locker rewards
        _claimRewards(msg.sender, msg.sender, rewardsData, params, aux);

        uint216 tokenAmount = locks[lockIndex].amount;
        uint256 unlockEpoch = freshLockEpoch();
        locks[lockIndex].unlockTime = freshLockTimestamp();

        // Remove their continuous lock bonus and document that they have tokens unlocking in a year
        unchecked {
            // only modified on locking/unlocking VeCVE and we know theres never
            // more than 420m so this should never over/underflow
            uint256 tokenPoints = _getContinuousPointValue(tokenAmount) -
                tokenAmount;
            chainPoints = chainPoints - tokenPoints;
            chainUnlocksByEpoch[unlockEpoch] =
                chainUnlocksByEpoch[unlockEpoch] +
                tokenAmount;
            userPoints[msg.sender] =
                userPoints[msg.sender] -
                tokenPoints;
            userUnlocksByEpoch[msg.sender][unlockEpoch] =
                userUnlocksByEpoch[msg.sender][unlockEpoch] +
                tokenAmount;
        }
    }

    /// @notice Combines all locks into a single lock,
    ///         and processes any pending locker rewards
    /// @param continuousLock Whether the combined lock should be continuous
    ///                       or not
    /// @param rewardsData Rewards data for CVE rewards locker
    /// @param params Parameters for rewards claim function
    /// @param aux Auxiliary data
    function combineLocks(
        uint256[] calldata lockIndexes,
        bool continuousLock,
        RewardsData calldata rewardsData,
        bytes memory params,
        uint256 aux
    ) external nonReentrant {
        // Claim pending locker rewards
        _claimRewards(msg.sender, msg.sender, rewardsData, params, aux);

        Lock[] storage locks = userLocks[msg.sender];
        uint256 lastLockIndex = locks.length - 1;
        uint256 locksToCombineIndex = lockIndexes.length - 1;

        // Check that theres are at least 2 locks to combine,
        // otherwise the inputs are misconfigured.
        // Check that the user has sufficient locks to combine,
        // then decrement 1 so we can use it to go through the lockIndexes
        // array backwards.
        if (locksToCombineIndex == 0 || locksToCombineIndex > lastLockIndex) {
            _revert(_INVALID_LOCK_SELECTOR);
        }

        uint256 lockAmount;
        Lock storage userLock;
        uint256 previousLockIndex;
        uint256 excessPoints;

        // Go backwards through the locks and validate that they are entered from smallest to largest index
        for (uint256 i = locksToCombineIndex; i > 0; ) {
            if (i != locksToCombineIndex) {
                // If this is the first iteration we do not need to check
                // for sorted lockIndexes
                if (lockIndexes[i] >= previousLockIndex){
                    revert VeCVE__ParametersareInvalid();
                }
            }

            previousLockIndex = lockIndexes[i];

            if (previousLockIndex != lastLockIndex) {
                Lock memory tempValue = locks[previousLockIndex];
                locks[previousLockIndex] = locks[lastLockIndex];
                locks[lastLockIndex] = tempValue;
            }

            userLock = locks[lastLockIndex];

            if (userLock.unlockTime != CONTINUOUS_LOCK_VALUE) {
                // Remove unlock data if there is any
                _reduceTokenUnlocks(
                    msg.sender,
                    currentEpoch(userLock.unlockTime),
                    userLock.amount
                );
            } else {
                unchecked {
                    excessPoints +=
                        _getContinuousPointValue(userLock.amount) -
                        userLock.amount;
                }
                // calculate and sum how many additional points they got
                // from their continuous lock
            }

            unchecked {
                // Should never overflow as the total amount of tokens a user
                // could ever lock is equal to the entire token supply
                // Decrement the array length since we need to pop the last entry
                lockAmount += locks[lastLockIndex--].amount;
                --i;
            }

            locks.pop();
        }

        if (excessPoints > 0) {
            _reduceTokenPoints(msg.sender, excessPoints);
        }

        userLock = locks[lockIndexes[0]]; // We will combine the deleted locks into the first lock in the array

        uint256 epoch;

        if (continuousLock) {
            if (userLock.unlockTime != CONTINUOUS_LOCK_VALUE) {
                // Finalize new combined lock amount
                lockAmount += userLock.amount;

                // Remove the previous unlock data
                epoch = currentEpoch(userLock.unlockTime);
                _reduceTokenUnlocks(msg.sender, epoch, userLock.amount);

                // Give the user extra token points from continuous lock
                // being enabled
                _incrementTokenPoints(
                    msg.sender,
                    _getContinuousPointValue(lockAmount) - lockAmount
                );

                // Assign new lock data
                userLock.amount = uint216(lockAmount);
                userLock.unlockTime = CONTINUOUS_LOCK_VALUE;
            } else {
                // Give the user extra token points from continuous lock
                // being enabled, but only from the other locks
                _incrementTokenPoints(
                    msg.sender,
                    _getContinuousPointValue(lockAmount) - lockAmount
                );

                // Finalize new combined lock amount
                lockAmount += userLock.amount;
                // Assign new lock data
                userLock.amount = uint216(lockAmount);
            }
        } else {
            if (userLock.unlockTime == CONTINUOUS_LOCK_VALUE){
                revert VeCVE__LockTypeMismatch();
            }
            // Remove the previous unlock data
            _reduceTokenUnlocks(
                msg.sender,
                currentEpoch(userLock.unlockTime),
                userLock.amount
            );

            // Finalize new combined lock amount
            lockAmount += userLock.amount;
            // Assign new lock data
            userLock.amount = uint216(lockAmount);
            userLock.unlockTime = freshLockTimestamp();

            // Record the new unlock data
            _incrementTokenUnlocks(msg.sender, freshLockEpoch(), lockAmount);
        }
    }

    /// @notice Combines all locks into a single lock,
    ///         and processes any pending locker rewards
    /// @param continuousLock Whether the combined lock should be continuous
    ///                       or not
    /// @param rewardsData Rewards data for CVE rewards locker
    /// @param params Parameters for rewards claim function
    /// @param aux Auxiliary data
    function combineAllLocks(
        bool continuousLock,
        RewardsData calldata rewardsData,
        bytes calldata params,
        uint256 aux
    ) external nonReentrant {
        // Claim pending locker rewards
        _claimRewards(msg.sender, msg.sender, rewardsData, params, aux);

        // Need to have this check after _claimRewards as the user could have
        // created a new lock with their pending rewards
        Lock[] storage locks = userLocks[msg.sender];
        uint256 numLocks = locks.length;

        if (numLocks < 2) {
            _revert(_INVALID_LOCK_SELECTOR);
        }

        uint256 excessPoints;
        uint256 lockAmount;
        Lock storage userLock;

        for (uint256 i; i < numLocks; ) {
            userLock = locks[i];

            if (userLock.unlockTime != CONTINUOUS_LOCK_VALUE) {
                // Remove unlock data if there is any
                _reduceTokenUnlocks(
                    msg.sender,
                    currentEpoch(userLock.unlockTime),
                    userLock.amount
                );
            } else {
                unchecked {
                    excessPoints +=
                        _getContinuousPointValue(userLock.amount) -
                        userLock.amount;
                }
                // calculate and sum how many additional points they got
                // from their continuous lock
            }

            unchecked {
                // Should never overflow as the total amount of tokens a user
                // could ever lock is equal to the entire token supply
                lockAmount += locks[i++].amount;
            }
        }

        // Remove the users excess points from their continuous locks, if any
        if (excessPoints > 0) {
            _reduceTokenPoints(msg.sender, excessPoints);
        }
        // Remove the users locks
        delete userLocks[msg.sender];

        if (continuousLock) {
            userLocks[msg.sender].push(
                Lock({
                    amount: uint216(lockAmount),
                    unlockTime: CONTINUOUS_LOCK_VALUE
                })
            );
            // Give the user extra token points from continuous lock being enabled
            _incrementTokenPoints(
                msg.sender,
                _getContinuousPointValue(lockAmount) - lockAmount
            );
        } else {
            userLocks[msg.sender].push(
                Lock({
                    amount: uint216(lockAmount),
                    unlockTime: freshLockTimestamp()
                })
            );
            // Record the new unlock data
            _incrementTokenUnlocks(msg.sender, freshLockEpoch(), lockAmount);
        }
    }

    /// @notice Processes an expired lock for the specified lock index,
    ///         and processes any pending locker rewards
    /// @param lockIndex The index of the lock to process
    /// @param relock Whether the expired lock should be relocked in a fresh lock
    /// @param continuousLock Whether the relocked fresh lock should be
    ///                       continuous or not
    /// @param rewardsData Rewards data for CVE rewards locker
    /// @param params Parameters for rewards claim function
    /// @param aux Auxiliary data
    function processExpiredLock(
        uint256 lockIndex,
        bool relock,
        bool continuousLock,
        RewardsData calldata rewardsData,
        bytes calldata params,
        uint256 aux
    ) external nonReentrant {
        Lock[] storage locks = userLocks[msg.sender];

        // Length is index + 1 so has to be less than array length
        if (lockIndex >= locks.length) {
            _revert(_INVALID_LOCK_SELECTOR);
        }

        if (block.timestamp < locks[lockIndex].unlockTime && isShutdown != 2){
            _revert(_INVALID_LOCK_SELECTOR);
        }

        // Claim pending locker rewards
        _claimRewards(msg.sender, msg.sender, rewardsData, params, aux);

        Lock memory expiredLock = locks[lockIndex];
        uint256 lockAmount = expiredLock.amount;
        // If the locker is shutdown, do not allow them to relock,
        // we'd want them to exit locked positions 
        if (isShutdown == 2){
            relock = false;

            if (block.timestamp < locks[lockIndex].unlockTime){
                if (expiredLock.unlockTime == CONTINUOUS_LOCK_VALUE){
                    _reduceTokenPoints(msg.sender, _getContinuousPointValue(lockAmount));
                } else {
                    uint256 unlockEpoch = currentEpoch(expiredLock.unlockTime);
                    chainPoints = chainPoints - lockAmount;
                    chainUnlocksByEpoch[unlockEpoch] =
                        chainUnlocksByEpoch[unlockEpoch] -
                        lockAmount;
                    userPoints[msg.sender] =
                        userPoints[msg.sender] -
                        lockAmount;
                    userUnlocksByEpoch[msg.sender][unlockEpoch] =
                        userUnlocksByEpoch[msg.sender][unlockEpoch] -
                        lockAmount;
                }
            }    
        }

        if (relock) {
            // Token points will be caught up by _claimRewards call
            // so we can treat this as a fresh lock and increment rewards again
            _lock(msg.sender, lockAmount, continuousLock);
        } else {
            _burn(msg.sender, lockAmount);
            _removeLock(locks, lockIndex);

            // Transfer the user the unlocked CVE
            SafeTransferLib.safeTransfer(cve, msg.sender, lockAmount);

            emit Unlocked(msg.sender, lockAmount);

            // Check whether the user has no remaining locks and reset their index,
            // that way if in the future they create a new lock, they do not need to claim
            // a bunch of epochs they have no rewards for
            if (locks.length == 0 && isShutdown != 2) {
                cveLocker.resetUserClaimIndex(msg.sender);
            }
        }
    }

    /// @notice Processes an active lock as if its expired, for a penalty,
    ///         and processes any pending locker rewards
    /// @param lockIndex The index of the lock to process
    /// @param rewardsData Rewards data for CVE rewards locker
    /// @param params Parameters for rewards claim function
    /// @param aux Auxiliary data
    function earlyExpireLock(
        uint256 lockIndex,
        RewardsData calldata rewardsData,
        bytes calldata params,
        uint256 aux
    ) external nonReentrant {
        Lock[] storage locks = userLocks[msg.sender];

        // Length is index + 1 so has to be less than array length
        if (lockIndex >= locks.length) {
            _revert(_INVALID_LOCK_SELECTOR);
        }

        if (block.timestamp >= locks[lockIndex].unlockTime){
            _revert(_INVALID_LOCK_SELECTOR);
        }

        uint256 penaltyValue = centralRegistry.earlyUnlockPenaltyValue();

        if (penaltyValue == 0){
            _revert(_INVALID_LOCK_SELECTOR);
        }

        // Claim pending locker rewards
        _claimRewards(msg.sender, msg.sender, rewardsData, params, aux);

        Lock memory expiredLock = locks[lockIndex];
        uint256 lockAmount = expiredLock.amount;

        if (expiredLock.unlockTime == CONTINUOUS_LOCK_VALUE){
                _reduceTokenPoints(msg.sender, _getContinuousPointValue(lockAmount));
            } else {
                uint256 unlockEpoch = currentEpoch(expiredLock.unlockTime);
                chainPoints = chainPoints - lockAmount;
                chainUnlocksByEpoch[unlockEpoch] =
                    chainUnlocksByEpoch[unlockEpoch] -
                    lockAmount;
                userPoints[msg.sender] =
                    userPoints[msg.sender] -
                    lockAmount;
                userUnlocksByEpoch[msg.sender][unlockEpoch] =
                    userUnlocksByEpoch[msg.sender][unlockEpoch] -
                    lockAmount;
            }

        // Burn their VeCVE and remove their lock
        _burn(msg.sender, lockAmount);
        _removeLock(locks, lockIndex);

        uint256 penaltyAmount = (lockAmount * penaltyValue) / DENOMINATOR;

        // Transfer the CVE penalty amount to Curvance DAO
        SafeTransferLib.safeTransfer(
            cve,
            centralRegistry.daoAddress(),
            penaltyAmount
        );

        // Transfer the remainder of the CVE
        SafeTransferLib.safeTransfer(
            cve,
            msg.sender,
            lockAmount - penaltyAmount
        );

        emit UnlockedWithPenalty(msg.sender, lockAmount, penaltyAmount);

        // Check whether the user has no remaining locks and reset their index,
        // that way if in the future they create a new lock, they do not need to claim
        // a bunch of epochs they have no rewards for
        if (locks.length == 0 && isShutdown != 2) {
            cveLocker.resetUserClaimIndex(msg.sender);
        }
    }

    /// PUBLIC FUNCTIONS ///

    /// @dev Returns the name of the token
    function name() public view override returns (string memory) {
        return string(abi.encodePacked(_name));
    }

    /// @dev Returns the symbol of the token
    function symbol() public view override returns (string memory) {
        return string(abi.encodePacked(_symbol));
    }

    /// @notice Returns the current epoch for the given time
    /// @param time The timestamp for which to calculate the epoch
    /// @return The current epoch
    function currentEpoch(uint256 time) public view returns (uint256) {
        if (time < genesisEpoch) {
            return 0;
        }

        return ((time - genesisEpoch) / EPOCH_DURATION);
    }

    /// @notice Returns the current epoch for the given time
    /// @return The current epoch
    function nextEpochStartTime() public view returns (uint256) {
        uint256 timestampOffset = (currentEpoch(block.timestamp) + 1) *
            EPOCH_DURATION;
        return (genesisEpoch + timestampOffset);
    }

    /// @notice Returns the epoch to lock until for a lock executed
    ///         at this moment
    /// @return The epoch
    function freshLockEpoch() public view returns (uint256) {
        return currentEpoch(block.timestamp) + LOCK_DURATION_EPOCHS;
    }

    /// @notice Returns the timestamp to lock until for a lock executed
    ///         at this moment
    /// @return The timestamp
    function freshLockTimestamp() public view returns (uint40) {
        return
            uint40(
                genesisEpoch +
                    (currentEpoch(block.timestamp) * EPOCH_DURATION) +
                    LOCK_DURATION
            );
    }

    /// @notice Updates user points by reducing the amount that gets unlocked
    ///         in a specific epoch
    /// @param user The address of the user whose points are to be updated
    /// @param epoch The epoch from which the unlock amount will be reduced
    /// @dev This function is only called when
    ///      userUnlocksByEpoch[user][epoch] > 0
    ///      so do not need to check here
    function updateUserPoints(address user, uint256 epoch) public {
        address _cveLocker = address(cveLocker);
        assembly {
            if iszero(eq(caller(), _cveLocker)) {
                mstore(0x00, _UNAUTHORIZED_SELECTOR)
                revert(0x1c, 0x04)
            }
        }

        unchecked {
            userPoints[user] =
                userPoints[user] -
                userUnlocksByEpoch[user][epoch];
        }
    }

    /// View Functions ///

    /// @notice Calculates the total votes for a user based on their current locks
    /// @param user The address of the user to calculate votes for
    /// @return The total number of votes for the user
    function getVotes(address user) public view returns (uint256) {
        uint256 numLocks = userLocks[user].length;

        if (numLocks == 0) {
            return 0;
        }

        uint256 currentLockBoost = centralRegistry.voteBoostValue();
        uint256 votes;

        for (uint256 i; i < numLocks; ) {
            // Based on CVE maximum supply this cannot overflow
            unchecked {
                votes += getVotesForSingleLockForTime(
                    user,
                    i++,
                    block.timestamp,
                    currentLockBoost
                );
            }
        }

        return votes;
    }

    /// @notice Calculates the total votes for a user based
    ///         on their locks at a specific epoch
    /// @param user The address of the user to calculate votes for
    /// @param epoch The epoch for which the votes are calculated
    /// @return The total number of votes for the user at the specified epoch
    function getVotesForEpoch(
        address user,
        uint256 epoch
    ) public view returns (uint256) {
        uint256 numLocks = userLocks[user].length;

        if (numLocks == 0) {
            return 0;
        }

        uint256 timestamp = genesisEpoch + (EPOCH_DURATION * epoch);
        uint256 currentLockBoost = centralRegistry.voteBoostValue();
        uint256 votes;

        for (uint256 i; i < numLocks; ) {
            // Based on CVE maximum supply this cannot overflow
            unchecked {
                votes += getVotesForSingleLockForTime(
                    user,
                    i++,
                    timestamp,
                    currentLockBoost
                );
            }
        }

        return votes;
    }

    /// @notice Calculates the votes for a single lock of a user based
    ///         on a specific timestamp
    /// @param user The address of the user whose lock is being used
    ///              for the calculation
    /// @param lockIndex The index of the lock to calculate votes for
    /// @param time The timestamp to use for the calculation
    /// @param currentLockBoost The current voting boost a lock gets for being continuous
    /// @return The number of votes for the specified lock at the given timestamp
    function getVotesForSingleLockForTime(
        address user,
        uint256 lockIndex,
        uint256 time,
        uint256 currentLockBoost
    ) public view returns (uint256) {
        Lock storage userLock = userLocks[user][lockIndex];

        if (userLock.unlockTime < time) {
            return 0;
        }

        if (userLock.unlockTime == CONTINUOUS_LOCK_VALUE) {
            unchecked {
                return ((userLock.amount * currentLockBoost) / DENOMINATOR);
            }
        }

        // Equal to epochsLeft = (userLock.unlockTime - time) / EPOCH_DURATION
        // (userLock.amount * epochsLeft) / LOCK_DURATION_EPOCHS
        return
            (userLock.amount *
                ((userLock.unlockTime - time) / EPOCH_DURATION)) /
            LOCK_DURATION_EPOCHS;
    }

    /// Transfer Locked Functions ///

    /// @notice Overridden transfer function to prevent token transfers
    /// @dev This function always reverts, as the token is non-transferrable
    /// @return This function always reverts and does not return a value
    function transfer(address, uint256) public pure override returns (bool) {
        revert VeCVE__NonTransferrable();
    }

    /// @notice Overridden transferFrom function to prevent token transfers
    /// @dev This function always reverts, as the token is non-transferrable
    /// @return This function always reverts and does not return a value
    function transferFrom(
        address,
        address,
        uint256
    ) public pure override returns (bool) {
        revert VeCVE__NonTransferrable();
    }

    /// INTERNAL FUNCTIONS ///

    /// See claimRewardsFor in CVE Locker
    function _claimRewards(
        address user,
        address recipient,
        RewardsData memory rewardsData,
        bytes memory params,
        uint256 aux
    ) internal {
        uint256 epochs = cveLocker.epochsToClaim(user);
        if (epochs > 0) {
            cveLocker.claimRewardsFor(
                user,
                recipient,
                epochs,
                rewardsData,
                params,
                aux
            );
        }
    }

    /// @notice Internal function to lock tokens for a user
    /// @param recipient The address of the user receiving the lock
    /// @param amount The amount of tokens to lock
    /// @param continuousLock Whether the lock is continuous or not
    function _lock(
        address recipient,
        uint256 amount,
        bool continuousLock
    ) internal {
        /// Might be better gas to check if first user locker .amount == 0
        if (userLocks[recipient].length == 0) {
            cveLocker.updateUserClaimIndex(
                recipient,
                currentEpoch(block.timestamp)
            );
        }

        if (continuousLock) {
            userLocks[recipient].push(
                Lock({
                    amount: uint216(amount),
                    unlockTime: CONTINUOUS_LOCK_VALUE
                })
            );
            _incrementTokenPoints(recipient, _getContinuousPointValue(amount));
        } else {
            uint256 unlockEpoch = freshLockEpoch();
            userLocks[recipient].push(
                Lock({
                    amount: uint216(amount),
                    unlockTime: freshLockTimestamp()
                })
            );
            // Increment Token Data
            unchecked {
                // only modified on locking/unlocking VeCVE and we know theres never
                // more than 420m so this should never over/underflow
                chainPoints = chainPoints + amount;
                chainUnlocksByEpoch[unlockEpoch] =
                    chainUnlocksByEpoch[unlockEpoch] +
                    amount;
                userPoints[recipient] =
                    userPoints[recipient] +
                    amount;
                userUnlocksByEpoch[recipient][unlockEpoch] =
                    userUnlocksByEpoch[recipient][unlockEpoch] +
                    amount;
            }
        }

        _mint(recipient, amount);
    }

    /// @notice Internal function to handle whenever a user needs an increase
    ///         to a locked amount and extended lock
    /// @param recipient The address to lock and extend tokens for
    /// @param amount The amount to increase the lock by
    /// @param lockIndex The index of the lock to extend
    /// @param continuousLock Whether the lock should be continuous or not
    function _increaseAmountAndExtendLockFor(
        address recipient,
        uint256 amount,
        uint256 lockIndex,
        bool continuousLock
    ) internal {
        Lock[] storage user = userLocks[recipient];

        // Length is index + 1 so has to be less than array length
        if (lockIndex >= user.length) {
            _revert(_INVALID_LOCK_SELECTOR);
        }

        uint40 unlockTimestamp = user[lockIndex].unlockTime;

        if (unlockTimestamp == CONTINUOUS_LOCK_VALUE) {
            if (!continuousLock) {
                _revert(_INVALID_LOCK_SELECTOR);
            }

            // Increment the chain and user token point balance
            _incrementTokenPoints(recipient, _getContinuousPointValue(amount));

            // Update the lock value to include the new locked tokens
            user[lockIndex].amount = uint216(user[lockIndex].amount + amount);
        } else {
            // User was not continuous locked prior so we will need
            // to clean up their unlock data
            if (unlockTimestamp < block.timestamp) {
                _revert(_INVALID_LOCK_SELECTOR);
            }

            uint256 previousTokenAmount = user[lockIndex].amount;
            uint256 newTokenAmount = previousTokenAmount + amount;
            uint256 priorUnlockEpoch = currentEpoch(
                user[lockIndex].unlockTime
            );

            if (continuousLock) {
                user[lockIndex].unlockTime = CONTINUOUS_LOCK_VALUE;
                // Decrement their previous non-continuous lock value
                // and increase points by the continuous lock value
                _updateDataToContinuousOn(
                    recipient,
                    priorUnlockEpoch,
                    _getContinuousPointValue(newTokenAmount) -
                        previousTokenAmount,
                    previousTokenAmount
                );
            } else {
                user[lockIndex].unlockTime = freshLockTimestamp();
                uint256 unlockEpoch = freshLockEpoch();
                // Update unlock data removing the old lock amount
                // from old epoch and add the new lock amount to the new epoch
                _updateUnlockDataToExtendedLock(
                    recipient,
                    priorUnlockEpoch,
                    unlockEpoch,
                    previousTokenAmount,
                    newTokenAmount
                );

                // Increment the chain and user token point balance
                _incrementTokenPoints(recipient, amount);
            }

            user[lockIndex].amount = uint216(newTokenAmount);
        }

        _mint(recipient, amount);

        emit Locked(recipient, amount);
    }

    /// @notice Removes a lock from `user`
    /// @param user An array of locks for `user`
    /// @param lockIndex The index of the lock to be removed
    function _removeLock(Lock[] storage user, uint256 lockIndex) internal {
        uint256 lastLockIndex = user.length - 1;

        if (lockIndex != lastLockIndex) {
            Lock memory tempValue = user[lockIndex];
            user[lockIndex] = user[lastLockIndex];
            user[lastLockIndex] = tempValue;
        }

        user.pop();
    }

    /// @notice Increment token points
    /// @dev Increments the token points of the chain and user.
    ///      Can only be called by the VeCVE contract
    /// @param user The address of the user
    /// @param points The number of points to add
    function _incrementTokenPoints(address user, uint256 points) internal {
        // We know theres never more than 420m
        // so this should never over/underflow
        unchecked {
            chainPoints = chainPoints + points;
            userPoints[user] = userPoints[user] + points;
        }
    }

    /// @notice Reduce token points
    /// @dev Reduces the token points of the chain and user.
    ///      Can only be called by the VeCVE contract
    /// @param user The address of the user
    /// @param points The number of points to reduce
    function _reduceTokenPoints(address user, uint256 points) internal {
        // We know theres never more than 420m
        // so this should never over/underflow
        unchecked {
            chainPoints = chainPoints - points;
            userPoints[user] = userPoints[user] - points;
        }
    }

    /// @notice Increment token unlocks
    /// @dev Increments the token unlocks of the chain and user
    ///      for a given epoch. Can only be called by the VeCVE contract
    /// @param user The address of the user
    /// @param epoch The epoch to add the unlocks
    /// @param points The number of points to add
    function _incrementTokenUnlocks(
        address user,
        uint256 epoch,
        uint256 points
    ) internal {
        // might not need token unlock functions
        // We know theres never more than 420m
        // so this should never over/underflow
        unchecked {
            chainUnlocksByEpoch[epoch] = chainUnlocksByEpoch[epoch] + points;
            userUnlocksByEpoch[user][epoch] =
                userUnlocksByEpoch[user][epoch] +
                points;
        }
    }

    /// @notice Reduce token unlocks
    /// @dev Reduces the token unlocks of the chain and user
    ///      for a given epoch. Can only be called by the VeCVE contract
    /// @param user The address of the user
    /// @param epoch The epoch to reduce the unlocks
    /// @param points The number of points to reduce
    function _reduceTokenUnlocks(
        address user,
        uint256 epoch,
        uint256 points
    ) internal {
        // We know theres never more than 420m
        // so this should never over/underflow
        unchecked {
            chainUnlocksByEpoch[epoch] = chainUnlocksByEpoch[epoch] - points;
            userUnlocksByEpoch[user][epoch] =
                userUnlocksByEpoch[user][epoch] -
                points;
        }
    }

    /// @notice Update token unlock data from an extended lock that
    ///         is not continuous
    /// @dev Updates the token points and token unlocks for the chain
    ///      and user from a continuous lock for a given epoch.
    ///      Can only be called by the VeCVE contract
    /// @param user The address of the user
    /// @param previousEpoch The previous unlock epoch
    /// @param epoch The new unlock epoch
    /// @param previousPoints The previous points to remove
    ///                        from the old unlock time
    /// @param points The new token points to add for the new unlock time
    function _updateUnlockDataToExtendedLock(
        address user,
        uint256 previousEpoch,
        uint256 epoch,
        uint256 previousPoints,
        uint256 points
    ) internal {
        // We know theres never more than 420m
        // so this should never over/underflow
        unchecked {
            chainUnlocksByEpoch[previousEpoch] =
                chainUnlocksByEpoch[previousEpoch] -
                previousPoints;
            userUnlocksByEpoch[user][previousEpoch] =
                userUnlocksByEpoch[user][previousEpoch] -
                previousPoints;
            chainUnlocksByEpoch[epoch] = chainUnlocksByEpoch[epoch] + points;
            userUnlocksByEpoch[user][epoch] =
                userUnlocksByEpoch[user][epoch] +
                points;
        }
    }

    /// @notice Update token data from continuous lock on
    /// @dev Updates the token points and token unlocks for the chain
    ///      and user from a continuous lock for a given epoch.
    ///      Can only be called by the VeCVE contract
    /// @param user The address of the user
    /// @param epoch The epoch to update the data
    /// @param tokenPoints The token points to add
    /// @param tokenUnlocks The token unlocks to reduce
    function _updateDataToContinuousOn(
        address user,
        uint256 epoch,
        uint256 tokenPoints,
        uint256 tokenUnlocks
    ) internal {
        // We know theres never more than 420m
        // so this should never over/underflow
        unchecked {
            chainPoints = chainPoints + tokenPoints;
            chainUnlocksByEpoch[epoch] =
                chainUnlocksByEpoch[epoch] -
                tokenUnlocks;
            userPoints[user] = userPoints[user] + tokenPoints;
            userUnlocksByEpoch[user][epoch] =
                userUnlocksByEpoch[user][epoch] -
                tokenUnlocks;
        }
    }

    /// @notice Calculates the continuous lock token point value for basePoints
    /// @param basePoints The token points to be used in the calculation
    /// @return The calculated continuous lock token point value
    function _getContinuousPointValue(
        uint256 basePoints
    ) internal view returns (uint256) {
        unchecked {
            return ((basePoints * clPointMultiplier) / DENOMINATOR);
        }
    }

    /// @dev Internal helper for reverting efficiently.
    function _revert(uint256 s) internal pure {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, s)
            revert(0x1c, 0x04)
        }
    }
}
