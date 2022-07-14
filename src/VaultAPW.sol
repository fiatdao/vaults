// SPDX-License-Identifier: Unlicense
pragma solidity >=0.8.4;

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Clones} from "openzeppelin/contracts/proxy/Clones.sol";

import {ICollybus} from "fiat/interfaces/ICollybus.sol";
import {ICodex} from "fiat/interfaces/ICodex.sol";
import {Guarded} from "fiat/utils/Guarded.sol";
import {WAD, toInt256, wmul, wdiv, add, sub} from "fiat/utils/Math.sol";
import {IVault} from "fiat/interfaces/IVault.sol";

import {VaultFactory} from "./VaultFactory.sol";

//import {console} from "./test/utils/Console.sol";

interface IFutureVault {
    function getIBTAddress() external view returns (address);

    function claimFYT(address _user, uint256 _amount) external;

    function getClaimableFYTForPeriod(address _user, uint256 _periodIndex) external view returns (uint256);

    function getCurrentPeriodIndex() external view returns (uint256);

    function getFYTofPeriod(uint256 _periodIndex) external view returns (address);

    function updateUserState(address _user) external;

    function createFYTDelegationTo(
        address _delegator,
        address _receiver,
        uint256 _amount
    ) external;

    function withdrawFYTDelegationFrom(
        address _delegator,
        address _receiver,
        uint256 _amount
    ) external;
}

interface IPT {
    function futureVault() external view returns (IFutureVault);

    function recordedBalanceOf(address account) external view returns (uint256);
}

contract VaultAPW is Guarded, IVault, Initializable {
    using SafeERC20 for IERC20;

    /// ======== Custom Errors ======== ///
    error VaultAPW__enter_invalidTokenId();
    error VaultAPW__exit_invalidTokenId();
    error VaultAPW__nonzeroTokenId();
    error VaultAPW__setParam_notLive();
    error VaultAPW__setParam_unrecognizedParam();
    error VaultAPW__enter_notLive();
    error VaultAPW__initialize_invalidToken();
    error VaultAPW__initialize_invalidUnderlierToken();
    error VaultAPW__claimYield_invalidUserPeriod();

    /// ======== Storage ======== ///

    /// @notice Codex
    ICodex public immutable override codex;
    /// @notice Price Feed (set during intialization)
    ICollybus public override collybus;
    IFutureVault futureVault;
    /// @notice Collateral token (set during intialization)
    address public override token;
    /// @notice Scale of collateral token (set during intialization)
    uint256 public override tokenScale;
    /// @notice Underlier of collateral token
    address public immutable override underlierToken;
    /// @notice Scale of underlier of collateral token
    uint256 public immutable override underlierScale;
    /// @notice Cached balance of PT
    uint256 recordedPTBalance;
    /// @notice First period index vault was initialized with
    uint256 firstPeriodIndex;
    /// @notice Amount of total pt was deposited in a period
    mapping(uint256 => uint256) public ptDepositsFromPeriod;
    /// @notice Amount of pt accumulated for each period from compounded interest
    mapping(uint256 => uint256) public ptAccumulated;
    /// @notice PT rate = PnAccumulated / PnDeposited
    mapping(uint256 => uint256) public ptRate;

    uint256 public fytInterest;
    uint256 public currentPeriodIndex;

    /// @notice The vault type (set during intialization)
    bytes32 public override vaultType;

    /// @notice Boolean indicating if this contract is live (0 - not live, 1 - live) (set during intialization)
    uint256 public override live;

    /// ======== Events ======== ///

    event SetParam(bytes32 indexed param, address data);

    event Enter(address indexed user, uint256 amount);
    event Exit(address indexed user, uint256 amount);

    event Lock();

    constructor(address codex_, address underlierToken_) Guarded() {
        codex = ICodex(codex_);

        // underlier remains the same for all proxy instances of this contract
        underlierToken = underlierToken_;
        underlierScale = 10**IERC20Metadata(underlierToken_).decimals();
    }

    /// ======== EIP1167 Minimal Proxy Contract ======== ///

    /// @notice Initializes the proxy (clone) deployed via VaultFactory
    /// @dev Initializer modifier ensures it can only be called once
    /// @param params Constructor arguments of the proxy
    function initialize(bytes calldata params) external initializer {
        (address pt, address collybus_, address root) = abi.decode(params, (address, address, address));
        futureVault = IPT(pt).futureVault();
        address underlier = futureVault.getIBTAddress();
        if (underlier != underlierToken || 10**IERC20Metadata(pt).decimals() != underlierScale) {
            revert VaultAPW__initialize_invalidUnderlierToken();
        }
        firstPeriodIndex = futureVault.getCurrentPeriodIndex();
        currentPeriodIndex = firstPeriodIndex;

        // intialize all mutable vars
        _setRoot(root);
        live = 1;
        collybus = ICollybus(collybus_);
        token = pt;
        tokenScale = 10**IERC20Metadata(pt).decimals();
        vaultType = bytes32("ERC20:APW");
    }

    /// ======== Configuration ======== ///

    /// @notice Sets various variables for this contract
    /// @dev Sender has to be allowed to call this method
    /// @param param Name of the variable to set
    /// @param data New value to set for the variable [address]
    function setParam(bytes32 param, address data) external virtual override checkCaller {
        if (live == 0) revert VaultAPW__setParam_notLive();
        if (param == "collybus") collybus = ICollybus(data);
        else revert VaultAPW__setParam_unrecognizedParam();
        emit SetParam(param, data);
    }

    /// ======== Entering and Exiting Collateral ======== ///

    /// @notice Enters `amount` collateral into the system and credits it to `user`
    /// @dev Caller has to set allowance for this contract
    /// @param tokenId 0 for PT token, or the current period index of the FYT token
    /// @param user Address to whom the collateral should be credited to in Codex
    /// @param amount Amount of collateral to enter [tokenScale]
    function enter(
        uint256 tokenId,
        address user,
        uint256 amount
    ) external virtual override {
        if (live == 0) revert VaultAPW__enter_notLive();
        uint256 currentPeriodIndex_ = futureVault.getCurrentPeriodIndex();

        // For accounting purposes, tokenId must match current period
        if (tokenId != currentPeriodIndex_) revert VaultAPW__enter_invalidTokenId();
        int256 wad = toInt256(wdiv(amount, tokenScale));
        codex.modifyBalance(address(this), tokenId, user, wad);

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // If there was a period change
        if (currentPeriodIndex < currentPeriodIndex_) {
            currentPeriodIndex = currentPeriodIndex_;
            if (recordedPTBalance > 0) {
                uint256 totalPTInterest = IERC20(token).balanceOf(address(this)) - (recordedPTBalance + amount);
                for (uint256 i = firstPeriodIndex; i < currentPeriodIndex_; ++i) {
                    uint256 interestEarnedPerPeriod = (totalPTInterest * (ptDepositsFromPeriod[i] + ptAccumulated[i])) /
                        recordedPTBalance;
                    ptAccumulated[i] += interestEarnedPerPeriod;
                    if (ptDepositsFromPeriod[i] > 0) {
                        ptRate[i] =
                            ((ptDepositsFromPeriod[i] + ptAccumulated[i]) * tokenScale) /
                            ptDepositsFromPeriod[i];
                    }
                }
            }
        }

        ptDepositsFromPeriod[currentPeriodIndex_] += amount;
        recordedPTBalance = IERC20(token).balanceOf(address(this));
        emit Enter(user, amount);
    }

    /// @notice Exits `amount` collateral into the system and credits it to `user`
    /// @param tokenId 0 for PT, or the period index of a specific FYT
    /// @param user Address to whom the collateral should be credited to
    /// @param amount Amount of collateral to exit [tokenScale]
    function exit(
        uint256 tokenId,
        address user,
        uint256 amount
    ) external virtual override {
        if (live == 0) revert VaultAPW__enter_notLive();
        if (tokenId > currentPeriodIndex) revert VaultAPW__exit_invalidTokenId();
        int256 wad = toInt256(wdiv(amount, tokenScale));
        codex.modifyBalance(address(this), tokenId, msg.sender, -int256(wad));

        uint256 currentPeriodIndex_ = futureVault.getCurrentPeriodIndex();

        // If there was a period change
        if (currentPeriodIndex < currentPeriodIndex_) {
            // Claim pt
            futureVault.updateUserState(address(this));
            currentPeriodIndex = currentPeriodIndex_;
            if (recordedPTBalance > 0) {
                uint256 totalPTInterest = IERC20(token).balanceOf(address(this)) - recordedPTBalance;
                for (uint256 i = firstPeriodIndex; i < currentPeriodIndex_; ++i) {
                    uint256 interestEarnedPerPeriod = (totalPTInterest * (ptDepositsFromPeriod[i] + ptAccumulated[i])) /
                        recordedPTBalance;
                    ptAccumulated[i] += interestEarnedPerPeriod;
                    if (ptDepositsFromPeriod[i] > 0) {
                        ptRate[i] =
                            ((ptDepositsFromPeriod[i] + ptAccumulated[i]) * tokenScale) /
                            (ptDepositsFromPeriod[i]);
                    }
                }
            }
        }
        ptDepositsFromPeriod[tokenId] -= amount;
        if (ptRate[tokenId] > 0) {
            uint256 withdrawAmount = (amount * ptRate[tokenId]) / tokenScale;
            IERC20(token).safeTransfer(user, withdrawAmount);
            address fytAddress = futureVault.getFYTofPeriod(currentPeriodIndex_);
            IERC20(fytAddress).safeTransfer(user, withdrawAmount);
        } else {
            IERC20(token).safeTransfer(user, amount);
        }

        recordedPTBalance = IERC20(token).balanceOf(address(this));

        emit Exit(user, amount);
    }

    /// ======== Collateral Asset ======== ///

    /// @notice Returns the maturity of the collateral asset
    /// @param *tokenId ERC1155 or ERC721 style TokenId (leave at 0 for ERC20)
    /// @return maturity [seconds]
    function maturity(
        uint256 /* tokenId */
    ) public view virtual override returns (uint256) {
        // APW Principal Tokens never expire and are automatically rolled to the next period
        return 0;
    }

    /// ======== Valuing Collateral ======== ///

    /// @notice Returns the fair price of a single collateral unit
    /// @dev Caller has to set allowance for this contract
    /// @param *tokenId ERC1155 or ERC721 style TokenId (leave at 0 for ERC20)
    /// @param net Boolean indicating whether the liquidation safety margin should be applied to the fair value
    /// @param face Boolean indicating whether the current fair value or the fair value at maturity should be returned
    /// @return fair Price [wad]
    function fairPrice(
        uint256 tokenId,
        bool net,
        bool face
    ) external view override returns (uint256) {
        uint256 value = collybus.read(address(this), underlierToken, 0, (face) ? block.timestamp : maturity(0), net);
        return (value * ptRate[tokenId]) / tokenScale;
    }

    /// ======== Shutdown ======== ///

    /// @notice Locks the contract
    /// @dev Sender has to be allowed to call this method
    function lock() external virtual override checkCaller {
        live = 0;
        emit Lock();
    }
}
