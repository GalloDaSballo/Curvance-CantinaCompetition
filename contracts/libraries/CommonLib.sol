// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { IERC20 } from "contracts/interfaces/IERC20.sol";

library CommonLib {
    function isETH(address token) internal pure returns (bool) {
        return
            token == address(0) ||
            token == 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    }

    /// @notice Returns balance of `token` for this contract.
    /// @param token The token address.
    function getTokenBalance(address token) internal view returns (uint256) {
        if (isETH(token)) {
            return address(this).balance;
        } else {
            return IERC20(token).balanceOf(address(this));
        }
    }
}
