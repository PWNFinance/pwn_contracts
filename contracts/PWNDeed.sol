pragma abicoder v2;
pragma solidity ^0.8.0;

import "./MultiToken.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Pausable.sol";
import "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Burnable.sol";

contract PWNDeed is ERC1155, ERC1155Burnable, Ownable  {
    using MultiToken for MultiToken.Asset;

    /*----------------------------------------------------------*|
    |*  # VARIABLES & CONSTANTS DEFINITIONS                     *|
    |*----------------------------------------------------------*/

    address public PWN;                 // necessary msg.sender for all Deed related manipulations
    uint256 public id;                  // simple DeedID counter
    uint256 private nonce;              // server for offer hash generation

    enum Status {
        NONE,                           // not yet or no longer existent
        NEW,                            // created (means it wraps collateral), open for offers, but not locked-in
        SET,                            // locked-in offer (can't be revoked)
        PAID,                           // credit paid back -> means now it holds credit + interest
        EXP,                            // only returned after deed has expired
        DEAD,                           // never used but still holding collateral
        UNDEAD                          // expired for more than 2years
    }

    /*
     * Construct defining a Deed
     * @param status - see { enum Status }
     * @param expiration - unix timestamp (in seconds) setting up the default deadline
     * @param borrower - address of the issuer / borrower - stays the same for entire lifespan of the token
     * @param asset - consisting of another an `Asset` struct defined in the MultiToken library
     * @param acceptedOffer - hash of the offer which will be bound to the deed
     * @param pendingOffers - list of offers made to the Deed
     */
    struct Deed {
        Status status;
        uint256 expiration;
        address borrower;
        MultiToken.Asset asset;
        bytes32 acceptedOffer;
        bytes32[] pendingOffers;
    }

    /*
     * Construct defining an offer
     * @param deedID - Deed ID the offer is bound to
     * @param toBePaid - an amount to be paid back (borrowed + interest)
     * @param lender - address of the lender to be the credit will be withdrawn from
     * @param asset - consisting of another an `Asset` struct defined in the MultiToken library
     */
    struct Offer {
        uint256 deedID;
        uint256 toBePaid;
        address lender;
        MultiToken.Asset asset;
    }

    mapping (uint256 => Deed) public deeds;             // mapping of all Deed data
    mapping (bytes32 => Offer) public offers;           // mapping of all offer data

    /*----------------------------------------------------------*|
    |*  # EVENTS & ERRORS DEFINITIONS                           *|
    |*----------------------------------------------------------*/
    // NONE -> all events are handled at the PWN level or ERC1155 leve

    /*----------------------------------------------------------*|
    |*  # MODIFIERS                                             *|
    |*----------------------------------------------------------*/

    modifier onlyPWN() {
        require(msg.sender == PWN);
        _;
    }

    /*----------------------------------------------------------*|
    |*  # CONSTRUCTOR & FUNCTIONS                               *|
    |*----------------------------------------------------------*/

    /*
     *  Constructor
     *  @title PWN Deed
     *  @dev Creates the PWN Deed token contract - ERC1155 with extra use case specific features
     *  @dev Once the PWN contract is set, you'll have to call `this.setPWN(PWN.address)` for this contract to work
     *  @param _uri - uri to be used for finding the token metadata (https://api.pwn.finance/deed/...)
     */
    constructor(
        string memory _uri
    )
    ERC1155(_uri)
    Ownable()
    {
    }

    /*
     *   All contracts of this section can only be called by the PWN contract itself - once set via `setPWN(PWN.address)`
     */

    /*
     *  mint
     *  @dev Creates the PWN Deed token contract - ERC1155 with extra use case specific features
     *  @param _cat - category of the asset - see { MultiToken.sol }
     *  @param _id - ID of an ERC721 or ERC1155 token || 0 in case the token doesn't have IDs
     *  @param _amount - amount of an ERC20 or ERC1155 token || 0 in case of NFTs
     *  @param _tokenAddress - address of the asset contract
     *  @param _expiration - unix time stamp in !! seconds !! (not mili-seconds returned by JS)
     *  @param _borrower - the address initiating the new Deed
     *  @returns Deed ID of the newly minted Deed
     */
    function mint(
        uint8 _cat,
        uint256 _id,
        uint256 _amount,
        address _tokenAddress,
        uint256 _expiration,
        address _borrower
    )
    external
    onlyPWN
    returns (uint256)
    {
        id++;
        deeds[id].expiration = _expiration;
        deeds[id].borrower = _borrower;
        deeds[id].asset.cat = _cat;
        deeds[id].asset.id = _id;
        deeds[id].asset.amount = _amount;
        deeds[id].asset.tokenAddress = _tokenAddress;

        _mint(_borrower, id, 1, "");
        return id;
    }

    /*
     *  burn
     *  @dev Burns a deed token
     *  @param _did Deed ID of the token to be burned
     *  @param _owner address of the borrower who issued the Deed
     */
    function burn(
        uint256 _did,
        address _owner
    )
    external
    onlyPWN
    {
        delete deeds[_did];
        _burn(_owner, _did, 1);
    }

    /*
     *  setOffer
     *  @dev saves an offer object that defines credit terms
     *  @param _cat - category of the asset - see { MultiToken.sol }
     *  @param _amount - amount of an ERC20 or ERC1155 token to be offered as credit
     *  @param _tokenAddress - address of the asset contract
     *  @param _did - ID of the Deed the offer should be bound to
     *  @param _toBePaid - amount to be paid back by the borrower
     *  @returns hash of the newly created offer
     */
    function setOffer(
        uint8 _cat,
        uint256 _amount,
        address _tokenAddress,
        address _lender,
        uint256 _did,
        uint256 _toBePaid
    )
    external
    onlyPWN
    returns (bytes32)
    {
        bytes32 hash = keccak256(abi.encodePacked(msg.sender,nonce));
        nonce++;

        offers[hash].asset.cat = _cat;
        offers[hash].asset.amount = _amount;
        offers[hash].asset.tokenAddress = _tokenAddress;
        offers[hash].toBePaid = _toBePaid;
        offers[hash].lender = _lender;
        offers[hash].deedID = _did;

        deeds[_did].pendingOffers.push(hash);
        return hash;
    }

    /*
     *  deleteOffer
     *  @dev utility function to remove a pending offer
     *  @dev This only removes the offer representation but it doesn't remove the offer from a list of pending offers.
     *          The offers associated with a deed has to be filtered on the front end to only list the valid ones.
     *          No longer existent offers will simply return 0 if prompted about their DID.
     *  @param _hash - hash identifying a offer
     *  @dev TODO: consider ways to remove the offer from the pending offers array / maybe replace for a mapping
     */
    function deleteOffer(
        bytes32 _hash
    )
    external
    onlyPWN
    {
        delete offers[_hash];
    }

    function setCredit(
        uint256 _id,
        bytes32 _offer
    )
    external
    onlyPWN
    {
        deeds[_id].acceptedOffer = _offer;
        delete deeds[_id].pendingOffers;
    }

    /*
     *  changeStatus
     *  @dev utility function that changes a deed state from 1 -> 3
     *  @param _status - corresponds to the current stage of the Deed - see { enum Status }
     *  @param _did - Deed ID selecting the particular Deed
     */
    function bumpStatus(
        uint256 _did
    )
    external
    onlyPWN
    {
        deeds[_did].status = Status(uint8(deeds[_did].status)+1);
    }


    /*
     *  override of the check happening before Deed transfers
     *  @dev forbids for the Deed token to be transferred at the setup stage
     *  @dev for context see { ERC1155.sol }
     */
    function _beforeTokenTransfer(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    )
    internal view
    virtual override
    {
        for (uint i = 0; i < ids.length; i++) {
            require(deeds[i].status != Status.NEW, "Deed can't be transferred at this stage");
        }
    }

    /*----------------------------------------------------------*|
    |*  ## VIEW FUNCTIONS                                       *|
    |*----------------------------------------------------------*/

    /*--------------------------------*|
    |*  ## VIEW FUNCTIONS - DEEDS     *|
    |*--------------------------------*/

    /*
     *  getDeedStatus
     *  @dev used in contract calls & status checks and also in UI for elementary deed status categorization
     *  @param _did - Deed ID checked for status
     *  @returns a status number - see { enum Status }
     */
    function getDeedStatus(uint256 _did) public view returns (Status) {

        if (deeds[_did].expiration < block.timestamp) {
            if (deeds[_did].status == Status.NEW) {
                return Status.DEAD;
            } else if (deeds[_did].status == Status.SET) {
                return Status.EXP;
            }
        } else {
            return deeds[_did].status;
        }
        return Status.NONE;
    }

    /*
     *  getExpiration
     *  @dev utility function to find out exact expiration time of a particular Deed
     *  @dev for simple status check use `this.getDeedStatus(did)` if `status == 4` then Deed has expired
     *  @param _did - Deed ID to be checked
     *  @returns unix time stamp in seconds
     */
    function getExpiration(uint256 _did) public view returns (uint256) {
        return deeds[_did].expiration;
    }

    /*
     *  getBorrower
     *  @dev utility function to find out a borrower address of a particular Deed
     *  @param _did - Deed ID to be checked
     *  @returns address of the borrower
     */
    function getBorrower(uint256 _did) public view returns (address) {
        return deeds[_did].borrower;
    }

    /*
     *  getDeedAsset
     *  @dev utility function to find out collateral asset of a particular Deed
     *  @param _did - Deed ID to be checked
     *  @returns Asset construct - for definition see { MultiToken.sol }
     */
    function getDeedAsset(uint256 _did) public view returns (MultiToken.Asset memory) {
        return deeds[_did].asset;
    }

    /*
     *  getOffers
     *  @dev utility function to get a list of all pending offers of a Deed
     *  @param _did - Deed ID to be checked
     *  @returns a list of offer hashes
     */
    function getOffers(uint256 _did) public view returns (bytes32[] memory) {
        return deeds[_did].pendingOffers;
    }

    /*
     *  getAcceptedOffer
     *  @dev used to get a list of made offers to be queried in the UI - needs additional check for re-validating each offer
     *  @dev revalidation requires checking if the lender has sufficient balance and approved the asset
     *  @param _did - Deed ID being queried for offers
     *  @returns a hash of the accepted offer
     */
    function getAcceptedOffer(uint256 _did) public view returns (bytes32) {
        return deeds[_did].acceptedOffer;
    }

    /*--------------------------------*|
    |*  ## VIEW FUNCTIONS - OFFERS    *|
    |*--------------------------------*/

    /*
     *  getDeedID
     *  @dev utility function to find out which Deed is an offer associated with
     *  @param _offer - Offer hash of an offer to be prompted
     *  @returns a Deed ID
     */
    function getDeedID(bytes32 _offer) public view returns (uint256) {
        return offers[_offer].deedID;
    }

    /*
     *  getOfferAsset
     *  @dev utility function that returns the credit asset of a particular offer
     *  @param _offer - Offer hash of an offer to be prompted
     *  @returns Asset construct - for definition see { MultiToken.sol }
     */
    function getOfferAsset(bytes32 _offer) public view returns (MultiToken.Asset memory) {
        return offers[_offer].asset;
    }

    /*
     *  toBePaid
     *  @dev quick query of the total amount to be paid to an offer
     *  @param _offer - Offer hash of an offer to be prompted
     *  @returns amount to be paid back
     */
    function toBePaid(bytes32 _offer) public view returns (uint256) {
        return offers[_offer].toBePaid;
    }

    /*
     *  getLender
     *  @dev utility function to find out a lender address of a particular offer
     *  @param _offer - Offer hash of an offer to be prompted
     *  @returns address of the lender
     */
    function getLender(bytes32 _offer) public view returns (address) {
        return offers[_offer].lender;
    }

    /*--------------------------------*|
    |*  ## SETUP FUNCTIONS            *|
    |*--------------------------------*/

    /*
     *  setPWN
     *  @dev An essential setup function. Has to be called once PWN contract was deployed
     *  @param _address identifying the PWN contract
     */
    function setPWN(address _address) external onlyOwner {
        PWN = _address;
    }
}