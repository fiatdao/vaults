// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {DSTest} from "ds-test/test.sol";

import {MockProvider} from "../utils/MockProvider.sol";
import {TestERC20} from "../utils/TestERC20.sol";

import {Codex} from "fiat/Codex.sol";
import {IVault} from "fiat/interfaces/IVault.sol";

import {VaultFactory} from "../../VaultFactory.sol";
import {IFutureVault, IPT, VaultAPW} from "../../VaultAPW.sol";

//import {console} from "../utils/Console.sol";

contract FutureVault {
    TestERC20 fy1;
    TestERC20 fy2;
    TestERC20 ibt;

    constructor(
        address fy1_,
        address fy2_,
        address ibt_
    ) {
        fy1 = TestERC20(fy1_);
        fy2 = TestERC20(fy2_);
        ibt = TestERC20(ibt_);
    }

    function getIBTAddress() public view returns (address) {
        return address(ibt);
    }

    function getCurrentPeriodIndex() public pure returns (uint256) {
        return 2;
    }

    function getFYTofPeriod(uint256 index) external view returns (address) {
        if (index == 1) return address(fy1);
        else return address(fy2);
    }
}

contract PT is TestERC20 {
    FutureVault public futureVault;

    constructor(address futureVault_, uint8 decimals) TestERC20("Principal Token", "PT", decimals) {
        futureVault = FutureVault(futureVault_);
    }
}

contract VaultAPWTest is DSTest {
    VaultFactory vaultFactory;
    VaultAPW impl;
    IVault vault;

    PT pt;
    TestERC20 fy1;
    TestERC20 fy2;
    TestERC20 underlier;
    FutureVault futureVault;

    MockProvider codex;
    MockProvider collybus;

    uint256 constant MAX_DECIMALS = 38; // ~type(int256).max ~= 1e18*1e18
    uint256 constant MAX_AMOUNT = 10**(MAX_DECIMALS);

    function setUp() public {
        vaultFactory = new VaultFactory();
        codex = new MockProvider();
        collybus = new MockProvider();
        //maturity = block.timestamp + 12 weeks;
        fy1 = new TestERC20("Future Yield 1", "FY1", 18);
        fy2 = new TestERC20("Future Yield 2", "FY2", 18);
        underlier = new TestERC20("Interest Bearing Token", "IBT", 18);
        futureVault = new FutureVault(address(fy1), address(fy2), address(underlier));
        pt = new PT(address(futureVault), 18);

        impl = new VaultAPW(address(codex), address(underlier));
        address vaultAddr = vaultFactory.createVault(address(impl), abi.encode(address(pt), address(collybus)));
        vault = IVault(vaultAddr);
    }

    function test_codex() public {
        assertEq(address(vault.codex()), address(codex));
    }

    function test_collybus() public {
        assertEq(address(vault.collybus()), address(collybus));
    }

    function test_token() public {
        assertEq(vault.token(), address(pt));
    }

    function test_tokenScale() public {
        assertEq(vault.tokenScale(), 10**pt.decimals());
    }

    function test_live() public {
        assertEq(uint256(vault.live()), uint256(1));
    }

    function test_underlierToken() public {
        assertEq(vault.underlierToken(), address(underlier));
    }

    function test_underlierScale() public {
        assertEq(vault.underlierScale(), 10**underlier.decimals());
    }

    function test_vaultType() public {
        assertEq(vault.vaultType(), bytes32("ERC20:APW"));
    }

    function test_enter_transfers_to_vault(address owner, uint256 amount) public {
        if (amount >= MAX_AMOUNT) return;

        pt.approve(address(vault), amount);
        pt.mint(address(this), amount);

        fy2.approve(address(vault), amount);
        fy2.mint(address(this), amount);

        vault.enter(0, owner, amount);
        vault.enter(2, owner, amount);

        assertEq(pt.balanceOf(address(this)), 0);
        assertEq(pt.balanceOf(address(vault)), amount);
        assertEq(fy2.balanceOf(address(this)), 0);
        assertEq(fy2.balanceOf(address(vault)), amount);
    }

    function test_enter_calls_codex_modifyBalance(address owner, uint256 amount) public {
        if (amount >= MAX_AMOUNT) return;

        pt.approve(address(vault), amount);
        pt.mint(address(this), amount);

        vault.enter(0, owner, amount);

        MockProvider.CallData memory cd = codex.getCallData(0);
        assertEq(cd.caller, address(vault));
        assertEq(cd.functionSelector, Codex.modifyBalance.selector);
        assertEq(
            keccak256(cd.data),
            keccak256(abi.encodeWithSelector(Codex.modifyBalance.selector, address(vault), 0, owner, amount))
        );
        emit log_bytes(cd.data);
        emit log_bytes(abi.encodeWithSelector(Codex.modifyBalance.selector, address(vault), 0, owner, amount));
    }

    function test_enter_fy_calls_codex_modifyBalance(address owner, uint256 amount) public {
        if (amount >= MAX_AMOUNT) return;

        fy2.approve(address(vault), amount);
        fy2.mint(address(this), amount);

        vault.enter(2, owner, amount);

        MockProvider.CallData memory cd = codex.getCallData(0);
        assertEq(cd.caller, address(vault));
        assertEq(cd.functionSelector, Codex.modifyBalance.selector);
        assertEq(
            keccak256(cd.data),
            keccak256(abi.encodeWithSelector(Codex.modifyBalance.selector, address(vault), 2, owner, amount))
        );
        emit log_bytes(cd.data);
        emit log_bytes(abi.encodeWithSelector(Codex.modifyBalance.selector, address(vault), 2, owner, amount));
    }

    function test_exit_transfers_tokens(address owner, uint256 amount) public {
        if (amount >= MAX_AMOUNT) return;

        pt.approve(address(vault), amount);
        pt.mint(address(this), amount);
        fy2.approve(address(vault), amount);
        fy2.mint(address(this), amount);

        vault.enter(0, address(this), amount);
        vault.exit(0, owner, amount);
        vault.enter(2, address(this), amount);
        vault.exit(2, owner, amount);

        assertEq(pt.balanceOf(owner), amount);
        assertEq(pt.balanceOf(address(vault)), 0);
        assertEq(fy2.balanceOf(owner), amount);
        assertEq(fy2.balanceOf(address(vault)), 0);
    }

    function test_exit_calls_codex_modifyBalance(address owner, uint256 amount) public {
        if (amount >= MAX_AMOUNT) return;

        pt.approve(address(vault), amount);
        pt.mint(address(this), amount);

        vault.enter(0, address(this), amount);
        vault.exit(0, owner, amount);

        MockProvider.CallData memory cd = codex.getCallData(1);
        assertEq(cd.caller, address(vault));
        assertEq(cd.functionSelector, Codex.modifyBalance.selector);
        assertEq(
            keccak256(cd.data),
            keccak256(
                abi.encodeWithSelector(Codex.modifyBalance.selector, address(vault), 0, address(this), -int256(amount))
            )
        );
        emit log_bytes(cd.data);
        emit log_bytes(
            abi.encodeWithSelector(Codex.modifyBalance.selector, address(vault), 0, address(this), -int256(amount))
        );
    }

    function test_exit_fy_calls_codex_modifyBalance(address owner, uint256 amount) public {
        if (amount >= MAX_AMOUNT) return;

        fy2.approve(address(vault), amount);
        fy2.mint(address(this), amount);

        vault.enter(2, address(this), amount);
        vault.exit(2, owner, amount);

        MockProvider.CallData memory cd = codex.getCallData(1);
        assertEq(cd.caller, address(vault));
        assertEq(cd.functionSelector, Codex.modifyBalance.selector);
        assertEq(
            keccak256(cd.data),
            keccak256(
                abi.encodeWithSelector(Codex.modifyBalance.selector, address(vault), 2, address(this), -int256(amount))
            )
        );
        emit log_bytes(cd.data);
        emit log_bytes(
            abi.encodeWithSelector(Codex.modifyBalance.selector, address(vault), 2, address(this), -int256(amount))
        );
    }

    function testFail_enter_outdated_fyt(address owner, uint256 amount) public {
        if (amount >= MAX_AMOUNT) assert(false);

        fy1.approve(address(vault), amount);
        fy1.mint(address(this), amount);

        vault.enter(1, owner, amount);
    }

    function testFail_enter_amount_cannot_be_casted(uint256 amount) public {
        if (amount <= uint256(type(int256).max)) assert(false);

        pt.approve(address(vault), amount);
        pt.mint(address(this), amount);

        vault.enter(0, address(this), amount);
    }

    function testFail_exit_amount_cannot_be_casted(uint256 amount) public {
        if (amount <= MAX_AMOUNT) assert(false);

        pt.approve(address(vault), MAX_AMOUNT);
        pt.mint(address(this), MAX_AMOUNT);

        vault.enter(0, address(this), amount);
        vault.exit(0, address(this), amount);
    }

    function test_enter_scales_amount_to_wad(uint8 decimals) public {
        if (decimals > MAX_DECIMALS) return;

        address owner = address(this);
        uint256 vanillaAmount = 12345678901234567890;
        uint256 amount = vanillaAmount * 10**decimals;
        fy2 = new TestERC20("Future Yield 2", "FY2", decimals);
        underlier = new TestERC20("Interest Bearing Token", "IBT", decimals);
        futureVault = new FutureVault(address(fy1), address(fy2), address(underlier));
        PT pt2 = new PT(address(futureVault), decimals);

        vault = IVault(
            vaultFactory.createVault(
                address(new VaultAPW(address(codex), address(underlier))),
                abi.encode(address(pt2), address(collybus))
            )
        );

        pt2.approve(address(vault), amount);
        pt2.mint(address(this), amount);

        vault.enter(0, owner, amount);

        MockProvider.CallData memory cd = codex.getCallData(0);
        (, , , uint256 sentAmount) = abi.decode(cd.arguments, (address, uint256, address, uint256));

        uint256 scaledAmount = vanillaAmount * 10**18;
        assertEq(scaledAmount, sentAmount);
    }

    function test_exit_scales_wad_to_native(uint8 decimals) public {
        if (decimals > MAX_DECIMALS) return;

        address owner = address(this);
        uint256 vanillaAmount = 12345678901234567890;
        uint256 amount = vanillaAmount * 10**decimals;

        fy2 = new TestERC20("Future Yield 2", "FY2", decimals);
        underlier = new TestERC20("Interest Bearing Token", "IBT", decimals);
        futureVault = new FutureVault(address(fy1), address(fy2), address(underlier));
        PT pt2 = new PT(address(futureVault), decimals);
        vault = IVault(
            vaultFactory.createVault(
                address(new VaultAPW(address(codex), address(underlier))),
                abi.encode(address(pt2), address(collybus))
            )
        );

        pt2.approve(address(vault), amount);
        pt2.mint(address(vault), amount);

        vault.exit(0, owner, amount);

        MockProvider.CallData memory cd = codex.getCallData(0);
        (, , , int256 sentAmount) = abi.decode(cd.arguments, (address, uint256, address, int256));

        // exit decreases the amount in Codex by that much
        int256 scaledAmount = int256(vanillaAmount) * 10**18 * -1;
        assertEq(sentAmount, scaledAmount);
    }
}
