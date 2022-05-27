
//SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.6.12;

contract Ownable {

    address public policy;

    constructor () public {
        policy = msg.sender;
    }

    modifier onlyPolicy() {
        require( policy == msg.sender, "Ownable: caller is not the owner" );
        _;
    }

    function transferManagment(address _newOwner) external onlyPolicy() {
        require( _newOwner != address(0) );
        policy = _newOwner;
    }
}
