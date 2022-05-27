
//SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.6.12;

import {Treasury} from './Treasury.sol';

//Needs To
// Allow the Lending Pool Collat manager to call for a certain amount that is unsecured
//Transfer the amount required to the Atoken pool for the collateral
// calc when to update the terms for the bonding contract based on current amount of unsecured loans
//Will need to figure how to account for users with multiple different collats

//Decide if we are paying back the collateral token or the borrowed token


contract CoveragePool is Treasury {

  constructor(
    address _payoutToken,
    address _initialOwner
    ) public Treasury(_payoutToken, _initialOwner){
}

}
