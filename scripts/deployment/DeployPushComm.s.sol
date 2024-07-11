// SPDX-License-Identifier:MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import { PushCoreV3 } from "contracts/PushCore/PushCoreV3.sol";
import { PushCoreMock } from "contracts/mocks/PushCoreMock.sol";
import { EPNSCoreProxy, ITransparentUpgradeableProxy } from "contracts/PushCore/EPNSCoreProxy.sol";
import { EPNSCoreAdmin } from "contracts/PushCore/EPNSCoreAdmin.sol";
import { PushCommV3 } from "contracts/PushComm/PushCommV3.sol";
import { EPNSCommProxy } from "contracts/PushComm/EPNSCommProxy.sol";
import { EPNSCommAdmin } from "contracts/PushComm/EPNSCommAdmin.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract DeployPushComm is Test {
    PushCommV3 public comm;
    PushCommV3 public commProxy;
    EPNSCommProxy public epnsCommProxy;
    EPNSCommAdmin public epnsCommProxyAdmin;

    address public coreProxy = 0x34cd115a35252B0d946fA479B6eCb781dbBD5cef;
    address public pushToken = 0x09676C46aaE81a2E0e13ce201040400765BFe329; // base sepolia testnet token

    function run() public {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        address account = vm.addr(vm.envUint("PRIVATE_KEY"));

        comm = new PushCommV3();

        epnsCommProxyAdmin = new EPNSCommAdmin(account);
        epnsCommProxy =
            new EPNSCommProxy(address(comm), address(epnsCommProxyAdmin), account, "arb testnet");
        commProxy = PushCommV3(address(epnsCommProxy));

        // epnsCommProxyAdmin = new EPNSCommAdmin(account);
        // epnsCommProxy =
        //     new EPNSCommProxy(address(comm), address(epnsCommProxyAdmin), account, "bnb testnet");
        // commProxy = PushCommV3(address(epnsCommProxy));

        commProxy.setEPNSCoreAddress(coreProxy);
        commProxy.setPushTokenAddress(address(pushToken));

        vm.stopBroadcast();
    }
}