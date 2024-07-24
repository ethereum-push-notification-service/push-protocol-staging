pragma solidity ^0.8.20;
pragma experimental ABIEncoderV2;

import "contracts/token/Push.sol";

import { Helper } from "./CCRutils/Helper.sol";

contract BaseCCRTest is Helper {
    ///@notice start with forking the arbitrum testnet
    /// Wrap the token contract with the one deployed on arbitrum testnet
    /// getting the push tokens from whale address
    /// approving the tokens then initializing the Comm contract with already deployed
    /// bridge related contracts.
    function setUp() public virtual override {
        setUpSourceChain();
        sourceAddress = toWormholeFormat(address(commProxy));
    }
}