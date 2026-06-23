// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import "@openzeppelin/contracts/access/Ownable.sol";

interface IRewardManager {
        /// @dev Must be in the same units DSF expects (in your stack it's typically 1e18 "USDT terms").
        function totalHoldings() external view returns (uint256);
    }

/**
 * @title  DSFRewardForwarder
 * @author Andrei Averin — CTO dsf.finance
 *
 * @notice
 * A "plug / stub" strategy intended to be used as a DSF pool strategy when a wrong address
 * (e.g., RewardManager) was mistakenly added into DSF pools and cannot be removed.
 *
 * Goals:
 * 1) Do NOT break DSF global loops:
 *    - DSF.autoCompoundAll()   -> strategy.autoCompound() MUST NOT revert
 *    - DSF.claimAllManagementFee() -> strategy.claimManagementFees() MUST NOT revert
 *    - DSF.totalHoldings() / lpPrice() -> strategy.totalHoldings() MUST NOT revert
 *
 * 2) Prevent DSF from ever moving liquidity into this pool:
 *    - deposit(...) MUST revert
 *    - withdraw(...) MUST revert
 *    - withdrawAll() MUST revert
 *
 * 3) Forward accounting:
 *    - totalHoldings() returns RewardManager.totalHoldings()
 *      so DSF can include RewardManager holdings in its aggregated holdings math (if desired).
 *
 * Safety notes:
 * - This is NOT a yield strategy.
 * - Never set this pool as defaultDepositPid / defaultWithdrawPid.
 * - Never use it in moveFundsBatch sources/receivers.
 *
 * Compatibility:
 * - Matches DSF.sol calls and existing strategy signatures in your codebase
 *   (CurveConvexStratBaseMk2 / CurveConvexExtraStratBaseMk2).
 */
contract DSFRewardForwarder is Ownable {
    /* ───────────────────────── Minimal interfaces ───────────────────────── */

    /**
     * @dev DSF passes IStrategy.WithdrawalType (encoded as uint8).
     *      Having the same enum layout keeps ABI compatibility.
     */
    enum WithdrawalType {
        Base,
        OneCoin
    }

    /* ───────────────────────── Storage ───────────────────────── */

    /// @notice DSF core contract address
    address public immutable dsf;

    /// @notice RewardManager address used for holdings-forwarding
    address public rewardManager;

    /* ───────────────────────── Modifiers ───────────────────────── */

    modifier onlyDSF() {
        require(msg.sender == dsf, "STUB: only DSF");
        _;
    }

    /* ───────────────────────── Constructor / Admin ───────────────────────── */

    constructor(address _dsf, address _rewardManager)  Ownable(msg.sender) {
        require(_dsf != address(0), "STUB: dsf=0");
        require(_rewardManager != address(0), "STUB: rm=0");
        dsf = _dsf;
        rewardManager = _rewardManager;
    }

    /**
     * @notice Update RewardManager address (in case of RM upgrade/migration).
     */
    function setRewardManager(address _rewardManager) external onlyOwner {
        require(_rewardManager != address(0), "STUB: rm=0");
        rewardManager = _rewardManager;
    }

    /* ───────────────────────── DSF strategy API ───────────────────────── */

    /**
     * @notice Called by DSF.autoCompoundAll() in a loop.
     * @dev Must NOT revert.
     */
    function autoCompound() public onlyDSF {
        // no-op
    }

    /**
     * @notice Called by DSF.claimAllManagementFee() in a loop.
     * @dev Must NOT revert.
     */
    function claimManagementFees() public onlyDSF returns (uint256) {
        return 0;
    }

    /**
     * @notice Called by DSF.totalHoldings()/lpPrice() aggregation.
     * @dev Must NOT revert.
     */
    function totalHoldings() public view returns (uint256) {
        try IRewardManager(rewardManager).totalHoldings() returns (uint256 v) {
            return v;
        } catch {
            return 0;
        }
    }

    /**
     * @notice DSF deposit entrypoint.
     * @dev Always reverts to guarantee DSF can never move liquidity into this pool.
     */
    function deposit(uint256[3] memory /*amounts*/) external pure returns (uint256) {
        revert("STUB: deposit disabled");
    }

    /**
     * @notice DSF withdraw entrypoint.
     * @dev Always reverts to guarantee this pool can never be used as a liquidity source/sink.
     */
    function withdraw(
        address /*withdrawer*/,
        uint256 /*userRatioOfCrvLps*/,
        uint256[3] memory /*tokenAmounts*/,
        WithdrawalType /*withdrawalType*/,
        uint128 /*tokenIndex*/
    ) external pure returns (bool) {
        revert("STUB: withdraw disabled");
    }

    /**
     * @notice DSF withdraw-all entrypoint.
     * @dev Always reverts (same rationale as withdraw()).
     */
    function withdrawAll() external pure {
        revert("STUB: withdrawAll disabled");
    }

    /**
     * @notice View helper used by DSF/UI.
     * @dev Stubbed to zero.
     */
    function calcWithdrawOneCoin(uint256 /*lpShares*/, uint128 /*tokenIndex*/)
        external
        pure
        returns (uint256)
    {
        return 0;
    }

    /**
     * @notice View helper used by DSF/UI.
     * @dev Stubbed to zero.
     */
    function calcSharesAmount(uint256[3] memory /*tokenAmounts*/, bool /*isDeposit*/)
        external
        pure
        returns (uint256)
    {
        return 0;
    }

    /* ───────────────────────── Hard safety ───────────────────────── */

    receive() external payable {
        revert("STUB: no ETH");
    }
}
