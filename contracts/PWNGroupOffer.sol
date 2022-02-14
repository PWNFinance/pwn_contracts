// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import "./PWN.sol";
import "./PWNDeed.sol";

contract PWNGroupOffer is Ownable, ERC20, IERC1155Receiver {

    /*----------------------------------------------------------*|
    |*  # VARIABLES & CONSTANTS DEFINITIONS                     *|
    |*----------------------------------------------------------*/

    address public pwn;
    address public pwnDeed;
    uint8 public state; // 0 == open, 1 == claimed repaid loan, 2 == claimed defaulted collateral

    PWNDeed.LoanParams public loanParams;

    /*----------------------------------------------------------*|
    |*  # EVENTS & ERRORS DEFINITIONS                           *|
    |*----------------------------------------------------------*/

    event DeedClaimed(uint256 indexed did);
    event LenderClaimed(address indexed lender, uint256 amount);

    /*----------------------------------------------------------*|
    |*  # CONSTRUCTOR & FUNCTIONS                               *|
    |*----------------------------------------------------------*/

    constructor(
        address _pwn,
        address _pwnDeed,
        PWNDeed.LoanParams memory _loanParams,
        string memory _name,
        string memory _symbol
    ) Ownable() ERC20(_name, _symbol) {
        pwn = _pwn;
        pwnDeed = _pwnDeed;
        loanParams = _loanParams;
    }


    function claim(uint256 _did) external {
        // Claim repaid loan or defaulted collateral
        uint8 deedStatus = PWNDeed(pwnDeed).getStatus(_did);
        if (deedStatus == 3) {
            state = 1;
        } else if (deedStatus == 4) {
            state = 2;
        }

        PWN(pwn).claimDeed(_did);

        emit DeedClaimed(_did);

        claimPart();
    }

    function claimPart() public {
        // Claim lenders share in repaid loan
        require(state == 1, "Deed has not been claimed yet or is defaulted"); // TODO: Err message

        // shareToClaim = shares * repaidAmount / sharesTotalSupply
        uint256 shareToClaim = balanceOf(msg.sender) * IERC20(loanParams.loanAssetAddress).balanceOf(address(this)) / totalSupply();

        IERC20(loanParams.loanAssetAddress).transfer(msg.sender, shareToClaim);

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

    function setShareToken(address _owner, uint256 _shares) external onlyOwner {
        _mint(_owner, _shares);
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
            interfaceId == type(IERC20).interfaceId; // ERC1155Receiver
            // TODO: PWNGroupOffer iface
    }

}
