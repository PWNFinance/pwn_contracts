// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.4;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./PWNGroupOffer.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@pwnfinance/multitoken/contracts/MultiToken.sol";

contract PWNGroupOfferFactory {

    /*----------------------------------------------------------*|
    |*  # VARIABLES & CONSTANTS DEFINITIONS                     *|
    |*----------------------------------------------------------*/

    bytes4 constant internal EIP1271_VALID_SIGNATURE = 0x1626ba7e;

    bytes32 constant internal GROUP_OFFER_TYPEHASH = keccak256(
        "GroupOffer(address collateralAddress,uint8 collateralCategory,uint256 collateralAmount,uint256 collateralId,address loanAssetAddress,uint256 loanAmount,uint256 loanYield,uint32 duration,uint40 expiration,uint256 loanAmountPart,address lender,bytes32 nonce)"
    );

    uint256 public groupOfferId;

    address public pwn;
    address public pwnDeed;
    address public pwnVault;

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

    struct OfferDigestWithSignature {
        uint40 expiration;
        uint256 loanAmountPart;
        address lender;
        bytes32 nonce;
        bytes signature;
    }

    mapping (bytes32 => bool) public revokedOffers;

    /*----------------------------------------------------------*|
    |*  # EVENTS & ERRORS DEFINITIONS                           *|
    |*----------------------------------------------------------*/

    event GroupOfferCreated(uint256 indexed id, address groupOffer, address indexed borrower, address[] indexed lenders);

    event GroupOfferRevoked(bytes32 indexed offerHash);

    /*----------------------------------------------------------*|
    |*  # CONSTRUCTOR & FUNCTIONS                               *|
    |*----------------------------------------------------------*/

    constructor(address _pwn, address _pwnDeed, address _pwnVault) {
        pwn = _pwn;
        pwnDeed = _pwnDeed;
        pwnVault = _pwnVault;
    }


    function createGroupOffer(
        LoanParams calldata _loanParams,
        OfferDigestWithSignature[] calldata _digestWithSignatureList
    ) external returns (address) {

        uint256 totalLendedAmount;
        for (uint256 i = 0; i < _digestWithSignatureList.length; ++i) {
            OfferDigestWithSignature memory digestWithSignature = _digestWithSignatureList[i];

            totalLendedAmount += digestWithSignature.loanAmountPart;
        }

        // Check that loan amount is equal to proposed amount
        require(totalLendedAmount == _loanParams.loanAmount, "Borrowed amount has to equal total lended amount");

        // 1. PWNGroupOfferFactory checks that signatures are correct
        for (uint256 i = 0; i < _digestWithSignatureList.length; ++i) {

            OfferDigestWithSignature memory digestWithSignature = _digestWithSignatureList[i];

            bytes32 offerHash = keccak256(abi.encodePacked(
                "\x19\x01", _eip712DomainSeparator(), _hash(_loanParams, digestWithSignature)
            ));

            if (digestWithSignature.lender.code.length > 0) {
                require(IERC1271(digestWithSignature.lender).isValidSignature(offerHash, digestWithSignature.signature) == EIP1271_VALID_SIGNATURE, "Signature on behalf of contract is invalid");
            } else {
                require(ECDSA.recover(offerHash, digestWithSignature.signature) == digestWithSignature.lender, "Lender address didn't sign the offer");
            }

            require(digestWithSignature.expiration == 0 || block.timestamp < digestWithSignature.expiration, "Offer is expired");
            require(revokedOffers[offerHash] == false, "Offer is revoked or has been accepted");

            revokedOffers[offerHash] = true;

        }

        PWNDeed.Offer memory offer = PWNDeed.Offer(
            _loanParams.collateralAddress,
            _loanParams.collateralCategory,
            _loanParams.collateralAmount,
            _loanParams.collateralId,
            _loanParams.loanAssetAddress,
            _loanParams.loanAmount,
            _loanParams.loanYield,
            _loanParams.duration,
            uint40(block.timestamp + 1 days),
            address(0),
            keccak256("nonce")
        );

        ++groupOfferId;

        // 2. PWNGroupOfferFactory deploys PWNGroupOffer
        PWNGroupOffer groupOffer = new PWNGroupOffer(
            msg.sender,
            pwn,
            pwnDeed,
            pwnVault,
            offer,
            string(abi.encodePacked("PWN group offer #", groupOfferId)),
            string(abi.encodePacked("PWNGO", groupOfferId))
        );

        IERC20 loanAsset = IERC20(_loanParams.loanAssetAddress);
        address[] memory lenders = new address[](_digestWithSignatureList.length);

        for (uint256 i = 0; i < _digestWithSignatureList.length; ++i) {

            OfferDigestWithSignature memory digestWithSignature = _digestWithSignatureList[i];

            // 3. PWNGroupOfferFactory transfers funds from lenders to PWNGroupOffer
            loanAsset.transferFrom(digestWithSignature.lender, address(groupOffer), digestWithSignature.loanAmountPart);

            // 4. PWNGroupOfferFactory set “share” tokens for lenders in PWNGroupOffer
            groupOffer.setShareToken(digestWithSignature.lender, digestWithSignature.loanAmountPart);

            lenders[i] = digestWithSignature.lender;

        }

        groupOffer.renounceOwnership();

        emit GroupOfferCreated(groupOfferId, address(groupOffer), msg.sender, lenders);

        return address(groupOffer);
    }

    function revokeGroupOffer(
        bytes32 _offerHash,
        bytes calldata _signature
    ) external {
        require(ECDSA.recover(_offerHash, _signature) == msg.sender, "Sender is not an offer signer");
        require(revokedOffers[_offerHash] == false, "Offer is already revoked or has been accepted");

        revokedOffers[_offerHash] = true;

        emit GroupOfferRevoked(_offerHash);
    }


    function _eip712DomainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes("PWNGroupOfferFactory")),
            keccak256(bytes("1")),
            block.chainid,
            address(this)
        ));
    }

    function _hash(
        LoanParams memory _loanParams,
        OfferDigestWithSignature memory _digestWithSignature
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
