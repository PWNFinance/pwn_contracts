// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC1271.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import "./PWNDeed.sol";
import "./PWN.sol";

contract PWNGroupOffer is Ownable, ERC20, IERC1271, IERC1155Receiver {

    /*----------------------------------------------------------*|
    |*  # VARIABLES & CONSTANTS DEFINITIONS                     *|
    |*----------------------------------------------------------*/

    bytes4 constant internal EIP1271_VALID_SIGNATURE = 0x1626ba7e;

    bytes32 constant internal OFFER_TYPEHASH = keccak256(
        "Offer(address collateralAddress,uint8 collateralCategory,uint256 collateralAmount,uint256 collateralId,address loanAssetAddress,uint256 loanAmount,uint256 loanYield,uint32 duration,uint40 expiration,address lender,bytes32 nonce)"
    );

    address public borrower;
    address public pwn;
    address public pwnDeed;
    address public pwnVault;
    uint8 public state; // 0 == open, 1 == claimed repaid loan, 2 == claimed defaulted collateral

    PWNDeed.Offer public offer;

    /*----------------------------------------------------------*|
    |*  # EVENTS & ERRORS DEFINITIONS                           *|
    |*----------------------------------------------------------*/

    event DeedClaimed(uint256 indexed did);
    event LenderClaimed(address indexed lender, uint256 amount);

    /*----------------------------------------------------------*|
    |*  # CONSTRUCTOR & FUNCTIONS                               *|
    |*----------------------------------------------------------*/

    constructor(
        address _borrower,
        address _pwn,
        address _pwnDeed,
        address _pwnVault,
        PWNDeed.Offer memory _offer,
        string memory _name,
        string memory _symbol
    ) Ownable() ERC20(_name, _symbol) {
        borrower = _borrower;
        pwn = _pwn;
        pwnDeed = _pwnDeed;
        pwnVault = _pwnVault;
        offer = _offer;
    }


    function claim(uint256 _did) external {
        // Claim repaid loan or defaulted collateral
        uint8 deedStatus = PWNDeed(pwnDeed).getStatus(_did);
        if (deedStatus == 3) {
            state = 1;
        } else if (deedStatus == 4) {
            state = 2;
        }

        PWN(pwnDeed).claimDeed(_did);

        emit DeedClaimed(_did);

        claimPart();
    }

    function claimPart() public {
        // Claim lenders share in repaid loan
        require(state == 1, "Deed has not been claimed yet or is defaulted"); // TODO: Err message

        // shareToClaim = shares * repaidAmount / sharesTotalSupply
        uint256 shareToClaim = balanceOf(msg.sender) * IERC20(offer.loanAssetAddress).balanceOf(address(this)) / totalSupply();

        IERC20(offer.loanAssetAddress).transfer(msg.sender, shareToClaim);

        _burn(msg.sender, balanceOf(msg.sender));

        emit LenderClaimed(msg.sender, shareToClaim);
    }

    function startAuction() external {
        // Public action with starting price set to loan + interest
    }

    function redeem() external {
        // Redeem defaulted collateral by paying all lenders their shares
        // Need to have pre-approved loan asset
    }

    function approveLoanAsset() external {
        IERC20(offer.loanAssetAddress).approve(pwnVault, offer.loanAmount);
    }

    function setShareToken(address _owner, uint256 _shares) external onlyOwner {
        _mint(_owner, _shares);
    }

    function isValidSignature(bytes32 hash, bytes memory signature) override external view returns (bytes4 magicValue) {

        // Check that signer is borrower
        require(ECDSA.recover(hash, signature) == borrower, "Borrower address didn't sign the offer");

        // Check that given hash is really the group offer digest
        bytes32 offerHash = keccak256(abi.encodePacked(
            "\x19\x01", _eip712DomainSeparator(), _hash(offer)
        ));

        require(offerHash == hash, "Group offer digest is not matching given hash");

        return EIP1271_VALID_SIGNATURE;
    }

    function onERC1155Received(
        address /*operator*/,
        address /*from*/,
        uint256 /*id*/,
        uint256 /*value*/,
        bytes calldata /*data*/
    )
        override
        external
        pure
        returns(bytes4)
    {
        return 0xf23a6e61;
    }

    function onERC1155BatchReceived(
        address /*operator*/,
        address /*from*/,
        uint256[] calldata /*ids*/,
        uint256[] calldata /*values*/,
        bytes calldata /*data*/
    )
        override
        external
        pure
        returns(bytes4)
    {
        return 0xbc197c81;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return
            interfaceId == type(IERC165).interfaceId || // ERC165
            interfaceId == type(Ownable).interfaceId || // Ownable
            interfaceId == type(IERC1155Receiver).interfaceId || // ERC1155Receiver
            interfaceId == type(IERC1271).interfaceId || // ERC1155Receiver
            interfaceId == type(IERC20).interfaceId; // ERC1155Receiver
            // TODO: PWNGroupOffer iface
    }


    function _eip712DomainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes("PWN")),
            keccak256(bytes("1")),
            block.chainid,
            pwnDeed
        ));
    }

    function _hash(PWNDeed.Offer memory _offer) private view returns (bytes32) {
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
            address(this),
            _offer.nonce
        ));
    }

}
