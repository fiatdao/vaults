// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {IERC1155} from "openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155Receiver} from "openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {ERC1155PresetMinterPauser} from "openzeppelin/contracts/token/ERC1155/presets/ERC1155PresetMinterPauser.sol";
import {DSTest} from "ds-test/test.sol";

import {Codex} from "fiat/Codex.sol";

import {MockProvider} from "../utils/MockProvider.sol";
import {Vault1155} from "../../Vault.sol";

contract Vault1155Test is DSTest {
    Vault1155 vault;

    MockProvider codex;
    MockProvider collybus;
    ERC1155PresetMinterPauser token;

    uint256 constant MAX_DECIMALS = 38; // ~type(int256).max ~= 1e18*1e18
    uint256 constant MAX_AMOUNT = 10**(MAX_DECIMALS);

    function setUp() public {
        codex = new MockProvider();
        collybus = new MockProvider();
        token = new ERC1155PresetMinterPauser("");
        vault = new Vault1155(address(codex), address(token), address(collybus), "");
    }

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes memory
    ) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    ) external pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    function test_vaultType() public {
        assertEq(vault.vaultType(), bytes32("ERC1155"));
    }

    function test_token() public {
        assertEq(address(vault.token()), address(token));
    }

    function test_tokenScale() public {
        assertEq(vault.tokenScale(), 10**18);
    }

    function test_implements_ERC165Support_For_ERC1155Receiver() public {
        assertTrue(vault.supportsInterface(type(IERC1155Receiver).interfaceId));
    }

    function test_implements_onERC1155Received() public {
        assertEq(
            vault.onERC1155Received(address(0), address(0), 0, 0, new bytes(0)),
            IERC1155Receiver.onERC1155Received.selector
        );
    }

    function test_implements_onERC1155BatchReceived() public {
        assertEq(
            vault.onERC1155BatchReceived(address(0), address(0), new uint256[](0), new uint256[](0), new bytes(0)),
            IERC1155Receiver.onERC1155BatchReceived.selector
        );
    }

    function test_enter_transfersTokens_to_vault(
        uint256 tokenId,
        address owner,
        uint256 amount
    ) public {
        if (amount >= MAX_AMOUNT) return;

        token.setApprovalForAll(address(vault), true);
        token.mint(address(this), tokenId, amount, new bytes(0));

        vault.enter(tokenId, owner, amount);

        assertEq(token.balanceOf(address(this), tokenId), 0);
        assertEq(token.balanceOf(address(vault), tokenId), amount);
    }

    function test_enter_calls_codex_modifyBalance(
        uint256 tokenId,
        address owner,
        uint256 amount
    ) public {
        if (amount >= MAX_AMOUNT) return;

        token.setApprovalForAll(address(vault), true);
        token.mint(address(this), tokenId, amount, new bytes(0));

        vault.enter(tokenId, owner, amount);

        MockProvider.CallData memory cd = codex.getCallData(0);
        assertEq(cd.caller, address(vault));
        assertEq(cd.functionSelector, Codex.modifyBalance.selector);
        assertEq(
            keccak256(cd.data),
            keccak256(abi.encodeWithSelector(Codex.modifyBalance.selector, address(vault), tokenId, owner, amount))
        );
        emit log_bytes(cd.data);
        emit log_bytes(abi.encodeWithSelector(Codex.modifyBalance.selector, address(vault), tokenId, owner, amount));
    }

    function test_exit_transfers_tokens(
        uint256 tokenId,
        address owner,
        uint256 amount
    ) public {
        if (amount >= MAX_AMOUNT) return;
        if (owner == address(0)) return;

        token.setApprovalForAll(address(vault), true);
        token.mint(address(this), tokenId, amount, new bytes(0));

        vault.enter(tokenId, address(this), amount);
        vault.exit(tokenId, owner, amount);

        assertEq(token.balanceOf(owner, tokenId), amount);
        assertEq(token.balanceOf(address(vault), tokenId), 0);
    }

    function test_exit_calls_codex_modifyBalance(
        uint256 tokenId,
        address owner,
        uint256 amount
    ) public {
        if (amount >= MAX_AMOUNT) return;
        if (owner == address(0)) return;

        token.setApprovalForAll(address(vault), true);
        token.mint(address(this), tokenId, amount, new bytes(0));

        vault.enter(tokenId, address(this), amount);
        vault.exit(tokenId, owner, amount);

        MockProvider.CallData memory cd = codex.getCallData(1);
        assertEq(cd.caller, address(vault));
        assertEq(cd.functionSelector, Codex.modifyBalance.selector);
        assertEq(
            keccak256(cd.data),
            keccak256(
                abi.encodeWithSelector(
                    Codex.modifyBalance.selector,
                    address(vault),
                    tokenId,
                    address(this),
                    -int256(amount)
                )
            )
        );
        emit log_bytes(cd.data);
        emit log_bytes(
            abi.encodeWithSelector(
                Codex.modifyBalance.selector,
                address(vault),
                tokenId,
                address(this),
                -int256(amount)
            )
        );
    }

    function testFail_enter_amount_cannot_be_casted(uint256 amount) public {
        if (amount <= uint256(type(int256).max)) assert(false);

        token.setApprovalForAll(address(vault), true);
        token.mint(address(this), 0, amount, new bytes(0));

        vault.enter(0, address(0), amount);
    }

    function testFail_exit_amount_cannot_be_casted(uint256 amount) public {
        if (amount <= MAX_AMOUNT) assert(false);

        token.setApprovalForAll(address(vault), true);
        token.mint(address(this), 0, MAX_AMOUNT, new bytes(0));

        vault.enter(0, address(0), amount);
        vault.exit(0, address(0), amount);
    }
}
