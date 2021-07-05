pragma abicoder v2;
pragma solidity ^0.8.0;

import "./MultiToken.sol";
import "./PWNVault.sol";
import "./PWNDeed.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract PWNController is Ownable {

    /*----------------------------------------------------------*|
    |*  # VARIABLES & CONSTANTS DEFINITIONS                     *|
    |*----------------------------------------------------------*/

    using MultiToken for MultiToken.Asset;

    PWNDeed public deed;
    PWNVault public vault;

    uint256 public minDuration;
    uint256 public baseFee;         // for simpler division the resulting calculation is divided by `1000000`;
                                    // for 100% set 1000000
                                    // for 10% set 100000
                                    // for 1.5% set 15000
                                    // for 0.1% set 1000
                                    // smallest fee is 0.0001% == 1
    address public collector;
    address public DAO;

    /*----------------------------------------------------------*|
    |*  # EVENTS & ERRORS DEFINITIONS                           *|
    |*----------------------------------------------------------*/

    event NewDeed(uint8 cat, uint256 id, uint256 amount, address indexed tokenAddress, uint256 expiration, uint256 indexed did);
    event NewOffer(uint8 cat, uint256 amount, address tokenAddress, address indexed lender, uint256 toBePaid, uint256 indexed did, bytes32 indexed offer);
    event DeedRevoked(uint256 did);
    event OfferRevoked(bytes32 offer);
    event OfferAccepted(uint256 did, bytes32 offer);
    event PaidBack(uint256 did, bytes32 offer);
    event DeedClaimed(uint256 did);
    event MinDurationChange(uint256 minDuration);
    event FeeChanged(uint256 newFee);

    /*----------------------------------------------------------*|
    |*  # CONSTRUCTOR & FUNCTIONS                               *|
    |*----------------------------------------------------------*/

    /*
     *  Constructor
     *  @title PWN
     *  @dev establishes a connection with other pre-deployed components
     *  @dev for the set up to work both PWNDeed & PWNVault contracts have to called via `.setPWN(PWN.address)`
     *  @param _PWND address of the PWNDeed contract - defines Deed tokens
     *  @param _PWNV address of the PWNVault contract - holds assets
     */
    constructor(
        address _PWND,
        address _PWNV
    )
    Ownable()
    {
        deed = PWNDeed(_PWND);
        vault = PWNVault(_PWNV);
    }

    /*
     *  newDeed - sets & locks collateral
     *  @dev for UI integrations is this the function enabling creation of a new Deed token
     *  @dev Deed status is set to 1
     *  @param _cat - category of the asset - see { MultiToken.sol }
     *  @param _id - ID of an ERC721 or ERC1155 token || 0 in case the token doesn't have IDs
     *  @param _amount - amount of an ERC20 or ERC1155 token || 0 in case of NFTs
     *  @param _tokenAddress - address of the asset contract
     *  @param _expiration - unix time stamp in !! seconds !! (not miliseconds returned by JS)
     *  @returns a Deed ID of the newly created Deed
     */
    function newDeed(
        uint8   _cat,
        uint256 _id,
        uint256 _amount,
        address _tokenAddress,
        uint256 _expiration
    ) external returns (uint256) {
        require(_cat < 3, "Unknown asset type");
        require(_expiration > (block.timestamp + minDuration));

        uint256 did = deed.mint(_cat, _id, _amount, _tokenAddress, _expiration, msg.sender);
        vault.push(deed.getDeedAsset(did), msg.sender);
        deed.bumpStatus(did);

        emit NewDeed(_cat, _id, _amount, _tokenAddress, _expiration, did);
        return did;
    }

    /*
     *  revokeDeed
     *  @dev through this function the borrower can delete the Deed token given no offer was accepted
     *  @param _did - Deed ID specifying the concrete Deed
     */
    function revokeDeed(
        uint256 _did
    ) external {
        require(msg.sender == deed.getBorrower(_did), "The deed doesn't belong to the caller");
        require(deed.getDeedStatus(_did) == PWNDeed.Status.NEW, "Deed can't be revoked at this stage");

        vault.pull(deed.getDeedAsset(_did), msg.sender);
        deed.burn(_did, msg.sender);
        emit DeedRevoked(_did);
    }

    /*
     *  makeOffer
     *  @dev this is the function used by lenders to cast their offers
     *  @dev this function doesn't assume the asset is approved yet for PWNVault
     *  @dev this function requires lender to have a sufficient balance
     *  @param _cat - category of the asset - see { MultiToken.sol }
     *  @param _amount - amount of an ERC20 or ERC1155 token to be offered as credit
     *  @param _tokenAddress - address of the asset contract
     *  @param _did - ID of the Deed the offer should be bound to
     *  @param _toBePaid - amount to be paid back by the borrower
     *  @returns a hash of the newly created offer
     */
    function makeOffer(
        uint8 _cat,
        uint256 _amount,
        address _tokenAddress,
        uint256 _did,
        uint256 _toBePaid
    ) external returns (bytes32) {
        require(deed.getDeedStatus(_did) == PWNDeed.Status.NEW, "Deed not accepting offers");

        bytes32 offer = deed.setOffer(_cat, _amount, _tokenAddress, msg.sender, _did, _toBePaid);
        emit NewOffer(_cat, _amount, _tokenAddress,  msg.sender, _toBePaid, _did, offer);

        return offer;
    }

    /*
     *  revokeOffer
     *  @dev this is the function lenders can use to remove their offers on Deeds they are in the stage of getting offers
     *  @param _offer - identifier of the offer to be revoked
     */
    function revokeOffer(
        bytes32 _offer
    ) external {
        require(deed.getLender(_offer) == msg.sender, "This address didn't create ths offer");
        require(deed.getDeedStatus(deed.getDeedID(_offer)) == PWNDeed.Status.NEW, "Can only remove offers from open Deeds");
        deed.deleteOffer(_offer);
        emit OfferRevoked(_offer);
    }

    /*
     *  acceptOffer
     *  @dev through this function a borrower can accept an existing offer
     *  @dev a UI should do an off-chain balance check on the lender side to make sure the call won't throw
     *  @dev Deed status is set to 2
     *  @param _did - Deed ID specifying the deed being processed
     *  @param _offer - identifier of the offer to be accepted
     *  @returns true if successful
     */
    function acceptOffer(
        bytes32 _offer
    ) external returns (bool) {
        uint256 did = deed.getDeedID(_offer);
        require(msg.sender == deed.getBorrower(did), "The deed doesn't belong to the caller");
        require(deed.getDeedStatus(did) == PWNDeed.Status.NEW, "Deed can't accept more offers");

        deed.setCredit(did, _offer);
        deed.bumpStatus(did);

        address lender = deed.getLender(_offer);
        vault.pullProxy(deed.getOfferAsset(_offer), lender, msg.sender);

        MultiToken.Asset memory Deed;
        Deed.cat = 2;
        Deed.id = did;
        Deed.tokenAddress = address(deed);

        vault.pullProxy(Deed, msg.sender, lender);
        emit OfferAccepted(did, _offer);

        return true;
    }

    /*
     *  payBack
     *  @dev the borrower can pay back the funds through this function
     *  @dev the function assumes the asset (and amount to be paid back) to be returned is approved for PWNVault
     *  @dev the function assumes the borrower has the full amount to be paid back in their account
     *  @dev the Deed can be paid by any address BUT it will always be returned to the pre-set borrower address
     *  @param _did - Deed ID of the deed being paid back
     *  @returns true if successful
     */
    function payBack(uint256 _did) external returns (bool) {
        require(deed.getDeedStatus(_did) == PWNDeed.Status.SET, "Deed doesn't have an accepted offer to be paid back");

        deed.bumpStatus(_did);

        bytes32 offer = deed.getAcceptedOffer(_did);
        MultiToken.Asset memory credit = deed.getOfferAsset(offer);
        credit.amount = deed.toBePaid(offer);               //override the num of credit given

        vault.push(credit, msg.sender);
        vault.pull(deed.getDeedAsset(_did), deed.getBorrower(_did));

        // Pay success fee unless lender was the PWN DAO
        if (deed.getLender(offer) != DAO) {
            uint256 fee = calculateFee(offer);
            credit.amount = fee;
            vault.pullProxy(credit, msg.sender, collector);
        }

        emit PaidBack(_did, offer);
        return true;
    }

    /*
     *  claim Deed
     *  @dev The current Deed owner can call this function if the Deed
     *  @param _did - Deed ID of the deed to be claimed
     *  @returns true if successful
     */
    function claimDeed(uint256 _did) external returns (bool) {
        require(deed.balanceOf(msg.sender, _did) == 1, "Caller is not the deed owner");
        require(deed.getDeedStatus(_did) == PWNDeed.Status.PAID || deed.getDeedStatus(_did) == PWNDeed.Status.EXP, "Deed can't be claimed yet");

        bytes32 offer = deed.getAcceptedOffer(_did);
        MultiToken.Asset memory credit = deed.getOfferAsset(offer);

        if (deed.getDeedStatus(_did) == PWNDeed.Status.PAID) {
            credit.amount = deed.toBePaid(offer);
            vault.pull(credit, msg.sender);

        } else if (deed.getDeedStatus(_did) == PWNDeed.Status.EXP) {
            vault.pull(deed.getDeedAsset(_did), msg.sender);

            // Pay success fee
            if (deed.getLender(offer) != DAO) {
                credit.amount = calculateFee(offer);
                vault.pullProxy(credit, msg.sender, collector);
            }

        }

        emit DeedClaimed(_did);
        deed.burn(_did, msg.sender);
        return true;
    }

    /*----------------------------------------------------------*|
    |*  ## DAO & FEE RELATED FUNCTIONS                          *|
    |*----------------------------------------------------------*/

    function calculateFee(bytes32 _offer) internal view returns (uint256) {
        MultiToken.Asset memory credit = deed.getOfferAsset(_offer);
        return (credit.amount * baseFee) / 100000;
    }


    /*
        *  changeFee
        *  @dev this function sets a new fee
        *  @param _newFee - new base fee
        */
    function changeFee(uint256 _newFee) external onlyOwner {
        baseFee = _newFee;
        emit FeeChanged(_newFee);
    }
//
//    function collectGarbage(uint256 _did) external onlyDAO {
//    }


    /*----------------------------------------------------------*|
    |*  ## SETUP FUNCTIONS                                      *|
    |*----------------------------------------------------------*/

    /*
     *  changeMinDuration
     *  @dev this function sets a minimal time buffer requirement to the expiration time
     *  @param _newMinDuration
     */
    function changeMinDuration(uint256 _newMinDuration) external onlyOwner {
        minDuration = _newMinDuration;
        emit MinDurationChange(_newMinDuration);
    }

}