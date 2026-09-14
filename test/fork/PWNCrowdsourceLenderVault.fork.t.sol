// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.16;

import { MultiToken, IERC20 } from "MultiToken/MultiToken.sol";

import { PWNLoan, IPWNBorrowerCreateHook } from "pwn/core/loan/PWNLoan.sol";
import { PWNInstallmentsProduct } from "pwn/periphery/product/PWNInstallmentsProduct.sol";

import { PWNCrowdsourceLenderVault, ERC20 } from "src/periphery/crowdsource/PWNCrowdsourceLenderVault.sol";

import { DeploymentTest, PWNHubTags } from "test/DeploymentTest.t.sol";
import { T20 } from "test/helper/T20.sol";


contract PWNCrowdsourceLenderVaultForkTest is DeploymentTest {

    uint256 ERR_DELTA = 0.001 ether; // 0.01%

    IERC20 constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address constant aUSDC = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;
    address constant aWETH = 0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8;

    address constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address constant USD = address(840);

    PWNLoan.LenderSpec lenderSpec;
    PWNInstallmentsProduct.Proposal proposal;
    PWNInstallmentsProduct.AcceptorValues acceptorValues;
    PWNCrowdsourceLenderVault.Terms terms;
    T20 noAaveToken;

    PWNCrowdsourceLenderVault lenderVault;
    address[4] lenders;
    uint256 initialAmount = 50_000e6;

    function setUp() override public virtual {
        vm.createSelectFork("mainnet");

        super.setUp();

        noAaveToken = new T20();

        vm.startPrank(__e.protocolTimelock);
        __d.chainlinkFeedRegistry.proposeFeed(ETH, USD, 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
        __d.chainlinkFeedRegistry.confirmFeed(ETH, USD, 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
        __d.chainlinkFeedRegistry.proposeFeed(address(USDC), USD, 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6);
        __d.chainlinkFeedRegistry.confirmFeed(address(USDC), USD, 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6);
        // Use USDC price feed for noAaveToken
        __d.chainlinkFeedRegistry.proposeFeed(address(noAaveToken), USD, 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6);
        __d.chainlinkFeedRegistry.confirmFeed(address(noAaveToken), USD, 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6);
        vm.stopPrank();

        lenders = [makeAddr("lender1"), makeAddr("lender2"), makeAddr("lender3"), makeAddr("lender4")];

        _deployWith(address(USDC), 6);

        for (uint256 i; i < lenders.length; ++i) {
            vm.startPrank(aUSDC);
            USDC.transfer(lenders[i], initialAmount);

            vm.startPrank(lenders[i]);
            USDC.approve(address(lenderVault), type(uint256).max);
            lenderVault.deposit(initialAmount, lenders[i]);
            vm.stopPrank();
        }

        vm.prank(aWETH);
        WETH.transfer(borrower, 1000e18);
        vm.startPrank(borrower);
        WETH.approve(address(__d.loan), type(uint256).max);
        USDC.approve(address(__d.loan), type(uint256).max);
        vm.stopPrank();

        vm.label(address(lenderVault.aave()), "Aave");
        vm.label(address(USDC), "USDC");
        vm.label(address(WETH), "WETH");
        vm.label(address(noAaveToken), "NO-AAVE");
    }


    function _deployWith(address creditAddress, uint256 decimals) internal {
        _deployWith(creditAddress, decimals, 36500);
    }

    function _deployWith(address creditAddress, uint256 decimals, uint24 apr) internal {
        _deployWith(creditAddress, decimals, apr, 730 days);
    }

    function _deployWith(address creditAddress, uint256 decimals, uint24 apr, uint256 duration) internal {
        terms = PWNCrowdsourceLenderVault.Terms({
            collateralAddress: address(WETH),
            creditAddress: creditAddress,
            feedIntermediaryDenominations: new address[](1),
            feedInvertFlags: new bool[](2),
            loanToValue: 8000, // 80%
            interestAPR: apr,
            postponement: 120 days,
            duration: duration,
            minCreditAmount: 150_000 * 10 ** decimals,
            expiration: block.timestamp + 60 days,
            allowedAcceptor: address(0)
        });
        terms.feedIntermediaryDenominations[0] = USD;
        terms.feedInvertFlags[0] = false;
        terms.feedInvertFlags[1] = true;

        lenderVault = new PWNCrowdsourceLenderVault(__d.loan, __d.products.installments, __e.aave, "Bordel mortgage share", "BORDEL", terms);
        lenderSpec = PWNLoan.LenderSpec({
            createHook: lenderVault, createHookData: "", repaymentHook: lenderVault, repaymentHookData: ""
        });

        proposal = PWNInstallmentsProduct.Proposal({
            collateralAddress: terms.collateralAddress,
            creditAddress: terms.creditAddress,
            feedIntermediaryDenominations: terms.feedIntermediaryDenominations,
            feedInvertFlags: terms.feedInvertFlags,
            loanToValue: terms.loanToValue,
            interestAPR: terms.interestAPR,
            postponement: terms.postponement,
            duration: terms.duration,
            minCreditAmount: terms.minCreditAmount,
            availableCreditLimit: 0,
            utilizedCreditId: 0,
            nonceSpace: 0,
            nonce: 0,
            expiration: terms.expiration,
            proposerSpecHash: __d.loan.getLenderSpecHash(lenderSpec),
            isProposerLender: true,
            allowedAcceptor: terms.allowedAcceptor,
            loanContract: address(__d.loan)
        });
        acceptorValues = PWNInstallmentsProduct.AcceptorValues({
            creditAmount: 180_000 * 10 ** decimals
        });
    }

}


contract PWNCrowdsourceLenderVault_Pooling_ForkTest is PWNCrowdsourceLenderVaultForkTest {

    function test_shouldWithdraw_whenPoolingStage() external {
        assertApproxEqRel(lenderVault.totalAssets(), initialAmount * lenders.length, ERR_DELTA);
        assertApproxEqRel(lenderVault.balanceOf(lenders[0]), initialAmount, ERR_DELTA);
        assertApproxEqRel(USDC.balanceOf(lenders[0]), 0, ERR_DELTA);

        assertApproxEqRel(lenderVault.maxWithdraw(lenders[0]), initialAmount, ERR_DELTA);

        vm.prank(lenders[0]);
        lenderVault.withdraw(initialAmount / 2, lenders[0], lenders[0]);

        assertApproxEqRel(lenderVault.totalAssets(), initialAmount * lenders.length - initialAmount / 2, ERR_DELTA);
        assertApproxEqRel(lenderVault.balanceOf(lenders[0]), initialAmount / 2, ERR_DELTA);
        assertApproxEqRel(USDC.balanceOf(lenders[0]), initialAmount / 2, ERR_DELTA);
    }

    function test_shouldRedeem_whenPoolingStage() external {
        assertApproxEqRel(lenderVault.totalAssets(), initialAmount * lenders.length, ERR_DELTA);
        assertApproxEqRel(lenderVault.balanceOf(lenders[0]), initialAmount, ERR_DELTA);
        assertApproxEqRel(USDC.balanceOf(lenders[0]), 0, ERR_DELTA);

        assertApproxEqRel(lenderVault.maxRedeem(lenders[0]), initialAmount, ERR_DELTA);

        uint256 shares = lenderVault.convertToShares(initialAmount / 2);
        vm.prank(lenders[0]);
        lenderVault.redeem(shares, lenders[0], lenders[0]);

        assertApproxEqRel(lenderVault.totalAssets(), initialAmount * lenders.length - initialAmount / 2, ERR_DELTA);
        assertApproxEqRel(lenderVault.balanceOf(lenders[0]), initialAmount / 2, ERR_DELTA);
        assertApproxEqRel(USDC.balanceOf(lenders[0]), initialAmount / 2, ERR_DELTA);
    }

    function test_shouldDeposit_whenPoolingStage() external {
        assertApproxEqRel(lenderVault.totalAssets(), initialAmount * lenders.length, ERR_DELTA);
        assertApproxEqRel(lenderVault.balanceOf(lenders[0]), initialAmount, ERR_DELTA);
        vm.prank(aUSDC);
        USDC.transfer(lenders[0], initialAmount);

        assertEq(lenderVault.maxDeposit(lenders[0]), type(uint256).max);

        vm.prank(lenders[0]);
        lenderVault.deposit(initialAmount, lenders[0]);

        assertApproxEqRel(lenderVault.totalAssets(), initialAmount * lenders.length + initialAmount, ERR_DELTA);
        assertApproxEqRel(lenderVault.balanceOf(lenders[0]), 2 * initialAmount, ERR_DELTA);
    }

    function test_shouldMint_whenPoolingStage() external {
        assertApproxEqRel(lenderVault.totalAssets(), initialAmount * lenders.length, ERR_DELTA);
        assertApproxEqRel(lenderVault.balanceOf(lenders[0]), initialAmount, ERR_DELTA);
        vm.prank(aUSDC);
        USDC.transfer(lenders[0], initialAmount);

        assertEq(lenderVault.maxMint(lenders[0]), type(uint256).max);

        uint256 shares = lenderVault.convertToShares(initialAmount);
        vm.prank(lenders[0]);
        lenderVault.mint(shares, lenders[0]);

        assertApproxEqRel(lenderVault.totalAssets(), initialAmount * lenders.length + initialAmount, ERR_DELTA);
        assertApproxEqRel(lenderVault.balanceOf(lenders[0]), 2 * initialAmount, ERR_DELTA);
    }

    function test_loanStart() external {
        uint256 poolingTotalAssets = lenderVault.totalAssets();
        assertApproxEqRel(IERC20(aUSDC).balanceOf(address(lenderVault)), 4 * initialAmount, ERR_DELTA);
        assertEq(USDC.balanceOf(borrower), 0);

        bytes memory proposalData = __d.products.installments.encodeProposalData(proposal, acceptorValues);
        vm.prank(borrower);
        uint256 loanId = __d.loan.create({
            proposalSpec: PWNLoan.ProposalSpec({
                proposer: address(lenderVault),
                product: __d.products.installments,
                proposalData: proposalData,
                proposalInclusionProof: new bytes32[](0),
                signature: ""
            }),
            lenderSpec: lenderSpec,
            borrowerSpec: PWNLoan.BorrowerSpec({
                createHook: IPWNBorrowerCreateHook(address(0)),
                createHookData: ""
            }),
            extra: ""
        });

        assertEq(lenderVault.totalAssets(), acceptorValues.creditAmount); // debt excludes distributed cash
        assertApproxEqAbs(IERC20(lenderVault.asset()).balanceOf(address(lenderVault)) + lenderVault.totalAssets(), poolingTotalAssets, 1);
        assertEq(IERC20(aUSDC).balanceOf(address(lenderVault)), 0); // no aave deposit after loan start
        assertEq(USDC.balanceOf(borrower), acceptorValues.creditAmount); // borrower received the credit
        assertEq(lenderVault.totalCollateralAssets(), 0);
        assertEq(lenderVault.loanId(), loanId);
    }

    function test_loanStart_whenNoAaveToken() external {
        _deployWith(address(noAaveToken), 18);
        initialAmount = 50_000e18;

        for (uint256 i; i < lenders.length; ++i) {
            noAaveToken.mint(lenders[i], initialAmount);

            vm.startPrank(lenders[i]);
            noAaveToken.approve(address(lenderVault), type(uint256).max);
            lenderVault.deposit(initialAmount, lenders[i]);
            vm.stopPrank();
        }

        vm.prank(aWETH);
        WETH.transfer(borrower, 1000e18);

        vm.startPrank(borrower);
        WETH.approve(address(__d.loan), type(uint256).max);
        noAaveToken.approve(address(__d.loan), type(uint256).max);
        vm.stopPrank();

        uint256 poolingTotalAssets = lenderVault.totalAssets();
        assertApproxEqRel(noAaveToken.balanceOf(address(lenderVault)), 4 * initialAmount, ERR_DELTA);
        assertEq(noAaveToken.balanceOf(borrower), 0);

        bytes memory proposalData = __d.products.installments.encodeProposalData(proposal, acceptorValues);
        vm.prank(borrower);
        uint256 loanId = __d.loan.create({
            proposalSpec: PWNLoan.ProposalSpec({
                proposer: address(lenderVault),
                product: __d.products.installments,
                proposalData: proposalData,
                proposalInclusionProof: new bytes32[](0),
                signature: ""
            }),
            lenderSpec: lenderSpec,
            borrowerSpec: PWNLoan.BorrowerSpec({
                createHook: IPWNBorrowerCreateHook(address(0)),
                createHookData: ""
            }),
            extra: ""
        });

        assertEq(lenderVault.totalAssets(), acceptorValues.creditAmount); // debt excludes distributed cash
        assertApproxEqAbs(IERC20(lenderVault.asset()).balanceOf(address(lenderVault)) + lenderVault.totalAssets(), poolingTotalAssets, 1);
        assertEq(noAaveToken.balanceOf(borrower), acceptorValues.creditAmount); // borrower received the credit
        assertEq(lenderVault.totalCollateralAssets(), 0);
        assertEq(lenderVault.loanId(), loanId);
    }

}


contract PWNCrowdsourceLenderVault_Running_ForkTest is PWNCrowdsourceLenderVaultForkTest {

    uint256 loanId;
    uint256 unutilizedAmount;

    function setUp() override public virtual {
        super.setUp();

        bytes memory proposalData = __d.products.installments.encodeProposalData(proposal, acceptorValues);
        vm.prank(borrower);
        loanId = __d.loan.create({
            proposalSpec: PWNLoan.ProposalSpec({
                proposer: address(lenderVault),
                product: __d.products.installments,
                proposalData: proposalData,
                proposalInclusionProof: new bytes32[](0),
                signature: ""
            }),
            lenderSpec: lenderSpec,
            borrowerSpec: PWNLoan.BorrowerSpec({
                createHook: IPWNBorrowerCreateHook(address(0)),
                createHookData: ""
            }),
            extra: ""
        });

        unutilizedAmount = initialAmount * lenders.length - acceptorValues.creditAmount;
        assertApproxEqRel(IERC20(USDC).balanceOf(address(lenderVault)), unutilizedAmount, ERR_DELTA); // 20k
    }


    function test_shouldClaimWithoutBurningShares_whenRunningStage() external {
        uint256 originalShares = lenderVault.totalSupply();
        uint256 initialAllocation = lenderVault.claimableRepayments(lenders[0]);
        uint256 otherAllocation = lenderVault.claimableRepayments(lenders[1]);
        assertApproxEqRel(initialAllocation, unutilizedAmount / lenders.length, ERR_DELTA);
        vm.prank(lenders[0]);
        assertEq(lenderVault.claimRepayments(lenders[0]), initialAllocation);
        assertEq(lenderVault.claimableRepayments(lenders[0]), 0);
        assertEq(lenderVault.claimableRepayments(lenders[1]), otherAllocation);
        assertEq(lenderVault.totalAssets(), __d.loan.getLOANDebt(loanId));

        uint256 repayAmount = 30_000e6;
        uint256 expectedAllocation = otherAllocation
            + repayAmount * lenderVault.balanceOf(lenders[1]) / (originalShares + 1);
        vm.prank(borrower);
        __d.loan.repay(loanId, repayAmount);
        assertApproxEqAbs(lenderVault.claimableRepayments(lenders[1]), expectedAllocation, 1);
        for (uint256 i; i < lenders.length; ++i) {
            uint256 amount = lenderVault.claimableRepayments(lenders[i]);
            vm.prank(lenders[i]);
            assertEq(lenderVault.claimRepayments(lenders[i]), amount);
            assertEq(lenderVault.claimableRepayments(lenders[i]), 0);
        }
        assertEq(lenderVault.totalSupply(), originalShares);
        assertEq(lenderVault.totalAssets(), __d.loan.getLOANDebt(loanId));
        assertLe(USDC.balanceOf(address(lenderVault)), 4);
    }

    function test_runningSharesCannotBeBurnedThroughERC4626() external {
        assertEq(lenderVault.maxWithdraw(lenders[0]), 0);
        assertEq(lenderVault.maxRedeem(lenders[0]), 0);
        vm.startPrank(lenders[0]);
        vm.expectRevert("PWNCrowdsourceLenderVault: withdraw disabled, use claimRepayments");
        lenderVault.withdraw(1, lenders[0], lenders[0]);
        vm.expectRevert("PWNCrowdsourceLenderVault: redeem disabled");
        lenderVault.redeem(1, lenders[0], lenders[0]);
        vm.stopPrank();
    }

    function test_aaveFailureDoesNotBlockRepaymentOrDefaultRedemption() external {
        assertEq(IERC20(aUSDC).balanceOf(address(lenderVault)), 0);
        vm.mockCallRevert(address(lenderVault.aave()), hex"", abi.encodeWithSignature("Error(string)", "Aave unavailable"));

        vm.prank(borrower);
        __d.loan.repay(loanId, 10_000e6);
        uint256 allocation = lenderVault.claimableRepayments(lenders[0]);
        assertApproxEqRel(allocation, (unutilizedAmount + 10_000e6) / lenders.length, ERR_DELTA);
        vm.prank(lenders[0]);
        lenderVault.claimRepayments(lenders[0]);
        assertEq(lenderVault.claimableRepayments(lenders[0]), 0);

        vm.warp(block.timestamp + terms.duration);
        uint256 shares = lenderVault.balanceOf(lenders[0]);
        vm.prank(lenders[0]);
        lenderVault.redeem(shares, lenders[0], lenders[0]);
        assertGt(WETH.balanceOf(lenders[0]), 0);
        assertEq(lenderVault.balanceOf(lenders[0]), 0);
    }

    function test_coreFallbackIsRecoveredBeforeSharesMove() external {
        vm.mockCallRevert(
            address(lenderVault), abi.encodeWithSelector(lenderVault.onLoanRepaid.selector),
            abi.encodeWithSignature("Error(string)", "hook unavailable")
        );
        vm.prank(borrower);
        __d.loan.repay(loanId, 10_000e6);
        assertEq(__d.loan.getLOAN(loanId).unclaimedRepayment, 10_000e6);
        vm.clearMockedCalls();
        uint256 cash = lenderVault.claimableRepayments(lenders[0]);
        uint256 shares = lenderVault.balanceOf(lenders[0]);
        address buyer = makeAddr("buyer");
        vm.prank(lenders[0]);
        lenderVault.transfer(buyer, shares);
        assertEq(__d.loan.getLOAN(loanId).unclaimedRepayment, 0);
        assertEq(lenderVault.claimableRepayments(buyer), 0);
        assertEq(lenderVault.claimableRepayments(lenders[0]), cash);
        vm.prank(lenders[0]);
        assertEq(lenderVault.claimRepayments(lenders[0]), cash);
    }

    function test_shouldRevertDeposit_whenRunningStage() external {
        vm.expectRevert();
        vm.prank(lenders[0]);
        lenderVault.deposit(1, lenders[0]);
    }

    function test_shouldRevertMint_whenRunningStage() external {
        vm.expectRevert();
        vm.prank(lenders[0]);
        lenderVault.mint(1, lenders[0]);
    }

    function test_shareValueTracksDebtSeparatelyFromEarnedCash() external {
        uint256 originalTotalShares = lenderVault.totalSupply();
        uint256 principal = acceptorValues.creditAmount;
        assertApproxEqRel(lenderVault.convertToAssets(1e6), principal * 1e6 / originalTotalShares, ERR_DELTA);
        vm.warp(block.timestamp + 3 days);
        assertApproxEqRel(lenderVault.totalAssets(), principal * 103 / 100, ERR_DELTA);
        uint256 beforeRepayment = lenderVault.totalAssets();
        vm.prank(borrower);
        __d.loan.repay(loanId, 10_000e6);
        assertEq(lenderVault.totalAssets(), beforeRepayment - 10_000e6);
        uint256 beforeClaimPrice = lenderVault.convertToAssets(1e6);
        vm.prank(lenders[0]);
        lenderVault.claimRepayments(lenders[0]);
        assertEq(lenderVault.convertToAssets(1e6), beforeClaimPrice);
        assertEq(lenderVault.totalSupply(), originalTotalShares);
        vm.warp(block.timestamp + 10 days);
        assertEq(lenderVault.totalAssets(), __d.loan.getLOANDebt(loanId));
        assertGt(lenderVault.convertToAssets(1e6), beforeClaimPrice);
    }

    function test_loanRepaid() external {
        vm.prank(borrower);
        __d.loan.repay(loanId, 0);
        assertEq(lenderVault.totalCollateralAssets(), 0);
        assertEq(lenderVault.totalAssets(), 0);
        assertEq(lenderVault.maxRedeem(lenders[0]), lenderVault.balanceOf(lenders[0]));
        assertEq(lenderVault.previewRedeem(lenderVault.balanceOf(lenders[0])), 0);
        assertApproxEqRel(lenderVault.claimableRepayments(lenders[0]), initialAmount, ERR_DELTA);
    }

    function test_loanDefaulted() external {
        vm.warp(block.timestamp + terms.duration);
        // Note: defaulted loan

        assertEq(lenderVault.totalAssets(), 0);
        assertGt(lenderVault.totalCollateralAssets(), 0);
        assertGt(lenderVault.previewCollateralRedeem(50_000e6), 0);
    }

}


contract PWNCrowdsourceLenderVault_Ending_ForkTest is PWNCrowdsourceLenderVaultForkTest {

    modifier loanRepaid() {
        vm.prank(borrower);
        __d.loan.repay(loanId, 0);
        _;
    }

    modifier loanDefaulted() {
        vm.warp(block.timestamp + terms.duration);
        _;
    }

    uint256 loanId;
    uint256 unutilizedAmount;

    function setUp() override public virtual {
        super.setUp();

        bytes memory proposalData = __d.products.installments.encodeProposalData(proposal, acceptorValues);
        vm.prank(borrower);
        loanId = __d.loan.create({
            proposalSpec: PWNLoan.ProposalSpec({
                proposer: address(lenderVault),
                product: __d.products.installments,
                proposalData: proposalData,
                proposalInclusionProof: new bytes32[](0),
                signature: ""
            }),
            lenderSpec: lenderSpec,
            borrowerSpec: PWNLoan.BorrowerSpec({
                createHook: IPWNBorrowerCreateHook(address(0)),
                createHookData: ""
            }),
            extra: ""
        });

        unutilizedAmount = initialAmount * lenders.length - acceptorValues.creditAmount;
        assertApproxEqRel(IERC20(USDC).balanceOf(address(lenderVault)), unutilizedAmount, ERR_DELTA); // 20k
    }


    function test_shouldRevertWithdraw_whenEndingStage() external loanRepaid {
        vm.expectRevert();
        vm.prank(lenders[0]);
        lenderVault.withdraw(1, lenders[0], lenders[0]);
    }

    function test_shouldRedeem_whenEndingStage_whenLoanRepaid() external loanRepaid {
        uint256 donation = 1000 ether;
        vm.prank(aWETH);
        WETH.transfer(address(lenderVault), donation);

        // Note: any collateral asset donation should be redeemed

        for (uint256 i; i < lenders.length; ++i) {
            vm.prank(lenders[i]);
            lenderVault.claimAndRedeem(lenders[i]);

            assertApproxEqRel(USDC.balanceOf(lenders[i]), initialAmount, ERR_DELTA);
            assertApproxEqRel(WETH.balanceOf(lenders[i]), donation / 4, ERR_DELTA);
        }

        assertEq(lenderVault.totalAssets(), 0);
        assertEq(lenderVault.totalCollateralAssets(), 0);
    }

    function test_shouldRedeem_whenEndingStage_whenLoanDefaulted() external loanDefaulted {
        uint256 donation = 1000e6;
        vm.prank(aUSDC);
        USDC.transfer(address(lenderVault), donation);

        // Note: any undistributed asset (donation) should be redeemed

        PWNLoan.LOAN memory loan_ = __d.loan.getLOAN(loanId);
        uint256 collAmount = loan_.collateral.amount;
        for (uint256 i; i < lenders.length; ++i) {
            vm.prank(lenders[i]);
            lenderVault.claimAndRedeem(lenders[i]);

            assertApproxEqRel(USDC.balanceOf(lenders[i]), (unutilizedAmount + donation) / 4, ERR_DELTA);
            assertApproxEqRel(WETH.balanceOf(lenders[i]), collAmount / 4, ERR_DELTA);
        }

        assertEq(lenderVault.totalAssets(), 0);
        assertEq(lenderVault.totalCollateralAssets(), 0);
    }

    function test_shouldRevertDeposit_whenEndingStage() external loanRepaid {
        vm.expectRevert();
        vm.prank(lenders[0]);
        lenderVault.deposit(1, lenders[0]);
    }

    function test_shouldRevertMint_whenEndingStage() external loanRepaid {
        vm.expectRevert();
        vm.prank(lenders[0]);
        lenderVault.mint(1, lenders[0]);
    }

}


contract PWNCrowdsourceLenderVault_FullLifecycle_ForkTest is PWNCrowdsourceLenderVaultForkTest {

    uint256 loanId;

    function setUp() override public virtual {
        super.setUp();

        _deployWith(address(USDC), 6, 100);

        for (uint256 i; i < lenders.length; ++i) {
            vm.startPrank(aUSDC);
            USDC.transfer(lenders[i], initialAmount);

            vm.startPrank(lenders[i]);
            USDC.approve(address(lenderVault), type(uint256).max);
            lenderVault.deposit(initialAmount, lenders[i]);
            vm.stopPrank();
        }

        vm.prank(aUSDC);
        USDC.transfer(borrower, 3_000e6); // to cover interest
    }

    function test_fullLifecycle_whenRepaid() external {
        // loan starts
        bytes memory proposalData = __d.products.installments.encodeProposalData(proposal, acceptorValues);
        vm.prank(borrower);
        loanId = __d.loan.create({
            proposalSpec: PWNLoan.ProposalSpec({
                proposer: address(lenderVault),
                product: __d.products.installments,
                proposalData: proposalData,
                proposalInclusionProof: new bytes32[](0),
                signature: ""
            }),
            lenderSpec: lenderSpec,
            borrowerSpec: PWNLoan.BorrowerSpec({
                createHook: IPWNBorrowerCreateHook(address(0)),
                createHookData: ""
            }),
            extra: ""
        });

        // 3 months postponement
        vm.warp(block.timestamp + 90 days);

        // start repaying 10k/m
        uint256 repaidAmount;
        uint256 i = 1;
        uint256 debt = __d.loan.getLOANDebt(loanId);
        while (debt > 0) {
            vm.prank(borrower);
            __d.loan.repay(loanId, debt < 10_000e6 ? debt : 10_000e6);
            repaidAmount += debt < 10_000e6 ? debt : 10_000e6;

            // Every three months claim this lender's available allocation while the loan is running.
            if (i % 3 == 0 && __d.loan.getLOANDebt(loanId) > 0) {
                lender = lenders[i / 12];
                vm.prank(lender);
                lenderVault.claimRepayments(lender);
            }

            vm.warp(block.timestamp + 30 days);

            debt = __d.loan.getLOANDebt(loanId);
            ++i;
        }

        uint256 totalLendersBalance;
        // on repayment, claim by everyone
        for (uint256 j; j < lenders.length; ++j) {
            lender = lenders[j];
            vm.startPrank(lender);
            lenderVault.claimAndRedeem(lender);
            vm.stopPrank();

            totalLendersBalance += USDC.balanceOf(lender);
        }

        // assert that all assts are claimed
        assertEq(lenderVault.totalSupply(), 0); // no shares left
        assertLe(USDC.balanceOf(address(lenderVault)), 8); // virtual reserve and fractional claims
        assertApproxEqAbs(lenderVault.totalCollateralAssets(), 0, 2); // no collateral left (only dust)
        assertApproxEqRel(totalLendersBalance, repaidAmount + 20_000e6, ERR_DELTA); // all assets are claimed
    }

    function test_fullLifecycle_whenDefaulted() external {
        // loan starts
        bytes memory proposalData = __d.products.installments.encodeProposalData(proposal, acceptorValues);
        vm.prank(borrower);
        loanId = __d.loan.create({
            proposalSpec: PWNLoan.ProposalSpec({
                proposer: address(lenderVault),
                product: __d.products.installments,
                proposalData: proposalData,
                proposalInclusionProof: new bytes32[](0),
                signature: ""
            }),
            lenderSpec: lenderSpec,
            borrowerSpec: PWNLoan.BorrowerSpec({
                createHook: IPWNBorrowerCreateHook(address(0)),
                createHookData: ""
            }),
            extra: ""
        });

        // 3 months postponement
        vm.warp(block.timestamp + 90 days);

        PWNLoan.LOAN memory loan_ = __d.loan.getLOAN(loanId);

        // start repaying 5k/m
        uint256 repaidAmount;
        uint256 i = 1;
        uint256 debt = __d.loan.getLOANDebt(loanId);
        uint8 status = __d.loan.getLOANStatus(loanId);
        while (debt > 0 && status != 4) {
            vm.prank(borrower);
            __d.loan.repay(loanId, debt < 5_000e6 ? debt : 5_000e6);
            repaidAmount += debt < 5_000e6 ? debt : 5_000e6;

            // Every three months claim this lender's available allocation while the loan is running.
            if (i % 3 == 0 && __d.loan.getLOANDebt(loanId) > 0) {
                lender = lenders[i / 12];
                vm.prank(lender);
                lenderVault.claimRepayments(lender);
            }

            vm.warp(block.timestamp + 30 days);

            debt = __d.loan.getLOANDebt(loanId);
            status = __d.loan.getLOANStatus(loanId);
            ++i;
        }

        uint256 totalLendersBalance;
        uint256 totalLendersCollateralBalance;
        // on repayment, claim by everyone
        for (uint256 j; j < lenders.length; ++j) {
            lender = lenders[j];
            vm.startPrank(lender);
            lenderVault.claimAndRedeem(lender);
            vm.stopPrank();

            totalLendersBalance += USDC.balanceOf(lender);
            totalLendersCollateralBalance += WETH.balanceOf(lender);
        }

        // assert that all assts are claimed
        assertEq(lenderVault.totalSupply(), 0); // no shares left
        assertLe(USDC.balanceOf(address(lenderVault)), 8); // virtual reserve and fractional claims
        assertApproxEqAbs(lenderVault.totalCollateralAssets(), 0, 2); // no collateral left (only dust)
        assertApproxEqRel(totalLendersBalance, repaidAmount + 20_000e6, ERR_DELTA); // all assets are claimed
        assertApproxEqRel(totalLendersCollateralBalance, loan_.collateral.amount, ERR_DELTA); // collateral is claimed
    }

    function test_twentyYearLoanWithMonthlyClaims() external {
        _deployWith(address(USDC), 6, 100, 20 * 365 days);
        for (uint256 i; i < lenders.length; ++i) {
            vm.prank(aUSDC);
            USDC.transfer(lenders[i], initialAmount);
            vm.startPrank(lenders[i]);
            USDC.approve(address(lenderVault), type(uint256).max);
            lenderVault.deposit(initialAmount, lenders[i]);
            vm.stopPrank();
        }
        vm.prank(aUSDC);
        USDC.transfer(borrower, 40_000e6);
        bytes memory proposalData = __d.products.installments.encodeProposalData(proposal, acceptorValues);
        vm.prank(borrower);
        loanId = __d.loan.create({
            proposalSpec: PWNLoan.ProposalSpec({
                proposer: address(lenderVault), product: __d.products.installments,
                proposalData: proposalData,
                proposalInclusionProof: new bytes32[](0), signature: ""
            }),
            lenderSpec: lenderSpec,
            borrowerSpec: PWNLoan.BorrowerSpec({ createHook: IPWNBorrowerCreateHook(address(0)), createHookData: "" }),
            extra: ""
        });
        uint256 originalShares = lenderVault.totalSupply();
        uint256 started = block.timestamp;
        uint256 repaid;
        uint256 month;
        while (__d.loan.getLOANDebt(loanId) > 0) {
            require(month < 240, "loan exceeded twenty years");
            vm.warp(block.timestamp + 30 days);
            uint256 debt = __d.loan.getLOANDebt(loanId);
            uint256 payment = debt < 1_000e6 ? debt : 1_000e6;
            vm.prank(borrower);
            __d.loan.repay(loanId, payment);
            repaid += payment;
            // Different collection frequencies must not change collateral/loan ownership.
            for (uint256 i; i < lenders.length; ++i) {
                if (month % (i + 1) == 0) {
                    vm.prank(lenders[i]);
                    lenderVault.claimRepayments(lenders[i]);
                }
            }
            assertEq(lenderVault.totalSupply(), originalShares);
            ++month;
        }
        assertGt(block.timestamp - started, 15 * 365 days);
        uint256 totalPaid;
        for (uint256 i; i < lenders.length; ++i) {
            vm.prank(lenders[i]);
            lenderVault.claimAndRedeem(lenders[i]);
            totalPaid += USDC.balanceOf(lenders[i]);
            assertApproxEqAbs(USDC.balanceOf(lenders[i]), (repaid + 20_000e6) / 4, 10);
        }
        assertEq(lenderVault.totalSupply(), 0);
        assertLe(USDC.balanceOf(address(lenderVault)), 8);
        assertApproxEqAbs(totalPaid, repaid + 20_000e6, 10);
    }

}
