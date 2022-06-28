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
import {WAD, toInt256, wmul, wdiv} from "fiat/utils/Math.sol";
import {IVault} from "fiat/interfaces/IVault.sol";

import {VaultFactory} from "./VaultFactory.sol";

interface IFutureVault {
    function getIBTAddress() external view returns (address);

    function claimFYT(address _user, uint256 _amount) external;

    function getClaimableFYTForPeriod(address _user, uint256 _periodIndex) external view returns (uint256);

    function getCurrentPeriodIndex() external view returns (uint256);

    function getFYTofPeriod(uint256 _periodIndex) external view returns (address);

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
    /// @notice The current FYT period index
    uint256 public fytPeriodIndex;
    /// @notice Scale of collateral token (set during intialization)
    uint256 public override tokenScale;
    /// @notice Underlier of collateral token
    address public immutable override underlierToken;
    /// @notice Scale of underlier of collateral token
    uint256 public immutable override underlierScale;

    /// @notice The vault type (set during intialization)
    bytes32 public override vaultType;

    /// @notice Boolean indicating if this contract is live (0 - not live, 1 - live) (set during intialization)
    uint256 public override live;

    uint256 public vaultClaimablePT;
    /// @notice Mapping to track when a user entered or withdrew from the vault
    mapping(address => uint256) userPeriodInteraction;

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
        fytPeriodIndex = futureVault.getCurrentPeriodIndex();
        address underlier = futureVault.getIBTAddress();
        if (underlier != underlierToken || 10**IERC20Metadata(pt).decimals() != underlierScale) {
            revert VaultAPW__initialize_invalidUnderlierToken();
        }

        // intialize all mutable vars
        _setRoot(root);
        live = 1;
        collybus = ICollybus(collybus_);
        token = pt;
        tokenScale = 10**IERC20Metadata(pt).decimals();
        vaultType = bytes32("ERC20");
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
        uint256 currentPeriodIndex = futureVault.getCurrentPeriodIndex();
        // Only PT and current period FYTs can enter
        if (tokenId != 0 && tokenId != currentPeriodIndex) revert VaultAPW__enter_invalidTokenId();
        int256 wad = toInt256(wdiv(amount, tokenScale));
        codex.modifyBalance(address(this), tokenId, user, wad);
        // Use PT if token id is 0, otherwise get current fyt
        address assetIn;
        if (tokenId == 0) {
            futureVault.createFYTDelegationTo(address(this), user, amount);
            assetIn = token;
        } else {
            assetIn = futureVault.getFYTofPeriod(currentPeriodIndex);
        }
        IERC20(assetIn).safeTransferFrom(msg.sender, address(this), amount);
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
        uint256 currentPeriodIndex = futureVault.getCurrentPeriodIndex();
        if (tokenId > currentPeriodIndex) revert VaultAPW__exit_invalidTokenId();
        int256 wad = toInt256(wdiv(amount, tokenScale));
        codex.modifyBalance(address(this), tokenId, msg.sender, -int256(wad));
        address assetOut;
        if (tokenId == 0) {
            futureVault.withdrawFYTDelegationFrom(address(this), user, amount);
            assetOut = token;
        } else {
            assetOut = futureVault.getFYTofPeriod(tokenId);
        }
        IERC20(assetOut).safeTransfer(user, amount);

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
        uint256,
        bool net,
        bool face
    ) external view override returns (uint256) {
        return collybus.read(address(this), underlierToken, 0, (face) ? block.timestamp : maturity(0), net);
    }

    /// ======== Shutdown ======== ///

    /// @notice Locks the contract
    /// @dev Sender has to be allowed to call this method
    function lock() external virtual override checkCaller {
        live = 0;
        emit Lock();
    }
}