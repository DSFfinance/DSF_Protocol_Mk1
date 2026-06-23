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
import "./CurveConvexStrat_crvUSD_USDT.sol";

/**
 * @title  ConvexStrategy_CRVUSD_USDT
 * @author Andrei Averin — DSF.Finance
 * @notice Thin deployment wrapper for the crvUSD/USDT Curve+Convex strategy (factory-crvusd-1, Convex PID=179).
 *
 * @dev Responsibilities:
 * - This contract contains NO custom logic and introduces no new trust assumptions.
 * - It only wires the correct addresses/parameters into `CurveConvexStrat_crvUSD_USDT`.
 * - All token conversion (DAI/USDC/USDT), Curve interactions, Convex staking, and slippage checks
 *   are implemented in the underlying strategy/base contracts.
 */
contract ConvexStrategy_CRVUSD_USDT is CurveConvexStrat_crvUSD_USDT {
    constructor(Config memory config)
        CurveConvexStrat_crvUSD_USDT(
            config,
            Constants.CRV_CRVUSD_USDT_ADDRESS,
            Constants.CRV_CRVUSD_USDT_LP_ADDRESS,
            Constants.CVX_CRVUSD_USDT_REWARDS_ADDRESS,
            Constants.CVX_CRVUSD_USDT_PID,
            Constants.USDT_ADDRESS, // primary deposit token (we convert USDC/DAI -> USDT inside strategy)
            address(0),
            address(0)
        )
    {}
}
