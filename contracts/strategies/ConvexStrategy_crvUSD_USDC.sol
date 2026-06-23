//SPDX-License-Identifier: MIT

/**
 *⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
 *⠀⠀⠀⠀⠈⢻⣿⠛⠻⢷⣄⠀⠀ ⣴⡟⠛⠛⣷⠀ ⠘⣿⡿⠛⠛⢿⡇⠀⠀⠀⠀
 *⠀⠀⠀⠀⠀⢸⣿⠀⠀ ⠈⣿⡄⠀⠿⣧⣄⡀ ⠉⠀⠀ ⣿⣧⣀⣀⡀⠀⠀⠀⠀⠀
 *⠀⠀⠀⠀⠀⢸⣿⠀⠀ ⢀⣿⠃ ⣀ ⠈⠉⠻⣷⡄⠀ ⣿⡟⠉⠉⠁⠀⠀⠀⠀⠀
 *⠀⠀⠀⠀⢠⣼⣿⣤⣴⠿⠋⠀ ⠀⢿⣦⣤⣴⡿⠁ ⢠⣿⣷⡄⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
 *
 *      - Defining Successful Future -
 *
 */

pragma solidity ^0.8.35;

import "../utils/Constants.sol";
import "./CurveConvexStrat_crvUSD_USDC.sol";

/**
 * @title  ConvexStrategy_crvUSD_USDC
 * @author Andrei Averin — DSF.Finance
 * @notice Thin deployment wrapper for the crvUSD/USDC Curve+Convex strategy (Convex PID=182).
 *
 * @dev Responsibilities:
 * - This contract contains NO custom logic and introduces no new trust assumptions.
 * - It only wires the correct addresses/parameters into `CurveConvexStrat_crvUSD_USDC`.
 * - All token conversion (DAI/USDT -> USDC), Curve interactions, Convex staking,
 *   reward handling, and slippage checks are implemented in the underlying strategy/base contracts.
 */
contract ConvexStrategy_crvUSD_USDC is CurveConvexStrat_crvUSD_USDC {
    constructor(Config memory config)
        CurveConvexStrat_crvUSD_USDC(
            config,
            Constants.CRV_CRVUSD_USDC_ADDRESS,
            Constants.CRV_CRVUSD_USDC_LP_ADDRESS,
            Constants.CVX_CRVUSD_USDC_REWARDS_ADDRESS,
            Constants.CVX_CRVUSD_USDC_PID,
            Constants.USDC_ADDRESS, // primary deposit token (we convert USDT/DAI -> USDC inside strategy)
            address(0),
            address(0)
        )
    {}
}
