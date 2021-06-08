pragma abicoder v2;
pragma solidity ^0.8.0;

import "./MultiToken.sol";
import "./PWN.sol";
import "./PWNDeed.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";

contract PWNVault is Ownable, IERC1155Receiver{
    using MultiToken for MultiToken.Asset;

    /*----------------------------------------------------------*|
    |*  # VARIABLES & CONSTANTS DEFINITIONS                     *|
    |*----------------------------------------------------------*/

    address public PWN;

    /*----------------------------------------------------------*|
    |*  # MODIFIERS                                             *|
    |*----------------------------------------------------------*/

    modifier onlyPWN() {
        require(msg.sender == PWN);
        _;
    }

    /*----------------------------------------------------------*|
    |*  # EVENTS & ERRORS DEFINITIONS                           *|
    |*----------------------------------------------------------*/

    event VaultPush(MultiToken.Asset asset, address indexed origin);
    event VaultPull(MultiToken.Asset asset, address indexed beneficiary);
    event VaultProxy(MultiToken.Asset asset, address indexed origin, address indexed beneficiary);


    /*----------------------------------------------------------*|
    |*  # CONSTRUCTOR & FUNCTIONS                               *|
    |*----------------------------------------------------------*/

    /*
    *  Constructor
    *  @title PWN Vault
    *  @dev this contract holds balances of all locked collateral & paid back credit prior to their rightful claims
    *  @dev in order for the vault to work it has to have an association with the PWN logic via `.setPWN(PWN.address)`
    */
    constructor()
    Ownable()
    IERC1155Receiver()
    {
    }

    /*
     *  push
     *  @dev function accessing an asset and pushing it INTO the vault
     *  @dev the function assumes a prior token approval was made with the PWNVault.address to be approved
     *  @param _asset - an asset construct - for definition see { MultiToken.sol }
     */
    function push(MultiToken.Asset memory _asset, address _origin) external onlyPWN returns (bool) {
        _asset.transferAssetFrom(_origin, address(this));
        emit VaultPush(_asset, _origin);
        return true;
    }

    /*
     *  pull
     *  @dev function pulling an asset FROM the vault, sending to a defined recipient
     *  @dev this is used for unlocking the collateral on revocations & claims or when claiming a paidback credit
     *  @param _asset - an asset construct - for definition see { MultiToken.sol }
     *  @param _beneficiary and address of the recipient of the asset - is set in the PWN logic contract
     */
    function pull(MultiToken.Asset memory _asset, address _beneficiary) external onlyPWN returns (bool) {
        _asset.transferAsset(_beneficiary);
        emit VaultPull(_asset, _beneficiary);
        return true;
    }

    /*
     *  pullProxy
     *  @dev function pulling an asset FROM a lender, sending to a borrower
     *  @dev this function assumes prior approval for the asset to be spend by the PWNVault.address
     *  @param _asset - an asset construct - for definition see { MultiToken.sol }
     *  @param _origin - an address of the lender who is providing the credit asset
     *  @param _beneficiary and address of the recipient of the asset - is set in the PWN logic contract
     */
    function pullProxy(MultiToken.Asset memory _asset, address _origin, address _beneficiary) external onlyPWN returns (bool){
        _asset.transferAssetFrom(_origin, _beneficiary);
        emit VaultProxy(_asset, _origin, _beneficiary);
        return true;
    }
    
     /**
        @dev Handles the receipt of a single ERC1155 token type. This function is
        called at the end of a `safeTransferFrom` after the balance has been updated.
        To accept the transfer, this must return
        `bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)"))`
        (i.e. 0xf23a6e61, or its own function selector).
        @param operator The address which initiated the transfer (i.e. msg.sender)
        @param from The address which previously owned the token
        @param id The ID of the token being transferred
        @param value The amount of tokens being transferred
        @param data Additional data with no specified format
        @return `bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)"))` if transfer is allowed
    */
    function onERC1155Received(
        address operator,
        address from,
        uint256 id,
        uint256 value,
        bytes calldata data
    )
        override
        external
        returns(bytes4)
    {
        return 0xf23a6e61;
    }
    
    /**
        @dev Handles the receipt of a multiple ERC1155 token types. This function
        is called at the end of a `safeBatchTransferFrom` after the balances have
        been updated. To accept the transfer(s), this must return
        `bytes4(keccak256("onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)"))`
        (i.e. 0xbc197c81, or its own function selector).
        @param operator The address which initiated the batch transfer (i.e. msg.sender)
        @param from The address which previously owned the token
        @param ids An array containing ids of each token being transferred (order and length must match values array)
        @param values An array containing amounts of each token being transferred (order and length must match ids array)
        @param data Additional data with no specified format
        @return `bytes4(keccak256("onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)"))` if transfer is allowed
    */
    function onERC1155BatchReceived(
        address operator,
        address from,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata data
    )
        override
        external
        returns(bytes4)
    {
        return 0xbc197c81;
    }


    function setPWN(address _address) external onlyOwner {
        PWN = _address;
    }

    /**
     * @dev Returns true if this contract implements the interface defined by
     * `interfaceId`. See the corresponding
     * https://eips.ethereum.org/EIPS/eip-165#how-interfaces-are-identified[EIP section]
     * to learn more about how these ids are created.
     *
     * This function call must use less than 30 000 gas.
     */
    function supportsInterface(bytes4 interfaceId) external view override returns (bool) {
        return
            interfaceId == this.supportsInterface.selector || // ERC165
            interfaceId == this.owner.selector
                            ^ this.renounceOwnership.selector
                            ^ this.transferOwnership.selector || // Ownable
            interfaceId == this.PWN.selector
                            ^ this.push.selector
                            ^ this.pull.selector
                            ^ this.pullProxy.selector
                            ^ this.setPWN.selector || // PWN Vault
            interfaceId == this.onERC1155Received.selector
                            ^ this.onERC1155BatchReceived.selector; // ERC1155Receiver
    }
}
