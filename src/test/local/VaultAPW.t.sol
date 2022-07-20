// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {DSTest} from "ds-test/test.sol";

import {MockProvider} from "../utils/MockProvider.sol";
import {TestERC20} from "../utils/TestERC20.sol";

import {Codex} from "fiat/Codex.sol";
import {IVault} from "fiat/interfaces/IVault.sol";

import {VaultFactory} from "../../VaultFactory.sol";
import {IFutureVault, IPT, VaultAPW} from "../../VaultAPW.sol";

import {console} from "../utils/Console.sol";

contract FutureVault {
    TestERC20 fy1;
    TestERC20 fy2;
    TestERC20 ibt;
    PT pt;
    uint256 periodIndex;

    constructor(
        address fy1_,
        address fy2_,
        address ibt_
    ) {
        fy1 = TestERC20(fy1_);
        fy2 = TestERC20(fy2_);
        ibt = TestERC20(ibt_);
    }

    function setPT(PT pt_) public {
        pt = pt_;
    }

    function getIBTAddress() public view returns (address) {
        return address(ibt);
    }

    function setCurrentPeriodIndex(uint256 index) public {
        periodIndex = index;
    }

    function getCurrentPeriodIndex() public view returns (uint256) {
        return periodIndex;
    }

    function getFYTofPeriod(uint256 index) external view returns (address) {
        if (index == 1) return address(fy1);
        else return address(fy2);
    }

    function updateUserState(address _user) external {
        pt.claimYield(_user);
    }
}

contract PT is TestERC20 {
    FutureVault public futureVault;
    uint256 interestAmount;
    bool mintTo;
    bool mintFrom;

    constructor(address futureVault_, uint8 decimals) TestERC20("Principal Token", "PT", decimals) {
        futureVault = FutureVault(futureVault_);
    }

    function setInterestAmount(uint256 amount) public {
        interestAmount = amount;
    }

    function setMintTo(bool value) public {
        mintTo = value;
    }

    function setMintFrom(bool value) public {
        mintFrom = value;
    }

    function claimYield(address user) external {
        mint(user, interestAmount);
    }

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) public override returns (bool) {
        if (mintFrom) mint(from, interestAmount);
        if (mintTo) mint(to, interestAmount);

        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= value;
        }
        balanceOf[from] -= value;
        unchecked {
            balanceOf[to] += value;
        }
        emit Transfer(from, to, value);
        return true;
    }
}

contract VaultAPWTest is DSTest {
    VaultFactory vaultFactory;
    VaultAPW impl;
    VaultAPW vaultAPW;
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
        futureVault.setPT(pt);

        impl = new VaultAPW(address(codex), address(underlier));
        address vaultAddr = vaultFactory.createVault(address(impl), abi.encode(address(pt), address(collybus)));
        vault = IVault(vaultAddr);
        vaultAPW = VaultAPW(vaultAddr);
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

        vault.enter(0, owner, amount);

        assertEq(pt.balanceOf(address(this)), 0);
        assertEq(pt.balanceOf(address(vault)), amount);
    }

    function _periodSwitchAndEnter(
        address owner,
        uint256 amount,
        uint256 period,
        uint256 interestAmount
    ) internal {
        // Mint to vault on transfer to simulate redemptions
        pt.setMintTo(true);
        // Simulate a period switch
        futureVault.setCurrentPeriodIndex(period);
        // Set interest received during a transfer
        pt.setInterestAmount(interestAmount);

        pt.approve(address(vaultAPW), amount);
        pt.mint(address(this), amount);
        vaultAPW.enter(period, owner, amount);
        uint256 fyBalance = fy2.balanceOf(address(vaultAPW));
        uint256 ptBalance = pt.balanceOf(address(vaultAPW));
        console.log("minting fyt", ptBalance - amount - fyBalance);
        fy2.mint(address(vaultAPW), ptBalance - amount - fyBalance);
    }

    function test_enter_3_period_switch() public {
        uint256 amount = 100 * 10**18;
        address owner = address(123456567889);

        pt.approve(address(vault), amount);
        pt.mint(address(this), amount);
        vaultAPW.enter(0, owner, amount);
        assertEq(pt.balanceOf(address(this)), 0);
        assertEq(pt.balanceOf(address(vault)), amount);

        uint256 baseInterest = amount / 100;

        _periodSwitchAndEnter(owner, amount, 1, baseInterest);
        _periodSwitchAndEnter(owner, amount, 2, 2 * baseInterest);
        _periodSwitchAndEnter(owner, amount, 3, 3 * baseInterest);

        assertEq(pt.balanceOf(address(this)), 0);
        assertEq(pt.balanceOf(address(vaultAPW)), 4 * amount + baseInterest + 2 * baseInterest + 3 * baseInterest);

        // Verified balances with numbers calcualted here: https://docs.google.com/spreadsheets/d/12Lnzpr4z_18oRMMeITp1nz03pDZiy6ytMJsllzZ-qN8/edit#gid=0
        console.log("deposits 1", vaultAPW.ptDepositsFromPeriod(0));
        console.log("deposits 2", vaultAPW.ptDepositsFromPeriod(1));
        console.log("deposits 3", vaultAPW.ptDepositsFromPeriod(2));
        console.log("deposits 4", vaultAPW.ptDepositsFromPeriod(3));
        console.log("accumulated 1", vaultAPW.ptAccumulated(0));
        console.log("accumulated 2", vaultAPW.ptAccumulated(1));
        console.log("accumulated 3", vaultAPW.ptAccumulated(2));
        console.log("accumulated 4", vaultAPW.ptAccumulated(3));
        console.log("total 1", vaultAPW.ptDepositsFromPeriod(0) + vaultAPW.ptAccumulated(0));
        console.log("total 2", vaultAPW.ptDepositsFromPeriod(1) + vaultAPW.ptAccumulated(1));
        console.log("total 3", vaultAPW.ptDepositsFromPeriod(2) + vaultAPW.ptAccumulated(2));
        console.log("total 4", vaultAPW.ptDepositsFromPeriod(3) + vaultAPW.ptAccumulated(3));
        console.log("rate 1 ", vaultAPW.ptRate(0));
        console.log("rate 2 ", vaultAPW.ptRate(1));
        console.log("rate 3 ", vaultAPW.ptRate(2));
        console.log("rate 4 ", vaultAPW.ptRate(3));
    }

    function test_enter_3_period_switch_then_exit() public {
        uint256 amount = 100 * 10**18;
        address owner = address(123456567889);

        pt.approve(address(vault), amount);
        pt.mint(address(this), amount);
        vaultAPW.enter(0, owner, amount);
        assertEq(pt.balanceOf(address(this)), 0);
        assertEq(pt.balanceOf(address(vault)), amount);

        uint256 baseInterest = amount / 100;

        _periodSwitchAndEnter(owner, amount, 1, baseInterest);
        _periodSwitchAndEnter(owner, amount, 2, 2 * baseInterest);
        _periodSwitchAndEnter(owner, amount, 3, 3 * baseInterest);

        vault.exit(0, owner, amount);
        assertTrue(pt.balanceOf(owner) > amount);
        assertEq(pt.balanceOf(owner), (amount * vaultAPW.ptRate(0)) / vault.tokenScale());
        assertEq(pt.balanceOf(owner), fy2.balanceOf(owner));
    }

    function test_enter_3_period_switch_then_exit_on_period_switch() public {
        uint256 amount = 100 * 10**18;
        address owner = address(123456567889);

        pt.approve(address(vault), amount);
        pt.mint(address(this), amount);
        vaultAPW.enter(0, owner, amount);
        assertEq(pt.balanceOf(address(this)), 0);
        assertEq(pt.balanceOf(address(vault)), amount);

        uint256 baseInterest = amount / 100;

        _periodSwitchAndEnter(owner, amount, 1, baseInterest);
        _periodSwitchAndEnter(owner, amount, 2, 2 * baseInterest);
        futureVault.setCurrentPeriodIndex(3);
        pt.setInterestAmount(3 * baseInterest);

        uint256 fyBalance = fy2.balanceOf(address(vaultAPW));
        uint256 ptBalance = pt.balanceOf(address(vaultAPW));
        fy2.mint(address(vaultAPW), (ptBalance - fyBalance ) + (3 * baseInterest));

        vault.exit(0, owner, amount);
        assertTrue(pt.balanceOf(owner) > amount);
        assertEq(pt.balanceOf(owner), (amount * vaultAPW.ptRate(0)) / vault.tokenScale());
        assertEq(pt.balanceOf(owner), fy2.balanceOf(owner));

        vault.exit(1, owner, amount);
        assertEq(pt.balanceOf(owner), fy2.balanceOf(owner));

        vault.exit(2, owner, amount);
        assertEq(pt.balanceOf(owner), fy2.balanceOf(owner));
    }

    function test_enter_period_switch_decreased_deposits(address owner, uint256 amount) public {
        if (amount >= MAX_AMOUNT) return;

        pt.approve(address(vault), amount);
        pt.mint(address(this), amount);
        vaultAPW.enter(0, owner, amount);
        assertEq(pt.balanceOf(address(this)), 0);
        assertEq(pt.balanceOf(address(vault)), amount);

        // Mint to vault on transfer to simulate redemptions
        pt.setMintTo(true);
        // Simulate a period switch
        futureVault.setCurrentPeriodIndex(1);
        // Set interest amount for period switch
        uint256 interestAmount = amount / 100;
        pt.setInterestAmount(interestAmount);

        uint256 period2Amount = amount / 2;
        pt.approve(address(vaultAPW), period2Amount);
        pt.mint(address(this), period2Amount);
        vaultAPW.enter(1, owner, period2Amount);
        assertEq(pt.balanceOf(address(this)), 0);
        assertEq(pt.balanceOf(address(vaultAPW)), amount + period2Amount + interestAmount);

        assertEq(vaultAPW.ptDepositsFromPeriod(0), amount, "Bad deposits period 1");
        assertEq(vaultAPW.ptDepositsFromPeriod(1), period2Amount, "Bad deposits period 2");
        assertEq(vaultAPW.ptAccumulated(0), interestAmount, "Bad accumulated 1");
        assertEq(vaultAPW.ptAccumulated(1), 0, "Bad accumulated 2");
    }

    function test_enter_period_switch_increase_deposits(address owner, uint256 amount) public {
        if (amount >= MAX_AMOUNT) return;

        pt.approve(address(vault), amount);
        pt.mint(address(this), amount);
        vaultAPW.enter(0, owner, amount);
        assertEq(pt.balanceOf(address(this)), 0);
        assertEq(pt.balanceOf(address(vault)), amount);

        // Mint to vault on transfer to simulate redemptions
        pt.setMintTo(true);
        // Simulate a period switch
        futureVault.setCurrentPeriodIndex(1);
        // Set interest amount for period switch
        uint256 interestAmount = amount / 2;
        pt.setInterestAmount(interestAmount);

        uint256 period2Amount = amount * 2;
        pt.approve(address(vaultAPW), period2Amount);
        pt.mint(address(this), period2Amount);
        vaultAPW.enter(1, owner, period2Amount);
        assertEq(pt.balanceOf(address(this)), 0);
        assertEq(pt.balanceOf(address(vaultAPW)), amount + period2Amount + interestAmount);

        assertEq(vaultAPW.ptDepositsFromPeriod(0), amount, "Bad deposits period 1");
        assertEq(vaultAPW.ptDepositsFromPeriod(1), period2Amount, "Bad deposits period 2");
        assertEq(vaultAPW.ptAccumulated(0), interestAmount, "Bad accumulated 1");
        assertEq(vaultAPW.ptAccumulated(1), 0, "Bad accumulated 2");
    }

    function test_enter_period_switch_high_interest(address owner, uint256 amount) public {
        if (amount >= MAX_AMOUNT) return;

        pt.approve(address(vault), amount);
        pt.mint(address(this), amount);
        vaultAPW.enter(0, owner, amount);
        assertEq(pt.balanceOf(address(this)), 0);
        assertEq(pt.balanceOf(address(vault)), amount);

        // Mint to vault on transfer to simulate redemptions
        pt.setMintTo(true);
        // Simulate a period switch
        futureVault.setCurrentPeriodIndex(1);
        // Set interest amount for period switch
        uint256 interestAmount = amount * 10;
        pt.setInterestAmount(interestAmount);

        uint256 period2Amount = amount * 2;
        pt.approve(address(vaultAPW), period2Amount);
        pt.mint(address(this), period2Amount);
        vaultAPW.enter(1, owner, period2Amount);
        assertEq(pt.balanceOf(address(this)), 0);
        assertEq(pt.balanceOf(address(vaultAPW)), amount + period2Amount + interestAmount);

        assertEq(vaultAPW.ptDepositsFromPeriod(0), amount, "Bad deposits period 1");
        assertEq(vaultAPW.ptDepositsFromPeriod(1), period2Amount, "Bad deposits period 2");
        assertEq(vaultAPW.ptAccumulated(0), interestAmount, "Bad accumulated 1");
        assertEq(vaultAPW.ptAccumulated(1), 0, "Bad accumulated 2");
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

    function test_exit_transfers_tokens(address owner, uint256 amount) public {
        if (amount >= MAX_AMOUNT) return;

        pt.approve(address(vault), amount);
        pt.mint(address(this), amount);

        vault.enter(0, address(this), amount);
        vault.exit(0, owner, amount);

        assertEq(pt.balanceOf(owner), amount);
        assertEq(pt.balanceOf(address(vault)), 0);
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

    /*function test_enter_scales_amount_to_wad(uint8 decimals) public {
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
    }*/
}
