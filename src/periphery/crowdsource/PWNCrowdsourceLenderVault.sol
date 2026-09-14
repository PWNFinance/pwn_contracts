// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.16;

import { MultiToken } from "MultiToken/MultiToken.sol";

import { ERC4626, ERC20, IERC20, IERC20Metadata, Math, SafeERC20 } from "openzeppelin/token/ERC20/extensions/ERC4626.sol";
import { IERC721Receiver } from "openzeppelin/token/ERC721/IERC721Receiver.sol";
import { ReentrancyGuard } from "openzeppelin/security/ReentrancyGuard.sol";

import {
    PWNLoan, LOANStatus, PWNLOAN,
    IPWNLenderCreateHook, LENDER_CREATE_HOOK_RETURN_VALUE,
    IPWNLenderRepaymentHook, LENDER_REPAYMENT_HOOK_RETURN_VALUE
} from "pwn/core/loan/PWNLoan.sol";
import { PWNInstallmentsProduct } from "pwn/periphery/product/PWNInstallmentsProduct.sol";
import { IAaveLike } from "pwn/periphery/interfaces/IAaveLike.sol";


/**
 * @title PWNCrowdsourceLenderVault
 * @notice A vault that pools assets to lend through a PWNLoan contract.
 */
contract PWNCrowdsourceLenderVault is ERC4626, ReentrancyGuard, IPWNLenderCreateHook, IPWNLenderRepaymentHook, IERC721Receiver {
    using Math for uint256;

    /** @notice The PWNLoan contract through which the loan is created.*/
    PWNLoan immutable public loanContract;
    /** @notice The proposal contract that creates the loan proposal.*/
    PWNInstallmentsProduct immutable public product;
    /** @notice The Aave lending pool contract.*/
    IAaveLike immutable public aave;
    /**
     * @notice The address of the aToken for the asset, if exists.
     * @dev The aToken is used to earn interest on the assets while they are being pooled.
     */
    address immutable internal aAsset;
    /** @notice The address of the collateral token.*/
    address immutable internal collateralAddr;
    /**
     * @notice The hash of the loan proposal.
     * @dev The proposal is made on vault deployment.
     */
    bytes32 immutable internal proposalHash;

    /** @notice The ID of the loan funded by the vault.*/
    uint256 public loanId;
    /**
     * @notice Whether the loan has ended.
     * @dev The loan ends when it is repaid or defaulted.
     */
    bool internal loanEnded;

    uint256 internal constant REPAYMENT_PRECISION = 1e27;
    /** @notice Cumulative credit-token proceeds per share, including the initial virtual asset.*/
    uint256 internal repaymentPerShare;
    /** @notice Remainder carried between cash allocations.*/
    uint256 internal repaymentRemainder;
    /** @notice Physical cash already allocated, excluding amounts claimed.*/
    uint256 internal accountedRepayments;

    struct RepaymentAllocation {
        uint256 index;
        uint256 claimable;
        uint256 remainder;
    }

    /** @notice Earned cash stays with its owner when shares are transferred or redeemed.*/
    mapping (address => RepaymentAllocation) internal repaymentAllocations;

    /**
     * @notice The stages of the vault.
     * @dev The vault can be in the POOLING, RUNNING, or ENDING stage.
     * POOLING: The vault is pooling assets. Anyone can freely deposit and withdraw. The vault automatically supplies assets to Aave, if possible.
     * RUNNING: No deposits or share redemptions. Credit-token proceeds are claimed without burning shares.
     * ENDING: Cash remains independently claimable. Redeeming burns shares and pays default collateral.
     */
    enum Stage {
        POOLING, RUNNING, ENDING
    }

    /** @notice The terms of the loan proposal.*/
    struct Terms {
        address collateralAddress;
        address creditAddress;
        address[] feedIntermediaryDenominations;
        bool[] feedInvertFlags;
        uint256 loanToValue;
        uint256 interestAPR;
        uint256 postponement;
        uint256 duration;
        uint256 minCreditAmount;
        uint256 expiration;
        address allowedAcceptor;
    }

    /*** @notice Emitted when collateral is withdrawn.*/
    event WithdrawCollateral(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
    /** @notice Emitted when an owner collects earned credit-token proceeds without burning shares.*/
    event RepaymentsClaimed(address indexed owner, address indexed receiver, uint256 assets);


    constructor(
        PWNLoan _loan,
        PWNInstallmentsProduct _product,
        IAaveLike _aave,
        string memory _name,
        string memory _symbol,
        Terms memory _terms
    ) ERC4626(IERC20(_terms.creditAddress)) ERC20(_name, _symbol) {
        loanContract = _loan;
        product = _product;
        aave = _aave;

        require(_terms.creditAddress != _terms.collateralAddress, "PWNCrowdsourceLenderVault: identical assets");
        collateralAddr = _terms.collateralAddress;
        (bool success,) = _tryGetAssetDecimals_child(IERC20(collateralAddr));
        if (!success) {
            revert("PWNCrowdsourceLenderVault: collateral token missing decimals");
        }

        // TODO should we check the values here that they are correct?

        // TODO should we check here that the getCollateralAmount on installments product contract returns
        //  positive result (to ensure that the feeds are set up correctly)?

        proposalHash = loanContract.makeProposalAcceptable(product, abi.encode(
            PWNInstallmentsProduct.Proposal({
                collateralAddress: _terms.collateralAddress,
                creditAddress: _terms.creditAddress,
                feedIntermediaryDenominations: _terms.feedIntermediaryDenominations,
                feedInvertFlags: _terms.feedInvertFlags,
                loanToValue: _terms.loanToValue,
                interestAPR: _terms.interestAPR,
                duration: _terms.duration,
                postponement: _terms.postponement,
                minCreditAmount: _terms.minCreditAmount,
                allowedAcceptor: _terms.allowedAcceptor,
                availableCreditLimit: 0,
                utilizedCreditId: bytes32(0),
                nonceSpace: 0,
                nonce: 0,
                expiration: _terms.expiration,
                proposerSpecHash: loanContract.getLenderSpecHash(PWNLoan.LenderSpec({
                    createHook: this, createHookData: "", repaymentHook: this, repaymentHookData: ""
                })),
                isProposerLender: true,
                loanContract: address(loanContract)
            })
        ));

        IERC20(asset()).approve(address(loanContract), type(uint256).max);

        IAaveLike.ReserveData memory reserveData = aave.getReserveData(asset());
        aAsset = reserveData.aTokenAddress;
        if (aAsset != address(0)) {
            IERC20(asset()).approve(address(aave), type(uint256).max);
        }
    }


    /** @notice The stage of the vault.*/
    function stage() internal view returns (Stage) {
        if (loanId == 0) {
            return Stage.POOLING;
        } else if (loanEnded) {
            return Stage.ENDING;
        }
        return Stage.RUNNING;
    }


    /*----------------------------------------------------------*|
    |*  # ERC4626                                               *|
    |*----------------------------------------------------------*/

    /**
     * @notice Pooling assets, or outstanding loan debt after funding.
     * @dev After funding, earned cash is a separate entitlement exposed by claimableRepayments.
     * Collateral is exposed separately by totalCollateralAssets.
     */
    function totalAssets() public view override returns (uint256) {
        uint256 additionalAssets;
        Stage _stage = stage();
        if (_stage == Stage.POOLING) {
            if (aAsset != address(0)) {
                // Note: assuming aToken:token ratio is always 1:1
                additionalAssets = IERC20(aAsset).balanceOf(address(this));
            }
            return _availableLiquidity() + additionalAssets;
        }
        if (_stage == Stage.RUNNING && loanContract.getLOANStatus(loanId) == LOANStatus.RUNNING) {
            return loanContract.getLOANDebt(loanId);
        }
        return 0;
    }

    // # Max

    /** @inheritdoc ERC4626*/
    function maxDeposit(address receiver) public view override returns (uint256) {
        return stage() == Stage.POOLING && receiver != address(0) && receiver != address(this) ? type(uint256).max : 0;
    }

    /** @inheritdoc ERC4626*/
    function maxMint(address receiver) public view override returns (uint256) {
        return maxDeposit(receiver);
    }

    /** @inheritdoc ERC4626*/
    function maxWithdraw(address owner) public view override returns (uint256 max) {
        return stage() == Stage.POOLING ? _convertToAssets(balanceOf(owner), Math.Rounding.Down) : 0;
    }

    /** @inheritdoc ERC4626*/
    function maxRedeem(address owner) public view override returns (uint256 max) {
        if (loanId != 0) {
            if (loanContract.loanLock(loanId)) return 0;
            if (!loanEnded && loanContract.getLOANStatus(loanId) == LOANStatus.RUNNING) return 0;
        }
        return balanceOf(owner);
    }

    // # Preview

    /** @inheritdoc ERC4626*/
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        require(stage() == Stage.POOLING, "PWNCrowdsourceLenderVault: deposit disabled");
        return _convertToShares(assets, Math.Rounding.Down);
    }

    /** @inheritdoc ERC4626*/
    function previewMint(uint256 shares) public view override returns (uint256) {
        require(stage() == Stage.POOLING, "PWNCrowdsourceLenderVault: mint disabled");
        return _convertToAssets(shares, Math.Rounding.Up);
    }

    /** @inheritdoc ERC4626*/
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        require(stage() == Stage.POOLING, "PWNCrowdsourceLenderVault: withdraw disabled, use claimRepayments");
        return _convertToShares(assets, Math.Rounding.Up);
    }

    /** @inheritdoc ERC4626*/
    function previewRedeem(uint256 shares) public view override returns (uint256) {
        if (loanId != 0 && (loanEnded || loanContract.getLOANStatus(loanId) != LOANStatus.RUNNING)) return 0;
        return _convertToAssets(shares, Math.Rounding.Down);
    }

    // # Actions

    /** @inheritdoc ERC4626*/
    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256 shares) {
        shares = previewDeposit(assets);
        require(assets <= maxDeposit(receiver), "ERC4626: deposit more than max");
        // A borrower can recover their real-share collateral on default. Do not let donation-inflated
        // prices round away another lender's contribution; exact-share mint remains available.
        if (assets > 0) {
            require(
                shares > 0 && assets - _convertToAssets(shares, Math.Rounding.Up) <= 1,
                "PWNCrowdsourceLenderVault: excessive deposit rounding"
            );
        }
        _deposit(_msgSender(), receiver, assets, shares);
    }

    /** @inheritdoc ERC4626*/
    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256 assets) {
        assets = previewMint(shares);
        require(shares <= maxMint(receiver), "ERC4626: mint more than max");
        _deposit(_msgSender(), receiver, assets, shares);
    }

    /** @inheritdoc ERC4626*/
    function withdraw(uint256 assets, address receiver, address owner) public override nonReentrant returns (uint256 shares) {
        _requireValidReceiver(receiver);
        shares = previewWithdraw(assets);
        require(assets <= maxWithdraw(owner), "ERC4626: withdraw more than max");
        _withdraw(_msgSender(), receiver, owner, assets, shares);
    }

    /**
     * @notice Redeem pooling shares for credit, or terminal shares for collateral.
     * @dev Terminal redemption returns zero credit. Previously earned credit remains separately claimable
     * by owner, including when an approved spender redeems all of owner's shares.
     */
    function redeem(uint256 shares, address receiver, address owner) public override nonReentrant returns (uint256 assets) {
        _requireValidReceiver(receiver);
        if (stage() == Stage.POOLING) {
            assets = previewRedeem(shares);
            require(shares <= maxRedeem(owner), "ERC4626: redeem more than max");
            _withdraw(_msgSender(), receiver, owner, assets, shares);
        } else {
            _prepareFinalRedemption();
            _redeemCollateral(shares, receiver, owner);
        }
    }

    /**
     * @notice Credit-token proceeds earned by owner, independently of current share ownership.
     * @dev Includes unutilized funding cash, donations and recoverable core-held repayments. Returns zero
     * during vault operations and loan callbacks, when token balances may be transient.
     */
    function claimableRepayments(address owner) public view returns (uint256) {
        if (loanId == 0 || _reentrancyGuardEntered() || loanContract.loanLock(loanId)) return 0;
        (uint256 index,) = _currentRepaymentIndex(_availableLiquidity() + _unclaimedLoanRepayment());
        RepaymentAllocation memory allocation = repaymentAllocations[owner];
        (uint256 earned,) = _mulDivWithRemainder(
            balanceOf(owner), index - allocation.index, REPAYMENT_PRECISION, allocation.remainder
        );
        return allocation.claimable + earned;
    }

    /** @notice Claim all of the caller's earned cash without burning shares or liquidating collateral.*/
    function claimRepayments(address receiver) external nonReentrant returns (uint256 assets) {
        _requireValidReceiver(receiver);
        require(loanId != 0, "PWNCrowdsourceLenderVault: claims disabled");
        _syncRepayments();
        return _claimRepayments(_msgSender(), receiver);
    }

    /** @notice Settle an ended loan, claim the caller's cash and redeem all their shares in one transaction.*/
    function claimAndRedeem(address receiver) external nonReentrant returns (uint256 repayments, uint256 collateral) {
        _requireValidReceiver(receiver);
        require(loanId != 0, "PWNCrowdsourceLenderVault: claims disabled");
        _prepareFinalRedemption();
        address owner = _msgSender();
        repayments = _claimRepayments(owner, receiver);
        collateral = _redeemCollateral(balanceOf(owner), receiver, owner);
    }

    function _availableLiquidity() internal view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /** @dev Preserves the ERC4626 virtual share; previously allocated cash is never redistributed.*/
    function _currentRepaymentIndex(uint256 liquidity) internal view returns (uint256 index, uint256 remainder) {
        index = repaymentPerShare;
        remainder = repaymentRemainder;
        uint256 supply = totalSupply();
        if (liquidity > accountedRepayments && supply > 0) {
            uint256 increment;
            (increment, remainder) = _mulDivWithRemainder(
                liquidity - accountedRepayments, REPAYMENT_PRECISION, supply + 1, remainder
            );
            index += increment;
        }
    }

    function _unclaimedLoanRepayment() internal view returns (uint256) {
        return loanEnded ? 0 : loanContract.getLOAN(loanId).unclaimedRepayment;
    }

    function _recoverLoanRepayment() internal {
        if (_unclaimedLoanRepayment() > 0) loanContract.claimRepayment(loanId);
    }

    function _updateRepayments() internal {
        uint256 liquidity = _availableLiquidity();
        (repaymentPerShare, repaymentRemainder) = _currentRepaymentIndex(liquidity);
        accountedRepayments = liquidity;
    }

    function _syncRepayments() internal {
        _requireUnlockedLoan();
        _recoverLoanRepayment();
        _updateRepayments();
    }

    /** @dev Checkpoint fractions and return total earned cash; the caller must store or pay that amount.*/
    function _checkpointRepayments(address owner) internal returns (uint256 claimable) {
        RepaymentAllocation storage allocation = repaymentAllocations[owner];
        if (allocation.index == repaymentPerShare) return allocation.claimable;
        uint256 earned;
        (earned, allocation.remainder) = _mulDivWithRemainder(
            balanceOf(owner), repaymentPerShare - allocation.index, REPAYMENT_PRECISION, allocation.remainder
        );
        allocation.index = repaymentPerShare;
        return allocation.claimable + earned;
    }

    function _accrueRepayments(address owner) internal {
        repaymentAllocations[owner].claimable = _checkpointRepayments(owner);
    }

    function _claimRepayments(address owner, address receiver) internal returns (uint256 assets) {
        assets = _checkpointRepayments(owner);
        if (assets == 0) return 0;
        // Do not store newly earned cash just to clear it in the same claim.
        repaymentAllocations[owner].claimable = 0;
        accountedRepayments -= assets;
        SafeERC20.safeTransfer(IERC20(asset()), receiver, assets);
        emit RepaymentsClaimed(owner, receiver, assets);
    }

    /** @dev Only future proceeds follow shares. Cash earned before the transfer stays with the seller.*/
    function _transfer(address from, address to, uint256 amount) internal override nonReentrant {
        _requireValidReceiver(to);
        if (loanId != 0 && from != to && amount > 0) {
            _syncRepayments();
            _accrueRepayments(from);
            _accrueRepayments(to);
        }
        super._transfer(from, to, amount);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        _requireValidReceiver(receiver);
        super._deposit(caller, receiver, assets, shares);
        if (aAsset != address(0)) {
            aave.supply(asset(), assets, address(this), 0);
        }
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares) internal override {
        if (aAsset != address(0)) {
            aave.withdraw(asset(), assets, address(this));
        }
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    function _prepareFinalRedemption() internal {
        _requireUnlockedLoan();
        if (!loanEnded) {
            uint8 status = loanContract.getLOANStatus(loanId);
            require(status != LOANStatus.RUNNING, "PWNCrowdsourceLenderVault: redeem disabled");
            _recoverLoanRepayment();
            if (status == LOANStatus.DEFAULTED) {
                loanContract.liquidate(loanId, "");
            }
            loanEnded = true;
        }
        _updateRepayments();
    }

    function _redeemCollateral(uint256 shares, address receiver, address owner) internal returns (uint256 collateral) {
        require(shares <= balanceOf(owner), "ERC4626: redeem more than max");
        _accrueRepayments(owner);
        if (shares == 0) return 0;
        collateral = _convertToCollateralAssets(shares, Math.Rounding.Down);
        if (_msgSender() != owner) _spendAllowance(owner, _msgSender(), shares);
        _burn(owner, shares);
        emit Withdraw(_msgSender(), receiver, owner, 0, shares);
        if (collateral > 0) {
            SafeERC20.safeTransfer(IERC20(collateralAddr), receiver, collateral);
            emit WithdrawCollateral(_msgSender(), receiver, owner, collateral, shares);
        }
    }

    /** @dev Full-precision (x * y + carry) / denominator, retaining its remainder without overflowing the sum.*/
    function _mulDivWithRemainder(uint256 x, uint256 y, uint256 denominator, uint256 carry)
        internal pure returns (uint256 quotient, uint256 remainder)
    {
        quotient = Math.mulDiv(x, y, denominator) + carry / denominator;
        remainder = mulmod(x, y, denominator);
        carry %= denominator;
        if (remainder >= denominator - carry) {
            quotient += 1;
            remainder -= denominator - carry;
        } else {
            remainder += carry;
        }
    }

    function _requireValidReceiver(address receiver) internal view {
        require(receiver != address(0) && receiver != address(this), "PWNCrowdsourceLenderVault: invalid receiver");
    }

    /** @dev Funding and repayment callbacks must not allocate cash while the loan is being settled.*/
    function _requireUnlockedLoan() internal view {
        require(!loanContract.loanLock(loanId), "PWNCrowdsourceLenderVault: loan context locked");
    }


    /*----------------------------------------------------------*|
    |*  # ERC4626-LIKE COLLATERAL FUNCTIONS                     *|
    |*----------------------------------------------------------*/

    /** @notice ERC4626-like function that returns the total amount of the underlying collateral asset that is “managed” by Vault. */
    function totalCollateralAssets() public view returns (uint256) {
        uint256 additionalCollateralAssets;
        if (stage() == Stage.RUNNING) {
            uint8 status = loanContract.getLOANStatus(loanId);
            if (status == LOANStatus.DEFAULTED) {
                additionalCollateralAssets += loanContract.getLOAN(loanId).collateral.amount;
            }
        }
        return IERC20(collateralAddr).balanceOf(address(this)) + additionalCollateralAssets;
    }

    // TODO shall we keep this as `public`, or only as `external` since so far it's not used internally anywhere?
    // TODO same question for:
    //  1) totalAssets
    //  2) deposit
    //  3) mint
    //  4) withdraw
    //  5) redeem
    //  6) previewCollateralRedeem
    /**
     * @notice ERC4626-like function that allows an on-chain or off-chain user to simulate the effects
     * of their collateral redeemption at the current block, given current on-chain conditions.
     */
    function previewCollateralRedeem(uint256 shares) public view returns (uint256) {
        require(
            loanId != 0 && !loanContract.loanLock(loanId)
                && (loanEnded || loanContract.getLOANStatus(loanId) != LOANStatus.RUNNING),
            "PWNCrowdsourceLenderVault: collateral redeem disabled"
        );

        return _convertToCollateralAssets(shares, Math.Rounding.Down);
    }

    function _convertToCollateralAssets(uint256 shares, Math.Rounding rounding) internal view virtual returns (uint256) {
        uint256 _totalCollateralAssets = totalCollateralAssets();
        if (_totalCollateralAssets == 0) return 0;

        uint256 _totalSupply = totalSupply();
        if (_totalSupply == 0) return 0;

        // Shares and supply have the same units; scaling both is unnecessary and can overflow.
        return shares.mulDiv(_totalCollateralAssets, _totalSupply, rounding);
    }


    /*----------------------------------------------------------*|
    |*  # PWN LENDER HOOKS                                      *|
    |*----------------------------------------------------------*/

    /** @inheritdoc IPWNLenderCreateHook*/
    function onLoanCreated(
        uint256 loanId_,
        address lender,
        address creditAddress,
        uint256 /* principal */,
        bytes calldata lenderData
    ) external nonReentrant returns (bytes32) {
        require(msg.sender == address(loanContract));
        require(loanId == 0);

        require(lender == address(this));
        require(creditAddress == asset());
        require(lenderData.length == 0);
        require(totalSupply() > 0, "PWNCrowdsourceLenderVault: no shares");

        loanId = loanId_;
        // Credit the ERC4626 virtual asset exactly once. Physical cash is allocated only after funding unlocks.
        uint256 supply = totalSupply() + 1;
        repaymentPerShare = REPAYMENT_PRECISION / supply;
        repaymentRemainder = REPAYMENT_PRECISION % supply;
        if (aAsset != address(0)) {
            aave.withdraw(asset(), type(uint256).max, address(this));
        }

        return LENDER_CREATE_HOOK_RETURN_VALUE;
    }

    /** @inheritdoc IPWNLenderRepaymentHook*/
    function onLoanRepaid(
        address /* lender */,
        address /* creditAddress */,
        uint256 /* repayment */,
        bytes calldata /* lenderData */
    ) external pure returns (bytes32) {
        // Note: no need to validate anything, the hook only accepts repayments
        // Core-held fallback repayments, if any, are recovered before the next cash checkpoint.
        return LENDER_REPAYMENT_HOOK_RETURN_VALUE;
    }


    /*----------------------------------------------------------*|
    |*  # ERC721 ON RECEIVED                                    *|
    |*----------------------------------------------------------*/

    /** @inheritdoc IERC721Receiver*/
    function onERC721Received(
        address operator,
        address from,
        uint256 /* tokenId */,
        bytes calldata /* data */
    ) external view returns (bytes4) {
        require(stage() == Stage.POOLING);
        require(operator == address(loanContract));
        require(from == address(loanContract));

        return IERC721Receiver.onERC721Received.selector;
    }


    /*----------------------------------------------------------*|
    |*  # HELPERS                                               *|
    |*----------------------------------------------------------*/

    function _tryGetAssetDecimals_child(IERC20 asset_) private view returns (bool, uint8) {
        (bool success, bytes memory encodedDecimals) = address(asset_).staticcall(
            abi.encodeWithSelector(IERC20Metadata.decimals.selector)
        );
        if (success && encodedDecimals.length >= 32) {
            uint256 returnedDecimals = abi.decode(encodedDecimals, (uint256));
            if (returnedDecimals <= type(uint8).max) {
                return (true, uint8(returnedDecimals));
            }
        }
        return (false, 0);
    }

}
