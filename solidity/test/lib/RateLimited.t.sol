// SPDX-License-Identifier: MIT or Apache-2.0
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {RateLimited} from "../../contracts/libs/RateLimited.sol";

contract TestRateLimited is RateLimited {
    constructor(
        uint256 _maxCapacity,
        uint256 _duration
    ) RateLimited(_maxCapacity, _duration) {}

    function validateAndConsumeFilledLevel(
        uint256 _amount
    ) public returns (uint256) {
        return _validateAndConsumeFilledLevel(_amount);
    }
}

contract RateLimitLibTest is Test {
    TestRateLimited rateLimited;
    uint256 constant MAX_CAPACITY = 1 ether;
    uint256 constant DURATION = 1 days;
    uint256 constant ONE_PERCENT = 0.01 ether; // Used for assertApproxEqRel
    address HOOK = makeAddr("HOOK");

    function setUp() public {
        rateLimited = new TestRateLimited(MAX_CAPACITY, DURATION);
    }

    function testConstructor_revertsWhen_lowCapacity() public {
        vm.expectRevert("Capacity must be greater than DURATION");
        new RateLimited(DURATION - 1, DURATION);
    }

    function testConstructor_revertsWhen_zeroDuration() public {
        vm.expectRevert("DURATION must be greater than 0");
        new RateLimited(MAX_CAPACITY, 0);
    }

    function testConstructor_setsCustomDuration() public {
        TestRateLimited custom = new TestRateLimited(MAX_CAPACITY, 1 hours);
        assertEq(custom.DURATION(), 1 hours);
        // refillRate = capacity / duration; for 1 ether / 1 hour
        assertEq(custom.refillRate(), MAX_CAPACITY / uint256(1 hours));
    }

    function testRateLimited_setsNewLimit() external {
        assert(rateLimited.setRefillRate(2 ether) > 0);
        assertApproxEqRel(rateLimited.maxCapacity(), 2 ether, ONE_PERCENT);
        assertEq(rateLimited.refillRate(), uint256(2 ether) / 1 days); // 2 ether / 1 day
    }

    function testRateLimited_returnsZeroIfMaxNotSet() external {
        rateLimited.setRefillRate(0);
        // `calculateCurrentLevel` no longer reverts on zero capacity —
        // dynamic-capacity subclasses rely on it being a pass-through.
        assertEq(rateLimited.calculateCurrentLevel(), 0);
    }

    function testRateLimited_returnsCurrentFilledLevel_anyDay(
        uint40 time
    ) external {
        time = uint40(bound(time, 1 days, 2 days));
        vm.warp(time);

        // Using approx because division won't be exact
        assertApproxEqRel(
            rateLimited.calculateCurrentLevel(),
            MAX_CAPACITY,
            ONE_PERCENT
        );
    }

    function testRateLimited_onlyOwnerCanSetTargetLimit() external {
        vm.prank(address(0));
        vm.expectRevert();
        rateLimited.setRefillRate(1 ether);
    }

    function testConsumedFilledLevelEvent() public {
        uint256 consumeAmount = 0.5 ether;

        vm.expectEmit(true, true, false, true);
        emit RateLimited.ConsumedFilledLevel(
            499999999999993600,
            block.timestamp
        ); // precision loss
        rateLimited.validateAndConsumeFilledLevel(consumeAmount);

        assertApproxEqRelDecimal(
            rateLimited.filledLevel(),
            MAX_CAPACITY - consumeAmount,
            1e14,
            0
        );
        assertEq(rateLimited.lastUpdated(), block.timestamp);
    }

    function testRateLimited_neverReturnsGtMaxLimit(
        uint256 _newAmount,
        uint40 _newTime
    ) external {
        _newTime = uint40(bound(_newTime, 1 days, type(uint40).max));
        vm.warp(_newTime);
        vm.assume(_newAmount <= rateLimited.calculateCurrentLevel());
        rateLimited.validateAndConsumeFilledLevel(_newAmount);
        assertLe(
            rateLimited.calculateCurrentLevel(),
            rateLimited.maxCapacity()
        );
    }

    function testRateLimited_decreasesLimitWithinSameDay() external {
        vm.warp(1 days);
        uint256 currentTargetLimit = rateLimited.calculateCurrentLevel();
        uint256 amount = 0.4 ether;
        uint256 newLimit = rateLimited.validateAndConsumeFilledLevel(amount);
        assertEq(newLimit, currentTargetLimit - amount);

        // Consume the same amount
        currentTargetLimit = rateLimited.calculateCurrentLevel();
        newLimit = rateLimited.validateAndConsumeFilledLevel(amount);
        assertEq(newLimit, currentTargetLimit - amount);

        // One more to exceed limit
        vm.expectRevert();
        rateLimited.validateAndConsumeFilledLevel(amount);
    }

    function testRateLimited_replinishesWithinSameDay() external {
        vm.warp(1 days);
        uint256 amount = 0.95 ether;
        uint256 newLimit = rateLimited.validateAndConsumeFilledLevel(amount);
        uint256 currentTargetLimit = rateLimited.calculateCurrentLevel();
        assertApproxEqRel(currentTargetLimit, 0.05 ether, ONE_PERCENT);

        // Warp to near end-of-day
        vm.warp(block.timestamp + 0.99 days);
        newLimit = rateLimited.validateAndConsumeFilledLevel(amount);
        assertApproxEqRel(newLimit, 0.05 ether, ONE_PERCENT);
    }

    function testRateLimited_shouldResetLimit_ifDurationExceeds(
        uint256 _amount
    ) external {
        // Transfer less than the limit
        vm.warp(0.5 days);
        uint256 currentTargetLimit = rateLimited.calculateCurrentLevel();
        vm.assume(_amount < currentTargetLimit);

        uint256 newLimit = rateLimited.validateAndConsumeFilledLevel(_amount);
        assertApproxEqRel(newLimit, currentTargetLimit - _amount, ONE_PERCENT);

        // Warp to a new cycle
        vm.warp(10 days);
        currentTargetLimit = rateLimited.calculateCurrentLevel();
        assertApproxEqRel(currentTargetLimit, MAX_CAPACITY, ONE_PERCENT);
    }

    function testCalculateCurrentLevel_returnsZeroWhenCapacityIsZero() public {
        rateLimited.setRefillRate(0);
        assertEq(rateLimited.calculateCurrentLevel(), 0);
    }

    function testValidateAndConsumeFilledLevel_revertsWhenExceedingLimit()
        public
    {
        vm.warp(1 days);
        uint256 initialLevel = rateLimited.calculateCurrentLevel();

        uint256 excessAmount = initialLevel + 1 ether;

        vm.expectRevert("RateLimitExceeded");
        rateLimited.validateAndConsumeFilledLevel(excessAmount);
        assertEq(rateLimited.calculateCurrentLevel(), initialLevel);
    }

    function testRateLimited_customDuration_replenishesOverWindow() external {
        // 1-hour refill window: bucket should be full again 1 hour after a
        // full drain. With the previous hardcoded 1-day window, this would
        // sit at ~1/24 of the cap.
        TestRateLimited hourly = new TestRateLimited(MAX_CAPACITY, 1 hours);

        // Drain most of the bucket immediately after construction.
        uint256 drain = (MAX_CAPACITY * 99) / 100;
        hourly.validateAndConsumeFilledLevel(drain);

        // Skip a full refill window; bucket should be back at maxCapacity.
        vm.warp(block.timestamp + 1 hours);
        assertApproxEqRel(
            hourly.calculateCurrentLevel(),
            MAX_CAPACITY,
            ONE_PERCENT
        );
    }
}
