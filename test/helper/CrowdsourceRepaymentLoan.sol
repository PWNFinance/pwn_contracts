// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.16;

import { PWNLoan, PWNCrowdsourceLenderVault, IERC20 } from "pwn/periphery/crowdsource/PWNCrowdsourceLenderVault.sol";
import { T20 } from "test/helper/T20.sol";


/** @dev Real token movements and loan locks for accounting tests. Product integration is covered by fork tests.*/
contract CrowdsourceRepaymentLoan {
    mapping (uint256 => bool) public loanLock;
    PWNLoan.LOAN internal loan;
    PWNCrowdsourceLenderVault public vault;
    uint8 public status = 2;
    uint256 public liquidations;
    uint256 public recoveries;
    bool public failLiquidation;

    function makeProposalAcceptable(address, bytes calldata) external pure returns (bytes32) { return bytes32(0); }
    function getLenderSpecHash(PWNLoan.LenderSpec calldata) external pure returns (bytes32) { return bytes32(0); }
    function getLOAN(uint256) external view returns (PWNLoan.LOAN memory) { return loan; }
    function getLOANStatus(uint256) external view returns (uint8) { return status; }
    function getLOANDebt(uint256) external view returns (uint256) { return loan.principal; }

    function setLocked(bool locked) external { loanLock[1] = locked; }
    function setDefaulted(bool fail) external { status = 4; failLiquidation = fail; }

    function fund(PWNCrowdsourceLenderVault vault_, address borrower, uint256 principal, T20 collateral, uint256 amount) external {
        vault = vault_;
        loan.borrower = borrower;
        loan.creditAddress = vault.asset();
        loan.principal = principal;
        loan.collateral.assetAddress = address(collateral);
        loan.collateral.amount = amount;
        collateral.mint(address(this), amount);
        loanLock[1] = true;
        vault.onLoanCreated(1, address(vault), vault.asset(), principal, "");
        IERC20(vault.asset()).transferFrom(address(vault), borrower, principal);
        loanLock[1] = false;
    }

    function repay(uint256 amount, bool fallbackToCore) external {
        require(status == 2, "not running");
        loanLock[1] = true;
        loan.principal -= amount;
        if (loan.principal == 0) status = 3;
        if (fallbackToCore) {
            loan.unclaimedRepayment += amount;
            IERC20(loan.creditAddress).transferFrom(msg.sender, address(this), amount);
        } else {
            IERC20(loan.creditAddress).transferFrom(msg.sender, address(vault), amount);
            vault.onLoanRepaid(address(vault), loan.creditAddress, amount, "");
        }
        if (loan.principal == 0 && loan.unclaimedRepayment == 0) status = 0;
        loanLock[1] = false;
    }

    function claimRepayment(uint256) external {
        require(msg.sender == address(vault), "not loan owner");
        require(!loanLock[1], "locked");
        loanLock[1] = true;
        uint256 amount = loan.unclaimedRepayment;
        require(amount > 0, "no repayment");
        loan.unclaimedRepayment = 0;
        if (loan.principal == 0) status = 0;
        ++recoveries;
        IERC20(loan.creditAddress).transfer(msg.sender, amount);
        loanLock[1] = false;
    }

    function liquidate(uint256, bytes calldata) external {
        require(msg.sender == address(vault) && status == 4, "invalid liquidation");
        require(!failLiquidation, "liquidation unavailable");
        require(!loanLock[1], "locked");
        loanLock[1] = true;
        ++liquidations;
        status = 0;
        loan.principal = 0;
        uint256 amount = loan.collateral.amount;
        loan.collateral.amount = 0;
        IERC20(loan.collateral.assetAddress).transfer(msg.sender, amount);
        loanLock[1] = false;
    }
}


contract CrowdsourceCallbackToken is T20 {
    uint8 internal immutable assetDecimals;
    address internal watchedFrom;
    address internal callbackTarget;
    bytes internal callbackData;
    bool public callbackAttempted;
    bool public callbackSucceeded;
    bytes public callbackResult;
    bool public failTransfers;

    constructor(uint8 decimals_) { assetDecimals = decimals_; }
    function decimals() public view override returns (uint8) { return assetDecimals; }
    function setFailTransfers(bool fail) external { failTransfers = fail; }

    function setCallback(address from, address target, bytes calldata data) external {
        watchedFrom = from;
        callbackTarget = target;
        callbackData = data;
        callbackAttempted = false;
    }

    function _beforeTokenTransfer(address from, address, uint256) internal override {
        require(!failTransfers, "transfer unavailable");
        if (from == watchedFrom && callbackTarget != address(0)) {
            callbackAttempted = true;
            (callbackSucceeded, callbackResult) = callbackTarget.call(callbackData);
        }
    }
}
