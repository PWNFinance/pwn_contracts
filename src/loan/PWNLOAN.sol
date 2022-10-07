// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.16;

import "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";

import "../hub/PWNHubAccessControl.sol";


/**
 * @title PWN LOAN
 * @notice A LOAN token representing a loan in PWN protocol.
 * @dev Token doesn't hold any loan logic, just an address of a loan contract that minted the LOAN token.
 *      PWN LOAN token is shared between all loan contracts.
 */
contract PWNLOAN is PWNHubAccessControl, ERC721 {

    /*----------------------------------------------------------*|
    |*  # VARIABLES & CONSTANTS DEFINITIONS                     *|
    |*----------------------------------------------------------*/

    /**
     * @dev Last used LOAN id. First LOAN id is 1. This value is incremental.
     */
    uint256 public lastLoanId;

    /**
     * @dev Mapping of a LOAN id to a loan contract that minted the LOAN token.
     */
    mapping (uint256 => address) public loanContract;


    /*----------------------------------------------------------*|
    |*  # EVENTS & ERRORS DEFINITIONS                           *|
    |*----------------------------------------------------------*/

    /**
     * @dev Emitted when a new LOAN token is minted.
     */
    event LOANMinted(uint256 indexed loanId, address indexed owner);

    /**
     * @dev Emitted when a LOAN token is burned.
     */
    event LOANBurned(uint256 indexed loanId);


    /*----------------------------------------------------------*|
    |*  # CONSTRUCTOR                                           *|
    |*----------------------------------------------------------*/

    constructor(address hub) PWNHubAccessControl(hub) ERC721("PWN LOAN", "LOAN") {

    }


    /*----------------------------------------------------------*|
    |*  # TOKEN LIFECYCLE                                       *|
    |*----------------------------------------------------------*/

    /**
     * @notice Mint a new LOAN token.
     * @dev Only an addresse with associated `ACTIVE_LOAN` tag in PWN Hub can call this function.
     * @param owner Address of a LOAN token receiver.
     * @return loanId Id of a newly minted LOAN token.
     */
    function mint(address owner) external onlyActiveLoan returns (uint256 loanId) {
        loanId = ++lastLoanId;
        loanContract[loanId] = msg.sender;
        _mint(owner, loanId);
        emit LOANMinted(loanId, owner);
    }

    /**
     * @notice Burn a LOAN token.
     * @dev Only an addresse with associated `LOAN` tag in PWN Hub can call this function.
     * @param loanId Id of a LOAN token to be burned.
     */
    function burn(uint256 loanId) external onlyLoan {
        require(loanContract[loanId] == msg.sender, "Loan contract did not mint given loan id");
        delete loanContract[loanId];
        _burn(loanId);
        emit LOANBurned(loanId);
    }

}