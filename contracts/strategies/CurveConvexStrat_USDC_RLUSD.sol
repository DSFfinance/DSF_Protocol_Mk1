//SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../utils/Constants.sol";
import "../interfaces/ICurvePoolStableSwapNG.sol";
import "./CurveConvexExtraStratBaseMk3_NG.sol";

/**
 * @title  CurveConvexStrat_USDC_RLUSD
 * @author Andrei Averin — DSF.Finance
 * @notice Convex strategy for Curve Factory Plain Pool (USDC/RLUSD), Convex PID=443
 *
 * @dev High-level:
 * - DSF-facing API uses 3 stable tokens in DSF order: DAI(0), USDC(1), USDT(2)
 * - Internally all Curve interactions are USDC-only:
 *   - Deposit: swap DAI/USDT -> USDC via `_config.router`, then `add_liquidity([USDC, 0], minMint)`, then stake LP into Convex
 *   - Withdraw: `remove_liquidity_one_coin(..., USDC, ...)` then optionally swap USDC -> requested token(s) via router
 *
 * Assumptions:
 * - Curve pool coin order MUST be: 0 = USDC, 1 = RLUSD
 * - `tokenAddr` passed to base MUST be USDC
 * - View quotes and swap minOut rely on router quotes; execution safety uses:
 *   - `swapSlippageBps` for swaps (deadline: `block.timestamp + Constants.TRADE_DEADLINE`)
 *   - `minDepositAmount` for Curve `minMint`
 * - Uses SafeERC20.forceApprove (OZ v5) for USDC-like tokens
 */
contract CurveConvexStrat_USDC_RLUSD is CurveConvexExtraStratBaseMk3_NG {
    using SafeERC20 for IERC20Metadata;

    /**
     * @notice Curve pool USDC coin index (int128) for 2-coin pool
     * @dev    Expected pool coins: 0 = USDC, 1 = RLUSD
     */
    int128 public constant CURVE_USDC_COIN_ID_INT = 0;

    /// @notice Curve pool interface for USDC/RLUSD pool (2-coin)
    ICurvePoolStableSwapNG public pool;

    /**
     * @notice Creates the strategy instance and binds it to a specific Curve pool and Convex PID
     * @param  config           Strategy config (DSF tokens, router, booster, etc)
     * @param  poolAddr         Curve pool address (RLUSD/USDC factory pool)
     * @param  poolLPAddr       Curve LP token address
     * @param  rewardsAddr      Convex rewards contract for the PID
     * @param  poolPID          Convex PID (443 for RLUSD/USDC)
     * @param  tokenAddr        Main deposit token for this strategy (MUST be USDC)
     * @param  extraRewardsAddr Optional extra rewards contract (if used by base)
     * @param  extraTokenAddr   Optional extra reward token (if used by base)
     */
    constructor(
        Config memory config,
        address poolAddr,
        address poolLPAddr,
        address rewardsAddr,
        uint256 poolPID,
        address tokenAddr, // should be USDC for this strat
        address extraRewardsAddr,
        address extraTokenAddr
    )
        CurveConvexExtraStratBaseMk3_NG(
            config,
            poolLPAddr,
            rewardsAddr,
            poolPID,
            tokenAddr,
            extraRewardsAddr,
            extraTokenAddr
        )
    {
        pool = ICurvePoolStableSwapNG(poolAddr);
    }

    // =============================================================
    // Deposit
    // =============================================================

    /**
     * @notice Lightweight sanity check for deposit input
     * @dev    DSF core calls this to validate that deposit input is meaningful
     *         This strategy deposits only as USDC; DAI/USDT are swapped at execution time,
     *         so we cannot precisely predict LP mint in view without assuming swap execution price
     *
     * @param  amounts Token amounts in DSF order: [DAI, USDC, USDT]
     * @return True if the deposit input is non-trivial and passes the configured minimum threshold
     */
    function checkDepositSuccessful(uint256[3] memory amounts)
        internal
        view
        override
        returns (bool)
    {
        uint256 amountsTotalNorm1e18;
        for (uint256 i = 0; i < 3; i++) {
            amountsTotalNorm1e18 += amounts[i] * decimalsMultipliers[i];
        }

        uint256 amountsMinNorm1e18 = (amountsTotalNorm1e18 * minDepositAmount) / DEPOSIT_DENOMINATOR;

        // Estimate minted LP for a "best-effort" deposit:
        // We can't quote DAI/USDT -> USDC in view precisely without assumptions,
        // so we only ensure that the total amount is non-zero and min check is sane
        // Real protection happens via minMint in depositPool()
        if (amountsMinNorm1e18 == 0) return false;

        return true;
    }

    /**
     * @notice Executes the actual deposit:
     *         - Swaps DAI/USDT -> USDC via router (if provided in `amounts`)
     *         - Deposits USDC into Curve pool with minMint protection
     *         - Stakes LP into Convex
     *
     * @dev    Slippage protections:
     *         - For swaps: minOut = quote * swapSlippageBps / DEPOSIT_DENOMINATOR
     *         - For Curve mint: minMint = expectedLp * minDepositAmount / DEPOSIT_DENOMINATOR
     *
     * @param  amounts Token amounts in DSF order: [DAI, USDC, USDT]
     * @return poolLPs Amount of Curve LP tokens minted (then staked into Convex)
     */
    function depositPool(uint256[3] memory amounts) internal override returns (uint256 poolLPs) {
        // Convert DAI/USDT -> USDC via _config.router (DexV2AggregatorModuleMk3)
        uint256 usdcBefore = _config.tokens[DSF_USDC_TOKEN_ID].balanceOf(address(this));

        // Swap DAI -> USDC
        if (amounts[DSF_DAI_TOKEN_ID] > 0) {
            IERC20Metadata dai = _config.tokens[DSF_DAI_TOKEN_ID];
            dai.forceApprove(address(_config.router), amounts[DSF_DAI_TOKEN_ID]);

            address[] memory path = new address[](2);
            path[0] = address(dai);
            path[1] = address(_config.tokens[DSF_USDC_TOKEN_ID]);

            uint256[] memory outs = _config.router.getAmountsOut(amounts[DSF_DAI_TOKEN_ID], path);
            uint256 minOut = (outs[outs.length - 1] * swapSlippageBps) / DEPOSIT_DENOMINATOR;

            _config.router.swapExactTokensForTokens(
                amounts[DSF_DAI_TOKEN_ID],
                minOut,
                path,
                address(this),
                block.timestamp + Constants.TRADE_DEADLINE
            );
        }

        // Swap USDT -> USDC
        if (amounts[DSF_USDT_TOKEN_ID] > 0) {
            IERC20Metadata usdt = _config.tokens[DSF_USDT_TOKEN_ID];
            usdt.forceApprove(address(_config.router), amounts[DSF_USDT_TOKEN_ID]);

            address[] memory path = new address[](2);
            path[0] = address(usdt);
            path[1] = address(_config.tokens[DSF_USDC_TOKEN_ID]);

            uint256[] memory outs = _config.router.getAmountsOut(amounts[DSF_USDT_TOKEN_ID], path);
            uint256 minOut = (outs[outs.length - 1] * swapSlippageBps) / DEPOSIT_DENOMINATOR;

            _config.router.swapExactTokensForTokens(
                amounts[DSF_USDT_TOKEN_ID],
                minOut,
                path,
                address(this),
                block.timestamp + Constants.TRADE_DEADLINE
            );
        }

        // USDC direct (already in contract)
        // amounts[DSF_USDC_TOKEN_ID] stays as is

        uint256 usdcAfter = _config.tokens[DSF_USDC_TOKEN_ID].balanceOf(address(this));
        require(usdcAfter >= usdcBefore, "USDC delta underflow");
        uint256 usdcToDeposit = usdcAfter - usdcBefore + amounts[DSF_USDC_TOKEN_ID];

        require(usdcToDeposit > 0, "deposit=0");

        // Curve pool deposit: [USDC, RLUSD]
        uint256[] memory amounts2 = new uint256[](2);
        amounts2[0] = usdcToDeposit; // USDC
        amounts2[1] = 0;             // RLUSD

        _config.tokens[DSF_USDC_TOKEN_ID].forceApprove(address(pool), usdcToDeposit);

        uint256 expectedLp = pool.calc_token_amount(amounts2, true);
        uint256 minMint = (expectedLp * minDepositAmount) / DEPOSIT_DENOMINATOR; // ≤ 99.75%
        poolLPs = pool.add_liquidity(amounts2, minMint);

        // Convex
        poolLP.forceApprove(address(_config.booster), poolLPs);
        _config.booster.depositAll(cvxPoolPID, true);
    }

    /**
     * @notice Returns Curve virtual price of LP token (1e18)
     * @dev    Used by base contract for valuation / previews / accounting
     */
    function getCurvePoolPrice() internal view override returns (uint256) {
        return pool.get_virtual_price();
    }

    // =============================================================
    // Withdraw (view helpers)
    // =============================================================

    /**
     * @notice View quote for withdrawing a proportional share of Convex-staked LP into a single token
     * @dev    Always models Curve exit as USDC first. If tokenIndex != USDC, applies router quote (USDC -> token)
     * @param  userRatioOfCrvLps User share ratio scaled by 1e18
     * @param  tokenIndex        DSF token index: 0=DAI, 1=USDC, 2=USDT
     * @return tokenAmount       Estimated token out amount (in token native decimals)
     */
    function calcWithdrawOneCoin(uint256 userRatioOfCrvLps, uint128 tokenIndex)
        external
        view
        override
        returns (uint256 tokenAmount)
    {
        uint256 removingCrvLps = (cvxRewards.balanceOf(address(this)) * userRatioOfCrvLps) / 1e18;

        // First, withdraw USDC from curve pool
        uint256 usdcOut = pool.calc_withdraw_one_coin(removingCrvLps, CURVE_USDC_COIN_ID_INT);

        // If user wants USDC -> return as is
        if (tokenIndex == DSF_USDC_TOKEN_ID) return usdcOut;

        // If user wants DAI/USDT -> estimate via router quote (USDC -> token)
        address[] memory path = new address[](2);
        path[0] = address(_config.tokens[DSF_USDC_TOKEN_ID]);
        path[1] = address(_config.tokens[tokenIndex]);

        uint256[] memory outs = _config.router.getAmountsOut(usdcOut, path);
        return outs[outs.length - 1];
    }

    /**
     * @notice View estimate of how many Curve LP shares would be minted for a given input basket
     * @dev    UI helper only; execution uses real swaps + Curve minMint checks
     *         The estimate normalizes amounts to 1e18 and approximates them as USDC-equivalent
     * @param  tokenAmounts Token amounts in DSF order: [DAI, USDC, USDT]
     * @param  isDeposit    Passed through to Curve `calc_token_amount` to mimic deposit/withdraw pricing branch.
     * @return sharesAmount Estimated Curve LP amount
     */
    function calcSharesAmount(uint256[3] memory tokenAmounts, bool isDeposit)
        external
        view
        override
        returns (uint256 sharesAmount)
    {
        // Rough estimate: treat input as USDC-equivalent sum (normalized), deposit as USDC coin only
        // This is used for UI / previews; execution uses swaps + Curve minMint anyway
        uint256 totalNorm1e18;
        for (uint256 i = 0; i < 3; i++) totalNorm1e18 += tokenAmounts[i] * decimalsMultipliers[i];

        if (totalNorm1e18 == 0) return 0;

        // Convert normalized 1e18 amount back to USDC units for estimation:
        uint256 usdcApprox = totalNorm1e18 / decimalsMultipliers[DSF_USDC_TOKEN_ID];

        uint256[] memory a2 = new uint256[](2);
        a2[0] = usdcApprox;
        a2[1] = 0;

        sharesAmount = pool.calc_token_amount(a2, isDeposit);
    }

    // =============================================================
    // Withdraw (core)
    // =============================================================

    /**
     * @notice Computes if withdrawal requirements can be met and how many LP tokens to remove
     * @dev    Core planning step called by base withdrawal flow
     *         Always models Curve withdrawal as USDC one-coin exit first, then optional swap into requested token(s)
     *
     * @param  withdrawalType      OneCoin for a single token out; otherwise "base basket" mode
     * @param  userRatioOfCrvLps   User share ratio scaled by 1e18
     * @param  tokenAmounts        Minimum desired token amounts in DSF order: [DAI, USDC, USDT]
     * @param  tokenIndex          Token index for OneCoin mode
     * @return success             Whether requirements are satisfiable under current view quotes
     * @return removingCrvLps      LP amount (staked balance proportion) to remove from Convex/Curve
     * @return tokenAmountsDynamic Reserved dynamic array for base contract compatibility
     */
    function calcCrvLps(
        WithdrawalType withdrawalType,
        uint256 userRatioOfCrvLps, // multiplied by 1e18
        uint256[3] memory tokenAmounts,
        uint128 tokenIndex
    )
        internal
        view
        override
        returns (
            bool success,
            uint256 removingCrvLps,
            uint256[] memory tokenAmountsDynamic
        )
    {
        removingCrvLps = (cvxRewards.balanceOf(address(this)) * userRatioOfCrvLps) / 1e18;
        uint256 usdcOut = pool.calc_withdraw_one_coin(removingCrvLps, CURVE_USDC_COIN_ID_INT);

        if (withdrawalType == WithdrawalType.OneCoin) {
            if (tokenIndex == DSF_USDC_TOKEN_ID) {
                success = usdcOut >= tokenAmounts[DSF_USDC_TOKEN_ID];
            } else {
                address[] memory path = new address[](2);
                path[0] = address(_config.tokens[DSF_USDC_TOKEN_ID]);
                path[1] = address(_config.tokens[tokenIndex]);
                uint256[] memory outs = _config.router.getAmountsOut(usdcOut, path);
                success = outs[outs.length - 1] >= tokenAmounts[tokenIndex];
            }
        } else {
            // Basket mode: enforce USDC floor strictly, DAI/USDT via soft quote checks
            success = usdcOut >= tokenAmounts[DSF_USDC_TOKEN_ID];

            // (Soft checks for DAI/USDT mins: not perfect, but prevents obvious failures)
            if (success && tokenAmounts[DSF_DAI_TOKEN_ID] > 0) {
                address[] memory path = new address[](2);
                path[0] = address(_config.tokens[DSF_USDC_TOKEN_ID]);
                path[1] = address(_config.tokens[DSF_DAI_TOKEN_ID]);
                uint256[] memory outs = _config.router.getAmountsOut(usdcOut, path);
                success = outs[outs.length - 1] >= tokenAmounts[DSF_DAI_TOKEN_ID];
            }
            if (success && tokenAmounts[DSF_USDT_TOKEN_ID] > 0) {
                address[] memory path = new address[](2);
                path[0] = address(_config.tokens[DSF_USDC_TOKEN_ID]);
                path[1] = address(_config.tokens[DSF_USDT_TOKEN_ID]);
                uint256[] memory o1 = _config.router.getAmountsOut(usdcOut, path);
                success = o1[o1.length - 1] >= tokenAmounts[DSF_USDT_TOKEN_ID];
            }
        }

        tokenAmountsDynamic = new uint256[](1);
        tokenAmountsDynamic[0] = 0;
    }

    /**
     * @notice Executes Curve one-coin withdrawal to USDC and optional swaps into requested tokens
     * @dev    Always removes liquidity from Curve as USDC
     *         - OneCoin mode: swaps only enough USDC to meet required minOut for the chosen token
     *         - Basket mode: swaps best-effort for DAI and USDT mins, leaves remaining USDC
     *
     * @param  removingCrvLps      LP amount to remove (Curve LP units)
     * @param  tokenAmountsDynamic Reserved dynamic args for base compatibility
     * @param  withdrawalType      OneCoin vs basket mode
     * @param  tokenAmounts        Minimum desired token amounts in DSF order: [DAI, USDC, USDT]
     * @param  tokenIndex          Token index for OneCoin mode
     */
    function removeCrvLps(
        uint256 removingCrvLps,
        uint256[] memory tokenAmountsDynamic,
        WithdrawalType withdrawalType,
        uint256[3] memory tokenAmounts,
        uint128 tokenIndex
    ) internal override {
        // Always remove as USDC from Curve pool
        pool.remove_liquidity_one_coin(removingCrvLps, CURVE_USDC_COIN_ID_INT, 0);

        if (withdrawalType == WithdrawalType.OneCoin) {
            if (tokenIndex == DSF_USDC_TOKEN_ID) {
                // keep USDC as is; transferAllTokensOut will send it out
                return;
            }

            // Swap a portion of USDC -> requested token, ensuring at least tokenAmounts[tokenIndex]
            uint256 usdcBal = _config.tokens[DSF_USDC_TOKEN_ID].balanceOf(address(this));
            if (usdcBal == 0) return;

            address[] memory path = new address[](2);
            path[0] = address(_config.tokens[DSF_USDC_TOKEN_ID]);
            path[1] = address(_config.tokens[tokenIndex]);

            uint256[] memory outsFull = _config.router.getAmountsOut(usdcBal, path);
            uint256 maxOut = outsFull[outsFull.length - 1];
            require(maxOut >= tokenAmounts[tokenIndex], "swap:insufficient");

            // swap only what is needed (approx): usdcToSwap ~= usdcBal * minOut / maxOut
            uint256 usdcToSwap = (usdcBal * tokenAmounts[tokenIndex]) / maxOut;
            if (usdcToSwap == 0) usdcToSwap = usdcBal; // fallback

            _config.tokens[DSF_USDC_TOKEN_ID].forceApprove(address(_config.router), usdcToSwap);
            _config.router.swapExactTokensForTokens(
                usdcToSwap,
                tokenAmounts[tokenIndex],
                path,
                address(this),
                block.timestamp + Constants.TRADE_DEADLINE
            );

            return;
        }

        // Base withdrawal: try to satisfy DAI/USDT mins via USDC swaps (best-effort)
        // Swap to DAI (if requested)
        if (tokenAmounts[DSF_DAI_TOKEN_ID] > 0) {
            _swapFromUsdcToToken(DSF_DAI_TOKEN_ID, tokenAmounts[DSF_DAI_TOKEN_ID]);
        }

        // Swap to USDT (if requested)
        if (tokenAmounts[DSF_USDT_TOKEN_ID] > 0) {
            _swapFromUsdcToToken(DSF_USDT_TOKEN_ID, tokenAmounts[DSF_USDT_TOKEN_ID]);
        }

        // Leave remaining USDC (should satisfy tokenAmounts[USDC] if calcCrvLps checks passed)
    }

    /**
     * @notice Swaps USDC balance into a target token with a required minimum output
     * @dev    Swaps only an estimated portion of USDC needed to satisfy `minOut`
     * Reverts if router quote indicates `minOut` cannot be satisfied with current USDC balance
     * @param  outTokenIndex DSF token index of output token (DAI or USDT)
     * @param  minOut        Required minimum output amount in output token native decimals
     */
    function _swapFromUsdcToToken(uint256 outTokenIndex, uint256 minOut) internal {
        uint256 usdcBal = _config.tokens[DSF_USDC_TOKEN_ID].balanceOf(address(this));
        if (usdcBal == 0) return;

        address[] memory path = new address[](2);
        path[0] = address(_config.tokens[DSF_USDC_TOKEN_ID]);
        path[1] = address(_config.tokens[outTokenIndex]);

        uint256[] memory outsFull = _config.router.getAmountsOut(usdcBal, path);
        uint256 maxOut = outsFull[outsFull.length - 1];
        require(maxOut >= minOut, "swap:insufficient");

        uint256 usdcToSwap = (usdcBal * minOut) / maxOut;
        if (usdcToSwap == 0) usdcToSwap = usdcBal;

        _config.tokens[DSF_USDC_TOKEN_ID].forceApprove(address(_config.router), usdcToSwap);
        _config.router.swapExactTokensForTokens(
            usdcToSwap,
            minOut,
            path,
            address(this),
            block.timestamp + Constants.TRADE_DEADLINE
        );
    }

    // =============================================================
    // withdrawAllSpecific
    // =============================================================

    /**
     * @notice Emergency-style full exit from Curve as USDC
     * @dev    Used by base logic to unwind positions without multi-coin complexity
     * NOTE:   this removes directly from Curve LP balance held by this contract (if any)
     */
    function withdrawAllSpecific() internal override {
        // Remove everything as USDC (simplest, avoids needing RLUSD swaps here)
        uint256 lpBal = poolLP.balanceOf(address(this));
        if (lpBal == 0) return;
        pool.remove_liquidity_one_coin(lpBal, CURVE_USDC_COIN_ID_INT, 0);
    }

    // =============================================================
    // getEfficiencyByIndex UX/UI
    // =============================================================

    /**
     * @notice Estimates deposit and round-trip efficiency for a single token input
     * @dev    View-only helper for UI diagnostics:
     *         - Deposit efficiency: (LP_minted * virtual_price) / input_value
     *         - Round-trip efficiency: input token -> (swap to USDC if needed) -> Curve LP -> withdraw USDC -> swap back (if needed)
     *
     * @param  amount Input amount in token native decimals
     * @param  tokenIndex DSF token index: 0=DAI, 1=USDC, 2=USDT
     * @return depositEfficiency1e18 Efficiency of mint valuation vs. input, scaled by 1e18
     * @return roundTripEfficiency1e18 Estimated round-trip efficiency, scaled by 1e18
     */
    function getEfficiencyByIndex(uint256 amount, uint128 tokenIndex)
        external
        view
        returns (uint256 depositEfficiency1e18, uint256 roundTripEfficiency1e18)
    {
        require(tokenIndex < 3, "bad index");
        require(amount > 0, "amount=0");

        uint256 amountNorm1e18 = amount * decimalsMultipliers[tokenIndex];

        // 1) Estimating how much it will be in USDC after a possible swap
        uint256 usdcIn;

        if (tokenIndex == DSF_USDC_TOKEN_ID) {
            usdcIn = amount;
        } else {
            address[] memory pathIn = new address[](2);
            pathIn[0] = address(_config.tokens[tokenIndex]);
            pathIn[1] = address(_config.tokens[DSF_USDC_TOKEN_ID]);

            uint256[] memory outsIn = _config.router.getAmountsOut(amount, pathIn);
            usdcIn = outsIn[outsIn.length - 1];
        }

        // 2) Curve LP Mint
        uint256[] memory a2 = new uint256[](2);
        a2[0] = usdcIn;
        a2[1] = 0;

        uint256 expectedLp = pool.calc_token_amount(a2, true);
        uint256 lpPrice = pool.get_virtual_price(); // 1e18

        // Deposit cost in "USD 1e18" via LP*virtual_price
        uint256 depositValueUsd1e18 = (expectedLp * lpPrice) / CURVE_PRICE_DENOMINATOR;

        // deposit efficiency = value / input
        depositEfficiency1e18 = (depositValueUsd1e18 * 1e18) / amountNorm1e18;

        // 3) Round-trip: LP -> USDC (Curve view)
        uint256 usdcOut = pool.calc_withdraw_one_coin(expectedLp, CURVE_USDC_COIN_ID_INT);

        // 4) If not USDC — evaluate USDC -> token via router view
        uint256 tokenOut;

        if (tokenIndex == DSF_USDC_TOKEN_ID) {
            tokenOut = usdcOut;
        } else {
            address[] memory pathOut = new address[](2);
            pathOut[0] = address(_config.tokens[DSF_USDC_TOKEN_ID]);
            pathOut[1] = address(_config.tokens[tokenIndex]);

            uint256[] memory outsOut = _config.router.getAmountsOut(usdcOut, pathOut);
            tokenOut = outsOut[outsOut.length - 1];
        }

        uint256 tokenOutNorm1e18 = tokenOut * decimalsMultipliers[tokenIndex];
        roundTripEfficiency1e18 = (tokenOutNorm1e18 * 1e18) / amountNorm1e18;
    }
}
