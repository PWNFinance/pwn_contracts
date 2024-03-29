// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.16;

import "forge-std/Script.sol";

import "openzeppelin-contracts/contracts/governance/TimelockController.sol";

import { GnosisSafeLike, GnosisSafeUtils } from "./lib/GnosisSafeUtils.sol";

import "@pwn/deployer/IPWNDeployer.sol";
import "@pwn/Deployments.sol";


library PWNDeployerSalt {

    string internal constant VERSION = "1.2";

    // Old salts
    // bytes32 internal constant PROTOCOL_TEAM_TIMELOCK_CONTROLLER = keccak256("PWNProtocolTeamTimelockController");
    // bytes32 internal constant PRODUCT_TEAM_TIMELOCK_CONTROLLER = keccak256("PWNProductTeamTimelockController");

    // 0x608ebbaa27bfbe8dd5ce387b0590cab114c16a47f29d4df2aff471dff0da44cc
    bytes32 internal constant PROTOCOL_TIMELOCK = keccak256("PWNProtocolTimelock");
    // 0xd7150558706b0331a55357de4d842961470f283908b8ca35618c3cdbb470da18
    bytes32 internal constant PRODUCT_TIMELOCK = keccak256("PWNProductTimelock");

}


contract Deploy is Deployments, Script {
    using GnosisSafeUtils for GnosisSafeLike;

    function _protocolNotDeployedOnSelectedChain() internal pure override {
        revert("PWNTimelock: selected chain is not set in deployments.json");
    }

    function _deploy(
        bytes32 salt,
        bytes memory bytecode
    ) internal returns (address) {
        bool success = GnosisSafeLike(deployerSafe).execTransaction({
            to: address(deployer),
            data: abi.encodeWithSelector(
                IPWNDeployer.deploy.selector, salt, bytecode
            )
        });
        require(success, "Deploy failed");
        return deployer.computeAddress(salt, keccak256(bytecode));
    }

/*
forge script script/PWNTimelock.s.sol:Deploy \
--sig "deployProtocolTimelock()" \
--rpc-url $RPC_URL \
--private-key $PRIVATE_KEY \
--with-gas-price $(cast --to-wei 15 gwei) \
--verify --etherscan-api-key $ETHERSCAN_API_KEY \
--broadcast
*/
    function deployProtocolTimelock() external {
        console2.log("Deploying protocol timelock");
        _deployTimelock(PWNDeployerSalt.PROTOCOL_TIMELOCK);
    }

/*
forge script script/PWNTimelock.s.sol:Deploy \
--sig "deployProductTimelock()" \
--rpc-url $RPC_URL \
--private-key $PRIVATE_KEY \
--with-gas-price $(cast --to-wei 15 gwei) \
--verify --etherscan-api-key $ETHERSCAN_API_KEY \
--broadcast
*/
    function deployProductTimelock() external {
        console2.log("Deploying product timelock");
        _deployTimelock(PWNDeployerSalt.PRODUCT_TIMELOCK);
    }

    /// @dev Expecting to have deployer & deployerSafe addresses set in the `deployments.json`
    /// Will deploy new timelock with one proposer role for `0x0cfC...D6de` and open executor role
    function _deployTimelock(bytes32 salt) private {
        _loadDeployedAddresses();

        vm.startBroadcast();

        address[] memory proposers = new address[](1);
        proposers[0] = 0x0cfC62C2E82dA2f580Fd54a2f526F65B6cC8D6de;
        address[] memory executors = new address[](1);
        executors[0] = address(0);

        address timelock = _deploy({
            salt: salt,
            bytecode: abi.encodePacked(
                type(TimelockController).creationCode,
                abi.encode(uint256(0), proposers, executors, address(0))
            )
        });
        console2.log("Timelock deployed:", timelock);
        console2.log("Used salt:");
        console2.logBytes32(salt);

        vm.stopBroadcast();
    }

}


contract Setup is Deployments, Script {
    using GnosisSafeUtils for GnosisSafeLike;

    function _protocolNotDeployedOnSelectedChain() internal pure override {
        revert("PWN: selected chain is not set in deployments.json");
    }

/*
forge script script/PWNTimelock.s.sol:Setup \
--sig "updateProtocolTimelockProposer()" \
--rpc-url $RPC_URL \
--private-key $PRIVATE_KEY \
--with-gas-price $(cast --to-wei 15 gwei) \
--broadcast
*/
    function updateProtocolTimelockProposer() external {
        _loadDeployedAddresses();
        console2.log("Updating protocol timelock proposer (%s)", protocolTimelock);
        _updateProposer(TimelockController(payable(protocolTimelock)), protocolSafe);
    }

/*
forge script script/PWNTimelock.s.sol:Setup \
--sig "updateProductTimelockProposer()" \
--rpc-url $RPC_URL \
--private-key $PRIVATE_KEY \
--with-gas-price $(cast --to-wei 15 gwei) \
--broadcast
*/
    function updateProductTimelockProposer() external {
        _loadDeployedAddresses();
        console2.log("Updating product timelock proposer (%s)", productTimelock);
        _updateProposer(TimelockController(payable(productTimelock)), daoSafe);
    }

    /// @dev Will grant PROPOSER_ROLE & CANCELLOR_ROLE to the new address and revoke them from `0x0cfC...D6de`.
    /// Expecting to have address loaded from the `deployments.json` file.
    /// Expecting timelock to be freshly deployed with one proposer `0x0cfC...D6de` and min delay set to 0.
    function _updateProposer(TimelockController timelock, address newProposer) private {
        vm.startBroadcast();

        address initialProposer = 0x0cfC62C2E82dA2f580Fd54a2f526F65B6cC8D6de;

        bytes[] memory payloads = new bytes[](4);
        payloads[0] = abi.encodeWithSignature("grantRole(bytes32,address)", timelock.PROPOSER_ROLE(), newProposer);
        payloads[1] = abi.encodeWithSignature("grantRole(bytes32,address)", timelock.CANCELLER_ROLE(), newProposer);
        payloads[2] = abi.encodeWithSignature("revokeRole(bytes32,address)", timelock.PROPOSER_ROLE(), initialProposer);
        payloads[3] = abi.encodeWithSignature("revokeRole(bytes32,address)", timelock.CANCELLER_ROLE(), initialProposer);

        _scheduleAndExecuteBatch(timelock, payloads);

        console2.log("Proposer role granted to:", newProposer);
        console2.log("Cancellor role granted to:", newProposer);
        console2.log("Proposer role revoked from:", initialProposer);
        console2.log("Proposer role revoked from:", initialProposer);

        vm.stopBroadcast();
    }

    function _scheduleAndExecute(TimelockController timelock, bytes memory payload) private {
        timelock.schedule({ target: address(timelock), value: 0, data: payload, predecessor: 0, salt: 0, delay: 0 });
        timelock.execute({ target: address(timelock), value: 0, payload: payload, predecessor: 0, salt: 0 });
    }

    function _scheduleAndExecuteBatch(TimelockController timelock, bytes[] memory payloads) private {
        address[] memory targets = new address[](payloads.length);
        for (uint256 i; i < payloads.length; ++i) {
            targets[i] = address(timelock);
        }
        uint256[] memory values = new uint256[](payloads.length);
        for (uint256 i; i < payloads.length; ++i) {
            values[i] = 0;
        }

        timelock.scheduleBatch({
            targets: targets,
            values: values,
            payloads: payloads,
            predecessor: 0,
            salt: 0,
            delay: 0
         });
         timelock.executeBatch({
            targets: targets,
            values: values,
            payloads: payloads,
            predecessor: 0,
            salt: 0
         });
    }


/*
forge script script/PWNTimelock.s.sol:Setup \
--sig "setupProtocolTimelock()" \
--rpc-url $RPC_URL \
--private-key $PRIVATE_KEY \
--with-gas-price $(cast --to-wei 15 gwei) \
--broadcast
*/
    /// @dev Expecting to have protocol, protocolSafe & protocolTimelock addresses set in the `deployments.json`
    function setupProtocolTimelock() external {
        _loadDeployedAddresses();

        uint256 protocolTimelockMinDelay = 345_600; // 4 days

        vm.startBroadcast();

        // set PWNConfig admin
        bool success;
        success = GnosisSafeLike(protocolSafe).execTransaction({
            to: address(config),
            data: abi.encodeWithSignature("changeAdmin(address)", protocolTimelock)
        });
        require(success, "PWN: change admin failed");

        // transfer PWNHub owner
        success = GnosisSafeLike(protocolSafe).execTransaction({
            to: address(hub),
            data: abi.encodeWithSignature("transferOwnership(address)", protocolTimelock)
        });
        require(success, "PWN: change owner failed");

        // accept PWNHub owner
        success = GnosisSafeLike(protocolSafe).execTransaction({
            to: address(protocolTimelock),
            data: abi.encodeWithSignature(
                "schedule(address,uint256,bytes,bytes32,bytes32,uint256)",
                address(hub), 0, abi.encodeWithSignature("acceptOwnership()"), 0, 0, 0
            )
        });
        require(success, "PWN: schedule accept ownership failed");

        TimelockController(payable(protocolTimelock)).execute({
            target: address(hub),
            value: 0,
            payload: abi.encodeWithSignature("acceptOwnership()"),
            predecessor: 0,
            salt: 0
        });

        // set min delay
        success = GnosisSafeLike(protocolSafe).execTransaction({
            to: address(protocolTimelock),
            data: abi.encodeWithSignature(
                "schedule(address,uint256,bytes,bytes32,bytes32,uint256)",
                address(protocolTimelock), 0, abi.encodeWithSignature("updateDelay(uint256)", protocolTimelockMinDelay), 0, 0, 0
            )
        });
        require(success, "PWN: schedule update delay failed");

        TimelockController(payable(protocolTimelock)).execute({
            target: protocolTimelock,
            value: 0,
            payload: abi.encodeWithSignature("updateDelay(uint256)", protocolTimelockMinDelay),
            predecessor: 0,
            salt: 0
        });

        console2.log("Protocol timelock set");

        vm.stopBroadcast();
    }

/*
forge script script/PWNTimelock.s.sol:Setup \
--sig "setProductTimelock()" \
--rpc-url $RPC_URL \
--private-key $PRIVATE_KEY \
--with-gas-price $(cast --to-wei 15 gwei) \
--broadcast
*/
    /// @dev Expecting to have protocol, daoSafe & productTimelock addresses set in the `deployments.json`
    /// Expecting `0x0cfC...D6de` to be a proposer for the timelock
    function setProductTimelock() external {
        _loadDeployedAddresses();

        uint256 productTimelockMinDelay = 345_600; // 4 days

        vm.startBroadcast();

        // transfer PWNConfig owner
        bool success;
        success = GnosisSafeLike(daoSafe).execTransaction({
            to: address(config),
            data: abi.encodeWithSignature("transferOwnership(address)", productTimelock)
        });
        require(success, "PWN: change owner failed");

        // accept PWNConfig owner
        success = GnosisSafeLike(daoSafe).execTransaction({
            to: address(productTimelock),
            data: abi.encodeWithSignature(
                "schedule(address,uint256,bytes,bytes32,bytes32,uint256)",
                address(config), 0, abi.encodeWithSignature("acceptOwnership()"), 0, 0, 0
            )
        });
        require(success, "PWN: schedule failed");

        TimelockController(payable(productTimelock)).execute({
            target: address(config),
            value: 0,
            payload: abi.encodeWithSignature("acceptOwnership()"),
            predecessor: 0,
            salt: 0
        });

        // set min delay
        success = GnosisSafeLike(daoSafe).execTransaction({
            to: address(productTimelock),
            data: abi.encodeWithSignature(
                "schedule(address,uint256,bytes,bytes32,bytes32,uint256)",
                address(productTimelock), 0, abi.encodeWithSignature("updateDelay(uint256)", productTimelockMinDelay), 0, 0, 0
            )
        });
        require(success, "PWN: update delay failed");

        TimelockController(payable(productTimelock)).execute({
            target: productTimelock,
            value: 0,
            payload: abi.encodeWithSignature("updateDelay(uint256)", productTimelockMinDelay),
            predecessor: 0,
            salt: 0
        });

        console2.log("Product timelock set");

        vm.stopBroadcast();
    }

}
