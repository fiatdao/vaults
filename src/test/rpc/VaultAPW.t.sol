// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {DSTest} from "ds-test/test.sol";

import {ERC20} from "openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC1155Holder} from "openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

import {Codex} from "fiat/Codex.sol";
import {Collybus, ICollybus} from "fiat/Collybus.sol";
import {WAD, wdiv} from "fiat/utils/Math.sol";

import {Hevm} from "../utils/Hevm.sol";
import {MockProvider} from "../utils/MockProvider.sol";
import {Caller} from "../utils/Caller.sol";

import {VaultAPW} from "../../VaultAPW.sol";
import {VaultFactory} from "../../VaultFactory.sol";
import {console} from "../utils/Console.sol";
interface AMM {
    function swapExactAmountIn(
        uint256 _pairID,
        uint256 _tokenIn,
        uint256 _tokenAmountIn,
        uint256 _tokenOut,
        uint256 _minAmountOut,
        address _to
    ) external returns (uint256 tokenAmountOut, uint256 spotPriceAfter);
}

interface FutureVault {
    function getCurrentPeriodIndex() external view returns (uint256);
}


contract VaultEPT_ModifyPositionCollateralizationTest is DSTest, ERC1155Holder {
    Hevm internal hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    //ITrancheFactory internal trancheFactory = ITrancheFactory(0x62F161BF3692E4015BefB05A03a94A40f520d1c0);
    IERC20 internal underlierUSDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48); // USDC

    Codex internal codex;
    MockProvider internal collybus;
    VaultAPW internal impl;
    VaultAPW internal vaultPT_tfUSDC;
    VaultFactory vaultFactory;
    Caller kakaroto;

    uint256 internal tokenId = 0;
    address internal me = address(this);
    //address internal trancheUSDC_V4_3Months;

    address tfPT_AMM = address(0x0CC36e3cc5eACA6d046b537703ae946874d57299);
    address tfUSDCFutureVault = address(0x6fb566cB80A5038BBe0421A91D9F96F9Bb9D6D95);
    address tfPT = address(0x2B8692963C8eC4cdF30047a20F12C43E4d9aEf6C);
    address tfUSDC = address(0xA991356d261fbaF194463aF6DF8f0464F8f1c742);
    
    address stETH = address(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);

    uint256 ONE_USDC = 1e6;

    uint256 constant MAX_DECIMALS = 38; // ~type(int256).max ~= 1e18*1e18
    uint256 constant MAX_AMOUNT = 10**(MAX_DECIMALS);

    function _mintUSDC(address to, uint256 amount) internal {
        // USDC minters
        hevm.store(address(underlierUSDC), keccak256(abi.encode(address(this), uint256(12))), bytes32(uint256(1)));
        // USDC minterAllowed
        hevm.store(
            address(underlierUSDC),
            keccak256(abi.encode(address(this), uint256(13))),
            bytes32(uint256(type(uint256).max))
        );
        string memory sig = "mint(address,uint256)";
        (bool ok, ) = address(underlierUSDC).call(abi.encodeWithSignature(sig, to, amount));
        assert(ok);
    }

    function _balance(address vault, address user, uint256 periodIndex) internal view returns (uint256) {
        return codex.balances(vault, periodIndex, user);
    }

    function setUp() public {
        vaultFactory = new VaultFactory();
        codex = new Codex();
        collybus = new MockProvider();
        kakaroto = new Caller();

        impl = new VaultAPW(address(codex), tfUSDC);

        codex.setParam("globalDebtCeiling", uint256(1000 ether));

        _mintUSDC(me, 10000 * ONE_USDC);

        underlierUSDC.approve(tfPT_AMM, 10000 * ONE_USDC);
        AMM(tfPT_AMM).swapExactAmountIn(0, 1, 10000 * ONE_USDC, 0, 100, me);

        address instance = vaultFactory.createVault(address(impl), abi.encode(address(tfPT), address(collybus)));
        vaultPT_tfUSDC = VaultAPW(instance);
        codex.setParam(instance, "debtCeiling", uint256(1000 ether));
        codex.allowCaller(codex.modifyBalance.selector, instance);
        codex.init(instance);

        IERC20(tfPT).approve(instance, type(uint256).max);
    }

    function testFail_initialize_with_wrong_ptoken() public {
        vaultFactory.createVault(address(impl), abi.encode(stETH, address(collybus)));
    }

    function test_initialize_with_right_ptoken() public {
        vaultFactory.createVault(address(impl), abi.encode(tfPT, address(collybus)));
    }

    function test_initialize_parameters() public {
        address instance = vaultFactory.createVault(address(impl), abi.encode(tfPT, address(collybus)));
        assertEq(address(VaultAPW(instance).token()), tfPT);
        assertEq(VaultAPW(instance).tokenScale(), 10**IERC20Metadata(tfPT).decimals());
        //assertEq(VaultAPW(instance).maturity(0), IFYToken(fyUSDC04).maturity());
        assertEq(VaultAPW(instance).underlierToken(), address(tfUSDC));
        assertEq(VaultAPW(instance).underlierScale(), 10**IERC20Metadata(address(tfUSDC)).decimals());
        assertEq(address(VaultAPW(instance).collybus()), address(collybus));
    }

    function test_enter(uint32 rnd) public {
        if (rnd == 0) return;
        uint256 period = FutureVault(tfUSDCFutureVault).getCurrentPeriodIndex();

        uint256 amount = rnd % IERC20(tfPT).balanceOf(address(this));

        uint256 balanceBefore = IERC20(tfPT).balanceOf(address(vaultPT_tfUSDC));
        uint256 collateralBefore = _balance(address(vaultPT_tfUSDC), address(me), period);

        vaultPT_tfUSDC.enter(period, me, amount);

        assertEq(IERC20(tfPT).balanceOf(address(vaultPT_tfUSDC)), balanceBefore + amount);

        uint256 wadAmount = wdiv(amount, 10**IERC20Metadata(tfPT).decimals());
        assertEq(_balance(address(vaultPT_tfUSDC), address(me), period), collateralBefore + wadAmount);
    }

    function test_exit(uint32 rndA, uint32 rndB) public {
        if (rndA == 0 || rndB == 0) return;
        uint256 period = FutureVault(tfUSDCFutureVault).getCurrentPeriodIndex();
        uint256 amountEnter = rndA % IERC20(tfPT).balanceOf(address(this));
        uint256 amountExit = rndB % amountEnter;

        vaultPT_tfUSDC.enter(period, me, amountEnter);

        uint256 balanceBefore = IERC20(tfPT).balanceOf(address(vaultPT_tfUSDC));
        uint256 collateralBefore = _balance(address(vaultPT_tfUSDC), address(me), period);

        vaultPT_tfUSDC.exit(period, me, amountExit);

        assertEq(IERC20(tfPT).balanceOf(address(vaultPT_tfUSDC)), balanceBefore - amountExit);
        uint256 wadAmount = wdiv(amountExit, 10**IERC20Metadata(tfPT).decimals());
        assertEq(_balance(address(vaultPT_tfUSDC), address(me), period), collateralBefore - wadAmount);
    }

    function test_fairPrice_calls_into_collybus_face() public {
        uint256 fairPriceExpected = 100;
        bytes memory query = abi.encodeWithSelector(
            Collybus.read.selector,
            address(vaultPT_tfUSDC),
            address(tfUSDC),
            0,
            block.timestamp,
            true
        );
        collybus.givenQueryReturnResponse(
            query,
            MockProvider.ReturnData({success: true, data: abi.encode(uint256(fairPriceExpected))})
        );

        uint256 fairPriceReturned = vaultPT_tfUSDC.fairPrice(0, true, true);
        assertEq(fairPriceReturned, fairPriceExpected);
    }

    function test_fairPrice_calls_into_collybus_no_face() public {
        uint256 fairPriceExpected = 100;
        bytes memory query = abi.encodeWithSelector(
            Collybus.read.selector,
            address(vaultPT_tfUSDC),
            address(tfUSDC),
            0,
            vaultPT_tfUSDC.maturity(0),
            true
        );
        collybus.givenQueryReturnResponse(
            query,
            MockProvider.ReturnData({success: true, data: abi.encode(uint256(fairPriceExpected))})
        );

        uint256 fairPriceReturned = vaultPT_tfUSDC.fairPrice(0, true, false);
        assertEq(fairPriceReturned, fairPriceExpected);
    }

    function test_allowCaller_can_be_called_by_root() public {
        vaultPT_tfUSDC.allowCaller(vaultPT_tfUSDC.setParam.selector, address(kakaroto));
        assertTrue(vaultPT_tfUSDC.canCall(vaultPT_tfUSDC.setParam.selector, address(kakaroto)));
    }

    function test_lock_can_be_called_by_root() public {
        vaultPT_tfUSDC.lock();
        assertEq(vaultPT_tfUSDC.live(), 0);
    }

    function test_setParam_can_be_called_by_root() public {
        vaultPT_tfUSDC.setParam(bytes32("collybus"), me);
        assertEq(address(vaultPT_tfUSDC.collybus()), me);
    }

    function test_setParam_can_be_called_by_authorized() public {
        vaultPT_tfUSDC.allowCaller(vaultPT_tfUSDC.setParam.selector, address(kakaroto));

        (bool ok, ) = kakaroto.externalCall(
            address(vaultPT_tfUSDC),
            abi.encodeWithSelector(vaultPT_tfUSDC.setParam.selector, bytes32("collybus"), me)
        );
        assertTrue(ok);
        assertEq(address(vaultPT_tfUSDC.collybus()), me);
    }
}