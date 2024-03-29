// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.16;

import "forge-std/Test.sol";

import "MultiToken/MultiToken.sol";

import "openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";
import "openzeppelin-contracts/contracts/token/ERC721/IERC721Receiver.sol";
import "openzeppelin-contracts/contracts/token/ERC1155/IERC1155Receiver.sol";

import "@pwn/loan/PWNVault.sol";
import "@pwn/PWNErrors.sol";

import "@pwn-test/helper/token/T721.sol";


// The only reason for this contract is to expose internal functions of PWNVault
// No additional logic is applied here
contract PWNVaultExposed is PWNVault {

    function pull(MultiToken.Asset memory asset, address origin) external {
        _pull(asset, origin);
    }

    function push(MultiToken.Asset memory asset, address beneficiary) external {
        _push(asset, beneficiary);
    }

    function pushFrom(MultiToken.Asset memory asset, address origin, address beneficiary) external {
        _pushFrom(asset, origin, beneficiary);
    }

    function permit(MultiToken.Asset memory asset, address origin, bytes memory permit_) external {
        _permit(asset, origin, permit_);
    }

}

abstract contract PWNVaultTest is Test {

    PWNVaultExposed vault;
    address token = makeAddr("token");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    T721 t721;

    event VaultPull(MultiToken.Asset asset, address indexed origin);
    event VaultPush(MultiToken.Asset asset, address indexed beneficiary);
    event VaultPushFrom(MultiToken.Asset asset, address indexed origin, address indexed beneficiary);


    constructor() {
        vm.etch(token, bytes("data"));
    }

    function setUp() external {
        vault = new PWNVaultExposed();
        t721 = new T721();
    }

}


/*----------------------------------------------------------*|
|*  # PULL                                                  *|
|*----------------------------------------------------------*/

contract PWNVault_Pull_Test is PWNVaultTest {

    function test_shouldCallTransferFrom_fromOrigin_toVault() external {
        t721.mint(alice, 42);
        vm.prank(alice);
        t721.approve(address(vault), 42);

        vm.expectCall(
            address(t721),
            abi.encodeWithSignature("transferFrom(address,address,uint256)", alice, address(vault), 42)
        );

        MultiToken.Asset memory asset = MultiToken.Asset(MultiToken.Category.ERC721, address(t721), 42, 0);
        vault.pull(asset, alice);
    }

    function test_shouldFail_whenIncompleteTransaction() external {
        vm.mockCall(
            token,
            abi.encodeWithSignature("ownerOf(uint256)"),
            abi.encode(alice)
        );

        vm.expectRevert(abi.encodeWithSelector(IncompleteTransfer.selector));
        MultiToken.Asset memory asset = MultiToken.Asset(MultiToken.Category.ERC721, token, 42, 0);
        vault.pull(asset, alice);
    }

    function test_shouldEmitEvent_VaultPull() external {
        t721.mint(alice, 42);
        vm.prank(alice);
        t721.approve(address(vault), 42);

        MultiToken.Asset memory asset = MultiToken.Asset(MultiToken.Category.ERC721, address(t721), 42, 0);

        vm.expectEmit(true, true, true, true);
        emit VaultPull(asset, alice);

        vault.pull(asset, alice);
    }

}


/*----------------------------------------------------------*|
|*  # PUSH                                                  *|
|*----------------------------------------------------------*/

contract PWNVault_Push_Test is PWNVaultTest {

    function test_shouldCallSafeTransferFrom_fromVault_toBeneficiary() external {
        t721.mint(address(vault), 42);

        vm.expectCall(
            address(t721),
            abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)", address(vault), alice, 42, "")
        );

        MultiToken.Asset memory asset = MultiToken.Asset(MultiToken.Category.ERC721, address(t721), 42, 1);
        vault.push(asset, alice);
    }

    function test_shouldFail_whenIncompleteTransaction() external {
        vm.mockCall(
            token,
            abi.encodeWithSignature("ownerOf(uint256)"),
            abi.encode(address(vault))
        );

        vm.expectRevert(abi.encodeWithSelector(IncompleteTransfer.selector));
        MultiToken.Asset memory asset = MultiToken.Asset(MultiToken.Category.ERC721, token, 42, 0);
        vault.push(asset, alice);
    }

    function test_shouldEmitEvent_VaultPush() external {
        t721.mint(address(vault), 42);

        MultiToken.Asset memory asset = MultiToken.Asset(MultiToken.Category.ERC721, address(t721), 42, 1);

        vm.expectEmit(true, true, true, true);
        emit VaultPush(asset, alice);

        vault.push(asset, alice);
    }

}


/*----------------------------------------------------------*|
|*  # PUSH FROM                                             *|
|*----------------------------------------------------------*/

contract PWNVault_PushFrom_Test is PWNVaultTest {

    function test_shouldCallSafeTransferFrom_fromOrigin_toBeneficiary() external {
        t721.mint(alice, 42);
        vm.prank(alice);
        t721.approve(address(vault), 42);

        vm.expectCall(
            address(t721),
            abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)", alice, bob, 42, "")
        );

        MultiToken.Asset memory asset = MultiToken.Asset(MultiToken.Category.ERC721, address(t721), 42, 1);
        vault.pushFrom(asset, alice, bob);
    }

    function test_shouldFail_whenIncompleteTransaction() external {
        vm.mockCall(
            token,
            abi.encodeWithSignature("ownerOf(uint256)"),
            abi.encode(alice)
        );

        vm.expectRevert(abi.encodeWithSelector(IncompleteTransfer.selector));
        MultiToken.Asset memory asset = MultiToken.Asset(MultiToken.Category.ERC721, token, 42, 0);
        vault.pushFrom(asset, alice, bob);
    }

    function test_shouldEmitEvent_VaultPushFrom() external {
        t721.mint(alice, 42);
        vm.prank(alice);
        t721.approve(address(vault), 42);

        MultiToken.Asset memory asset = MultiToken.Asset(MultiToken.Category.ERC721, address(t721), 42, 1);

        vm.expectEmit(true, true, true, false);
        emit VaultPushFrom(asset, alice, bob);

        vault.pushFrom(asset, alice, bob);
    }

}


/*----------------------------------------------------------*|
|*  # PERMIT                                                *|
|*----------------------------------------------------------*/

contract PWNVault_Permit_Test is PWNVaultTest {

    function test_shouldCallPermit_whenPermitNonZero() external {
        vm.expectCall(
            token,
            abi.encodeWithSignature(
                "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)",
                alice, address(vault), 100, 1, uint8(4), bytes32(uint256(2)), bytes32(uint256(3)))
        );

        MultiToken.Asset memory asset = MultiToken.Asset(MultiToken.Category.ERC20, token, 0, 100);
        bytes memory permit = abi.encodePacked(uint256(1), bytes32(uint256(2)), bytes32(uint256(3)), uint8(4));
        vault.permit(asset, alice, permit);
    }

    function testFail_shouldNotCallPermit_whenPermitIsZero() external {
        // Should fail, because permit is not called
        vm.expectCall(
            token,
            abi.encodeWithSignature("permit(address,address,uint256,uint256,uint8,bytes32,bytes32)")
        );

        MultiToken.Asset memory asset = MultiToken.Asset(MultiToken.Category.ERC20, token, 0, 100);
        vault.permit(asset, alice, "");
    }

}


/*----------------------------------------------------------*|
|*  # ERC721/1155 RECEIVED HOOKS                            *|
|*----------------------------------------------------------*/

contract PWNVault_ReceivedHooks_Test is PWNVaultTest {

    function test_shouldReturnCorrectValue_whenOperatorIsVault_onERC721Received() external {
        bytes4 returnValue = vault.onERC721Received(address(vault), address(0), 0, "");

        assertTrue(returnValue == IERC721Receiver.onERC721Received.selector);
    }

    function test_shouldFail_whenOperatorIsNotVault_onERC721Received() external {
        vm.expectRevert(abi.encodeWithSelector(UnsupportedTransferFunction.selector));
        vault.onERC721Received(address(0), address(0), 0, "");
    }

    function test_shouldReturnCorrectValue_whenOperatorIsVault_onERC1155Received() external {
        bytes4 returnValue = vault.onERC1155Received(address(vault), address(0), 0, 0, "");

        assertTrue(returnValue == IERC1155Receiver.onERC1155Received.selector);
    }

    function test_shouldFail_whenOperatorIsNotVault_onERC1155Received() external {
        vm.expectRevert(abi.encodeWithSelector(UnsupportedTransferFunction.selector));
        vault.onERC1155Received(address(0), address(0), 0, 0, "");
    }

    function test_shouldFail_whenOnERC1155BatchReceived() external {
        uint256[] memory ids;
        uint256[] memory values;

        vm.expectRevert(abi.encodeWithSelector(UnsupportedTransferFunction.selector));
        vault.onERC1155BatchReceived(address(0), address(0), ids, values, "");
    }

}


/*----------------------------------------------------------*|
|*  # SUPPORTS INTERFACE                                    *|
|*----------------------------------------------------------*/

contract PWNVault_SupportsInterface_Test is PWNVaultTest {

    function test_shouldReturnTrue_whenIERC165() external {
        assertTrue(vault.supportsInterface(type(IERC165).interfaceId));
    }

    function test_shouldReturnTrue_whenIERC721Receiver() external {
        assertTrue(vault.supportsInterface(type(IERC721Receiver).interfaceId));
    }

    function test_shouldReturnTrue_whenIERC1155Receiver() external {
        assertTrue(vault.supportsInterface(type(IERC1155Receiver).interfaceId));
    }

}
