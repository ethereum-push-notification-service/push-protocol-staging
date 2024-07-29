// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

import { BasePushCommTest } from "../../PushComm/unit_tests/BasePushCommTest.t.sol";
import "contracts/token/Push.sol";
import { CoreTypes, CrossChainRequestTypes, GenericTypes } from "contracts/libraries/DataTypes.sol";

import "contracts/libraries/wormhole-lib/TrimmedAmount.sol";
import { TransceiverStructs } from "contracts/libraries/wormhole-lib/TransceiverStructs.sol";
import "contracts/interfaces/wormhole/IWormholeRelayer.sol";
import { CCRConfig } from "./CCRConfig.sol";
import { IWormholeTransceiver } from "contracts/interfaces/wormhole/IWormholeTransceiver.sol";
import { Vm } from "forge-std/Vm.sol";
import {EPNS} from "contracts/token/EPNS.sol";
contract Helper is BasePushCommTest, CCRConfig {
    // Set Source and dest chains

    SourceConfig SourceChain = ArbSepolia;
    DestConfig DestChain = EthSepolia;

    bytes _payload;

    bytes requestPayload;

    bytes[] additionalVaas;
    bytes32 deliveryHash = 0x97f309914aa8b670f4a9212ba06670557b0c92a7ad853b637be8a9a6c2ea6447;
    bytes32 sourceAddress;
    uint16 sourceChain = SourceChain.SourceChainId;
    GenericTypes.Percentage percentage;
    uint256 GasLimit = 10_000_000; // ToDo: to be finalised

    bytes4 constant TEST_TRANSCEIVER_PAYLOAD_PREFIX = 0x9945ff10;

    function switchChains(string memory url) public {
        vm.createSelectFork(url);
    }

    function getPushTokenOnfork(address _addr, uint256 _amount) public {
        changePrank(SourceChain.PushHolder);
        pushNttToken.transfer(_addr, _amount);

        changePrank(_addr);
        pushNttToken.approve(address(commProxy), type(uint256).max);
    }

    function setUpSourceChain() internal {
        switchChains(SourceChain.rpc);
        BasePushCommTest.setUp();
        pushNttToken = Push(SourceChain.PUSH_NTT_SOURCE);

        getPushTokenOnfork(actor.bob_channel_owner, 1000e18);
        getPushTokenOnfork(actor.charlie_channel_owner, 1000e18);

        changePrank(actor.admin);
        commProxy.setBridgeConfig(
            SourceChain.PUSH_NTT_SOURCE,
            SourceChain.NTT_MANAGER,
            SourceChain.wormholeTransceiverChain1,
            IWormholeRelayer(SourceChain.WORMHOLE_RELAYER_SOURCE),
            DestChain.DestChainId
        );
        commProxy.setCoreFeeConfig(ADD_CHANNEL_MIN_FEES, FEE_AMOUNT, MIN_POOL_CONTRIBUTION);
    }

    function setUpDestChain() internal {
        switchChains(DestChain.rpc);
        BasePushCommTest.setUp();
        pushToken = EPNS(DestChain.PUSH_NTT_DEST);
        changePrank(actor.admin);
        coreProxy.setWormholeRelayer(DestChain.WORMHOLE_RELAYER_DEST);
        coreProxy.setEpnsTokenAddress(address(pushToken));
        coreProxy.setRegisteredSender(SourceChain.SourceChainId, toWormholeFormat(address(commProxy)));
    }

    function toWormholeFormat(address addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }

    function getPoolFundsAndFees(uint256 _amountDeposited)
        internal
        view
        returns (uint256 CHANNEL_POOL_FUNDS, uint256 PROTOCOL_POOL_FEES)
    {
        uint256 poolFeeAmount = coreProxy.FEE_AMOUNT();
        uint256 poolFundAmount = _amountDeposited - poolFeeAmount;
        //store funds in pool_funds & pool_fees
        CHANNEL_POOL_FUNDS = coreProxy.CHANNEL_POOL_FUNDS() + poolFundAmount;
        PROTOCOL_POOL_FEES = coreProxy.PROTOCOL_POOL_FEES() + poolFeeAmount;
    }

    function getSpecificPayload(
        CrossChainRequestTypes.CrossChainFunction typeOfReq,
        address amountRecipient,
        uint256 amount,
        uint8 _feeId,
        GenericTypes.Percentage memory _percentage,
        address sender
    )
        internal
        pure
        returns (bytes memory payload, bytes memory reqPayload)
    {
        if (typeOfReq == CrossChainRequestTypes.CrossChainFunction.AddChannel) {
            payload = abi.encode(CoreTypes.ChannelType.InterestBearingMutual, _testChannelUpdatedIdentity, 0);

            reqPayload = abi.encode(typeOfReq, payload, amount, sender);
        } else if (typeOfReq == CrossChainRequestTypes.CrossChainFunction.IncentivizedChat) {
            payload = abi.encode(amountRecipient);

            reqPayload = abi.encode(typeOfReq, payload, amount, sender);
        } else if (typeOfReq == CrossChainRequestTypes.CrossChainFunction.ArbitraryRequest) {
            payload = abi.encode(_feeId, _percentage, amountRecipient);

            reqPayload = abi.encode(typeOfReq, payload, amount, sender);
        }
    }

    function receiveWormholeMessage(bytes memory _requestPayload) internal {
        changePrank(DestChain.WORMHOLE_RELAYER_DEST);
        coreProxy.receiveWormholeMessages(_requestPayload, additionalVaas, sourceAddress, sourceChain, deliveryHash);
    }

    function _trimTransferAmount(uint256 amount) internal pure returns (TrimmedAmount) {
        uint8 toDecimals = 18;

        TrimmedAmount trimmedAmount;
        {
            uint8 fromDecimals = 18;
            trimmedAmount = TrimmedAmountLib.trim(amount, fromDecimals, toDecimals);
            // don't deposit dust that can not be bridged due to the decimal shift
            uint256 newAmount = TrimmedAmountLib.untrim(trimmedAmount, fromDecimals);
            if (amount != newAmount) {
                // revert TransferAmountHasDust(amount, amount - newAmount);
            }
        }

        return trimmedAmount;
    }

    function buildTransceiverInstruction(bool relayer_off)
        public
        view
        returns (TransceiverStructs.TransceiverInstruction memory)
    {
        IWormholeTransceiver.WormholeTransceiverInstruction memory instruction =
            IWormholeTransceiver.WormholeTransceiverInstruction(relayer_off);

        bytes memory encodedInstructionWormhole;
        // Source fork has id 0 and corresponds to chain 1
        if (vm.activeFork() == 0) {
            encodedInstructionWormhole =
                SourceChain.wormholeTransceiverChain1.encodeWormholeTransceiverInstruction(instruction);
        } else {
            encodedInstructionWormhole =
                DestChain.wormholeTransceiverChain2.encodeWormholeTransceiverInstruction(instruction);
        }
        return TransceiverStructs.TransceiverInstruction({ index: 0, payload: encodedInstructionWormhole });
    }

    function encodeTransceiverInstruction(bool relayer_off) public view returns (bytes memory) {
        TransceiverStructs.TransceiverInstruction memory TransceiverInstruction =
            buildTransceiverInstruction(relayer_off);
        TransceiverStructs.TransceiverInstruction[] memory TransceiverInstructions =
            new TransceiverStructs.TransceiverInstruction[](1);
        TransceiverInstructions[0] = TransceiverInstruction;
        return TransceiverStructs.encodeTransceiverInstructions(TransceiverInstructions);
    }

    function buildTransceiverMessageWithNttManagerPayload(
        bytes32 id,
        bytes32 sender,
        bytes32 sourceNttManager,
        bytes32 recipientNttManager,
        bytes memory payload
    )
        internal
        pure
        returns (TransceiverStructs.NttManagerMessage memory, bytes memory)
    {
        TransceiverStructs.NttManagerMessage memory m = TransceiverStructs.NttManagerMessage(id, sender, payload);
        bytes memory nttManagerMessage = TransceiverStructs.encodeNttManagerMessage(m);
        bytes memory transceiverMessage;
        (, transceiverMessage) = TransceiverStructs.buildAndEncodeTransceiverMessage(
            TEST_TRANSCEIVER_PAYLOAD_PREFIX, sourceNttManager, recipientNttManager, nttManagerMessage, new bytes(0)
        );
        return (m, transceiverMessage);
    }

    function getMessagefromLog(Vm.Log[] memory logs)
        internal
        pure
        returns (address sourceNttManager, bytes32 recipient, uint256 _amount, uint16 recipientChain)
    {
        bytes memory data;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("TransferSent(bytes32,bytes32,uint256,uint256,uint16,uint64)")) {
                data = logs[i].data;
                sourceNttManager = logs[i].emitter;
            }
        }
        (recipient,, _amount,, recipientChain,) = abi.decode(data, (bytes32, bytes32, uint256, uint256, uint16, uint64));
    }

    function getRequestPayload(
        uint256 _amount,
        bytes32 recipient,
        uint16 recipientChain,
        address sourceNttManager
    )
        internal
        view
        returns (bytes memory transceiverMessage, bytes32 hash)
    {
        TrimmedAmount _amt = _trimTransferAmount(_amount);
        bytes memory tokenTransferMessage = TransceiverStructs.encodeNativeTokenTransfer(
            TransceiverStructs.NativeTokenTransfer({
                amount: _amt,
                sourceToken: toWormholeFormat(address(SourceChain.PUSH_NTT_SOURCE)),
                to: recipient,
                toChain: recipientChain
            })
        );

        TransceiverStructs.NttManagerMessage memory nttManagerMessage;
        (nttManagerMessage, transceiverMessage) = buildTransceiverMessageWithNttManagerPayload(
            0,
            toWormholeFormat(address(SourceChain.PushHolder)),
            toWormholeFormat(sourceNttManager),
            toWormholeFormat(DestChain.NTT_MANAGER),
            tokenTransferMessage
        );
        hash = TransceiverStructs.nttManagerMessageDigest(10_003, nttManagerMessage);
    }
}
