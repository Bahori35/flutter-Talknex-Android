import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import '../models/message_model.dart';
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
typedef OnMessageDeleted = void Function(String messageId, [String mode]);
typedef OnMessageEdited = void Function(String messageId, String newContent);
typedef OnMessageSent = void Function(String tempId, String realId);

class SocketService {
  static final SocketService _instance = SocketService._internal();
  factory SocketService() => _instance;
  SocketService._internal();

  WebSocket? _socket;
  String? _currentUserId;
  bool _isConnecting = false;
  Timer? _reconnectTimer;
  Timer? _pingTimer;

  bool get isConnected => _socket != null && _socket!.readyState == WebSocket.open;

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

  // Initialize and connect native WebSocket to Go backend (Port 3000 -> Nginx -> Go)
  void initSocket(String userId) {
    if (isConnected && _currentUserId == userId) return;

    _currentUserId = userId;
    _connect();
  }

  void _connect() async {
    if (_isConnecting) return;
    _isConnecting = true;

    try {
      _socket?.close();
      _socket = null;
    } catch (_) {}

    final wsUri = Uri.parse('ws://46.197.188.20:3000/ws');
    debugPrint('[GORILLA WS] Connecting to Go backend: $wsUri');

    try {
      _socket = await WebSocket.connect(
        wsUri.toString(),
      ).timeout(const Duration(seconds: 10));

      _isConnecting = false;
      debugPrint('[GORILLA WS] Connected successfully to Go backend!');

      // Register current user immediately
      _emit('join', {'userId': _currentUserId});

      // Keepalive ping interval (every 25 seconds)
      _socket!.pingInterval = const Duration(seconds: 25);

      _socket!.listen(
        (data) {
          _handleIncomingData(data);
        },
        onError: (err) {
          debugPrint('[GORILLA WS] Error: $err');
          _scheduleReconnect();
        },
        onDone: () {
          debugPrint('[GORILLA WS] Disconnected.');
          _scheduleReconnect();
        },
        cancelOnError: true,
      );
    } catch (e) {
      _isConnecting = false;
      debugPrint('[GORILLA WS] Connection failed: $e');
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _pingTimer?.cancel();
    _socket = null;
    if (_currentUserId == null) return;

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      if (!isConnected && _currentUserId != null) {
        debugPrint('[GORILLA WS] Attempting reconnection...');
        _connect();
      }
    });
  }

  void _emit(String event, Map<String, dynamic> data) {
    if (!isConnected) {
      debugPrint('[GORILLA WS] Cannot emit "$event": socket not open, buffering reconnect.');
      if (_currentUserId != null) _connect();
      return;
    }

    try {
      final packet = jsonEncode({
        'event': event,
        'data': data,
      });
      _socket!.add(packet);
      debugPrint('[GORILLA WS OUT] $event -> $data');
    } catch (e) {
      debugPrint('[GORILLA WS] Emit error: $e');
    }
  }

  void _handleIncomingData(dynamic raw) {
    try {
      final text = raw is String ? raw : utf8.decode(raw as List<int>);
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return;

      final event = decoded['event']?.toString() ?? '';
      final data = decoded['data'];

      debugPrint('[GORILLA WS IN] Event: $event, Data: $data');

      switch (event) {
        case 'receive_message':
          if (data is Map<String, dynamic>) {
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

            // Acknowledge delivery
            emitMessageDelivered(
              senderId: message.senderId,
              receiverId: message.receiverId,
              messageId: message.id,
            );

            if (onMessageReceived != null) {
              onMessageReceived!(message);
            }
          }
          break;

        case 'messages_delivered':
          if (onMessageDelivered != null && data is Map<String, dynamic>) {
            onMessageDelivered!(Map<String, dynamic>.from(data));
          }
          break;

        case 'messages_read':
          if (onMessageRead != null && data is Map<String, dynamic>) {
            onMessageRead!(Map<String, dynamic>.from(data));
          }
          break;

        case 'incoming_call':
          if (onIncomingCall != null && data is Map<String, dynamic>) {
            onIncomingCall!(Map<String, dynamic>.from(data));
          }
          break;

        case 'call_answered':
          if (onCallAnswered != null && data is Map<String, dynamic>) {
            onCallAnswered!(Map<String, dynamic>.from(data));
          }
          break;

        case 'ice_candidate':
          if (onIceCandidate != null && data is Map<String, dynamic>) {
            onIceCandidate!(Map<String, dynamic>.from(data));
          }
          break;

        case 'call_ended':
          if (onCallEnded != null) {
            onCallEnded!();
          }
          break;

        case 'user_status_change':
          if (onUserStatusChange != null && data is Map<String, dynamic>) {
            final userId = data['userId']?.toString() ?? '';
            final isOnline = data['isOnline'] == true || data['isOnline'] == 1;
            onUserStatusChange!(userId, isOnline);
          }
          break;

        case 'live_location_received':
          if (onLiveLocationUpdate != null && data is Map<String, dynamic>) {
            onLiveLocationUpdate!(Map<String, dynamic>.from(data));
          }
          break;

        case 'live_location_stopped':
          if (onLiveLocationStopped != null && data is Map<String, dynamic>) {
            onLiveLocationStopped!(Map<String, dynamic>.from(data));
          }
          break;

        case 'message_deleted':
          if (onMessageDeleted != null && data is Map<String, dynamic>) {
            final msgId = data['messageId']?.toString() ?? '';
            final mode = data['mode']?.toString() ?? 'everyone';
            onMessageDeleted!(msgId, mode);
          }
          break;

        case 'message_edited':
          if (onMessageEdited != null && data is Map<String, dynamic>) {
            final msgId = data['messageId']?.toString() ?? '';
            final rawContent = data['content']?.toString() ?? '';
            final senderId = data['senderId']?.toString() ?? '';
            final receiverId = data['receiverId']?.toString() ?? '';
            final dec = EndToEndEncryptionService.decryptText(rawContent, senderId, receiverId);
            onMessageEdited!(msgId, dec);
          }
          break;

        case 'message_sent':
          if (onMessageSent != null && data is Map<String, dynamic>) {
            final tempId = data['clientTempId']?.toString() ?? '';
            final realId = data['id']?.toString() ?? '';
            if (tempId.isNotEmpty && realId.isNotEmpty) {
              onMessageSent!(tempId, realId);
            }
          }
          break;
      }
    } catch (e) {
      debugPrint('[GORILLA WS] Parse error: $e');
    }
  }

  // Report message delivered
  void emitMessageDelivered({required String senderId, required String receiverId, String? messageId}) {
    _emit('message_delivered', {
      'senderId': senderId,
      'receiverId': receiverId,
      if (messageId != null) 'messageId': messageId,
    });
  }

  // Report message read
  void emitMessageRead({required String senderId, required String receiverId, String? messageId}) {
    _emit('message_read', {
      'senderId': senderId,
      'receiverId': receiverId,
      if (messageId != null) 'messageId': messageId,
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
    _emit('live_location_update', {
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
    _emit('stop_live_location', {
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
    _emit('send_message', {
      'senderId': senderId,
      'receiverId': receiverId,
      'content': content,
      'type': type,
      if (mediaUrl != null) 'mediaUrl': mediaUrl,
      if (clientTempId != null) 'clientTempId': clientTempId,
    });
  }

  // Emit WebRTC Call
  void emitCall({
    required UserModel caller,
    required String receiverId,
    required Map<String, dynamic> offer,
    required String callType,
  }) {
    _emit('call_user', {
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
    _emit('answer_call', {
      'callerId': callerId,
      'answer': answer,
    });
  }

  // Emit ICE Candidate
  void emitIceCandidate({
    required String targetUserId,
    required Map<String, dynamic> candidate,
  }) {
    _emit('ice_candidate', {
      'targetUserId': targetUserId,
      'candidate': candidate,
    });
  }

  // Emit End Call
  void emitEndCall(String targetUserId) {
    _emit('end_call', {
      'targetUserId': targetUserId,
    });
  }

  // Delete message (mode: 'everyone' or 'me')
  void deleteMessage({
    required String messageId,
    required String senderId,
    required String receiverId,
    String mode = 'everyone',
  }) {
    _emit('delete_message', {
      'messageId': messageId,
      'senderId': senderId,
      'receiverId': receiverId,
      'mode': mode,
    });
  }

  // Edit message
  void editMessage({
    required String messageId,
    required String senderId,
    required String receiverId,
    required String newContent,
  }) {
    _emit('edit_message', {
      'messageId': messageId,
      'senderId': senderId,
      'receiverId': receiverId,
      'newContent': newContent,
    });
  }

  void disconnect() {
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    _currentUserId = null;
    _socket?.close();
    _socket = null;
  }
}
