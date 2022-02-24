// SPDX-License-Identifier: agpl-3.0
pragma solidity ^0.8.0;

import {IVeBend} from "./interfaces/IVeBend.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {ILendPool} from "./interfaces/ILendPool.sol";
import {ILendPoolAddressesProvider} from "./interfaces/ILendPoolAddressesProvider.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract FeeDistributor is ReentrancyGuard, Ownable {
    event Checkpoint(uint256 time, uint256 tokenAmount);

    event Claimed(
        address indexed recipient,
        uint256 amount,
        uint256 claimEpoch,
        uint256 maxEpoch
    );

    uint256 public constant WEEK = 7 * 86400;
    uint256 public constant TOKEN_CHECKPOINT_DEADLINE = 86400;

    uint256 public startTime;
    uint256 public timeCursor;
    mapping(address => uint256) public timeCursorOf;
    mapping(address => uint256) public userEpochOf;

    uint256 public lastTokenTime;
    uint256[] public tokensPerWeek;
    uint256 public tokenLastBalance;

    uint256[] public veSupply; // VE total supply at week bounds

    IVeBend public veBend;
    IWETH internal WETH;
    ILendPoolAddressesProvider public addressesProvider;
    address public token;
    address public bendCollector;

    constructor(
        ILendPoolAddressesProvider _addressesProvider,
        IVeBend _veBendAddress,
        IWETH _weth,
        address _bendCollector,
        address _tokenAddress
    ) {
        addressesProvider = _addressesProvider;
        veBend = _veBendAddress;
        WETH = _weth;
        bendCollector = _bendCollector;
        token = _tokenAddress;
    }

    modifier shouldStarted() {
        require(startTime <= block.timestamp, "Distribute not started!");
        _;
    }

    function start() external onlyOwner {
        uint256 t = (block.timestamp / WEEK) * WEEK;
        startTime = t;
        lastTokenTime = t;
        timeCursor = t;
    }

    /***
     *@notice Update fee checkpoint
     *@dev Up to 20 weeks since the last update
     */
    function _checkpointBalance() internal {
        uint256 tokenBalance = IERC20(token).balanceOf(address(this));

        uint256 toDistribute = tokenBalance - tokenLastBalance;

        tokenLastBalance = tokenBalance;

        uint256 t = lastTokenTime;
        uint256 sinceLast = block.timestamp - t;
        lastTokenTime = block.timestamp;
        uint256 thisWeek = (t / WEEK) * WEEK;
        uint256 nextWeek = 0;

        for (uint256 i = 0; i < 20; i++) {
            nextWeek = thisWeek + WEEK;
            if (block.timestamp < nextWeek) {
                if (sinceLast == 0 && block.timestamp == t) {
                    tokensPerWeek[thisWeek] += toDistribute;
                } else {
                    tokensPerWeek[thisWeek] +=
                        (toDistribute * (block.timestamp - t)) /
                        sinceLast;
                }
                break;
            } else {
                if (sinceLast == 0 && nextWeek == t) {
                    tokensPerWeek[thisWeek] += toDistribute;
                } else {
                    tokensPerWeek[thisWeek] +=
                        (toDistribute * (nextWeek - t)) /
                        sinceLast;
                }
            }
            t = nextWeek;
            thisWeek = nextWeek;
        }

        emit Checkpoint(block.timestamp, toDistribute);
    }

    /***
     *@notice Transfer fee and update checkpoint
     *@dev Manual transfer and update in extreme cases, The checkpoint can be updated at most once every 24 hours
     */

    function distribute() public shouldStarted {
        uint256 amount = IERC20(token).balanceOf(bendCollector);
        if (
            amount != 0 &&
            (block.timestamp > lastTokenTime + TOKEN_CHECKPOINT_DEADLINE)
        ) {
            IERC20(token).transferFrom(bendCollector, address(this), amount);
            _checkpointBalance();
        }
    }

    /***
    *@notice Update the veBend total supply checkpoint
    *@dev The checkpoint is also updated by the first claimant each
         new epoch week. This function may be called independently
         of a claim, to reduce claiming gas costs.
    */
    function _checkpointTotalSupply() internal {
        IVeBend ve = veBend;
        uint256 t = timeCursor;
        uint256 roundedTimestamp = (block.timestamp / WEEK) * WEEK;
        ve.checkpointSupply();

        for (uint256 i = 0; i < 20; i++) {
            if (t > roundedTimestamp) {
                break;
            } else {
                uint256 epoch = _findTimestampEpoch(ve, t);
                IVeBend.Point memory pt = ve.supplyPointHistory(epoch);
                int256 dt = 0;
                if (t > pt.ts) {
                    // If the point is at 0 epoch, it can actually be earlier than the first deposit
                    // Then make dt 0
                    dt = int256(t - pt.ts);
                }
                int256 _veSupply = pt.bias - pt.slope * dt;
                veSupply[t] = uint256(_veSupply > 0 ? _veSupply : 0);
            }
            t += WEEK;
        }

        timeCursor = t;
    }

    function _findTimestampEpoch(IVeBend ve, uint256 _timestamp)
        internal
        view
        returns (uint256)
    {
        uint256 _min = 0;
        uint256 _max = ve.epoch();
        for (uint256 i = 0; i < 128; i++) {
            if (_min >= _max) {
                break;
            }
            uint256 _mid = (_min + _max + 2) / 2;
            IVeBend.Point memory pt = ve.supplyPointHistory(_mid);
            if (pt.ts <= _timestamp) {
                _min = _mid;
            } else {
                _max = _mid - 1;
            }
        }
        return _min;
    }

    function _findTimestampUserEpoch(
        IVeBend ve,
        address _user,
        uint256 _timestamp,
        uint256 _maxUserEpoch
    ) internal view returns (uint256) {
        uint256 _min = 0;
        uint256 _max = _maxUserEpoch;
        for (uint256 i = 0; i < 128; i++) {
            if (_min >= _max) {
                break;
            }
            uint256 _mid = (_min + _max + 2) / 2;
            IVeBend.Point memory pt = ve.userPointHistory(_user, _mid);
            if (pt.ts <= _timestamp) {
                _min = _mid;
            } else {
                _max = _mid - 1;
            }
        }
        return _min;
    }

    function _claim(
        address _addr,
        IVeBend _ve,
        uint256 _lastTokenTime
    ) internal returns (uint256) {
        // Minimal userEpoch is 0 (if user had no point)
        uint256 userEpoch = 0;
        uint256 toDistribute = 0;

        uint256 maxUserEpoch = _ve.userPointEpoch(_addr);
        if (maxUserEpoch == 0) {
            // No lock = no fees
            return 0;
        }
        uint256 weekCursor = timeCursorOf[_addr];
        if (weekCursor == 0) {
            // Need to do the initial binary search
            userEpoch = _findTimestampUserEpoch(
                _ve,
                _addr,
                startTime,
                maxUserEpoch
            );
        } else {
            userEpoch = userEpochOf[_addr];
        }

        if (userEpoch == 0) {
            userEpoch = 1;
        }

        IVeBend.Point memory userPoint = _ve.userPointHistory(_addr, userEpoch);

        if (weekCursor == 0) {
            weekCursor = ((userPoint.ts + WEEK - 1) / WEEK) * WEEK;
        }

        if (weekCursor >= _lastTokenTime) {
            return 0;
        }

        if (weekCursor < startTime) {
            weekCursor = startTime;
        }
        IVeBend.Point memory emptyPoint;
        IVeBend.Point memory oldUserPoint;

        // Iterate over weeks
        for (uint256 i = 0; i < 50; i++) {
            if (weekCursor >= _lastTokenTime) {
                break;
            }
            if (weekCursor >= userPoint.ts && userEpoch <= maxUserEpoch) {
                userEpoch += 1;
                oldUserPoint = userPoint;
                if (userEpoch > maxUserEpoch) {
                    userPoint = emptyPoint;
                } else {
                    userPoint = _ve.userPointHistory(_addr, userEpoch);
                }
            } else {
                // Calc
                // + i * 2 is for rounding errors
                int256 dt = int256(weekCursor - oldUserPoint.ts);
                int256 _balanceOf = oldUserPoint.bias - dt * oldUserPoint.slope;
                uint256 balanceOf = uint256(_balanceOf > 0 ? _balanceOf : 0);
                if (balanceOf == 0 && userEpoch > maxUserEpoch) {
                    break;
                }
                if (balanceOf > 0) {
                    toDistribute +=
                        (balanceOf * tokensPerWeek[weekCursor]) /
                        veSupply[weekCursor];
                }

                weekCursor += WEEK;
            }
        }

        userEpoch = Math.min(maxUserEpoch, userEpoch - 1);
        userEpochOf[_addr] = userEpoch;
        timeCursorOf[_addr] = weekCursor;

        emit Claimed(_addr, toDistribute, userEpoch, maxUserEpoch);

        return toDistribute;
    }

    /***
     *@notice Claim fees for `_addr`
     *@dev Each call to claim look at a maximum of 50 user veBend points.
        For accounts with many veBend related actions, this function
        may need to be called more than once to claim all available
        fees. In the `Claimed` event that fires, if `claimEpoch` is
        less than `max_epoch`, the account may claim again.
     *@param weth Whether claim weth or raw eth
     *@return uint256 Amount of fees claimed in the call
     */
    function claim(bool weth)
        external
        nonReentrant
        shouldStarted
        returns (uint256)
    {
        address _addr = msg.sender;

        // update veBend total supply checkpoint when a new epoch start
        if (block.timestamp >= timeCursor) {
            _checkpointTotalSupply();
        }

        // Transfer fee and update checkpoint
        distribute();

        lastTokenTime = (lastTokenTime / WEEK) * WEEK;

        uint256 amount = _claim(_addr, veBend, lastTokenTime);

        if (amount != 0) {
            if (weth) {
                _getLendPool().withdraw(token, amount, _addr);
            } else {
                _getLendPool().withdraw(token, amount, address(this));
                WETH.withdraw(amount);
                _safeTransferETH(_addr, amount);
            }
            tokenLastBalance -= amount;
        }

        return amount;
    }

    function _getLendPool() internal view returns (ILendPool) {
        return ILendPool(addressesProvider.getLendPool());
    }

    /**
     * @dev transfer ETH to an address, revert if it fails.
     * @param to recipient of the transfer
     * @param value the amount to send
     */
    function _safeTransferETH(address to, uint256 value) internal {
        (bool success, ) = to.call{value: value}(new bytes(0));
        require(success, "ETH_TRANSFER_FAILED");
    }
}