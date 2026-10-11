import 'dart:async';
import 'package:flutter/material.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import '../models/message_model.dart';
import '../models/call_model.dart';
import '../models/user_model.dart';
import 'encryption_service.dart';

typedef OnMessageReceived = void Function(MessageModel message);
typedef OnMessageDelivered = void Function(Map<String, dynamic> data);
typedef OnMessageRead = void Function(Map<String, dynamic> data);
typedef OnIncomingCall = void Function(Map<String, dynamic> callData);
typedef OnCallAnswered = void Function(Map<String, dynamic> answerData);
typedef OnIceCandidate = void Function(Map<String, dynamic> candidateData);
typedef OnCallEnded = void Function();
typedef OnUserStatusChange = void Function(String userId, bool isOnline);
typedef OnLiveLocationUpdate = void Function(Map<String, dynamic> data);
typedef OnLiveLocationStopped = void Function(Map<String, dynamic> data);
typedef OnMessageDeleted = void Function(String messageId);
typedef OnMessageEdited = void Function(String messageId, String newContent);
typedef OnMessageSent = void Function(String tempId, String realId);

class SocketService {
  static final SocketService _instance = SocketService._internal();
  factory SocketService() => _instance;
  SocketService._internal();

  IO.Socket? socket;
  String? _currentUserId;

  OnMessageReceived? onMessageReceived;
  OnMessageDelivered? onMessageDelivered;
  OnMessageRead? onMessageRead;
  OnIncomingCall? onIncomingCall;
  OnCallAnswered? onCallAnswered;
  OnIceCandidate? onIceCandidate;
  OnCallEnded? onCallEnded;
  OnUserStatusChange? onUserStatusChange;
  OnLiveLocationUpdate? onLiveLocationUpdate;
  OnLiveLocationStopped? onLiveLocationStopped;
  OnMessageDeleted? onMessageDeleted;
  OnMessageEdited? onMessageEdited;
  OnMessageSent? onMessageSent;


  // Initialize and connect socket to Python server
  void initSocket(String userId) {
    if (socket != null && socket!.connected && _currentUserId == userId) return;

    _currentUserId = userId;
    
    // Connect to Python server Socket.io (Port 3000)
    socket = IO.io(
      'http://46.197.188.20:3000',
      IO.OptionBuilder()
          .setTransports(['websocket', 'polling'])
          .enableAutoConnect()
          .enableReconnection()
          .build(),
    );

    socket!.onConnect((_) {
      debugPrint('[SOCKET] Connected to Python server');
      // Join room with current user ID
      socket!.emit('join', userId);
    });

    socket!.on('receive_message', (data) {
      debugPrint('[SOCKET] Received Message: $data');
      if (data != null) {
        final typeStr = data['type']?.toString() ?? 'text';
        final msgType = MessageType.values.firstWhere(
          (e) => e.name == typeStr,
          orElse: () => MessageType.text,
        );

        final rawContent = data['content'] ?? '';
        final decryptedContent = EndToEndEncryptionService.decryptText(
          rawContent,
          data['senderId'].toString(),
          data['receiverId'].toString(),
        );

        final message = MessageModel(
          id: data['id'].toString(),
          senderId: data['senderId'].toString(),
          receiverId: data['receiverId'].toString(),
          content: decryptedContent,
          type: msgType,
          timestamp: DateTime.tryParse(data['timestamp'] ?? '') ?? DateTime.now(),
          isDelivered: true,
          isRead: data['isRead'] == 1 || data['isRead'] == true,
          mediaUrl: data['mediaUrl'],
        );

        // Notify sender that message was delivered
        emitMessageDelivered(
          senderId: message.senderId,
          receiverId: message.receiverId,
          messageId: message.id,
        );

        if (onMessageReceived != null) {
          onMessageReceived!(message);
        }
      }
    });

    socket!.on('messages_delivered', (data) {
      debugPrint('[SOCKET] Messages Delivered: $data');
      if (onMessageDelivered != null && data != null) {
        onMessageDelivered!(Map<String, dynamic>.from(data));
      }
    });

    socket!.on('messages_read', (data) {
      debugPrint('[SOCKET] Messages Read: $data');
      if (onMessageRead != null && data != null) {
        onMessageRead!(Map<String, dynamic>.from(data));
      }
    });

    socket!.on('incoming_call', (data) {
      debugPrint('[SOCKET] Incoming Call: $data');
      if (onIncomingCall != null && data != null) {
        onIncomingCall!(Map<String, dynamic>.from(data));
      }
    });

    socket!.on('call_answered', (data) {
      debugPrint('[SOCKET] Call Answered: $data');
      if (onCallAnswered != null && data != null) {
        onCallAnswered!(Map<String, dynamic>.from(data));
      }
    });

    socket!.on('ice_candidate', (data) {
      debugPrint('[SOCKET] Ice Candidate: $data');
      if (onIceCandidate != null && data != null) {
        onIceCandidate!(Map<String, dynamic>.from(data));
      }
    });

    socket!.on('call_ended', (_) {
      debugPrint('[SOCKET] Call Ended by peer');
      if (onCallEnded != null) {
        onCallEnded!();
      }
    });

    socket!.on('user_status_change', (data) {
      debugPrint('[SOCKET] User status change: $data');
      if (onUserStatusChange != null && data != null) {
        final userId = data['userId']?.toString() ?? '';
        final isOnline = data['isOnline'] == true || data['isOnline'] == 1;
        onUserStatusChange!(userId, isOnline);
      }
    });

    socket!.on('live_location_received', (data) {
      debugPrint('[SOCKET] Live Location Received: $data');
      if (onLiveLocationUpdate != null && data != null) {
        onLiveLocationUpdate!(Map<String, dynamic>.from(data));
      }
    });

    socket!.on('live_location_stopped', (data) {
      debugPrint('[SOCKET] Live Location Stopped: $data');
      if (onLiveLocationStopped != null && data != null) {
        onLiveLocationStopped!(Map<String, dynamic>.from(data));
      }
    });

    socket!.on('message_deleted', (data) {
      debugPrint('[SOCKET] Message Deleted: $data');
      if (onMessageDeleted != null && data != null) {
        final msgId = data['messageId']?.toString() ?? '';
        onMessageDeleted!(msgId);
      }
    });

    socket!.on('message_edited', (data) {
      debugPrint('[SOCKET] Message Edited: $data');
      if (onMessageEdited != null && data != null) {
        final msgId = data['messageId']?.toString() ?? '';
        final rawContent = data['content']?.toString() ?? '';
        final senderId = data['senderId']?.toString() ?? '';
        final receiverId = data['receiverId']?.toString() ?? '';
        final dec = EndToEndEncryptionService.decryptText(rawContent, senderId, receiverId);
        onMessageEdited!(msgId, dec);
      }
    });

    socket!.on('message_sent', (data) {
      debugPrint('[SOCKET] Message Sent confirmed: $data');
      if (onMessageSent != null && data != null) {
        final tempId = data['clientTempId']?.toString() ?? '';
        final realId = data['id']?.toString() ?? '';
        if (tempId.isNotEmpty && realId.isNotEmpty) {
          onMessageSent!(tempId, realId);
        }
      }
    });

    socket!.onDisconnect((_) => debugPrint('[SOCKET] Disconnected'));
  }

  // Report message delivered
  void emitMessageDelivered({required String senderId, required String receiverId, String? messageId}) {
    socket?.emit('message_delivered', {
      'senderId': senderId,
      'receiverId': receiverId,
      'messageId': messageId,
    });
  }

  // Report message read
  void emitMessageRead({required String senderId, required String receiverId, String? messageId}) {
    socket?.emit('message_read', {
      'senderId': senderId,
      'receiverId': receiverId,
      'messageId': messageId,
    });
  }

  // Live Location Update
  void emitLiveLocationUpdate({
    required String senderId,
    required String receiverId,
    required double latitude,
    required double longitude,
    double? heading,
    double? speed,
    String? messageId,
  }) {
    socket?.emit('live_location_update', {
      'senderId': senderId,
      'receiverId': receiverId,
      'latitude': latitude,
      'longitude': longitude,
      'heading': heading ?? 0.0,
      'speed': speed ?? 0.0,
      if (messageId != null) 'messageId': messageId,
    });
  }

  // Stop Live Location
  void emitStopLiveLocation({
    required String senderId,
    required String receiverId,
    String? messageId,
  }) {
    socket?.emit('stop_live_location', {
      'senderId': senderId,
      'receiverId': receiverId,
      if (messageId != null) 'messageId': messageId,
    });
  }


  // Send real-time chat message
  void sendMessage({
    required String senderId,
    required String receiverId,
    required String content,
    String type = 'text',
    String? mediaUrl,
    String? clientTempId,
  }) {
    if (socket != null && socket!.connected) {
      socket!.emit('send_message', {
        'senderId': senderId,
        'receiverId': receiverId,
        'content': content,
        'type': type,
        if (mediaUrl != null) 'mediaUrl': mediaUrl,
        if (clientTempId != null) 'clientTempId': clientTempId,
      });
    }
  }

  // Emit WebRTC Call
  void emitCall({
    required UserModel caller,
    required String receiverId,
    required Map<String, dynamic> offer,
    required String callType,
  }) {
    socket?.emit('call_user', {
      'caller': {
        'uid': caller.uid,
        'username': caller.username,
        'displayName': caller.displayName,
        'photoUrl': caller.photoUrl,
      },
      'receiverId': receiverId,
      'offer': offer,
      'callType': callType,
    });
  }

  // Emit WebRTC Answer
  void emitAnswer({
    required String callerId,
    required Map<String, dynamic> answer,
  }) {
    socket?.emit('answer_call', {
      'callerId': callerId,
      'answer': answer,
    });
  }

  // Emit ICE Candidate
  void emitIceCandidate({
    required String targetUserId,
    required Map<String, dynamic> candidate,
  }) {
    socket?.emit('ice_candidate', {
      'targetUserId': targetUserId,
      'candidate': candidate,
    });
  }

  // Emit End Call
  void emitEndCall(String targetUserId) {
    socket?.emit('end_call', {
      'targetUserId': targetUserId,
    });
  }

  // Delete message (Soft delete, keeps audit trail for admin)
  void deleteMessage({
    required String messageId,
    required String senderId,
    required String receiverId,
  }) {
    socket?.emit('delete_message', {
      'messageId': messageId,
      'senderId': senderId,
      'receiverId': receiverId,
    });
  }

  // Edit message (Updates message, keeps original content for admin audit)
  void editMessage({
    required String messageId,
    required String senderId,
    required String receiverId,
    required String newContent,
  }) {
    socket?.emit('edit_message', {
      'messageId': messageId,
      'senderId': senderId,
      'receiverId': receiverId,
      'newContent': newContent,
    });
  }
}
