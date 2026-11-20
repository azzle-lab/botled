// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAzzleBondVaultV2} from "../../interfaces/IAzzle.sol";

/// @dev Seat surface of the deployed BotledPanelOwner (0xF7E5…7a04 on Base).
interface IBotledPanelOwnerSeatN {
    function micro() external view returns (address);
    function standard() external view returns (address);
    function pfand() external view returns (uint256);
    function isSeated(address m) external view returns (bool);
    function join() external payable;
    function leave() external;
    function claim() external;
    function claimable(address m) external view returns (uint256);
}

/// @title CageSeat — operator seat / bond management of BotledCageV5Near, moved out of the cage for bytecode headroom
/// @notice Linked library (public functions, reached by DELEGATECALL): runs in the cage's context, so
///         `address(this)` is the cage, balances and approvals are the cage's, and events are emitted by the cage.
///         Access control (onlyOperator) and the reentrancy lock stay in the cage wrappers. No case logic lives here.
library CageSeat {
    using SafeERC20 for IERC20;

    event Seated(uint256 pfand, uint256 microBond, uint256 standardBond);
    event Unseated(uint256 refunded);
    event BondWithdrawn(address indexed vault, uint256 amount);

    /// @dev bonds up to `target` (raised to minimumBond and reserved slashes); a pending withdrawal is reset by bonding 1
    function topUp(IAzzleBondVaultV2 v, IERC20 azl, address operator, uint256 target) public {
        uint256 have = v.bonds(address(this));
        uint256 need = v.reservedSlash(address(this)) + v.assignmentReserve();
        uint256 min = v.minimumBond();
        if (target < need) target = need;
        if (target < min) target = min;
        uint256 add = target > have ? target - have : (v.withdrawReadyAt(address(this)) != 0 ? 1 : 0);
        if (add == 0) return;
        azl.safeTransferFrom(operator, address(this), add);
        azl.forceApprove(address(v), add);
        v.bond(add);
    }

    /// @dev `pfand` is forwarded from the cage's balance (the cage wrapper received it as msg.value)
    function seat(
        IAzzleBondVaultV2 mv,
        IAzzleBondVaultV2 sv,
        IERC20 azl,
        address operator,
        IBotledPanelOwnerSeatN po,
        uint256 microTarget,
        uint256 standardTarget,
        uint256 pfand
    ) public {
        topUp(mv, azl, operator, microTarget);
        topUp(sv, azl, operator, standardTarget);
        po.join{value: pfand}();
        emit Seated(pfand, mv.bonds(address(this)), sv.bonds(address(this)));
    }

    function unseat(IBotledPanelOwnerSeatN po, address operator) public {
        po.leave();
        uint256 bal = address(this).balance;
        _sendEth(operator, bal);
        emit Unseated(bal);
    }

    function claimPfand(IBotledPanelOwnerSeatN po, address operator) public {
        if (po.claimable(address(this)) > 0) po.claim();
        _sendEth(operator, address(this).balance);
    }

    /// @dev refuses while seated: a seated cage that is not eligible can be kicked and would forfeit its pfand
    function scheduleExit(IBotledPanelOwnerSeatN po, IAzzleBondVaultV2 mv, IAzzleBondVaultV2 sv) public returns (bool) {
        if (po.isSeated(address(this))) return false;
        if (mv.bonds(address(this)) > 0) mv.scheduleWithdrawal();
        if (sv.bonds(address(this)) > 0) sv.scheduleWithdrawal();
        return true;
    }

    /// @dev forwards exactly what left the vault: held appeal bonds (same token) are never touched
    function withdrawBond(IAzzleBondVaultV2 v, IERC20 azl, address operator, uint256 amount) public {
        if (amount == 0) amount = v.bonds(address(this));
        uint256 before = azl.balanceOf(address(this));
        v.withdraw(amount);
        uint256 got = azl.balanceOf(address(this)) - before;
        azl.safeTransfer(operator, got);
        emit BondWithdrawn(address(v), got);
    }

    function _sendEth(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        require(ok, "BL: eth");
    }
}
