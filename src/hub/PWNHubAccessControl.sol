// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.16;

import "@pwn/hub/PWNHub.sol";
import "@pwn/hub/PWNHubTags.sol";
import "@pwn/PWNError.sol";


/**
 * @title PWN Hub Access Control
 * @notice Implement modifiers for PWN Hub access control.
 */
abstract contract PWNHubAccessControl {

    /*----------------------------------------------------------*|
    |*  # VARIABLES & CONSTANTS DEFINITIONS                     *|
    |*----------------------------------------------------------*/

    PWNHub immutable internal hub;


    /*----------------------------------------------------------*|
    |*  # MODIFIERS                                             *|
    |*----------------------------------------------------------*/

    modifier onlyActiveLoan() {
        if (hub.hasTag(msg.sender, PWNHubTags.ACTIVE_LOAN) == false)
            revert PWNError.CallerMissingHubTag(PWNHubTags.ACTIVE_LOAN);
        _;
    }

    modifier onlyLoanOffer() {
        if (hub.hasTag(msg.sender, PWNHubTags.LOAN_OFFER) == false)
            revert PWNError.CallerMissingHubTag(PWNHubTags.LOAN_OFFER);
        _;
    }


    /*----------------------------------------------------------*|
    |*  # CONSTRUCTOR                                           *|
    |*----------------------------------------------------------*/

    constructor(address pwnHub) {
        hub = PWNHub(pwnHub);
    }

}
