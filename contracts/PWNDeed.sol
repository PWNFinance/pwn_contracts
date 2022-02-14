// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.4;

import "@pwnfinance/multitoken/contracts/MultiToken.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/interfaces/IERC1271.sol";

contract PWNDeed is ERC1155, Ownable {

    /*----------------------------------------------------------*|
    |*  # VARIABLES & CONSTANTS DEFINITIONS                     *|
    |*----------------------------------------------------------*/

    /**
     * Necessary msg.sender for all Deed related manipulations
     */
    address public PWN;

    /**
     * Incremental DeedID counter
     */
    uint256 public id;

    /**
     * EIP-1271 valid signature magic value
     */
    bytes4 constant internal EIP1271_VALID_SIGNATURE = 0x1626ba7e;

    /**
     * EIP-712 offer struct type hash
     */
    bytes32 constant internal OFFER_TYPEHASH = keccak256(
        "Offer(address collateralAddress,uint8 collateralCategory,uint256 collateralAmount,uint256 collateralId,address loanAssetAddress,uint256 loanAmount,uint256 loanYield,uint32 duration,uint40 expiration,address lender,bytes32 nonce)"
    );

    /**
     * EIP-712 flexible offer struct type hash
     */
    bytes32 constant internal FLEXIBLE_OFFER_TYPEHASH = keccak256(
        "FlexibleOffer(address collateralAddress,uint8 collateralCategory,uint256 collateralAmount,uint256[] collateralIdsWhitelist,address loanAssetAddress,uint256 loanAmountMax,uint256 loanAmountMin,uint256 loanYieldMax,uint32 durationMax,uint32 durationMin,uint40 expiration,address lender,bytes32 nonce)"
    );

    // TODO: Doc
    bytes32 constant internal GROUP_OFFER_TYPEHASH = keccak256(
        "GroupOffer(address collateralAddress,uint8 collateralCategory,uint256 collateralAmount,uint256 collateralId,address loanAssetAddress,uint256 loanAmount,uint256 loanYield,uint32 duration,uint40 expiration,uint256 loanAmountPart,address lender,bytes32 nonce)"
    );

    /**
     * Construct defining a Deed
     * @param status 0 == none/dead || 2 == running/accepted offer || 3 == paid back || 4 == expired
     * @param borrower Address of the borrower - stays the same for entire lifespan of the token
     * @param duration Loan duration in seconds
     * @param expiration Unix timestamp (in seconds) setting up the default deadline
     * @param collateral Asset used as a loan collateral. Consisting of another `Asset` struct defined in the MultiToken library
     * @param loan Asset to be borrowed by lender to borrower. Consisting of another `Asset` struct defined in the MultiToken library
     * @param loanRepayAmount Amount of loan asset to be repaid
     */
    struct Deed {
        uint8 status;
        address borrower;
        uint32 duration;
        uint40 expiration;
        MultiToken.Asset collateral;
        MultiToken.Asset loan;
        uint256 loanRepayAmount;
    }

    /**
     * Construct defining an Offer
     * @param collateralAddress Address of an asset used as a collateral
     * @param collateralCategory Category of an asset used as a collateral (0 == ERC20, 1 == ERC721, 2 == ERC1155)
     * @param collateralAmount Amount of tokens used as a collateral, in case of ERC721 should be 0
     * @param collateralId Token id of an asset used as a collateral, in case of ERC20 should be 0
     * @param loanAssetAddress Address of an asset which is lended to borrower
     * @param loanAmount Amount of tokens which is offered as a loan to borrower
     * @param loanYield Amount of tokens which acts as a lenders loan interest. Borrower has to pay back borrowed amount + yield.
     * @param duration Loan duration in seconds
     * @param expiration Offer expiration timestamp in seconds
     * @param lender Address of a lender. This address has to sign an offer to be valid.
     * @param nonce Additional value to enable identical offers in time. Without it, it would be impossible to make again offer, which was once revoked.
     */
    struct Offer {
        address collateralAddress;
        MultiToken.Category collateralCategory;
        uint256 collateralAmount;
        uint256 collateralId;
        address loanAssetAddress;
        uint256 loanAmount;
        uint256 loanYield;
        uint32 duration;
        uint40 expiration;
        address lender;
        bytes32 nonce;
    }

    /**
     * Construct defining an Flexible offer
     * @param collateralAddress Address of an asset used as a collateral
     * @param collateralCategory Category of an asset used as a collateral (0 == ERC20, 1 == ERC721, 2 == ERC1155)
     * @param collateralAmount Amount of tokens used as a collateral, in case of ERC721 should be 0
     * @param collateralIdsWhitelist List of acceptable collateral ids. If empty, any id is acceptable. Should be empty in case of ERC20.
     * @param collateralIdsBlacklist List of blacklisted collateral ids. These ids are excluded from the list of acceptable ids.
     * @param loanAssetAddress Address of an asset which is lended to borrower
     * @param loanAmountMax Max amount of tokens which is offered as a loan to borrower
     * @param loanAmountMin Min amount of tokens which is offered as a loan to borrower
     * @param loanYieldMax Amount of tokens which acts as a lenders loan interest for max duration.
     * @param durationMax Max loan duration in seconds
     * @param durationMin Min loan duration in seconds
     * @param expiration Offer expiration timestamp in seconds
     * @param lender Address of a lender. This address has to sign a flexible offer to be valid.
     * @param nonce Additional value to enable identical offers in time. Without it, it would be impossible to make again offer, which was once revoked.
     */
    struct FlexibleOffer {
        address collateralAddress;
        MultiToken.Category collateralCategory;
        uint256 collateralAmount;
        uint256[] collateralIdsWhitelist;
        address loanAssetAddress;
        uint256 loanAmountMax;
        uint256 loanAmountMin;
        uint256 loanYieldMax;
        uint32 durationMax;
        uint32 durationMin;
        uint40 expiration;
        address lender;
        bytes32 nonce;
    }

    /**
     * Construct defining an Flexible offer concrete instance
     * @param collateralId Selected collateral id to be used as a collateral. Id has to be in the flexible offer list `collateralIdsWhitelist`. If `collateralIdsWhitelist` is empty, it could be any id.
     * @param loanAmount Selected loan amount to be borrowed from lender.
     * @param duration Selected loan duration. Shorter duration reflexts into smaller loan yield for a lender.
     */
    struct OfferInstance {
        uint256 collateralId;
        uint256 loanAmount;
        uint32 duration;
    }

    // TODO: Doc
    struct LoanParams {
        address collateralAddress;
        MultiToken.Category collateralCategory;
        uint256 collateralAmount;
        uint256 collateralId;
        address loanAssetAddress;
        uint256 loanAmount;
        uint256 loanYield;
        uint32 duration;
    }

    // TODO: Doc
    struct GroupOfferDigestWithSignature {
        uint40 expiration;
        uint256 loanAmountPart;
        address lender;
        bytes32 nonce;
        bytes signature;
    }

    /**
     * Mapping of all Deed data by deed id
     */
    mapping (uint256 => Deed) public deeds;

    /**
     * Mapping of revoked offers by offer struct typed hash
     */
    mapping (bytes32 => bool) public revokedOffers;

    /*----------------------------------------------------------*|
    |*  # EVENTS & ERRORS DEFINITIONS                           *|
    |*----------------------------------------------------------*/

    event DeedCreated(uint256 indexed did, address indexed lender, bytes32 indexed offerHash);
    event GroupDeedCreated(uint256 indexed did, address indexed lender);
    event OfferRevoked(bytes32 indexed offerHash);
    event PaidBack(uint256 did);
    event DeedClaimed(uint256 did);

    /*----------------------------------------------------------*|
    |*  # MODIFIERS                                             *|
    |*----------------------------------------------------------*/

    modifier onlyPWN() {
        require(msg.sender == PWN, "Caller is not the PWN");
        _;
    }

    /*----------------------------------------------------------*|
    |*  # CONSTRUCTOR & FUNCTIONS                               *|
    |*----------------------------------------------------------*/

    /*
     * PWN Deed constructor
     * @dev Creates the PWN Deed token contract - ERC1155 with extra use case specific features
     * @dev Once the PWN contract is set, you'll have to call `this.setPWN(PWN.address)` for this contract to work
     * @param _uri Uri to be used for finding the token metadata (https://api.pwn.finance/deed/...)
     */
    constructor(string memory _uri) ERC1155(_uri) Ownable() {

    }

    /**
     * All contracts of this section can only be called by the PWN contract itself - once set via `setPWN(PWN.address)`
     */

    /**
     * revokeOffer
     * @notice Revoke an offer
     * @dev Offer is revoked by lender or when offer is accepted by borrower to prevent accepting it twice
     * @param _offerHash Offer typed struct hash
     * @param _signature Offer typed struct signature
     * @param _sender Address of a message sender (lender)
     */
    function revokeOffer(
        bytes32 _offerHash,
        bytes calldata _signature,
        address _sender
    ) external onlyPWN {
        require(ECDSA.recover(_offerHash, _signature) == _sender, "Sender is not an offer signer");
        require(revokedOffers[_offerHash] == false, "Offer is already revoked or has been accepted");

        revokedOffers[_offerHash] = true;

        emit OfferRevoked(_offerHash);
    }

    /**
     * create
     * @notice Creates the PWN Deed token contract - ERC1155 with extra use case specific features from simple offer
     * @dev Contract wallets need to implement EIP-1271 to validate signature on the contract behalf
     * @param _offer Offer struct holding plain offer data
     * @param _signature Offer typed struct signature signed by lender
     * @param _sender Address of a message sender (borrower)
     */
    function create(
        Offer memory _offer,
        bytes memory _signature,
        address _sender
    ) external onlyPWN {
        bytes32 offerHash = keccak256(abi.encodePacked(
            "\x19\x01", _eip712DomainSeparator(), hash(_offer)
        ));

        _checkValidSignature(_offer.lender, offerHash, _signature);
        _checkValidOffer(_offer.expiration, offerHash);

        revokedOffers[offerHash] = true;

        uint256 _id = ++id;

        Deed storage deed = deeds[_id];
        deed.status = 2;
        deed.borrower = _sender;
        deed.duration = _offer.duration;
        deed.expiration = uint40(block.timestamp) + _offer.duration;
        deed.collateral = MultiToken.Asset(
            _offer.collateralAddress,
            _offer.collateralCategory,
            _offer.collateralAmount,
            _offer.collateralId
        );
        deed.loan = MultiToken.Asset(
            _offer.loanAssetAddress,
            MultiToken.Category.ERC20,
            _offer.loanAmount,
            0
        );
        deed.loanRepayAmount = _offer.loanAmount + _offer.loanYield;

        _mint(_offer.lender, _id, 1, "");

        emit DeedCreated(_id, _offer.lender, offerHash);
    }

    /**
     * createFlexible
     * @notice Creates the PWN Deed token contract - ERC1155 with extra use case specific features from flexible offer
     * @dev Contract wallets need to implement EIP-1271 to validate signature on the contract behalf
     * @param _offer Flexible offer struct holding plain flexible offer data
     * @param _offerInstance Concrete values for flexible offer selected by borrower
     * @param _signature Offer typed struct signature signed by lender
     * @param _sender Address of a message sender (borrower)
     */
    function createFlexible(
        FlexibleOffer memory _offer,
        OfferInstance memory _offerInstance,
        bytes memory _signature,
        address _sender
    ) external onlyPWN {
        bytes32 offerHash = keccak256(abi.encodePacked(
            "\x19\x01", _eip712DomainSeparator(), hash(_offer)
        ));

        _checkValidSignature(_offer.lender, offerHash, _signature);
        _checkValidOffer(_offer.expiration, offerHash);

        // Flexible collateral id
        if (_offer.collateralIdsWhitelist.length > 0) {
            // Whitelisted collateral id
            require(_contains(_offer.collateralIdsWhitelist, _offerInstance.collateralId), "Selected collateral id is not contained in whitelist");
        } // else: Any collateral id - collection offer

        // Flexible amount
        require(_offer.loanAmountMin <= _offerInstance.loanAmount && _offerInstance.loanAmount <= _offer.loanAmountMax, "Loan amount is not in offered range");

        // Flexible duration
        require(_offer.durationMin <= _offerInstance.duration && _offerInstance.duration <= _offer.durationMax, "Loan duration is not in offered range");

        revokedOffers[offerHash] = true;

        uint256 _id = ++id;

        Deed storage deed = deeds[_id];
        deed.status = 2;
        deed.borrower = _sender;
        deed.duration = _offerInstance.duration;
        deed.expiration = uint40(block.timestamp) + _offerInstance.duration;
        deed.collateral = MultiToken.Asset(
            _offer.collateralAddress,
            _offer.collateralCategory,
            _offer.collateralAmount,
            _offerInstance.collateralId
        );
        deed.loan = MultiToken.Asset(
            _offer.loanAssetAddress,
            MultiToken.Category.ERC20,
            _offerInstance.loanAmount,
            0
        );
        deed.loanRepayAmount = countLoanRepayAmount(
            _offerInstance.loanAmount,
            _offerInstance.duration,
            _offer.loanYieldMax,
            _offer.durationMax
        );

        _mint(_offer.lender, _id, 1, "");

        emit DeedCreated(_id, _offer.lender, offerHash);
    }

    // TODO: Doc
    function createGroup(
        LoanParams memory _loanParams,
        GroupOfferDigestWithSignature[] memory _digestWithSignatureList,
        address _lender,
        address _sender
    ) external onlyPWN {
        uint256 totalLendedAmount;

        // Checks that signatures are correct
        for (uint256 i = 0; i < _digestWithSignatureList.length; ++i) {

            GroupOfferDigestWithSignature memory digestWithSignature = _digestWithSignatureList[i];

            bytes32 offerHash = keccak256(abi.encodePacked(
                "\x19\x01", _eip712DomainSeparator(), hash(_loanParams, digestWithSignature)
            ));

            _checkValidSignature(digestWithSignature.lender, offerHash, digestWithSignature.signature);
            _checkValidOffer(digestWithSignature.expiration, offerHash);

            revokedOffers[offerHash] = true;

            totalLendedAmount += digestWithSignature.loanAmountPart;

        }

        // Check that loan amount is equal to proposed amount
        require(totalLendedAmount == _loanParams.loanAmount, "Borrowed amount has to equal total lended amount");

        uint256 _id = ++id;

        Deed storage deed = deeds[_id];
        deed.status = 2;
        deed.borrower = _sender;
        deed.duration = _loanParams.duration;
        deed.expiration = uint40(block.timestamp) + _loanParams.duration;
        deed.collateral = MultiToken.Asset(
            _loanParams.collateralAddress,
            _loanParams.collateralCategory,
            _loanParams.collateralAmount,
            _loanParams.collateralId
        );
        deed.loan = MultiToken.Asset(
            _loanParams.loanAssetAddress,
            MultiToken.Category.ERC20,
            _loanParams.loanAmount,
            0
        );
        deed.loanRepayAmount = _loanParams.loanAmount + _loanParams.loanYield;

        _mint(_lender, _id, 1, "");

        emit GroupDeedCreated(_id, _lender);
    }

    /**
     * repayLoan
     * @notice Function to make proper state transition
     * @param _did ID of the Deed which is paid back
     */
    function repayLoan(uint256 _did) external onlyPWN {
        require(getStatus(_did) == 2, "Deed is not running and cannot be paid back");

        deeds[_did].status = 3;

        emit PaidBack(_did);
    }

    /**
     * claim
     * @notice Function that would set the deed to the dead state if the token is in paidBack or expired state
     * @param _did ID of the Deed which is claimed
     * @param _owner Address of the deed token owner
     */
    function claim(
        uint256 _did,
        address _owner
    ) external onlyPWN {
        require(balanceOf(_owner, _did) == 1, "Caller is not the deed owner");
        require(getStatus(_did) >= 3, "Deed can't be claimed yet");

        deeds[_did].status = 0;

        emit DeedClaimed(_did);
    }

    /**
     * burn
     * @notice Function that would burn the deed token if the token is in dead state
     * @param _did ID of the Deed which is burned
     * @param _owner Address of the deed token owner
     */
    function burn(
        uint256 _did,
        address _owner
    ) external onlyPWN {
        require(balanceOf(_owner, _did) == 1, "Caller is not the deed owner");
        require(deeds[_did].status == 0, "Deed can't be burned at this stage");

        delete deeds[_did];
        _burn(_owner, _did, 1);
    }

    /**
     * countLoanRepayAmount
     * @notice Count a loan repay amount of flexible offer based on a loan amount and duration.
     * @notice The smaller the duration is, the smaller is the lenders yield.
     * @notice Loan repay amount is decreasing linearly from maximum duration and is fixing loans APR.
     * @param _loanAmount Selected amount of loan asset by borrower
     * @param _duration Selected loan duration by borrower
     * @param _loanYieldMax Yield for maximum loan duration set by lender in an offer
     * @param _durationMax Maximum loan duration set by lender in an offer
     */
    function countLoanRepayAmount(
        uint256 _loanAmount,
        uint32 _duration,
        uint256 _loanYieldMax,
        uint32 _durationMax
    ) public pure returns (uint256) {
        return _loanAmount + _loanYieldMax * _duration / _durationMax;
    }

    /*----------------------------------------------------------*|
    |*  ## VIEW FUNCTIONS                                       *|
    |*----------------------------------------------------------*/

    /**
     * getStatus
     * @dev used in contract calls & status checks and also in UI for elementary deed status categorization
     * @param _did Deed ID checked for status
     * @return a status number
     */
    function getStatus(uint256 _did) public view returns (uint8) {
        if (deeds[_did].expiration > 0 && deeds[_did].expiration < block.timestamp && deeds[_did].status != 3) {
            return 4;
        } else {
            return deeds[_did].status;
        }
    }

    /**
     * getExpiration
     * @dev utility function to find out exact expiration time of a particular Deed
     * @dev for simple status check use `this.getStatus(did)` if `status == 4` then Deed has expired
     * @param _did Deed ID to be checked
     * @return unix time stamp in seconds
     */
    function getExpiration(uint256 _did) public view returns (uint40) {
        return deeds[_did].expiration;
    }

    /**
     * getDuration
     * @dev utility function to find out loan duration period of a particular Deed
     * @param _did Deed ID to be checked
     * @return loan duration period in seconds
     */
    function getDuration(uint256 _did) public view returns (uint32) {
        return deeds[_did].duration;
    }

    /**
     * getBorrower
     * @dev utility function to find out a borrower address of a particular Deed
     * @param _did Deed ID to be checked
     * @return address of the borrower
     */
    function getBorrower(uint256 _did) public view returns (address) {
        return deeds[_did].borrower;
    }

    /**
     * getCollateral
     * @dev utility function to find out collateral asset of a particular Deed
     * @param _did Deed ID to be checked
     * @return Asset construct - for definition see { MultiToken.sol }
     */
    function getCollateral(uint256 _did) public view returns (MultiToken.Asset memory) {
        return deeds[_did].collateral;
    }

    /**
     * getLoan
     * @dev utility function to find out loan asset of a particular Deed
     * @param _did Deed ID to be checked
     * @return Asset construct - for definition see { MultiToken.sol }
     */
    function getLoan(uint256 _did) public view returns (MultiToken.Asset memory) {
        return deeds[_did].loan;
    }

    /**
     * getLoan
     * @dev utility function to find out loan repay amount of a particular Deed
     * @param _did Deed ID to be checked
     * @return Amount of loan asset to be repaid
     */
    function getLoanRepayAmount(uint256 _did) public view returns (uint256) {
        return deeds[_did].loanRepayAmount;
    }

    /**
     * isRevoked
     * @dev utility function to find out if offer is revoked
     * @param _offerHash Offer typed struct hash
     * @return True if offer is revoked
     */
    function isRevoked(bytes32 _offerHash) public view returns (bool) {
        return revokedOffers[_offerHash];
    }

    /*--------------------------------*|
    |*  ## SETUP FUNCTIONS            *|
    |*--------------------------------*/

    /**
     * setPWN
     * @dev An essential setup function. Has to be called once PWN contract was deployed
     * @param _address Identifying the PWN contract
     */
    function setPWN(address _address) external onlyOwner {
        PWN = _address;
    }

    /**
     * setUri
     * @dev An non-essential setup function. Can be called to adjust the Deed token metadata URI
     * @param _newUri setting the new origin of Deed metadata
     */
    function setUri(string memory _newUri) external onlyOwner {
        _setURI(_newUri);
    }

    /*--------------------------------*|
    |*  ## PRIVATE FUNCTIONS          *|
    |*--------------------------------*/

    /**
     * _eip712DomainSeparator
     * @notice Compose EIP712 domain separator
     * @dev Domain separator is composing to prevent repay attack in case of an Ethereum fork
     */
    function _eip712DomainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes("PWN")),
            keccak256(bytes("1")),
            block.chainid,
            address(this)
        ));
    }

    /**
     * _checkValidSignature
     * @notice
     * @param _lender Address of a lender. This address has to sign an offer to be valid.
     * @param _offerHash Hash of an offer EIP-712 data struct
     * @param _signature Signed offer data
     */
    function _checkValidSignature(
        address _lender,
        bytes32 _offerHash,
        bytes memory _signature
    ) private view {
        if (_lender.code.length > 0) {
            require(IERC1271(_lender).isValidSignature(_offerHash, _signature) == EIP1271_VALID_SIGNATURE, "Signature on behalf of contract is invalid");
        } else {
            require(ECDSA.recover(_offerHash, _signature) == _lender, "Lender address didn't sign the offer");
        }
    }

    /**
     * _checkValidOffer
     * @notice
     * @param _expiration Offer expiration timestamp in seconds
     * @param _offerHash Hash of an offer EIP-712 data struct
     */
    function _checkValidOffer(
        uint40 _expiration,
        bytes32 _offerHash
    ) private view {
        require(_expiration == 0 || block.timestamp < _expiration, "Offer is expired");
        require(revokedOffers[_offerHash] == false, "Offer is revoked or has been accepted");
    }

    /**
     * _contains
     * @notice Function to determine if an item is in contained a list
     * @param _list List of all items
     * @param _item Item that should be found in a list
     * @return True if item is in the list
     */
    function _contains(uint256[] memory _list, uint256 _item) private pure returns (bool) {
        unchecked {
            for (uint256 i = 0; i < _list.length; ++i)
                if (_list[i] == _item)
                    return true;
        }

        return false;
    }

    /**
     * hash offer
     * @notice Hash offer struct according to EIP-712
     * @param _offer Offer struct to be hashed
     * @return Offer struct hash
     */
    function hash(Offer memory _offer) private pure returns (bytes32) {
        return keccak256(abi.encode(
            OFFER_TYPEHASH,
            _offer.collateralAddress,
            _offer.collateralCategory,
            _offer.collateralAmount,
            _offer.collateralId,
            _offer.loanAssetAddress,
            _offer.loanAmount,
            _offer.loanYield,
            _offer.duration,
            _offer.expiration,
            _offer.lender,
            _offer.nonce
        ));
    }

    /**
     * hash offer
     * @notice Hash flexible offer struct according to EIP-712
     * @param _offer FlexibleOffer struct to be hashed
     * @return FlexibleOffer struct hash
     */
    function hash(FlexibleOffer memory _offer) private pure returns (bytes32) {
        // Need to divide encoding into smaller parts because of "Stack to deep" error

        bytes memory encodedOfferCollateralData = abi.encode(
            _offer.collateralAddress,
            _offer.collateralCategory,
            _offer.collateralAmount,
            keccak256(abi.encodePacked(_offer.collateralIdsWhitelist))
        );

        bytes memory encodedOfferLoanData = abi.encode(
            _offer.loanAssetAddress,
            _offer.loanAmountMax,
            _offer.loanAmountMin,
            _offer.loanYieldMax
        );

        bytes memory encodedOfferOtherData = abi.encode(
            _offer.durationMax,
            _offer.durationMin,
            _offer.expiration,
            _offer.lender,
            _offer.nonce
        );

        return keccak256(abi.encodePacked(
            FLEXIBLE_OFFER_TYPEHASH,
            encodedOfferCollateralData,
            encodedOfferLoanData,
            encodedOfferOtherData
        ));
    }

    // TODO: Doc
    function hash(
        LoanParams memory _loanParams,
        GroupOfferDigestWithSignature memory _digestWithSignature
    ) private pure returns (bytes32) {
        return keccak256(abi.encode(
            GROUP_OFFER_TYPEHASH,
            _loanParams.collateralAddress,
            _loanParams.collateralCategory,
            _loanParams.collateralAmount,
            _loanParams.collateralId,
            _loanParams.loanAssetAddress,
            _loanParams.loanAmount,
            _loanParams.loanYield,
            _loanParams.duration,
            _digestWithSignature.expiration,
            _digestWithSignature.loanAmountPart,
            _digestWithSignature.lender,
            _digestWithSignature.nonce
        ));
    }
}
