// contracts/TokenVesting.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.19;

// OpenZeppelin dependencies
import {ERC20} from "./dependencies/tokens/ERC20.sol";
import {Owned} from "./dependencies/auth/Owned.sol";
import {ReentrancyGuard} from "./dependencies/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "./dependencies/utils/SafeTransferLib.sol";

/**
 * @title TokenVesting
 */
contract TokenVesting is Owned, ReentrancyGuard {
    struct VestingSchedule {
        // cliff time of the vesting start in seconds since the UNIX epoch
        uint256 cliff;
        // start time of the vesting period in seconds since the UNIX epoch
        uint256 start;
        // duration of the vesting period in seconds
        uint256 duration;
        // duration of a slice period for the vesting in seconds
        uint256 slicePeriodSeconds;
        // total amount of tokens to be released at the end of the vesting
        uint256 amountTotal;
        // amount of tokens released
        uint256 released;
    }

    // address of the ERC20 token
    ERC20 public immutable _token;

    address[] public vestingAddresses;
    mapping(address => VestingSchedule) private vestingSchedules;
    uint256 public vestingSchedulesTotalAmount;



    /**
     * @dev Creates a vesting contract.
     * @param token_ address of the ERC20 token contract
     */
    constructor(address token_) Owned(msg.sender) {
        // Check that the token address is not 0x0.
        require(token_ != address(0x0));
        // Set the token address.
        _token = ERC20(token_);
    }

    /**
     * @dev This function is called for plain Ether transfers, i.e. for every call with empty calldata.
     */
    receive() external payable {}

    /**
     * @dev Fallback function is executed if none of the other functions match the function
     * identifier or no data was provided with the function call.
     */
    fallback() external payable {}


    function createVestingSchedule(
        address _beneficiary,
        uint256 _start,
        uint256 _cliff,
        uint256 _duration,
        uint256 _slicePeriodSeconds,
        uint256 _amount
    ) external onlyOwner {
        require(
            getWithdrawableAmount() >= _amount,
            "TokenVesting: cannot create vesting schedule because not sufficient tokens"
        );
        require(_duration > 0, "TokenVesting: duration must be > 0");
        require(_amount > 0, "TokenVesting: amount must be > 0");
        require(
            _slicePeriodSeconds >= 1,
            "TokenVesting: slicePeriodSeconds must be >= 1"
        );
        require(_duration >= _cliff, "TokenVesting: duration must be >= cliff");
        uint256 cliff = _start + _cliff;
        vestingSchedules[_beneficiary] = VestingSchedule(
            cliff,
            _start,
            _duration,
            _slicePeriodSeconds,
            _amount,
            0
        );
        vestingSchedulesTotalAmount = vestingSchedulesTotalAmount + _amount;
        vestingAddresses.push(_beneficiary);
    }

    function batchCreateVestingSchedule(
        address[] calldata _beneficiaries,
        uint256[] calldata _starts,
        uint256[] calldata _cliffs,
        uint256[] calldata _durations,
        uint256[] calldata _slicePeriodSeconds,
        uint256[] calldata _amounts
    ) external onlyOwner {
        // 检查输入数组长度是否一致
        require(
            _beneficiaries.length == _starts.length &&
            _beneficiaries.length == _cliffs.length &&
            _beneficiaries.length == _durations.length &&
            _beneficiaries.length == _slicePeriodSeconds.length &&
            _beneficiaries.length == _amounts.length,
            "TokenVesting: input arrays must have same length"
        );

        // 计算总金额
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < _amounts.length; i++) {
            totalAmount += _amounts[i];
        }

        // 检查合约中是否有足够的代币
        require(
            getWithdrawableAmount() >= totalAmount,
            "TokenVesting: cannot create vesting schedules because not sufficient tokens"
        );

        // 批量创建vesting schedules
        for (uint256 i = 0; i < _beneficiaries.length; i++) {
            require(_durations[i] > 0, "TokenVesting: duration must be > 0");
            require(_amounts[i] > 0, "TokenVesting: amount must be > 0");
            require(
                _slicePeriodSeconds[i] >= 1,
                "TokenVesting: slicePeriodSeconds must be >= 1"
            );
            require(_durations[i] >= _cliffs[i], "TokenVesting: duration must be >= cliff");

            uint256 cliff = _starts[i] + _cliffs[i];
            vestingSchedules[_beneficiaries[i]] = VestingSchedule(
                cliff,
                _starts[i],
                _durations[i],
                _slicePeriodSeconds[i],
                _amounts[i],
                0
            );
            vestingSchedulesTotalAmount = vestingSchedulesTotalAmount + _amounts[i];
            vestingAddresses.push(_beneficiaries[i]);
        }
    }

    /**
     * @notice Withdraw the specified amount if possible.
     * @param amount the amount to withdraw
     */
    function withdraw(uint256 amount) external nonReentrant onlyOwner {
        require(
            getWithdrawableAmount() >= amount,
            "TokenVesting: not enough withdrawable funds"
        );
        /*
         * @dev Replaced owner() with msg.sender => address of WITHDRAWER_ROLE
         */
        SafeTransferLib.safeTransfer(_token, msg.sender, amount);
    }

 
    function release(
        address vestingAddress,
        uint256 amount
    ) public nonReentrant {
        VestingSchedule storage vestingSchedule = vestingSchedules[
            vestingAddress
        ];
        bool isBeneficiary = vestingAddress == msg.sender;

        bool isReleasor = (msg.sender == owner);
        require(
            isBeneficiary || isReleasor,
            "TokenVesting: only beneficiary and owner can release vested tokens"
        );
        uint256 vestedAmount = _computeReleasableAmount(vestingSchedule);
        require(
            vestedAmount >= amount,
            "TokenVesting: cannot release tokens, not enough vested tokens"
        );
        vestingSchedule.released = vestingSchedule.released + amount;
        address payable beneficiaryPayable = payable(
            vestingAddress
        );
        vestingSchedulesTotalAmount = vestingSchedulesTotalAmount - amount;
        SafeTransferLib.safeTransfer(_token, beneficiaryPayable, amount);
    }



    /**
     * @dev Returns the address of the ERC20 token managed by the vesting contract.
     */
    function getToken() external view returns (address) {
        return address(_token);
    }


    /**
     * @notice Computes the vested amount of tokens for the given vesting schedule identifier.
     * @return the vested amount
     */
    function computeReleasableAmount(
        address vestingAddress
    )
        external
        view
        returns (uint256)
    {
        VestingSchedule storage vestingSchedule = vestingSchedules[
            vestingAddress
        ];
        return _computeReleasableAmount(vestingSchedule);
    }


    /**
     * @dev Returns the amount of tokens that can be withdrawn by the owner.
     * @return the amount of tokens
     */
    function getWithdrawableAmount() public view returns (uint256) {
        return _token.balanceOf(address(this)) - vestingSchedulesTotalAmount;
    }


    /**
     * @dev Computes the releasable amount of tokens for a vesting schedule.
     * @return the amount of releasable tokens
     */
    function _computeReleasableAmount(
        VestingSchedule memory vestingSchedule
    ) internal view returns (uint256) {
        // Retrieve the current time.
        uint256 currentTime = block.timestamp;
        // If the current time is before the cliff, no tokens are releasable.
        if (currentTime < vestingSchedule.cliff) {
            return 0;
        }
        // If the current time is after the vesting period, all tokens are releasable,
        // minus the amount already released.
        else if (
            currentTime >= vestingSchedule.cliff + vestingSchedule.duration
        ) {
            return vestingSchedule.amountTotal - vestingSchedule.released;
        }
        // Otherwise, some tokens are releasable.
        else {
            // Compute the number of full vesting periods that have elapsed.
            uint256 timeFromStart = currentTime - vestingSchedule.cliff;
            uint256 secondsPerSlice = vestingSchedule.slicePeriodSeconds;
            uint256 vestedSlicePeriods = timeFromStart / secondsPerSlice;
            uint256 vestedSeconds = vestedSlicePeriods * secondsPerSlice;
            // Compute the amount of tokens that are vested.
            uint256 vestedAmount = (vestingSchedule.amountTotal *
                vestedSeconds) / vestingSchedule.duration;
            // Subtract the amount already released and return.
            return vestedAmount - vestingSchedule.released;
        }
    }

}
