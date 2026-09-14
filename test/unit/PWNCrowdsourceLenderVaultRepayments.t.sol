// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.16;

import { Test } from "forge-std/Test.sol";
import {
    PWNCrowdsourceLenderVault, PWNLoan, PWNInstallmentsProduct, IAaveLike, Math
} from "pwn/periphery/crowdsource/PWNCrowdsourceLenderVault.sol";
import { CrowdsourceRepaymentLoan, CrowdsourceCallbackToken } from "test/helper/CrowdsourceRepaymentLoan.sol";
import { T20 } from "test/helper/T20.sol";


abstract contract CrowdsourceRepaymentTest is Test {
    PWNCrowdsourceLenderVault internal vault;
    CrowdsourceCallbackToken internal credit;
    T20 internal collateral;
    CrowdsourceRepaymentLoan internal loan;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal charlie = makeAddr("charlie");
    address internal dave = makeAddr("dave");
    address internal borrower = makeAddr("borrower");
    uint256 internal unit;

    function assetDecimals() internal pure virtual returns (uint8) { return 6; }

    function setUp() public virtual {
        unit = 10 ** assetDecimals();
        _deploy();
        _deposit(alice, 25_000 * unit);
        _deposit(bob, 75_000 * unit);
        _fund(80_000 * unit);
    }

    function _deploy() internal {
        credit = new CrowdsourceCallbackToken(assetDecimals());
        collateral = new CrowdsourceCallbackToken(18);
        loan = new CrowdsourceRepaymentLoan();
        IAaveLike.ReserveData memory reserve;
        address aave = makeAddr("aave");
        vm.mockCall(aave, abi.encodeWithSelector(IAaveLike.getReserveData.selector), abi.encode(reserve));
        PWNCrowdsourceLenderVault.Terms memory terms;
        terms.creditAddress = address(credit);
        terms.collateralAddress = address(collateral);
        vault = new PWNCrowdsourceLenderVault(
            PWNLoan(address(loan)), PWNInstallmentsProduct(makeAddr("product")), IAaveLike(aave), "Vault", "VLT", terms
        );
        vm.prank(borrower);
        credit.approve(address(loan), type(uint256).max);
    }

    function _deposit(address owner, uint256 assets) internal {
        credit.mint(owner, assets);
        vm.startPrank(owner);
        credit.approve(address(vault), assets);
        vault.deposit(assets, owner);
        vm.stopPrank();
    }

    function _fund(uint256 principal) internal {
        loan.fund(vault, borrower, principal, collateral, 100 ether);
    }

    function _repay(uint256 assets, bool fallbackToCore) internal {
        vm.prank(borrower);
        loan.repay(assets, fallbackToCore);
    }

    function _claim(address owner) internal returns (uint256 amount) {
        uint256 expected = vault.claimableRepayments(owner);
        uint256 shares = vault.balanceOf(owner);
        uint256 supply = vault.totalSupply();
        vm.prank(owner);
        amount = vault.claimRepayments(owner);
        assertEq(amount, expected, "claim preview mismatch");
        assertEq(vault.balanceOf(owner), shares, "claim burned shares");
        assertEq(vault.totalSupply(), supply);
        assertEq(vault.claimableRepayments(owner), 0, "cash can be claimed twice");
    }
}


contract PWNCrowdsourceLenderVaultRepayments_Test is CrowdsourceRepaymentTest {
    function test_claimsPreserveOwnershipAndOtherLendersCash() external {
        uint256 otherClaim = vault.claimableRepayments(bob);
        assertApproxEqAbs(_claim(alice), 5_000 * unit, 1);
        assertEq(_claim(alice), 0);
        assertEq(vault.claimableRepayments(bob), otherClaim);
        assertEq(vault.totalAssets(), 80_000 * unit);
        assertEq(vault.maxWithdraw(alice), 0);
        assertEq(vault.maxRedeem(alice), 0);
        _repay(20_000 * unit, false);
        assertApproxEqAbs(_claim(alice), 5_000 * unit, 1);
        assertApproxEqAbs(_claim(bob), 30_000 * unit, 1);
        assertEq(vault.totalAssets(), 60_000 * unit);
        assertEq(vault.balanceOf(alice), 25_000 * unit);
        assertEq(vault.balanceOf(bob), 75_000 * unit);
    }

    function test_orphanCashRegressionUsesIndependentClaims() external {
        _claim(alice);
        _repay(79_000 * unit, false);
        assertApproxEqAbs(_claim(alice), 19_750 * unit, 1);
        assertApproxEqAbs(_claim(bob), 74_250 * unit, 1);
        assertLe(credit.balanceOf(address(vault)), 2);
        assertEq(loan.getLOANDebt(1), 1_000 * unit);
        assertEq(vault.totalSupply(), 100_000 * unit);
        _repay(1_000 * unit, false);
        _claim(alice);
        _claim(bob);
        assertEq(credit.balanceOf(alice), 25_000 * unit);
        assertEq(credit.balanceOf(bob), 75_000 * unit);
        assertEq(credit.balanceOf(address(vault)), 0);
    }

    function test_fullTransferLeavesAccruedCashWithZeroShareSeller() external {
        uint256 earned = vault.claimableRepayments(alice);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.transfer(charlie, shares);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.claimableRepayments(charlie), 0);
        assertEq(_claim(alice), earned);
        _repay(20_000 * unit, false);
        assertEq(_claim(alice), 0);
        assertApproxEqAbs(_claim(charlie), 5_000 * unit, 1);
    }

    function test_almostCompleteExitCannotStrandAccruedCash() external {
        _claim(alice);
        _repay(79_000 * unit, false);
        uint256 shares = vault.balanceOf(bob) - 1;
        vm.prank(bob);
        vault.transfer(charlie, shares);
        assertEq(vault.balanceOf(bob), 1);
        assertApproxEqAbs(_claim(bob), 74_250 * unit, 1);
        _claim(alice);
        assertLe(credit.balanceOf(address(vault)), 2);
    }

    function test_partialTransferToExistingHolderPreservesBothAccruals() external {
        uint256 a = vault.claimableRepayments(alice);
        uint256 b = vault.claimableRepayments(bob);
        vm.prank(alice);
        vault.transfer(bob, 10_000 * unit);
        assertEq(vault.claimableRepayments(alice), a);
        assertEq(vault.claimableRepayments(bob), b);
        _repay(20_000 * unit, false);
        assertApproxEqAbs(_claim(alice), 8_000 * unit, 1);
        assertApproxEqAbs(_claim(bob), 32_000 * unit, 1);
    }

    function test_shareAllowanceCannotSpendEarnedRepayments() external {
        vm.prank(alice);
        vault.approve(charlie, type(uint256).max);
        vm.prank(charlie);
        assertEq(vault.claimRepayments(charlie), 0);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(charlie);
        vault.transferFrom(alice, charlie, shares);
        assertEq(_claim(charlie), 0);
        assertApproxEqAbs(_claim(alice), 5_000 * unit, 1);
    }

    function test_multipleRepaymentsAndDonationsAllocateOnlyOnce() external {
        _repay(4_000 * unit, false);
        _repay(8_000 * unit, false);
        credit.mint(address(vault), 8_000 * unit);
        assertApproxEqAbs(_claim(alice), 10_000 * unit, 1);
        assertEq(_claim(alice), 0);
        assertApproxEqAbs(_claim(bob), 30_000 * unit, 1);
        assertLe(credit.balanceOf(address(vault)), 2);
    }

    function test_defaultCollateralDoesNotDependOnEarlierCashClaims() external {
        _claim(alice);
        uint256 bobCash = vault.claimableRepayments(bob);
        loan.setDefaulted(false);
        assertEq(vault.maxRedeem(alice), 25_000 * unit);
        assertEq(vault.previewRedeem(25_000 * unit), 0);
        assertEq(vault.totalAssets(), 0);
        vm.prank(alice);
        vault.redeem(25_000 * unit, alice, alice);
        assertEq(collateral.balanceOf(alice), 25 ether);
        assertEq(vault.claimableRepayments(bob), bobCash);
        vm.prank(bob);
        vault.claimAndRedeem(bob);
        assertEq(collateral.balanceOf(bob), 75 ether);
        assertEq(credit.balanceOf(bob), bobCash);
        assertEq(loan.liquidations(), 1);
        assertEq(vault.totalSupply(), 0);
        assertEq(collateral.balanceOf(address(vault)), 0);
    }

    function test_allLendersCanClaimCashThenDefaultCollateral() external {
        _claim(alice);
        _claim(bob);
        loan.setDefaulted(false);
        vm.prank(bob);
        vault.claimAndRedeem(bob);
        vm.prank(alice);
        vault.claimAndRedeem(alice);
        assertEq(collateral.balanceOf(alice), 25 ether);
        assertEq(collateral.balanceOf(bob), 75 ether);
        assertEq(loan.liquidations(), 1);
    }

    function test_zeroShareOwnersCanClaimAfterEveryoneRedeems() external {
        _repay(80_000 * unit, false);
        assertEq(vault.maxRedeem(alice), vault.balanceOf(alice));
        vm.prank(alice);
        vault.approve(charlie, 25_000 * unit);
        vm.prank(charlie);
        assertEq(vault.redeem(25_000 * unit, charlie, alice), 0);
        vm.prank(bob);
        vault.redeem(75_000 * unit, bob, bob);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.allowance(alice, charlie), 0);
        assertEq(_claim(charlie), 0);
        assertEq(_claim(alice), 25_000 * unit);
        vm.prank(bob);
        (uint256 cash, uint256 coll) = vault.claimAndRedeem(bob);
        assertEq(cash, 75_000 * unit);
        assertEq(coll, 0);
        assertEq(credit.balanceOf(address(vault)), 0);
    }

    function test_combinedExitMatchesSeparateOperations() external {
        _repay(10_000 * unit, false);
        loan.setDefaulted(false);
        uint256 snapshot = vm.snapshot();
        vm.prank(alice);
        (uint256 cash, uint256 coll) = vault.claimAndRedeem(charlie);
        assertEq(credit.balanceOf(charlie), cash);
        assertEq(collateral.balanceOf(charlie), coll);
        vm.revertTo(snapshot);
        vm.startPrank(alice);
        uint256 separateCash = vault.claimRepayments(charlie);
        vault.redeem(vault.balanceOf(alice), charlie, alice);
        vm.stopPrank();
        assertEq(separateCash, cash);
        assertEq(collateral.balanceOf(charlie), coll);
    }

    function test_cashClaimDoesNotRequireSuccessfulLiquidation() external {
        loan.setDefaulted(true);
        uint256 expected = vault.claimableRepayments(alice);
        vm.expectRevert("liquidation unavailable");
        vm.prank(alice);
        vault.claimAndRedeem(alice);
        assertEq(vault.claimableRepayments(alice), expected);
        assertEq(_claim(alice), expected);
        assertEq(loan.liquidations(), 0);
    }

    function test_coreHeldRepaymentRecoveredBeforeShareTransfer() external {
        _repay(20_000 * unit, true);
        uint256 a = vault.claimableRepayments(alice);
        assertApproxEqAbs(a, 10_000 * unit, 1);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.transfer(charlie, shares);
        assertEq(loan.recoveries(), 1);
        assertEq(loan.getLOAN(1).unclaimedRepayment, 0);
        assertEq(vault.claimableRepayments(alice), a);
        assertEq(_claim(charlie), 0);
        assertEq(_claim(alice), a);
        assertApproxEqAbs(_claim(bob), 30_000 * unit, 1);
        assertEq(loan.recoveries(), 1);
    }

    function test_coreHeldFinalRepaymentRecoveredBeforeBurn() external {
        _repay(80_000 * unit, true);
        assertEq(vault.maxRedeem(alice), 25_000 * unit);
        vm.prank(alice);
        vault.redeem(25_000 * unit, alice, alice);
        assertEq(loan.recoveries(), 1);
        assertEq(_claim(alice), 25_000 * unit);
        vm.prank(bob);
        vault.claimAndRedeem(bob);
        assertEq(credit.balanceOf(address(vault)), 0);
    }

    function test_endingDonationGoesOnlyToRemainingShares() external {
        _repay(80_000 * unit, false);
        vm.prank(alice);
        vault.redeem(25_000 * unit, alice, alice);
        credit.mint(address(vault), 100 * unit);
        assertEq(_claim(alice), 25_000 * unit);
        assertApproxEqAbs(_claim(bob), 75_100 * unit, 1);
        vm.prank(bob);
        vault.redeem(75_000 * unit, bob, bob);
        uint256 reserve = credit.balanceOf(address(vault));
        credit.mint(address(vault), 100 * unit);
        assertEq(_claim(alice), 0);
        assertEq(_claim(bob), 0);
        assertEq(credit.balanceOf(address(vault)), reserve + 100 * unit);
    }

    function test_virtualReserveCannotBeSweptByFinalExit() external {
        _deploy();
        _deposit(alice, 1);
        _fund(1);
        credit.mint(address(vault), 100 * unit - 1);
        _repay(1, false);
        vm.prank(alice);
        (uint256 cash,) = vault.claimAndRedeem(alice);
        assertEq(cash, 50 * unit);
        assertEq(credit.balanceOf(address(vault)), 50 * unit);
        assertEq(vault.totalSupply(), 0);
        assertEq(_claim(alice), 0);
    }

    function test_exactShareMintRetainsReserveThroughRepayment() external {
        _deploy();
        _deposit(alice, 2);
        credit.mint(address(vault), 100 * unit);
        uint256 mintCost = vault.previewMint(1);
        credit.mint(bob, mintCost);
        vm.startPrank(bob);
        credit.approve(address(vault), mintCost);
        vault.mint(1, bob);
        vm.stopPrank();
        uint256 principal = credit.balanceOf(address(vault));
        _fund(principal);
        _repay(principal, false);
        vm.prank(alice);
        (uint256 attackerCash,) = vault.claimAndRedeem(alice);
        vm.prank(bob);
        vault.claimAndRedeem(bob);
        assertLt(attackerCash, 100 * unit + 2, "new exit refunds attacker's donation reserve");
        assertGt(credit.balanceOf(address(vault)), 0);
        assertApproxEqAbs(credit.balanceOf(bob), mintCost, 1);
    }

    function _assertRoundingDepositRejected(uint256 assets) internal {
        credit.mint(bob, assets);
        vm.startPrank(bob);
        credit.approve(address(vault), assets);
        vm.expectRevert("PWNCrowdsourceLenderVault: excessive deposit rounding");
        vault.deposit(assets, bob);
        vm.stopPrank();
        assertEq(vault.balanceOf(bob), 0);
        assertEq(credit.balanceOf(bob), assets);
    }

    function test_donationCannotRoundVictimDepositToZeroShares() external {
        _deploy();
        _deposit(alice, 1);
        credit.mint(address(vault), 100 * unit);
        assertEq(vault.previewDeposit(49 * unit), 0);
        _assertRoundingDepositRejected(49 * unit);
    }

    function test_donationCannotRoundAwayValueEvenWithPositiveShares() external {
        _deploy();
        _deposit(alice, 2);
        credit.mint(address(vault), 100 * unit);
        assertEq(vault.previewDeposit(60 * unit), 1);
        _assertRoundingDepositRejected(60 * unit);
        _deploy();
        _deposit(alice, 10);
        credit.mint(address(vault), 100 * unit);
        assertEq(vault.previewDeposit(18 * unit), 1);
        _assertRoundingDepositRejected(18 * unit);
    }

    function test_depositAcceptsOneBaseUnitConversionDifference() external {
        _deploy();
        _deposit(alice, 1);
        credit.mint(address(vault), 4); // share price = (5+1)/(1+1) = 3
        assertEq(vault.previewDeposit(4), 1);
        assertEq(vault.previewMint(1), 3);
        _deposit(bob, 4);
        assertEq(vault.balanceOf(bob), 1);
    }

    function test_failedTransferPreservesClaimAndAccounting() external {
        uint256 expected = vault.claimableRepayments(alice);
        credit.setFailTransfers(true);
        vm.expectRevert("transfer unavailable");
        vm.prank(alice);
        vault.claimRepayments(alice);
        credit.setFailTransfers(false);
        assertEq(_claim(alice), expected);
    }

    function test_outgoingCallbackCannotTransferSharesOrClaimTwice() external {
        vm.prank(alice);
        vault.approve(address(credit), type(uint256).max);
        credit.setCallback(address(vault), address(vault), abi.encodeWithSelector(vault.transferFrom.selector, alice, charlie, 1));
        _claim(alice);
        assertTrue(credit.callbackAttempted());
        assertFalse(credit.callbackSucceeded());
        assertEq(vault.balanceOf(charlie), 0);
        credit.setCallback(address(vault), address(vault), abi.encodeWithSelector(vault.claimRepayments.selector, charlie));
        _claim(bob);
        assertTrue(credit.callbackAttempted());
        assertFalse(credit.callbackSucceeded());
    }

    function test_lockedLoanDoesNotExposeOrAllocateTransientCash() external {
        loan.setLocked(true);
        assertEq(vault.claimableRepayments(alice), 0);
        assertEq(vault.maxRedeem(alice), 0);
        vm.expectRevert("PWNCrowdsourceLenderVault: loan context locked");
        vm.prank(alice);
        vault.claimRepayments(alice);
        vm.expectRevert("PWNCrowdsourceLenderVault: loan context locked");
        vm.prank(alice);
        vault.transfer(charlie, 1);
        loan.setLocked(false);
        assertApproxEqAbs(_claim(alice), 5_000 * unit, 1);
    }

    function test_fundingCallbackCannotAllocatePrincipal() external {
        _deploy();
        _deposit(alice, 25_000 * unit);
        _deposit(bob, 75_000 * unit);
        credit.setCallback(address(vault), address(vault), abi.encodeWithSelector(vault.claimableRepayments.selector, alice));
        _fund(80_000 * unit);
        assertTrue(credit.callbackSucceeded());
        assertEq(abi.decode(credit.callbackResult(), (uint256)), 0);
        assertApproxEqAbs(_claim(alice), 5_000 * unit, 1);
    }

    function test_finalRepaymentCallbackCannotBurnBeforeCashArrives() external {
        credit.setCallback(borrower, address(vault), abi.encodeWithSelector(vault.claimAndRedeem.selector, charlie));
        _repay(80_000 * unit, false);
        assertTrue(credit.callbackAttempted());
        assertFalse(credit.callbackSucceeded());
        assertEq(vault.totalSupply(), 100_000 * unit);
        assertEq(_claim(alice), 25_000 * unit);
    }

    function test_zeroAndSelfTransfersDoNotChangeClaims() external {
        uint256 expected = vault.claimableRepayments(alice);
        vm.startPrank(alice);
        vault.transfer(bob, 0);
        vault.transfer(alice, vault.balanceOf(alice));
        vm.stopPrank();
        assertEq(_claim(alice), expected);
    }

    function test_rejectReceiversThatStrandClaimsOrShares() external {
        vm.startPrank(alice);
        vm.expectRevert("PWNCrowdsourceLenderVault: invalid receiver");
        vault.claimRepayments(address(vault));
        vm.expectRevert("PWNCrowdsourceLenderVault: invalid receiver");
        vault.claimRepayments(address(0));
        vm.expectRevert("PWNCrowdsourceLenderVault: invalid receiver");
        vault.transfer(address(vault), 1);
        vm.stopPrank();
        _deploy();
        assertEq(vault.maxDeposit(address(vault)), 0);
        assertEq(vault.maxMint(address(0)), 0);
        vm.expectRevert("PWNCrowdsourceLenderVault: no shares");
        _fund(1);
    }

    function test_runningWithdrawRedeemAndCombinedExitAreDisabled() external {
        vm.startPrank(alice);
        vm.expectRevert("PWNCrowdsourceLenderVault: withdraw disabled, use claimRepayments");
        vault.withdraw(1, alice, alice);
        vm.expectRevert("PWNCrowdsourceLenderVault: redeem disabled");
        vault.redeem(1, alice, alice);
        vm.expectRevert("PWNCrowdsourceLenderVault: redeem disabled");
        vault.claimAndRedeem(alice);
        vm.stopPrank();
    }

    function test_claimViewDoesNotQuoteTransientOutgoingCash() external {
        credit.setCallback(address(vault), address(vault), abi.encodeWithSelector(vault.claimableRepayments.selector, bob));
        uint256 expected = vault.claimableRepayments(bob);
        _claim(alice);
        assertTrue(credit.callbackSucceeded());
        assertEq(abi.decode(credit.callbackResult(), (uint256)), 0);
        assertEq(vault.claimableRepayments(bob), expected);
    }

    function test_collateralCallbackCannotMoveAnotherLendersShares() external {
        loan.setDefaulted(false);
        vm.prank(bob);
        vault.approve(address(collateral), type(uint256).max);
        CrowdsourceCallbackToken token = CrowdsourceCallbackToken(address(collateral));
        token.setCallback(address(vault), address(vault), abi.encodeWithSelector(vault.transferFrom.selector, bob, charlie, 1));
        vm.prank(alice);
        vault.claimAndRedeem(alice);
        assertTrue(token.callbackAttempted());
        assertFalse(token.callbackSucceeded());
        assertEq(vault.balanceOf(bob), 75_000 * unit);
    }

    function test_fullPrecisionProductsCanExceed256Bits() external {
        _deploy();
        _deposit(alice, 1e40);
        _fund(1e40);
        credit.mint(address(vault), 1e60);
        uint256 expected = Math.mulDiv(1e40, 1e60 + 1, 1e40 + 1);
        // Index precision is finite; its maximum whole-asset error is bounded by shares / precision.
        assertApproxEqAbs(_claim(alice), expected, 1e13);
        assertEq(credit.balanceOf(alice) + credit.balanceOf(address(vault)), 1e60);
    }

    function test_frequentClaimsPreserveFractionalEntitlements() external {
        uint256 snapshot = vm.snapshot();
        for (uint256 i; i < 200; ++i) {
            credit.mint(address(vault), 1);
            _claim(alice);
            _claim(bob);
        }
        uint256 a = credit.balanceOf(alice);
        uint256 b = credit.balanceOf(bob);
        vm.revertTo(snapshot);
        credit.mint(address(vault), 200);
        assertEq(_claim(alice), a);
        assertEq(_claim(bob), b);
    }
}


/** @dev A receipt-by-receipt rational model, independent of the contract's fixed-point index.*/
contract PWNCrowdsourceLenderVaultRepaymentModel_Test is CrowdsourceRepaymentTest {
    struct Model {
        address[4] owners;
        uint256[4] numerator;
        uint256 supply;
        uint256 received;
    }

    function testFuzz_cashConservationAndRationalEntitlements(uint256 seed, bool defaulted) external {
        Model memory m;
        m.owners = [alice, bob, charlie, dave];
        m.supply = vault.totalSupply();
        uint256 denominator = m.supply + 1;
        m.received = 20_000 * unit;
        for (uint256 i; i < m.owners.length; ++i) m.numerator[i] = (m.received + 1) * vault.balanceOf(m.owners[i]);

        for (uint256 step; step < 96; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint256 actor = (seed >> 8) % m.owners.length;
            uint256 action = seed % 3;
            if (action == 0) {
                uint256 amount = (seed >> 16) % (1_000 * unit + 1);
                credit.mint(address(vault), amount);
                m.received += amount;
                for (uint256 i; i < m.owners.length; ++i) m.numerator[i] += amount * vault.balanceOf(m.owners[i]);
            } else if (action == 1) {
                _claim(m.owners[actor]);
            } else {
                uint256 shares = vault.balanceOf(m.owners[actor]);
                uint256 amount = (seed >> 16) % (shares + 1);
                vm.prank(m.owners[actor]);
                vault.transfer(m.owners[(seed >> 32) % m.owners.length], amount);
            }
            uint256 paid;
            uint256 claimable;
            for (uint256 i; i < m.owners.length; ++i) {
                uint256 cash = credit.balanceOf(m.owners[i]);
                uint256 pending = vault.claimableRepayments(m.owners[i]);
                // Fixed-point division can move a sub-unit fraction across a transfer checkpoint.
                assertApproxEqAbs(cash + pending, m.numerator[i] / denominator, 1, "rational entitlement mismatch");
                paid += cash;
                claimable += pending;
            }
            assertEq(paid + credit.balanceOf(address(vault)), m.received, "cash not conserved");
            assertLe(claimable, credit.balanceOf(address(vault)), "unbacked claims");
            assertEq(vault.totalSupply(), m.supply, "running ownership changed");
        }

        if (defaulted) {
            loan.setDefaulted(false);
        } else {
            uint256 repayment = loan.getLOANDebt(1);
            for (uint256 i; i < m.owners.length; ++i) m.numerator[i] += repayment * vault.balanceOf(m.owners[i]);
            m.received += repayment;
            _repay(repayment, false);
        }
        for (uint256 i; i < m.owners.length; ++i) {
            uint256 shares = vault.balanceOf(m.owners[i]);
            assertEq(vault.maxRedeem(m.owners[i]), shares);
            vm.prank(m.owners[i]);
            vault.redeem(shares, m.owners[i], m.owners[i]);
            if (defaulted) assertApproxEqAbs(collateral.balanceOf(m.owners[i]), Math.mulDiv(shares, 100 ether, m.supply), 3);
        }
        uint256 totalPaid;
        for (uint256 i; i < m.owners.length; ++i) {
            _claim(m.owners[i]);
            totalPaid += credit.balanceOf(m.owners[i]);
            assertApproxEqAbs(credit.balanceOf(m.owners[i]), m.numerator[i] / denominator, 1);
        }
        assertEq(vault.totalSupply(), 0);
        assertEq(totalPaid + credit.balanceOf(address(vault)), m.received);
        // Virtual reserve plus at most one fractional base unit per address (and fixed-point error).
        assertLe(credit.balanceOf(address(vault)), m.received / denominator + 8);
        if (defaulted) assertEq(collateral.balanceOf(address(vault)), 0);
    }
}


contract PWNCrowdsourceLenderVaultRepaymentModel18_Test is PWNCrowdsourceLenderVaultRepaymentModel_Test {
    function assetDecimals() internal pure override returns (uint8) { return 18; }
}
