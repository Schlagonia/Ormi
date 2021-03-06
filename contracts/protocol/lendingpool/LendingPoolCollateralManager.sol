// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.6.12;

import {SafeMath} from '../../dependencies/openzeppelin/contracts//SafeMath.sol';
import {IERC20} from '../../dependencies/openzeppelin/contracts//IERC20.sol';
import {IAToken} from '../../interfaces/IAToken.sol';
import {IStableDebtToken} from '../../interfaces/IStableDebtToken.sol';
import {IVariableDebtToken} from '../../interfaces/IVariableDebtToken.sol';
import {IPriceOracleGetter} from '../../interfaces/IPriceOracleGetter.sol';
import {ILendingPoolCollateralManager} from '../../interfaces/ILendingPoolCollateralManager.sol';
import {VersionedInitializable} from '../libraries/aave-upgradeability/VersionedInitializable.sol';
import {GenericLogic} from '../libraries/logic/GenericLogic.sol';
import {Helpers} from '../libraries/helpers/Helpers.sol';
import {WadRayMath} from '../libraries/math/WadRayMath.sol';
import {PercentageMath} from '../libraries/math/PercentageMath.sol';
import {SafeERC20} from '../../dependencies/openzeppelin/contracts/SafeERC20.sol';
import {Errors} from '../libraries/helpers/Errors.sol';
import {ValidationLogic} from '../libraries/logic/ValidationLogic.sol';
import {DataTypes} from '../libraries/types/DataTypes.sol';
import {LendingPoolStorage} from './LendingPoolStorage.sol';

/**
 * @title LendingPoolCollateralManager contract
 * @author Aave
 * @dev Implements actions involving management of collateral in the protocol, the main one being the liquidations
 * IMPORTANT This contract will run always via DELEGATECALL, through the LendingPool, so the chain of inheritance
 * is the same as the LendingPool, to have compatible storage layouts
 **/
contract LendingPoolCollateralManager is
  ILendingPoolCollateralManager,
  VersionedInitializable,
  LendingPoolStorage
{
  using SafeERC20 for IERC20;
  using SafeMath for uint256;
  using WadRayMath for uint256;
  using PercentageMath for uint256;

  //ideally should update address provider to be able to return the address
  address coveragePoolAddress;
  uint256 wad = uint256(1e18);

  uint256 internal constant LIQUIDATION_CLOSE_FACTOR_PERCENT = 5000;

  struct LiquidationCallLocalVars {
    uint256 userEthCollateral;
    uint256 userEthDebt;
    uint256 userCollateralBalance;
    uint256 userStableDebt;
    uint256 userVariableDebt;
    uint256 maxLiquidatableDebt;
    uint256 actualDebtToLiquidate;
    uint256 liquidationRatio;
    uint256 maxAmountCollateralToLiquidate;
    uint256 userStableRate;
    uint256 maxCollateralToLiquidate;
    uint256 debtAmountNeeded;
    uint256 coveragePoolLiability;
    uint256 healthFactor;
    uint256 userHealthFactor;
    uint256 ltv;
    uint256 ccr;
    uint256 collateralAllowed;
    uint256 debtAssetPrice;
    uint256 debtDecimals;
    uint256 diff;
    uint256 currentAvailableCollateral;
    uint256 liquidatorPreviousATokenBalance;
    IAToken collateralAtoken;
    bool isCollateralEnabled;
    DataTypes.InterestRateMode borrowRateMode;
    uint256 errorCode;
    string errorMsg;
  }

  /**
   * @dev As thIS contract extends the VersionedInitializable contract to match the state
   * of the LendingPool contract, the getRevision() function is needed, but the value is not
   * important, as the initialize() function will never be called here
   */
  function getRevision() internal pure override returns (uint256) {
    return 0;
  }

  /**
   * @dev Function to liquidate a position if its Health Factor drops below 1
   * - The caller (liquidator) covers `debtToCover` amount of debt of the user getting liquidated, and receives
   *   a proportionally amount of the `collateralAsset` plus a bonus to cover market risk
   * @param collateralAsset The address of the underlying asset used as collateral, to receive as result of the liquidation
   * @param debtAsset The address of the underlying borrowed asset to be repaid with the liquidation
   * @param user The address of the borrower getting liquidated
   * @param debtToCover The debt amount of borrowed `asset` the liquidator wants to cover
   * @param receiveAToken `true` if the liquidators wants to receive the collateral aTokens, `false` if he wants
   * to receive the underlying collateral asset directly
   **/
  function liquidationCall(
    address collateralAsset,
    address debtAsset,
    address user,
    uint256 debtToCover,
    bool receiveAToken
  ) external override returns (uint256, string memory) {
    DataTypes.ReserveData storage collateralReserve = _reserves[collateralAsset];
    DataTypes.ReserveData storage debtReserve = _reserves[debtAsset];
    DataTypes.UserConfigurationMap storage userConfig = _usersConfig[user];
    LiquidationCallLocalVars memory vars;
    vars.coveragePoolLiability = 0;

    (vars.userEthCollateral, vars.userEthDebt, vars.ltv, , vars.healthFactor) = GenericLogic.calculateUserAccountData(
      user,
      _reserves,
      userConfig,
      _reservesList,
      _reservesCount,
      _addressesProvider.getPriceOracle()
    );

    (vars.userStableDebt, vars.userVariableDebt) = Helpers.getUserCurrentDebt(user, debtReserve);

    (vars.errorCode, vars.errorMsg) = ValidationLogic.validateLiquidationCall(
      collateralReserve,
      debtReserve,
      userConfig,
      vars.healthFactor,
      vars.userStableDebt,
      vars.userVariableDebt
    );

    if (Errors.CollateralManagerErrors(vars.errorCode) != Errors.CollateralManagerErrors.NO_ERROR) {
      return (vars.errorCode, vars.errorMsg);
    }

    vars.collateralAtoken = IAToken(collateralReserve.aTokenAddress);

    vars.userCollateralBalance = vars.collateralAtoken.balanceOf(user);

    vars.maxLiquidatableDebt = vars.userStableDebt.add(vars.userVariableDebt).percentMul(
      LIQUIDATION_CLOSE_FACTOR_PERCENT
    );

    vars.actualDebtToLiquidate = debtToCover > vars.maxLiquidatableDebt
      ? vars.maxLiquidatableDebt
      : debtToCover;

    (
      vars.maxCollateralToLiquidate,
      vars.debtAmountNeeded,
      vars.debtAssetPrice,
      vars.debtDecimals
    ) = _calculateAvailableCollateralToLiquidate(
      collateralReserve,
      debtReserve,
      collateralAsset,
      debtAsset,
      vars.actualDebtToLiquidate,
      vars.userCollateralBalance
    );

    // If debtAmountNeeded < actualDebtToLiquidate, there isn't enough
    // collateral to cover the actual amount that is being liquidated, hence we need to either
    // liquidatea a smaller amount or the CP needs to pay part of the remainder
    if(vars.debtAmountNeeded < vars.actualDebtToLiquidate) {

      ////****logic to account for how much the coverage pool is responsible for covering
      vars.userHealthFactor = userConfig.getHealthFactorLiquidationThreshold();

      if(vars.userHealthFactor < wad) {
        //Means they could have underCollat loan. Need to figure how much to determin CP liability

        vars.coveragePoolLiability = vars.actualDebtToLiquidate.sub(vars.debtAmountNeeded); //If undercollaterlized CP will pay the difference in debt

        // Calculate the normal collateral Coverage ratio based of user LTV // ((1 - LTV) / LTV) +1
        vars.ccr = (wad.sub(vars.ltv)).mul(wad).div(vars.ltv).add(wad);
        vars.collateralAllowed = vars.userEthDebt.mul(vars.ccr).div(wad);
        vars.collateralAllowed = vars.collateralAllowed.mul(vars.userHealthFactor).div(wad);

        vars.diff = vars.collateralAllowed.sub(vars.userEthCollateral);
        //--need to adjust diff for price of debt // debtAmount * price / 10 ** (18 + (18 - debt decimals))
        vars.diff = vars.diff.mul(vars.debtAssetPrice).div(10 ** (18 + (18 - vars.debtDecimals)));

        vars.coveragePoolLiability = vars.diff > vars.coveragePoolLiability ? vars.coveragePoolLiability : vars.diff;
        //--Need to determine if this how much we want to pay back since the users allowed health factor should increase

        //Just in case the CP doesnt have enough we want to cover whatever we can
        vars.currentAvailableCollateral = IERC20(debtAsset).balanceOf(coveragePoolAddress);
        if(vars.currentAvailableCollateral < vars.coveragePoolLiability) {
          vars.coveragePoolLiability = vars.currentAvailableCollateral;
          vars.actualDebtToLiquidate = vars.debtAmountNeeded.add(vars.currentAvailableCollateral);
        }

      } else {
        //User isnt auth for underCollat, we need to just liquidate less
        vars.actualDebtToLiquidate = vars.debtAmountNeeded;
      }
    }


    // If the liquidator reclaims the underlying asset, we make sure there is enough available liquidity in the
    // collateral reserve
    if (!receiveAToken) {
      vars.currentAvailableCollateral =  //Reusing variable to avoid stack to deep errors
        IERC20(collateralAsset).balanceOf(address(vars.collateralAtoken));
      if (vars.currentAvailableCollateral < vars.maxCollateralToLiquidate) {
        return (
          uint256(Errors.CollateralManagerErrors.NOT_ENOUGH_LIQUIDITY),
          Errors.LPCM_NOT_ENOUGH_LIQUIDITY_TO_LIQUIDATE
        );
      }
    }

    debtReserve.updateState();

    if (vars.userVariableDebt >= vars.actualDebtToLiquidate) {
      IVariableDebtToken(debtReserve.variableDebtTokenAddress).burn(
        user,
        vars.actualDebtToLiquidate,
        debtReserve.variableBorrowIndex
      );
    } else {
      // If the user doesn't have variable debt, no need to try to burn variable debt tokens
      if (vars.userVariableDebt > 0) {
        IVariableDebtToken(debtReserve.variableDebtTokenAddress).burn(
          user,
          vars.userVariableDebt,
          debtReserve.variableBorrowIndex
        );
      }
      IStableDebtToken(debtReserve.stableDebtTokenAddress).burn(
        user,
        vars.actualDebtToLiquidate.sub(vars.userVariableDebt)
      );
    }

    debtReserve.updateInterestRates(
      debtAsset,
      debtReserve.aTokenAddress,
      vars.actualDebtToLiquidate,
      0
    );

    if (receiveAToken) {
      vars.liquidatorPreviousATokenBalance = IERC20(vars.collateralAtoken).balanceOf(msg.sender);
      vars.collateralAtoken.transferOnLiquidation(user, msg.sender, vars.maxCollateralToLiquidate);

      if (vars.liquidatorPreviousATokenBalance == 0) {
        DataTypes.UserConfigurationMap storage liquidatorConfig = _usersConfig[msg.sender];
        liquidatorConfig.setUsingAsCollateral(collateralReserve.id, true);
        if (liquidatorConfig.getHealthFactorLiquidationThreshold() == 0) {
          liquidatorConfig.setHealthFactorLiquidationThreshold(1 ether);
        }
        emit ReserveUsedAsCollateralEnabled(collateralAsset, msg.sender);
      }
    } else {
      collateralReserve.updateState();
      collateralReserve.updateInterestRates(
        collateralAsset,
        address(vars.collateralAtoken),
        0,
        vars.maxCollateralToLiquidate
      );

      // Burn the equivalent amount of aToken, sending the underlying to the liquidator
      vars.collateralAtoken.burn(
        user,
        msg.sender,
        vars.maxCollateralToLiquidate,
        collateralReserve.liquidityIndex
      );
    }

    // If the collateral being liquidated is equal to the user balance,
    // we set the currency as not being used as collateral anymore
    if (vars.maxCollateralToLiquidate == vars.userCollateralBalance) {
      userConfig.setUsingAsCollateral(collateralReserve.id, false);
      emit ReserveUsedAsCollateralDisabled(collateralAsset, user);
    }

    // Transfers the debt asset being repaid to the aToken, where the liquidity is kept
    IERC20(debtAsset).safeTransferFrom(
      msg.sender,
      debtReserve.aTokenAddress,
      vars.debtAmountNeeded
    );

    //Transfer the amount CP is resposible for to Atoken address if applicable
    if(vars.coveragePoolLiability > 0) {
      IERC20(debtAsset).safeTransferFrom(
        coveragePoolAddress,
        debtReserve.aTokenAddress,
        vars.coveragePoolLiability
      );
    }

    emit LiquidationCall(
      collateralAsset,
      debtAsset,
      user,
      vars.actualDebtToLiquidate,
      vars.maxCollateralToLiquidate,
      msg.sender,
      receiveAToken,
      vars.coveragePoolLiability
    );

    return (uint256(Errors.CollateralManagerErrors.NO_ERROR), Errors.LPCM_NO_ERRORS);
  }

  struct AvailableCollateralToLiquidateLocalVars {
    uint256 userCompoundedBorrowBalance;
    uint256 liquidationBonus;
    uint256 collateralPrice;
    uint256 debtAssetPrice;
    uint256 maxAmountCollateralToLiquidate;
    uint256 debtAssetDecimals;
    uint256 collateralDecimals;
  }

  /**
   * @dev Calculates how much of a specific collateral can be liquidated, given
   * a certain amount of debt asset.
   * - This function needs to be called after all the checks to validate the liquidation have been performed,
   *   otherwise it might fail.
   * @param collateralReserve The data of the collateral reserve
   * @param debtReserve The data of the debt reserve
   * @param collateralAsset The address of the underlying asset used as collateral, to receive as result of the liquidation
   * @param debtAsset The address of the underlying borrowed asset to be repaid with the liquidation
   * @param debtToCover The debt amount of borrowed `asset` the liquidator wants to cover
   * @param userCollateralBalance The collateral balance for the specific `collateralAsset` of the user being liquidated
   * @return collateralAmount: The maximum amount that is possible to liquidate given all the liquidation constraints
   *                           (user balance, close factor)
   *         debtAmountNeeded: The amount to repay with the liquidation
   **/
  function _calculateAvailableCollateralToLiquidate(
    DataTypes.ReserveData storage collateralReserve,
    DataTypes.ReserveData storage debtReserve,
    address collateralAsset,
    address debtAsset,
    uint256 debtToCover,
    uint256 userCollateralBalance
  ) internal view returns (uint256, uint256, uint256, uint256) {
    uint256 collateralAmount = 0;
    uint256 debtAmountNeeded = 0;
    //IPriceOracleGetter oracle = IPriceOracleGetter(_addressesProvider.getPriceOracle());

    AvailableCollateralToLiquidateLocalVars memory vars;

    vars.collateralPrice = IPriceOracleGetter(_addressesProvider.getPriceOracle()).getAssetPrice(collateralAsset);
    vars.debtAssetPrice = IPriceOracleGetter(_addressesProvider.getPriceOracle()).getAssetPrice(debtAsset);

    (, , vars.liquidationBonus, vars.collateralDecimals, ) = collateralReserve
      .configuration
      .getParams();
    vars.debtAssetDecimals = debtReserve.configuration.getDecimals();

    // This is the maximum possible amount of the selected collateral that can be liquidated, given the
    // max amount of liquidatable debt
    vars.maxAmountCollateralToLiquidate = vars
      .debtAssetPrice
      .mul(debtToCover)
      .mul(10**vars.collateralDecimals)
      .percentMul(vars.liquidationBonus)
      .div(vars.collateralPrice.mul(10**vars.debtAssetDecimals));

    if (vars.maxAmountCollateralToLiquidate > userCollateralBalance) {
      collateralAmount = userCollateralBalance;
      debtAmountNeeded = vars
        .collateralPrice
        .mul(collateralAmount)
        .mul(10**vars.debtAssetDecimals)
        .div(vars.debtAssetPrice.mul(10**vars.collateralDecimals))
        .percentDiv(vars.liquidationBonus);

    } else {
      collateralAmount = vars.maxAmountCollateralToLiquidate;
      debtAmountNeeded = debtToCover;
    }
    return (collateralAmount, debtAmountNeeded, vars.debtAssetPrice, vars.debtAssetDecimals);
  }
}
/*
function _getCoveragePoolLiability(
  uint256 actualDebtToLiquidate,
  uint256 debtAmountNeeded,
  address debtAsset,
  uint256 ltv,
  uint256 userEthCollateral,
  uint256 userEthDebt,
  uint256 userHealthFactor,
  uint256 debtAssetPrice,
  uint256 debtDecimals
) internal view returns(uint256, uint256){
  uint256 maxCoveragePoolLiability = actualDebtToLiquidate.sub(debtAmountNeeded); //If undercollaterlized CP will pay the difference in debt

        // Calculate the normal collateral Coverage ratio based of user LTV // ((1 - LTV) / LTV) +1
        uint256 ccr = (uint256(1e18).sub(ltv)).mul(1e18).div(ltv).add(1e18);
        uint256 normalCollatarelNeeded = userEthDebt.mul(ccr).div(1e18);
        uint256 userCollateralAllowed = normalCollatarelNeeded.mul(userHealthFactor).div(1e18);

        uint256 diff = userCollateralAllowed.sub(userEthCollateral);
        //--need to adjust diff for price of debt // debtAmount * price / 10 ** (18 + (18 - debt decimals))
        uint256 diffInDebtPrice = diff.mul(debtAssetPrice).div(10 ** (18 + (18 - debtDecimals)));

        uint256 coveragePoolLiability = diffInDebtPrice > maxCoveragePoolLiability ? maxCoveragePoolLiability : diffInDebtPrice;
        //--Need to determine if this how much we want to pay back since the users allowed health factor should increase

        //Just in case the CP doesnt have enough we want to cover whatever we can
        uint256 coveragePoolLiquidity = IERC20(debtAsset).balanceOf(coveragePoolAddress);
        if(coveragePoolLiquidity < coveragePoolLiability) {
          coveragePoolLiability = coveragePoolLiquidity;
          actualDebtToLiquidate = debtAmountNeeded.add(coveragePoolLiquidity);
        }

        return( actualDebtToLiqduidate, coveragePoolLiability);
}
*/
