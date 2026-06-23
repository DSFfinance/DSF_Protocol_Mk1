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
import "./CurveConvexStrat_USDC_PYUSD.sol";

/**
 * @title  ConvexStrategy_USDC_PYUSD
 * @author Andrei Averin — DSF.Finance
 * @notice Thin deployment wrapper for the USDC/PYUSD Curve+Convex strategy (Convex PID=270)
 *
 * @dev Responsibilities:
 * - This contract contains NO custom logic and introduces no new trust assumptions
 * - It only wires the correct addresses/parameters into `CurveConvexStrat_USDC_PYUSD`
 * - All token conversion (DAI/USDT -> USDC), Curve interactions, Convex staking,
 *   reward handling, and slippage checks are implemented in the underlying strategy/base contracts
 */
contract ConvexStrategy_USDC_PYUSD is CurveConvexStrat_USDC_PYUSD {
    constructor(Config memory config)
        CurveConvexStrat_USDC_PYUSD(
            config,
            Constants.CRV_USDC_PYUSD_ADDRESS,
            Constants.CRV_USDC_PYUSD_LP_ADDRESS,
            Constants.CVX_USDC_PYUSD_REWARDS_ADDRESS,
            Constants.CVX_USDC_PYUSD_PID,
            Constants.USDC_ADDRESS, // primary deposit token (we convert USDT/DAI -> USDC inside strategy)
            Constants.CVX_USDC_PYUSD_EXTRA_PYUSD_REWARDS_ADDRESS,
            Constants.PYUSD_ADDRESS
        )
    {}
} 
