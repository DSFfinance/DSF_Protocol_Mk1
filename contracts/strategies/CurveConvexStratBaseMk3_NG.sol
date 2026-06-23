//SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../utils/Constants.sol";

import "../interfaces/IUniswapRouter.sol";
import "../interfaces/IConvexMinter.sol";
import "../interfaces/IDSF.sol";
import "../interfaces/IConvexBooster.sol";
import "../interfaces/IConvexBaseRewardPool.sol";

abstract contract CurveConvexStratBaseMk3_NG is Ownable {
    using SafeERC20 for IERC20Metadata;
    using SafeERC20 for IConvexMinter;

    /// @notice Withdrawal modes: Base (basket) or OneCoin (single token out)
    enum WithdrawalType {
        Base,
        OneCoin
    }

    struct Config {
        IERC20Metadata[3] tokens;
        IERC20Metadata crv;
        IConvexMinter cvx;
        IUniswapRouter router;
        IConvexBooster booster;
        address[] cvxToUsdtPath;
        address[] crvToUsdtPath;
    }

    Config internal _config;

    IDSF public DSF;

    address public rewardManager;

    uint256 public constant UNISWAP_USD_MULTIPLIER = 1e12;
    uint256 public constant CURVE_PRICE_DENOMINATOR = 1e18;
    uint256 public constant DEPOSIT_DENOMINATOR = 10000;
    uint256 public constant DSF_DAI_TOKEN_ID = 0;
    uint256 public constant DSF_USDC_TOKEN_ID = 1;
    uint256 public constant DSF_USDT_TOKEN_ID = 2;

    uint256 public minDepositAmount = 9975; // 99.75%
    uint256 public swapSlippageBps = 9975;  // 99.75%
    address public feeDistributor;

    bool public autoCompoundEnabled = true;
    uint256 public managementFees = 0;

    IERC20Metadata public poolLP;
    IConvexBaseRewardPool public cvxRewards;
    uint256 public cvxPoolPID;

    uint256[4] public decimalsMultipliers;
    uint256 public minRewardToSell = 10 * 1e6; // 10 USDT

    event SlippageUpdated(uint256 oldBps, uint256 newBps);
    event AutoCompoundToggled(bool enabled);
    event RouterUpdated(address indexed oldRouter, address indexed newRouter);

    event SoldRewards(uint256 cvxBalance, uint256 crvBalance, uint256 extraBalance);

    event RewardManagerUpdated(address indexed oldManager, address indexed newManager);

    event ManagerCompounded(uint256 usdtAmount, uint256 lpMinted);

    event StrategyDepositExecuted(
        uint256[3] amounts,
        uint256 poolLPsMinted,
        uint256 valueAddedUSDT
    );

    event StrategyWithdrawExecuted(
        address indexed withdrawer,
        uint256 removingCrvLps,
        uint256[3] actualOut
    );

    /**
     * @notice Restricts a call to DSF core contract only
     * @dev    Used for withdrawals and DSF-managed operations
     */
    modifier onlyDSF() {
        require(_msgSender() == address(DSF), "must be called by DSF contract");
        _;
    }

    /**
     * @notice Allows execution only by RewardManager
     * @dev    Reverts if caller is not `rewardManager`
     */
    modifier onlyRewardManager() {
        require(_msgSender() == rewardManager, "only rewardManager");
        _;
    }

    constructor(Config memory config_, address poolLPAddr, address rewardsAddr, uint256 poolPID)
        Ownable(_msgSender())
    {
        _config = config_;

        for (uint256 i; i < 3; i++) {
            decimalsMultipliers[i] = calcTokenDecimalsMultiplier(_config.tokens[i]);
        }

        cvxPoolPID = poolPID;
        poolLP = IERC20Metadata(poolLPAddr);
        cvxRewards = IConvexBaseRewardPool(rewardsAddr);
        feeDistributor = _msgSender();
    }

    /**
     * @notice Returns the current strategy config struct
     * @dev Intended for UI/monitoring; paths may be long arrays
     */
    function config() external view returns (Config memory) {
        return _config;
    }

    /**
     * @notice DSF-facing deposit entrypoint
     * @dev    Returns deposited value in "USD 1e18" units as `mintedLP * virtual_price`
     *         If `checkDepositSuccessful(...)` fails, returns 0 and performs no state changes
     *
     * @param  amounts Token amounts in DSF order: [DAI, USDC, USDT]
     * @return usdValue1e18 Estimated deposited value using Curve virtual price
     */
    function deposit(uint256[3] memory amounts) external onlyDSF returns (uint256) {
        if (!checkDepositSuccessful(amounts)) {
            return 0;
        }

        uint256 poolLPs = depositPool(amounts);

        uint256 valueAdded = (poolLPs * getCurvePoolPrice()) / CURVE_PRICE_DENOMINATOR;

        emit StrategyDepositExecuted(
            amounts,
            poolLPs,
            valueAdded
        );

        return valueAdded;
    }

    function checkDepositSuccessful(uint256[3] memory amounts) internal view virtual returns (bool);

    function depositPool(uint256[3] memory amounts) internal virtual returns (uint256);

    function getCurvePoolPrice() internal view virtual returns (uint256);

    function transferAllTokensOut(address withdrawer, uint256[] memory prevBalances) internal {
        uint256 transferAmount;
        for (uint256 i = 0; i < 3; i++) {
            transferAmount =
                _config.tokens[i].balanceOf(address(this)) -
                prevBalances[i] -
                ((i == DSF_USDT_TOKEN_ID) ? managementFees : 0);
            if (transferAmount > 0) {
                _config.tokens[i].safeTransfer(withdrawer, transferAmount);
            }
        }
    }

    function transferDSFAllTokens() internal {
        for (uint256 i = 0; i < 3; i++) {
            uint256 bal = _config.tokens[i].balanceOf(address(this));

            if (i == DSF_USDT_TOKEN_ID) {
                if (bal <= managementFees) continue;
                bal -= managementFees;
            }

            if (bal > 0) {
                _config.tokens[i].safeTransfer(_msgSender(), bal);
            }
        }
    }

    function calcWithdrawOneCoin(uint256 sharesAmount, uint128 tokenIndex)
        external
        view
        virtual
        returns (uint256 tokenAmount);

    function calcSharesAmount(uint256[3] memory tokenAmounts, bool isDeposit)
        external
        view
        virtual
        returns (uint256 sharesAmount);

    /**
     * @notice DSF-facing withdraw entrypoint (DSF-only)
     * @dev Flow:
     * - Computes required LP to unwrap via `calcCrvLps(...)` (strategy-specific)
     * - Unwraps from Convex.
     * - Executes pool-specific exit + optional swaps via `removeCrvLps(...)`
     * - Transfers net token deltas to `withdrawer` (excludes `managementFees` from USDT)
     *
     * @param withdrawer User receiving funds
     * @param userRatioOfCrvLps User share ratio in 1e18 (0 < r <= 1e18)
     * @param tokenAmounts Minimum desired amounts in DSF order: [DAI, USDC, USDT]
     * @param withdrawalType Base (basket) or OneCoin (single token)
     * @param tokenIndex Token index for OneCoin mode
     * @return success True if requirements are satisfiable under strategy checks and execution completed
     */
    function withdraw(
        address withdrawer,
        uint256 userRatioOfCrvLps, // multiplied by 1e18
        uint256[3] memory tokenAmounts,
        WithdrawalType withdrawalType,
        uint128 tokenIndex
    ) external virtual onlyDSF returns (bool) {
        require(userRatioOfCrvLps > 0 && userRatioOfCrvLps <= 1e18, "Wrong lp Ratio");
        (bool success, uint256 removingCrvLps, uint256[] memory tokenAmountsDynamic) =
            calcCrvLps(withdrawalType, userRatioOfCrvLps, tokenAmounts, tokenIndex);

        if (!success) {
            return false;
        }

        uint256[] memory prevBalances = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            prevBalances[i] =
                _config.tokens[i].balanceOf(address(this)) -
                ((i == DSF_USDT_TOKEN_ID) ? managementFees : 0);
        }

        cvxRewards.withdrawAndUnwrap(removingCrvLps, false);

        removeCrvLps(removingCrvLps, tokenAmountsDynamic, withdrawalType, tokenAmounts, tokenIndex);

        uint256[3] memory actualOut;

        for (uint256 i = 0; i < 3; i++) {
            uint256 balNet =
                _config.tokens[i].balanceOf(address(this)) -
                ((i == DSF_USDT_TOKEN_ID) ? managementFees : 0);

            if (balNet > prevBalances[i]) {
                actualOut[i] = balNet - prevBalances[i];
            }
        }

        emit StrategyWithdrawExecuted(
            withdrawer,
            removingCrvLps,
            actualOut
        );

        transferAllTokensOut(withdrawer, prevBalances);

        return true;
    }

    function calcCrvLps(
        WithdrawalType withdrawalType,
        uint256 userRatioOfCrvLps, // multiplied by 1e18
        uint256[3] memory tokenAmounts,
        uint128 tokenIndex
    )
        internal
        virtual
        returns (bool success, uint256 removingCrvLps, uint256[] memory tokenAmountsDynamic);

    function removeCrvLps(
        uint256 removingCrvLps,
        uint256[] memory tokenAmountsDynamic,
        WithdrawalType withdrawalType,
        uint256[3] memory tokenAmounts,
        uint128 tokenIndex
    ) internal virtual;

    function calcTokenDecimalsMultiplier(IERC20Metadata token) internal view returns (uint256) {
        uint8 decimals = token.decimals();
        require(decimals <= 18, "DSF: wrong token decimals");
        if (decimals == 18) return 1;
        return 10 ** (18 - decimals);
    }

    /**
     * @notice DSF-triggered auto-compound: claim Convex rewards, sell into USDT, and reinvest USDT
     * @dev DSF-only. Reinvests USDT balance excluding `managementFees`
     * Strategy-specific reinvest logic is inside `depositPool(...)`
     */
    function autoCompound() public virtual onlyDSF {
        require(autoCompoundEnabled, "autocompound disabled");
        require(rewardManager != address(0), "rewardManager not set");
        
        // claim rewards
        try cvxRewards.getReward(address(this), true) {
            // ok
        } catch {
            return;
        }

        // send reward tokens to RewardManager 
        _pushToken(_config.crv);
        _pushCvxToManager();
    }

    function managerCompound(uint256 amount) external onlyRewardManager {
        require(autoCompoundEnabled, "autocompound disabled");
        require(amount > 0, "zero amount");

        // pull USDT from RM (RM must approve strategy)
        _config.tokens[DSF_USDT_TOKEN_ID].safeTransferFrom(rewardManager, address(this), amount);

        uint256[3] memory amounts;
        amounts[DSF_USDT_TOKEN_ID] = amount;
        
        uint256 lpMinted = depositPool(amounts);

        emit ManagerCompounded(amount, lpMinted);
    }

    function _pushToken(IERC20Metadata t) internal {
        uint256 bal = t.balanceOf(address(this));
        if (bal > 0) {
            t.safeTransfer(rewardManager, bal);
        }
    }

    function _pushCvxToManager() internal {
        uint256 bal = _config.cvx.balanceOf(address(this)); // if the interface has balanceOf
        if (bal > 0) {
            _config.cvx.safeTransfer(rewardManager, bal);
        }
    }

    /**
     * @dev   Returns total holdings value normalized to DSF "USD 1e18" units
     *        - Staked LP value via `balanceOf * virtual_price`
     *        - Pending and held CRV/CVX valued via router quotes
     *        - On-contract stable balances (DAI/USDC/USDT) normalized via `decimalsMultipliers`
     */
    function totalHoldings() public view virtual returns (uint256) {
        uint256 crvLpHoldings =
            (cvxRewards.balanceOf(address(this)) * getCurvePoolPrice()) / CURVE_PRICE_DENOMINATOR;

        uint256 crvEarned = cvxRewards.earned(address(this));

        uint256 cvxTotalCliffs = _config.cvx.totalCliffs();
        uint256 rpc = _config.cvx.reductionPerCliff();
        uint256 cliff = rpc == 0 ? 0 : _config.cvx.totalSupply() / rpc;

        uint256 cvxRemainCliffs = cliff < cvxTotalCliffs ? (cvxTotalCliffs - cliff) : 0;

        uint256 amountIn =
            (cvxTotalCliffs == 0)
                ? _config.cvx.balanceOf(address(this))
                : (crvEarned * cvxRemainCliffs) / cvxTotalCliffs + _config.cvx.balanceOf(address(this));

        uint256 cvxEarningsUSDT = priceTokenByExchange(amountIn, _config.cvxToUsdtPath);

        amountIn = crvEarned + _config.crv.balanceOf(address(this));
        uint256 crvEarningsUSDT = priceTokenByExchange(amountIn, _config.crvToUsdtPath);

        // ==== NET pending rewards (fee is taken from TOTAL income) ====
        uint256 rewardsGrossUSDT = cvxEarningsUSDT + crvEarningsUSDT;

        if (rewardsGrossUSDT > 0) {
            uint256 feeUSDT = DSF.calcManagementFee(rewardsGrossUSDT);
            if (feeUSDT < rewardsGrossUSDT) {
                rewardsGrossUSDT -= feeUSDT;
            } else {
                rewardsGrossUSDT = 0;
            }
        }

        uint256 tokensHoldings = 0;
        for (uint256 i = 0; i < 3; i++) {
            tokensHoldings += _config.tokens[i].balanceOf(address(this)) * decimalsMultipliers[i];
        }

        return 
            tokensHoldings + 
            crvLpHoldings + 
            rewardsGrossUSDT * decimalsMultipliers[DSF_USDT_TOKEN_ID];
    }

    function priceTokenByExchange(uint256 amountIn, address[] memory path)
        internal
        view
        returns (uint256)
    {
        if (amountIn == 0) return 0;
        if (path.length < 2) return 0;

        try _config.router.getAmountsOut(amountIn, path) returns (uint256[] memory amounts) {
            // must have at least one element and match the route steps
            if (amounts.length == 0) return 0;
            if (amounts.length < path.length) return 0;

            return amounts[amounts.length - 1];
        } catch {
            return 0;
        }
    }

    function _getExtraRewardsGrossUSDT() internal view virtual returns (uint256) {
        return 0;
    }

    function getCVXCRVHoldingsGross()
        external
        view
        returns (
            uint256 amountIn_cvx,
            uint256 amountIn_crv,
            uint256 cvxEarningsUSDT,
            uint256 crvEarningsUSDT,
            uint256 extraEarningsUSDT
        )
    {
        uint256 crvEarned = cvxRewards.earned(address(this));

        uint256 cvxTotalCliffs = _config.cvx.totalCliffs();
        uint256 rpc = _config.cvx.reductionPerCliff();
        uint256 cliff = rpc == 0 ? 0 : _config.cvx.totalSupply() / rpc;

        uint256 cvxRemainCliffs = cliff < cvxTotalCliffs ? (cvxTotalCliffs - cliff) : 0;

        amountIn_cvx =
            (cvxTotalCliffs == 0)
                ? _config.cvx.balanceOf(address(this))
                : (crvEarned * cvxRemainCliffs) / cvxTotalCliffs + _config.cvx.balanceOf(address(this));

        amountIn_crv = crvEarned + _config.crv.balanceOf(address(this));

        cvxEarningsUSDT = (amountIn_cvx == 0) ? 0 : priceTokenByExchange(amountIn_cvx, _config.cvxToUsdtPath);
        crvEarningsUSDT = (amountIn_crv == 0) ? 0 : priceTokenByExchange(amountIn_crv, _config.crvToUsdtPath);

        extraEarningsUSDT = _getExtraRewardsGrossUSDT();
    }

    function getCVXCRVHoldings()
        external
        view
        returns (
            uint256 amountIn_cvx,
            uint256 amountIn_crv,
            uint256 cvxEarningsUSDT,
            uint256 crvEarningsUSDT,
            uint256 extraEarningsUSDT
        )
    {
        uint256 crvEarned = cvxRewards.earned(address(this));

        uint256 cvxTotalCliffs = _config.cvx.totalCliffs();
        uint256 rpc = _config.cvx.reductionPerCliff();
        uint256 cliff = rpc == 0 ? 0 : _config.cvx.totalSupply() / rpc;

        uint256 cvxRemainCliffs = cliff < cvxTotalCliffs ? (cvxTotalCliffs - cliff) : 0;

        uint256 amountIn_cvx_gross =
            (cvxTotalCliffs == 0)
                ? _config.cvx.balanceOf(address(this))
                : (crvEarned * cvxRemainCliffs) / cvxTotalCliffs + _config.cvx.balanceOf(address(this));

        uint256 amountIn_crv_gross = crvEarned + _config.crv.balanceOf(address(this));

        // ---- gross USDT estimates ----
        uint256 cvxGrossUSDT =
            (amountIn_cvx_gross == 0) ? 0 : priceTokenByExchange(amountIn_cvx_gross, _config.cvxToUsdtPath);

        uint256 crvGrossUSDT =
            (amountIn_crv_gross == 0) ? 0 : priceTokenByExchange(amountIn_crv_gross, _config.crvToUsdtPath);

        // Extra rewards may consist of heterogeneous tokens,
        // therefore only USDT-normalized valuation is exposed.
        uint256 extraGrossUSDT = _getExtraRewardsGrossUSDT();

        uint256 totalGrossUSDT = cvxGrossUSDT + crvGrossUSDT + extraGrossUSDT;

        // defaults
        amountIn_cvx = amountIn_cvx_gross;
        amountIn_crv = amountIn_crv_gross;
        cvxEarningsUSDT = cvxGrossUSDT;
        crvEarningsUSDT = crvGrossUSDT;
        extraEarningsUSDT = extraGrossUSDT;

        if (totalGrossUSDT == 0) return (amountIn_cvx, amountIn_crv, cvxEarningsUSDT, crvEarningsUSDT, extraEarningsUSDT);

        // Fee is taken from TOTAL income
        uint256 totalFeeUSDT = DSF.calcManagementFee(totalGrossUSDT);

        // extreme safety case
        if (totalFeeUSDT >= totalGrossUSDT) return (0, 0, 0, 0, 0);

        // proportional split (keeps rounding consistent)
        uint256 feeCvxUSDT = (totalFeeUSDT * cvxGrossUSDT) / totalGrossUSDT;
        uint256 feeCrvUSDT = (totalFeeUSDT * crvGrossUSDT) / totalGrossUSDT;
        uint256 feeExtraUSDT = totalFeeUSDT - feeCvxUSDT - feeCrvUSDT;
        
        // NET USDT
        cvxEarningsUSDT = (feeCvxUSDT >= cvxGrossUSDT)
                                ? 0
                                : (cvxGrossUSDT - feeCvxUSDT);
        crvEarningsUSDT = (feeCrvUSDT >= crvGrossUSDT)
                                ? 0
                                : (crvGrossUSDT - feeCrvUSDT);
        extraEarningsUSDT = (feeExtraUSDT >= extraGrossUSDT)
                                ? 0
                                : (extraGrossUSDT - feeExtraUSDT);

        // Convert fee (USDT) back to tokens using spot ratio:
        // feeTokens = feeUSDT * grossTokens / grossUSDT
        if (feeCvxUSDT > 0 && cvxGrossUSDT > 0 && amountIn_cvx_gross > 0) {
            uint256 feeCvxTokens = (feeCvxUSDT * amountIn_cvx_gross) / cvxGrossUSDT;
            amountIn_cvx = (feeCvxTokens >= amountIn_cvx_gross) ? 0 : (amountIn_cvx_gross - feeCvxTokens);
        }

        if (feeCrvUSDT > 0 && crvGrossUSDT > 0 && amountIn_crv_gross > 0) {
            uint256 feeCrvTokens = (feeCrvUSDT * amountIn_crv_gross) / crvGrossUSDT;
            amountIn_crv = (feeCrvTokens >= amountIn_crv_gross) ? 0 : (amountIn_crv_gross - feeCrvTokens);
        }

        return (amountIn_cvx, amountIn_crv, cvxEarningsUSDT, crvEarningsUSDT, extraEarningsUSDT);
    }

    /// @notice Claims accrued `managementFees` (USDT) to `feeDistributor` and resets it to zero
    function claimManagementFees() public returns (uint256) {
        uint256 usdtBalance = _config.tokens[DSF_USDT_TOKEN_ID].balanceOf(address(this));
        uint256 transferBalance = managementFees > usdtBalance ? usdtBalance : managementFees;
        if (transferBalance > 0) {
            _config.tokens[DSF_USDT_TOKEN_ID].safeTransfer(feeDistributor, transferBalance);
        }
        managementFees = 0;

        return transferBalance;
    }

    /**
     * @dev   dev can update minDepositAmount but it can't be higher than 10000 (100%)
     *        If user send deposit tx and get deposit amount lower than minDepositAmount than deposit tx failed
     * @param _minDepositAmount - amount which must be the minimum (%) after the deposit, min amount 1, max amount 10000
     */
    function updateMinDepositAmount(uint256 _minDepositAmount) public onlyOwner {
        require(_minDepositAmount > 0 && _minDepositAmount <= 10000, "Wrong amount!");
        minDepositAmount = _minDepositAmount;
    }

    /**
     * @dev   disable renounceOwnership for safety
     */
    function renounceOwnership() public view override onlyOwner {
        revert("The strategy must have an owner");
    }

    /**
     * @dev   dev set DSF (main contract) address
     * @param DSFAddr - address of main contract (DSF)
     */
    function setDSF(address DSFAddr) external onlyOwner {
        DSF = IDSF(DSFAddr);
    }

    function setRouter(address newRouter) external onlyOwner {
        require(newRouter != address(0), "router is zero");
        address old = address(_config.router);
        _config.router = IUniswapRouter(newRouter);
        emit RouterUpdated(old, newRouter);
    }

    function setRewardManager(address newManager) external onlyOwner {
        require(newManager != address(0), "zero addr");
        emit RewardManagerUpdated(rewardManager, newManager);
        rewardManager = newManager;
    }

    /**
     * @notice update allowable slippage when welding CVX/CRV → USDT
     * @param  _newBps value in bps: 1 ... 10 000 (10 000 = 100%)
     */
    function updateSwapSlippageBps(uint256 _newBps) external onlyOwner {
        require(_newBps > 0 && _newBps <= 10_000, "Wrong bps");
        uint256 old = swapSlippageBps;
        swapSlippageBps = _newBps;
        emit SlippageUpdated(old, _newBps);
    }

    /**
     * @notice enable/disable auto-compound (in case of emergency stop)
     */
    function toggleAutoCompound(bool _enable) external onlyOwner {
        autoCompoundEnabled = _enable;
        emit AutoCompoundToggled(_enable);
    }

    /**
     * @notice Owner can update minimum USDT-equivalent value of CVX to sell
     * @param  _minRewardToSell Minimum amount in USDT token units (6 decimals)
     */
    function updateMinRewardToSell(uint256 _minRewardToSell) external onlyOwner {
        minRewardToSell = _minRewardToSell;
    }

    /**
     * @dev    governance can withdraw all stuck funds in emergency case
     * @param  _token - IERC20Metadata token that should be fully withdraw from Strategy
     */
    function withdrawStuckToken(IERC20Metadata _token) external onlyOwner {
        uint256 tokenBalance = _token.balanceOf(address(this));
        if (tokenBalance > 0) {
            _token.safeTransfer(_msgSender(), tokenBalance);
        }
    }

    /**
     * @dev     governance can set feeDistributor address for distribute protocol fees
     * @param  _feeDistributor - address feeDistributor that be used for claim fees
     */
    function changeFeeDistributor(address _feeDistributor) external onlyOwner {
        feeDistributor = _feeDistributor;
    }

    function toArr2(uint256[] memory arrInf) internal pure returns (uint256[2] memory arr) {
        arr[0] = arrInf[0];
        arr[1] = arrInf[1];
    }

    function fromArr2(uint256[2] memory arr) internal pure returns (uint256[] memory arrInf) {
        arrInf = new uint256[](2);
        arrInf[0] = arr[0];
        arrInf[1] = arr[1];
    }

    function toArr3(uint256[] memory arrInf) internal pure returns (uint256[3] memory arr) {
        arr[0] = arrInf[0];
        arr[1] = arrInf[1];
        arr[2] = arrInf[2];
    }

    function fromArr3(uint256[3] memory arr) internal pure returns (uint256[] memory arrInf) {
        arrInf = new uint256[](3);
        arrInf[0] = arr[0];
        arrInf[1] = arr[1];
        arrInf[2] = arr[2];
    }

    function toArr4(uint256[] memory arrInf) internal pure returns (uint256[4] memory arr) {
        arr[0] = arrInf[0];
        arr[1] = arrInf[1];
        arr[2] = arrInf[2];
        arr[3] = arrInf[3];
    }

    function fromArr4(uint256[4] memory arr) internal pure returns (uint256[] memory arrInf) {
        arrInf = new uint256[](4);
        arrInf[0] = arr[0];
        arrInf[1] = arr[1];
        arrInf[2] = arr[2];
        arrInf[3] = arr[3];
    }
}
