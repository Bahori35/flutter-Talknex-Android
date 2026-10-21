import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import '../models/message_model.dart';
import '../models/user_model.dart';
import 'encryption_service.dart';
import '../models/message_envelope.dart';
import 'starred_messages_service.dart';
import 'message_reactions_service.dart';

typedef OnMessageReactionReceived = void Function(Map<String, dynamic> data);
typedef OnGroupMessageReactionReceived = void Function(Map<String, dynamic> data);

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
typedef OnGroupMessageReceived = void Function(Map<String, dynamic> data);
typedef OnGroupMessageDeleted = void Function(String messageId, String groupId, [String mode]);
typedef OnGroupMessageSent = void Function(String tempId, String realId, String groupId);
typedef OnGroupMessageEdited = void Function(String messageId, String groupId, String newContent);
typedef OnGroupDeleted = void Function(String groupId, String message);
typedef OnGroupPollUpdated = void Function(Map<String, dynamic> data);
typedef OnGroupEventUpdated = void Function(Map<String, dynamic> data);

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
  String? get currentUserId => _currentUserId;

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
  final StreamController<Map<String, dynamic>> _liveLocationStreamController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get liveLocationStream => _liveLocationStreamController.stream;
  final StreamController<Map<String, dynamic>> _liveLocationStoppedStreamController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get liveLocationStoppedStream => _liveLocationStoppedStreamController.stream;
  final Map<String, Map<String, dynamic>> lastLiveLocations = {};
  OnMessageDeleted? onMessageDeleted;
  OnMessageEdited? onMessageEdited;
  OnMessageSent? onMessageSent;
  OnGroupMessageReceived? onGroupMessageReceived;
  OnGroupMessageDeleted? onGroupMessageDeleted;
  OnGroupMessageSent? onGroupMessageSent;
  OnGroupMessageEdited? onGroupMessageEdited;
  OnGroupDeleted? onGroupDeleted;
  OnGroupPollUpdated? onGroupPollUpdated;
  OnGroupEventUpdated? onGroupEventUpdated;
  OnMessageReactionReceived? onMessageReactionReceived;
  OnGroupMessageReactionReceived? onGroupMessageReactionReceived;

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

            final unpacked = MessageEnvelope.unpack(decryptedContent);
            final msgId = data['id'].toString();
            final isStarred = StarredMessagesService.isStarred(msgId);

            final message = MessageModel(
              id: msgId,
              senderId: data['senderId'].toString(),
              receiverId: data['receiverId'].toString(),
              content: unpacked.text,
              type: msgType,
              timestamp: DateTime.tryParse(data['timestamp'] ?? '') ?? DateTime.now(),
              isDelivered: true,
              isRead: data['isRead'] == 1 || data['isRead'] == true,
              mediaUrl: data['mediaUrl'],
              replyTo: unpacked.replyTo,
              isForwarded: unpacked.isForwarded,
              isStarred: isStarred,
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
          if (data is Map<String, dynamic>) {
            final sId = data['senderId']?.toString();
            final mapData = Map<String, dynamic>.from(data);
            if (sId != null && sId.isNotEmpty) {
              lastLiveLocations[sId] = mapData;
            }
            if (!_liveLocationStreamController.isClosed) {
              _liveLocationStreamController.add(mapData);
            }
            if (onLiveLocationUpdate != null) {
              onLiveLocationUpdate!(mapData);
            }
          }
          break;

        case 'live_location_stopped':
          if (data is Map<String, dynamic>) {
            final sId = data['senderId']?.toString();
            final mapData = Map<String, dynamic>.from(data);
            if (sId != null && sId.isNotEmpty) {
              lastLiveLocations.remove(sId);
            }
            if (!_liveLocationStoppedStreamController.isClosed) {
              _liveLocationStoppedStreamController.add(mapData);
            }
            if (onLiveLocationStopped != null) {
              onLiveLocationStopped!(mapData);
            }
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

        case 'receive_group_message':
          if (onGroupMessageReceived != null && data is Map<String, dynamic>) {
            onGroupMessageReceived!(Map<String, dynamic>.from(data));
          }
          break;

        case 'group_message_deleted':
          if (onGroupMessageDeleted != null && data is Map<String, dynamic>) {
            final msgId = data['messageId']?.toString() ?? '';
            final gId = data['groupId']?.toString() ?? '';
            final mode = data['mode']?.toString() ?? 'everyone';
            onGroupMessageDeleted!(msgId, gId, mode);
          }
          break;

        case 'group_message_sent':
          if (onGroupMessageSent != null && data is Map<String, dynamic>) {
            final tempId = data['clientTempId']?.toString() ?? '';
            final realId = data['id']?.toString() ?? '';
            final gId = data['groupId']?.toString() ?? '';
            if (tempId.isNotEmpty && realId.isNotEmpty) {
              onGroupMessageSent!(tempId, realId, gId);
            }
          }
          break;

        case 'group_deleted':
          if (onGroupDeleted != null && data is Map<String, dynamic>) {
            final gId = data['groupId']?.toString() ?? '';
            final msg = data['message']?.toString() ?? 'Grup kapatıldı';
            onGroupDeleted!(gId, msg);
          }
          break;

        case 'group_message_edited':
          if (onGroupMessageEdited != null && data is Map<String, dynamic>) {
            final msgId = data['messageId']?.toString() ?? '';
            final gId = data['groupId']?.toString() ?? '';
            final newText = data['newContent']?.toString() ?? '';
            onGroupMessageEdited!(msgId, gId, newText);
          }
          break;

        case 'group_poll_updated':
          if (onGroupPollUpdated != null && data is Map<String, dynamic>) {
            onGroupPollUpdated!(Map<String, dynamic>.from(data));
          }
          break;

        case 'group_event_updated':
          if (onGroupEventUpdated != null && data is Map<String, dynamic>) {
            onGroupEventUpdated!(Map<String, dynamic>.from(data));
          }
          break;

        case 'message_reaction':
        case 'receive_message_reaction':
          if (data is Map<String, dynamic>) {
            final mapData = Map<String, dynamic>.from(data);
            MessageReactionsService.applyIncomingReaction(
              messageId: mapData['messageId']?.toString() ?? '',
              userId: mapData['senderId']?.toString() ?? '',
              userName: mapData['senderName']?.toString() ?? '',
              emoji: mapData['emoji']?.toString() ?? '',
            );
            onMessageReactionReceived?.call(mapData);
          }
          break;

        case 'group_message_reaction':
        case 'receive_group_message_reaction':
          if (data is Map<String, dynamic>) {
            final mapData = Map<String, dynamic>.from(data);
            MessageReactionsService.applyIncomingReaction(
              messageId: mapData['messageId']?.toString() ?? '',
              userId: mapData['senderId']?.toString() ?? '',
              userName: mapData['senderName']?.toString() ?? '',
              emoji: mapData['emoji']?.toString() ?? '',
            );
            onGroupMessageReactionReceived?.call(mapData);
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
    final payload = {
      'senderId': senderId,
      'receiverId': receiverId,
      'latitude': latitude,
      'longitude': longitude,
      'heading': heading ?? 0.0,
      'speed': speed ?? 0.0,
      if (messageId != null) 'messageId': messageId,
    };
    lastLiveLocations[senderId] = payload;
    _emit('live_location_update', payload);
  }

  // Stop Live Location
  void emitStopLiveLocation({
    required String senderId,
    required String receiverId,
    String? messageId,
  }) {
    lastLiveLocations.remove(senderId);
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

  // Send group message
  void sendGroupMessage({
    required int groupId,
    required String senderId,
    required String content,
    String type = 'text',
    String? mediaUrl,
    String? clientTempId,
  }) {
    _emit('send_group_message', {
      'groupId': groupId,
      'senderId': senderId,
      'content': content,
      'type': type,
      'mediaUrl': mediaUrl ?? '',
      'clientTempId': clientTempId ?? '',
    });
  }

  // Delete group message (everyone or me)
  void deleteGroupMessage({
    required String messageId,
    required int groupId,
    String mode = 'everyone',
  }) {
    _emit('delete_group_message', {
      'messageId': messageId,
      'groupId': groupId,
      'mode': mode,
    });
  }

  // Edit group message
  void editGroupMessage({
    required String messageId,
    required int groupId,
    required String newContent,
  }) {
    _emit('edit_group_message', {
      'messageId': messageId,
      'groupId': groupId,
      'newContent': newContent,
    });
  }

  // Create group poll (admin only)
  void createGroupPoll({
    required int groupId,
    required String senderId,
    required String title,
    required List<String> options,
    required String durationType,
    required int durationValue,
    String? clientTempId,
  }) {
    _emit('create_group_poll', {
      'groupId': groupId,
      'senderId': senderId,
      'title': title,
      'options': options,
      'durationType': durationType,
      'durationValue': durationValue,
      'clientTempId': clientTempId ?? '',
    });
  }

  // Vote or toggle option on a group poll
  void voteGroupPoll({
    required int groupId,
    required int pollId,
    required int optionIndex,
  }) {
    _emit('vote_group_poll', {
      'groupId': groupId,
      'pollId': pollId,
      'optionIndex': optionIndex,
    });
  }

  // Create group event (admin only)
  void createGroupEvent({
    required int groupId,
    required String senderId,
    required String title,
    String description = '',
    required String location,
    double? latitude,
    double? longitude,
    required DateTime startTime,
    required DateTime endTime,
    required int reminderValue,
    required String reminderUnit,
    required bool allowGuests,
    String? clientTempId,
  }) {
    _emit('create_group_event', {
      'groupId': groupId,
      'senderId': senderId,
      'title': title,
      'description': description,
      'location': location,
      'latitude': latitude ?? 0.0,
      'longitude': longitude ?? 0.0,
      'startTime': startTime.toIso8601String(),
      'endTime': endTime.toIso8601String(),
      'reminderValue': reminderValue,
      'reminderUnit': reminderUnit,
      'allowGuests': allowGuests,
      'clientTempId': clientTempId ?? '',
    });
  }

  // RSVP response to a group event
  void rsvpGroupEvent({
    required int groupId,
    required int eventId,
    required String status,
    int guestCount = 0,
  }) {
    _emit('rsvp_group_event', {
      'groupId': groupId,
      'eventId': eventId,
      'status': status,
      'guestCount': guestCount,
    });
  }

  // Send 1-on-1 reaction
  void sendReaction({
    required String messageId,
    required String senderId,
    required String senderName,
    required String receiverId,
    required String emoji,
  }) {
    _emit('message_reaction', {
      'messageId': messageId,
      'senderId': senderId,
      'senderName': senderName,
      'receiverId': receiverId,
      'emoji': emoji,
    });
  }

  // Send group reaction
  void sendGroupReaction({
    required String messageId,
    required int groupId,
    required String senderId,
    required String senderName,
    required String emoji,
  }) {
    _emit('group_message_reaction', {
      'messageId': messageId,
      'groupId': groupId,
      'senderId': senderId,
      'senderName': senderName,
      'emoji': emoji,
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
