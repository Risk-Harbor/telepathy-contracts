pragma solidity ^0.8.16;

import {Subscription, IPublisher} from "src/pubsub/interfaces/IPubSub.sol";
import {EventProof} from "src/pubsub/EventProof.sol";
import {ISubscriptionReceiver} from "src/pubsub/interfaces/ISubscriptionReceiver.sol";
import {TelepathyRouter} from "src/amb/TelepathyRouter.sol";
import {SSZ} from "src/libraries/SimpleSerialize.sol";
import {Address} from "src/libraries/Typecast.sol";
import {PubSubStorage} from "src/pubsub/PubSubStorage.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import {PublishStatus} from "src/pubsub/interfaces/IPubSub.sol";

/// @title TelepathyPublisher
/// @author Succinct Labs
/// @notice A contract that can publish events to a ISubscriptionReceiver contract.
contract TelepathyPublisher is IPublisher, PubSubStorage, ReentrancyGuard {
    error CallFailed();
    error InvalidSelector();

    /// @notice Publishes an event emit to a callback Subscriber, given an event proof.
    /// @param srcSlotTxSlotPack The slot where we want to read the header from and the slot where
    ///                          the tx executed, packed as two uint64s.
    /// @param receiptsRootProof A merkle proof proving the receiptsRoot in the block header.
    /// @param receiptsRoot The receipts root which contains the event.
    /// @param txIndexRLPEncoded The index of our transaction inside the block RLP encoded.
    /// @param logIndex The index of the event in our transaction.
    /// @param subscription The subscription data (sourceChainId, sourceAddress, callbackAddress, eventSig).
    /// @dev This function should be called for every subscriber that is subscribed to the event.
    function publishEvent(
        bytes calldata srcSlotTxSlotPack,
        bytes32[] calldata receiptsRootProof,
        bytes32 receiptsRoot,
        bytes[] calldata receiptProof,
        bytes memory txIndexRLPEncoded,
        uint256 logIndex,
        Subscription calldata subscription
    ) external nonReentrant {
        require(!paused, "Publishing events is paused");
        requireLightClientConsistency(subscription.sourceChainId);

        (uint64 srcSlot, uint64 txSlot) = abi.decode(srcSlotTxSlotPack, (uint64, uint64));
        // Ensure the event emit may only be published to a subscriber once
        bytes32 subscriptionId = keccak256(abi.encode(subscription));
        bytes32 publishKey =
            keccak256(abi.encode(txSlot, txIndexRLPEncoded, logIndex, subscriptionId));
        require(
            eventsPublished[publishKey] == PublishStatus.NOT_EXECUTED, "Event already published"
        );

        bytes32 headerRoot = lightClient.headers(srcSlot);
        require(headerRoot != bytes32(0), "HeaderRoot is missing");
        bool isValid = SSZ.verifyReceiptsRoot(
            receiptsRoot, receiptsRootProof, headerRoot, srcSlot, txSlot, subscription.sourceChainId
        );
        require(isValid, "Invalid receipts root proof");

        (bytes32[] memory eventTopics, bytes memory eventData) = EventProof.parseEvent(
            receiptProof,
            receiptsRoot,
            txIndexRLPEncoded,
            logIndex,
            subscription.sourceAddress,
            subscription.eventSig
        );

        _publish(subscriptionId, subscription, txSlot, publishKey, eventTopics, eventData);
    }

    /// @notice Checks that the light client for a given chainId is consistent.
    function requireLightClientConsistency(uint32 chainId) internal view {
        require(address(lightClient) != address(0), "Light client is not set.");
        require(lightClient.consistent(), "Light client is inconsistent.");
    }

    /// @notice Executes the callback function on the subscriber, and marks the event publish as successful or failed.
    function _publish(
        bytes32 _subscriptionId,
        Subscription calldata _subscription,
        uint64 _txSlot,
        bytes32 _publishKey,
        bytes32[] memory _eventTopics,
        bytes memory _eventData
    ) internal {
        bool success;
        bytes memory data;
        {
            bytes memory receiveCall = abi.encodeWithSelector(
                ISubscriptionReceiver.handlePublish.selector,
                _subscriptionId,
                _subscription.sourceChainId,
                _subscription.sourceAddress,
                _txSlot,
                _publishKey,
                _eventTopics,
                _eventData
            );
            (success, data) = _subscription.callbackAddress.call(receiveCall);
        }

        bool implementsHandler = false;
        if (data.length == 32) {
            (bytes4 magic) = abi.decode(data, (bytes4));
            implementsHandler = magic == ISubscriptionReceiver.handlePublish.selector;
        }

        // Resolves issue regarding EIP-150 (where the child call can fail due to "out of gas" error
        // but the parent call will have 1/64 of original gas to finish execution) or, for example,
        // because of possible NonReentrant logic in callback contract.
        //
        // This leads to the possibility to maliciously mark the event as published with
        // `PublishStatus.EXECUTION_FAILED` status, while with "fair" execution it should succeed.
        //
        // To fix the issue, we simply revert the entire tx if the callback fails. This allows for
        // retries.
        if (!success) {
            revert CallFailed();
        } else if (!implementsHandler) {
            revert InvalidSelector();
        }

        eventsPublished[_publishKey] = PublishStatus.EXECUTION_SUCCEEDED;
        emit Publish(
            _subscriptionId,
            _subscription.sourceChainId,
            _subscription.sourceAddress,
            _subscription.callbackAddress,
            success
        );
    }
}
