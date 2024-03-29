// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.16;

import "forge-std/StdJson.sol";
import "forge-std/Base.sol";

import "openzeppelin-contracts/contracts/utils/Strings.sol";

import "@pwn/config/PWNConfig.sol";
import "@pwn/deployer/IPWNDeployer.sol";
import "@pwn/hub/PWNHub.sol";
import "@pwn/hub/PWNHubTags.sol";
import "@pwn/loan/terms/simple/loan/PWNSimpleLoan.sol";
import "@pwn/loan/terms/simple/factory/offer/PWNSimpleLoanListOffer.sol";
import "@pwn/loan/terms/simple/factory/offer/PWNSimpleLoanSimpleOffer.sol";
import "@pwn/loan/terms/simple/factory/request/PWNSimpleLoanSimpleRequest.sol";
import "@pwn/loan/token/PWNLOAN.sol";
import "@pwn/nonce/PWNRevokedNonce.sol";


abstract contract Deployments is CommonBase {
    using stdJson for string;
    using Strings for uint256;

    uint256[] deployedChains;
    Deployment deployment;

    // Properties need to be in alphabetical order
    struct Deployment {
        PWNConfig config;
        PWNConfig configSingleton;
        address dao;
        address daoSafe;
        IPWNDeployer deployer;
        address deployerSafe;
        address feeCollector;
        PWNHub hub;
        PWNLOAN loanToken;
        address productTimelock;
        address protocolSafe;
        address protocolTimelock;
        PWNRevokedNonce revokedOfferNonce;
        PWNRevokedNonce revokedRequestNonce;
        PWNSimpleLoan simpleLoan;
        PWNSimpleLoanListOffer simpleLoanListOffer;
        PWNSimpleLoanSimpleOffer simpleLoanSimpleOffer;
        PWNSimpleLoanSimpleRequest simpleLoanSimpleRequest;
    }

    address dao;

    address productTimelock;
    address protocolTimelock;

    address deployerSafe;
    address protocolSafe;
    address daoSafe;
    address feeCollector;

    IPWNDeployer deployer;
    PWNHub hub;
    PWNConfig configSingleton;
    PWNConfig config;
    PWNLOAN loanToken;
    PWNSimpleLoan simpleLoan;
    PWNRevokedNonce revokedOfferNonce;
    PWNRevokedNonce revokedRequestNonce;
    PWNSimpleLoanSimpleOffer simpleLoanSimpleOffer;
    PWNSimpleLoanListOffer simpleLoanListOffer;
    PWNSimpleLoanSimpleRequest simpleLoanSimpleRequest;


    function _loadDeployedAddresses() internal {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/deployments.json");
        string memory json = vm.readFile(path);
        bytes memory rawDeployedChains = json.parseRaw(".deployedChains");
        deployedChains = abi.decode(rawDeployedChains, (uint256[]));

        if (_contains(deployedChains, block.chainid)) {
            bytes memory rawDeployment = json.parseRaw(string.concat(".chains.", block.chainid.toString()));
            deployment = abi.decode(rawDeployment, (Deployment));

            dao = deployment.dao;
            productTimelock = deployment.productTimelock;
            protocolTimelock = deployment.protocolTimelock;
            deployerSafe = deployment.deployerSafe;
            protocolSafe = deployment.protocolSafe;
            daoSafe = deployment.daoSafe;
            feeCollector = deployment.feeCollector;
            deployer = deployment.deployer;
            hub = deployment.hub;
            configSingleton = deployment.configSingleton;
            config = deployment.config;
            loanToken = deployment.loanToken;
            simpleLoan = deployment.simpleLoan;
            revokedOfferNonce = deployment.revokedOfferNonce;
            revokedRequestNonce = deployment.revokedRequestNonce;
            simpleLoanSimpleOffer = deployment.simpleLoanSimpleOffer;
            simpleLoanListOffer = deployment.simpleLoanListOffer;
            simpleLoanSimpleRequest = deployment.simpleLoanSimpleRequest;
        } else {
            _protocolNotDeployedOnSelectedChain();
        }
    }

    function _contains(uint256[] storage array, uint256 value) private view returns (bool) {
        for (uint256 i; i < array.length; ++i)
            if (array[i] == value)
                return true;

        return false;
    }

    function _protocolNotDeployedOnSelectedChain() internal virtual {
        // Override
    }

}
