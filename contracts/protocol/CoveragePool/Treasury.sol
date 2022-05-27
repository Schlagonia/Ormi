
//SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.6.12;

import {SafeMath} from '../../dependencies/openzeppelin/contracts//SafeMath.sol';
import {IERC20Detailed} from '../../dependencies/openzeppelin/contracts//IERC20Detailed.sol';
import {Address} from '../../dependencies/openzeppelin/contracts/Address.sol';
import {SafeERC20} from '../../dependencies/openzeppelin/contracts/SafeERC20.sol';
import {Ownable} from './Ownable.sol';


contract Treasury is Ownable {

    /* ======== DEPENDENCIES ======== */

    using SafeERC20 for IERC20Detailed;
    using SafeMath for uint;


    /* ======== STATE VARIABLS ======== */

    IERC20Detailed immutable payoutToken; // token paid for principal

    mapping(address => bool) public bondContract;

    /* ======== EVENTS ======== */

    event BondContractToggled(address bondContract, bool approved);
    event Withdraw(address token, address destination, uint amount);

    /* ======== CONSTRUCTOR ======== */

    constructor(address _payoutToken, address _initialOwner) public {
        require( _payoutToken != address(0) );
        payoutToken = IERC20Detailed(_payoutToken);
        require( _initialOwner != address(0) );
        policy = _initialOwner;
    }

    /* ======== BOND CONTRACT FUNCTION ======== */

    /**
     *  @notice deposit principle token and recieve back payout token
     *  @param _principleTokenAddress address
     *  @param _amountPrincipleToken uint
     *  @param _amountPayoutToken uint
     */
    function deposit(address _principleTokenAddress, uint _amountPrincipleToken, uint _amountPayoutToken) external {
        require(bondContract[msg.sender], "msg.sender is not a bond contract");
        IERC20Detailed(_principleTokenAddress).safeTransferFrom(msg.sender, address(this), _amountPrincipleToken);
        payoutToken.safeTransfer(msg.sender, _amountPayoutToken);
    }

    /* ======== VIEW FUNCTION ======== */

    /**
    *   @notice returns payout token valuation of priciple
    *   @param _principleTokenAddress address
    *   @param _amount uint
    *   @return value_ uint
     */
    function valueOfToken( address _principleTokenAddress, uint _amount ) public view returns ( uint value_ ) {
        // convert amount to match payout token decimals
        value_ = _amount.mul( 10 ** uint256(payoutToken.decimals()) ).div( 10 ** uint256(IERC20Detailed( _principleTokenAddress ).decimals()) );
    }


    /* ======== POLICY FUNCTIONS ======== */

    /**
     *  @notice policy can withdraw ERC20 token to desired address
     *  @param _token uint
     *  @param _destination address
     *  @param _amount uint
     */
    function withdraw(address _token, address _destination, uint _amount) external onlyPolicy() {
        IERC20Detailed(_token).safeTransfer(_destination, _amount);

        emit Withdraw(_token, _destination, _amount);
    }

    /**
        @notice toggle bond contract
        @param _bondContract address
     */
    function toggleBondContract(address _bondContract) external onlyPolicy() {
        bondContract[_bondContract] = !bondContract[_bondContract];
        emit BondContractToggled(_bondContract, bondContract[_bondContract]);
    }

}
