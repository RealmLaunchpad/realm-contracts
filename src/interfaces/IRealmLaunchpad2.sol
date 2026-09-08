// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRealmBondingCurve} from "src/interfaces/IRealmBondingCurve.sol";
import {TokenConfig, TokenState} from "src/types/tokenData.sol";

/// @title IRealmLaunchpad2
/// @notice v2 of `IRealmLaunchpad`: identical function set, except the two buy-quote views now also
///         return `canGraduate` — `true` when broadcasting the corresponding buy would top the
///         bonding curve past its graduation threshold and trigger graduation within the same tx.
/// @dev    The function selectors are unchanged (inputs are identical), so a consumer still reading
///         the legacy 3-tuple via `IRealmLaunchpad` keeps decoding correctly; the appended
///         `canGraduate` is simply ignored by it.
interface IRealmLaunchpad2 {
    function VERSION() external view returns (string memory);
    function treasury() external view returns (address);
    function whitelistedFactories(address factory) external view returns (bool);
    function launchToken(address token, IRealmBondingCurve curve) external;
    function buyTokensWithExactEth(address token, uint256 minTokenAmount, uint256 deadline)
        external
        payable
        returns (uint256 receivedTokens);

    function sellExactTokens(address token, uint256 tokenAmount, uint256 minEthAmount, uint256 deadline)
        external
        returns (uint256 receivedEth);

    function quoteBuyTokensWithExactEth(address token, uint256 ethValue)
        external
        view
        returns (uint256 ethForPurchase, uint256 ethFee, uint256 tokensToReceive, bool canGraduate);

    function quoteBuyExactTokens(address token, uint256 tokenAmount)
        external
        view
        returns (uint256 ethFee, uint256 ethForReserves, uint256 totalEthNeeded, bool canGraduate);

    function quoteSellExactTokens(address token, uint256 tokenAmount)
        external
        view
        returns (uint256 ethPulledFromReserves, uint256 ethFee, uint256 ethForSeller);

    function quoteSellTokensForExactEth(address token, uint256 ethAmount)
        external
        view
        returns (uint256 ethPulledFromReserves, uint256 ethFee, uint256 tokensRequired);

    function getMaxEthToSpend(address token) external view returns (uint256);

    function getTokenState(address token) external view returns (TokenState memory);

    function getTokenConfig(address token) external view returns (TokenConfig memory);
}
