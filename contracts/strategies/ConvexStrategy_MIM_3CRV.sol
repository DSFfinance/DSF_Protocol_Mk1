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
import "./CurveConvexStrat_MIM_3CRV.sol";

/**
 * @title  ConvexStrategy_MIM_3CRV
 * @author Andrei Averin — DSF.Finance
 * @notice Thin deployment wrapper for the Curve MIM-3CRV metapool strategy with Convex staking
 *
 * @dev Responsibilities:
 * - This contract introduces NO new business logic
 * - It only injects the correct pool / LP / Convex / extra reward addresses
 *   into the underlying `CurveConvexStrat_MIM_3CRV` implementation
 */

contract ConvexStrategy_MIM_3CRV is CurveConvexStrat_MIM_3CRV {
    constructor(Config memory config)
        CurveConvexStrat_MIM_3CRV(
            config,
            Constants.CRV_MIM_ADDRESS,
            Constants.CRV_MIM_LP_ADDRESS,
            Constants.CVX_MIM_REWARDS_ADDRESS,
            Constants.CVX_MIM_PID,
            Constants.MIM_ADDRESS,
            Constants.CVX_MIM_EXTRA_ADDRESS,
            Constants.MIM_EXTRA_ADDRESS
        )
    {}
}
