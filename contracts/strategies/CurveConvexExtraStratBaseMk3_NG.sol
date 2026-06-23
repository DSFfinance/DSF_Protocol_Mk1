//SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../utils/Constants.sol";
import "../interfaces/ICurvePool_Mk3.sol";
import "../interfaces/IConvexExtraRewardPool.sol";
import "./CurveConvexStratBaseMk3_NG.sol";

/**
 * @title  CurveConvexExtraStratBaseMk3_NG
 * @notice Extension layer over `CurveConvexStratBaseMk3_NG` adding support for an optional extra reward token
 */
abstract contract CurveConvexExtraStratBaseMk3_NG is Context, CurveConvexStratBaseMk3_NG {
    using SafeERC20 for IERC20Metadata;

    uint256 public constant DSF_EXTRA_TOKEN_ID = 3;

    IERC20Metadata public token;
    IERC20Metadata[] public extraTokens;
    IConvexExtraRewardPool[] public extraRewards;

    event ExtraRewardPairAdded(address indexed extraRewardsAddr, address indexed extraTokenAddr);
    event ExtraRewardPairRemoved(address indexed extraRewardsAddr, address indexed extraTokenAddr);

    constructor(
        Config memory config,
        address poolLPAddr,
        address rewardsAddr,
        uint256 poolPID,
        address tokenAddr,
        address extraRewardsAddr,
        address extraTokenAddr
    ) CurveConvexStratBaseMk3_NG(config, poolLPAddr, rewardsAddr, poolPID) {
        token = IERC20Metadata(tokenAddr);

        if (extraRewardsAddr != address(0) && extraTokenAddr != address(0)) {
            _addExtraRewardPair(extraRewardsAddr, extraTokenAddr);
        }

        // keep DSF_EXTRA_TOKEN_ID semantics as in original (dust accounting for token)
        decimalsMultipliers[DSF_EXTRA_TOKEN_ID] = calcTokenDecimalsMultiplier(token);
    }

    /**
     * @notice Returns total holdings value normalized to DSF "USD 1e18" units (same convention as base)
     * @dev    Composition:
     *         - Base holdings from `CurveConvexStratBaseMk3_NG` (LP + CRV/CVX + USDT, etc)
     *         - Plus: all configured extra rewards valued in USDT
     *         - For each extra reward pair:
     *              - current extra token balance
     *              - pending rewards from `earned(address(this))`
     *              - valuation through router path:
     *                    extraToken -> WETH -> USDT
     *         - Plus: `token` dust balance valued using DSF_EXTRA_TOKEN_ID multiplier
     *
     *         Broken extra reward pools are ignored individually via try/catch.
     *
     * @return Total holdings value in normalized 1e18 units (DSF internal accounting convention)
     */
    function totalHoldings() public view virtual override returns (uint256) {
        uint256 extraEarningsUSDT = 0;

        uint256 len = extraTokens.length;

        for (uint256 i = 0; i < len; i++) {
            uint256 amountIn = extraTokens[i].balanceOf(address(this));

            try extraRewards[i].earned(address(this)) returns (uint256 earnedAmount) {
                amountIn += earnedAmount;
            } catch {
                // ignore broken extra reward pool
            }

            if (amountIn > 0) {
                address[] memory path = new address[](3);
                path[0] = address(extraTokens[i]);
                path[1] = Constants.WETH_ADDRESS;
                path[2] = Constants.USDT_ADDRESS;

                extraEarningsUSDT += priceTokenByExchange(amountIn, path);
            }
        }

        uint256 extraNetUSDT = extraEarningsUSDT;
        if (extraNetUSDT > 0) {
            uint256 feeUSDT = DSF.calcManagementFee(extraNetUSDT);
            extraNetUSDT = (feeUSDT < extraNetUSDT) ? (extraNetUSDT - feeUSDT) : 0;
        }

        return
            super.totalHoldings() +
            extraNetUSDT *
            decimalsMultipliers[DSF_USDT_TOKEN_ID];
    }

    /**
     * @notice Claims CRV/CVX and all configured extra rewards, then forwards reward tokens to RewardManager
     *
     * @dev    Flow:
     *         - Claims base Convex rewards via `cvxRewards.getReward()`
     *         - Claims all configured extra reward pools
     *         - Pushes CRV to RewardManager
     *         - Pushes CVX to RewardManager
     *         - Pushes all extra reward tokens to RewardManager
     *         Extra reward pool failures are ignored individually via try/catch,
     *         allowing remaining rewards to continue processing.
     *         RewardManager is responsible for further reward processing.
     *
     *         Callable only by DSF core (`onlyDSF`)
     */
    function autoCompound() public virtual override onlyDSF {
        super.autoCompound();

        uint256 len = extraTokens.length;

        for (uint256 i = 0; i < len;) {
            _pushToken(extraTokens[i]);

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Full unwind of the strategy into DSF-supported tokens and transfer to DSF.
     * @dev    Callable only by DSF core (`onlyDSF`)
     */
    function withdrawAll() external virtual onlyDSF {
        try cvxRewards.withdrawAllAndUnwrap(true) {
            // ok
        } catch {
            try cvxRewards.withdrawAllAndUnwrap(false) {
            // ok
            } catch {
                // ignore, continue with any direct LP/tokens
            }
        }

        uint256 len = extraRewards.length;

        for (uint256 i = 0; i < len;) {
            try extraRewards[i].getReward() {} catch {}

            unchecked {
                ++i;
            }
        }

        if (rewardManager != address(0)) {
            _pushToken(_config.crv);
            _pushCvxToManager();

            for (uint256 i = 0; i < len;) {
                _pushToken(extraTokens[i]);

                unchecked {
                    ++i;
                }
            }
        }

        withdrawAllSpecific();

        transferDSFAllTokens();
    }

    /**
     * @notice Strategy-specific full exit hook (implemented by concrete strategies)
     * @dev    Must convert remaining position into DSF-supported tokens ready for `transferDSFAllTokens()`
     */
    function withdrawAllSpecific() internal virtual;

    /**
     * @notice Returns number of configured extra reward pairs
     * @return Number of extra reward/token pairs
     */
    function extraRewardsLength() external view returns (uint256) {
        return extraRewards.length;
    }

    /**
     * @notice Returns extra reward pool and reward token pair by index
     * @param  index Pair index
     * @return extraRewardsAddr Convex/Virtual reward pool address
     * @return extraTokenAddr   Reward token address
     */
    function getExtraRewardPair(uint256 index)
        external
        view
        returns (address extraRewardsAddr, address extraTokenAddr)
    {
        require(index < extraRewards.length, "index out of bounds");

        return (
            address(extraRewards[index]),
            address(extraTokens[index])
        );
    }

    /**
     * @notice Adds a new extra reward pool/token pair
     * @dev    Used for Convex extra rewards such as
     *         VirtualBalanceRewardPool reward distributions.
     *         Reverts if:
     *         - any address is zero
     *         - pair already exists
     * @param  extraRewardsAddr Convex/Virtual reward pool address
     * @param  extraTokenAddr   Reward token address
     */
    function addExtraRewardPair(address extraRewardsAddr, address extraTokenAddr)
        external
        onlyOwner
    {
        _addExtraRewardPair(extraRewardsAddr, extraTokenAddr);
    }

    /**
     * @notice Removes existing extra reward pool/token pair
     * @dev    Uses swap-and-pop removal for gas efficiency.
     *         Reverts if pair does not exist.
     * @param  extraRewardsAddr Convex/Virtual reward pool address
     * @param  extraTokenAddr   Reward token address
     */
    function removeExtraRewardPair(address extraRewardsAddr, address extraTokenAddr)
        external
        onlyOwner
    {
        require(extraRewardsAddr != address(0), "extraRewards zero");
        require(extraTokenAddr != address(0), "extraToken zero");

        uint256 len = extraRewards.length;

        for (uint256 i = 0; i < len; i++) {
            if (
                address(extraRewards[i]) == extraRewardsAddr &&
                address(extraTokens[i]) == extraTokenAddr
            ) {
                uint256 last = len - 1;

                if (i != last) {
                    extraRewards[i] = extraRewards[last];
                    extraTokens[i] = extraTokens[last];
                }

                extraRewards.pop();
                extraTokens.pop();

                emit ExtraRewardPairRemoved(extraRewardsAddr, extraTokenAddr);
                return;
            }
        }

        revert("pair not found");
    }

    /**
     * @dev Internal helper for adding extra reward pool/token pairs
     *      Reverts if:
     *      - any address is zero
     *      - pair already exists
     * @param extraRewardsAddr Convex/Virtual reward pool address
     * @param extraTokenAddr   Reward token address
     */
    function _addExtraRewardPair(address extraRewardsAddr, address extraTokenAddr)
        internal
    {
        require(extraRewardsAddr != address(0), "extraRewards zero");
        require(extraTokenAddr != address(0), "extraToken zero");

        uint256 len = extraRewards.length;

        for (uint256 i = 0; i < len; i++) {
            require(
                !(
                    address(extraRewards[i]) == extraRewardsAddr &&
                    address(extraTokens[i]) == extraTokenAddr
                ),
                "pair exists"
            );
        }

        extraRewards.push(IConvexExtraRewardPool(extraRewardsAddr));
        extraTokens.push(IERC20Metadata(extraTokenAddr));

        emit ExtraRewardPairAdded(extraRewardsAddr, extraTokenAddr);
    }

    function _getExtraRewardsGrossUSDT() internal view virtual override returns (uint256 extraEarningsUSDT) {
        uint256 len = extraTokens.length;

        for (uint256 i = 0; i < len; i++) {
            uint256 amountIn = extraTokens[i].balanceOf(address(this));

            try extraRewards[i].earned(address(this)) returns (uint256 earnedAmount) {
                amountIn += earnedAmount;
            } catch {
                // ignore broken extra reward pool
            }

            if (amountIn > 0) {
                address[] memory path = new address[](3);
                path[0] = address(extraTokens[i]);
                path[1] = Constants.WETH_ADDRESS;
                path[2] = Constants.USDT_ADDRESS;

                extraEarningsUSDT += priceTokenByExchange(amountIn, path);
            }
        }
    }
}
