// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import { TestBaseDToken } from "../TestBaseDToken.sol";

contract DTokenRepayTest is TestBaseDToken {
    event Repay(address payer, address borrower, uint256 repayAmount);

    function setUp() public override {
        super.setUp();

        dUSDC.borrow(100e6);

        skip(15 minutes);
    }

    function test_dTokenRepay_fail_whenRepayIsNotAllowed() public {
        rewind(1);

        vm.expectRevert();
        dUSDC.repay(100e6);
    }

    function test_dTokenRepay_fail_whenBorrowAmountExceedsCash() public {
        uint256 borrowBalanceCurrent = dUSDC.borrowBalanceCurrent(
            address(this)
        );

        vm.expectRevert();
        dUSDC.repay(borrowBalanceCurrent + 1);
    }

    function test_dTokenRepay_success() public {
        dUSDC.borrowBalanceCurrent(address(this));

        uint256 underlyingBalance = usdc.balanceOf(address(this));
        uint256 balance = dUSDC.balanceOf(address(this));
        uint256 totalSupply = dUSDC.totalSupply();
        uint256 totalBorrows = dUSDC.totalBorrows();

        vm.expectEmit(true, true, true, true, address(dUSDC));
        emit Repay(address(this), address(this), 100e6);

        dUSDC.repay(100e6);

        assertEq(usdc.balanceOf(address(this)), underlyingBalance - 100e6);
        assertEq(dUSDC.balanceOf(address(this)), balance);
        assertEq(dUSDC.totalSupply(), totalSupply);
        assertEq(dUSDC.totalBorrows(), totalBorrows - 100e6);
    }

    function test_dTokenRepay_success_whenRepayAll() public {
        uint256 borrowBalanceCurrent = dUSDC.borrowBalanceCurrent(
            address(this)
        );
        uint256 underlyingBalance = usdc.balanceOf(address(this));
        uint256 balance = dUSDC.balanceOf(address(this));
        uint256 totalSupply = dUSDC.totalSupply();
        uint256 totalBorrows = dUSDC.totalBorrows();

        vm.expectEmit(true, true, true, true, address(dUSDC));
        emit Repay(address(this), address(this), borrowBalanceCurrent);

        dUSDC.repay(0);

        assertEq(
            usdc.balanceOf(address(this)),
            underlyingBalance - borrowBalanceCurrent
        );
        assertEq(dUSDC.balanceOf(address(this)), balance);
        assertEq(dUSDC.totalSupply(), totalSupply);
        assertEq(dUSDC.totalBorrows(), totalBorrows - borrowBalanceCurrent);
    }
}
