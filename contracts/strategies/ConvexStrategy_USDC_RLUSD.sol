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
import "./CurveConvexStrat_USDC_RLUSD.sol";

/**
 * @title  ConvexStrategy_USDC_RLUSD
 * @author Andrei Averin — DSF.Finance
 * @notice Thin deployment wrapper for the USDC/RLUSD Curve+Convex strategy (Convex PID=443)
 *
 * @dev Responsibilities:
 * - This contract contains NO custom logic and introduces no new trust assumptions
 * - It only wires the correct addresses/parameters into `CurveConvexStrat_USDC_RLUSD`
 * - All token conversion (DAI/USDT -> USDC), Curve interactions, Convex staking,
 *   reward handling, and slippage checks are implemented in the underlying strategy/base contracts
 */
contract ConvexStrategy_USDC_RLUSD is CurveConvexStrat_USDC_RLUSD {
    constructor(Config memory config)
        CurveConvexStrat_USDC_RLUSD(
            config,
            Constants.CRV_USDC_RLUSD_ADDRESS,
            Constants.CRV_USDC_RLUSD_LP_ADDRESS,
            Constants.CVX_USDC_RLUSD_REWARDS_ADDRESS,
            Constants.CVX_USDC_RLUSD_PID,
            Constants.USDC_ADDRESS, // primary deposit token (we convert USDT/DAI -> USDC inside strategy)
            Constants.CVX_USDC_RLUSD_EXTRA_RLUSD_REWARDS_ADDRESS,
            Constants.RLUSD_ADDRESS
        )
    {}
}
