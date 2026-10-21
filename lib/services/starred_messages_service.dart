import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class StarredMessage {
  final String messageId;
  final String chatId; // peerUserId or "group_$groupId"
  final String chatTitle; // user displayName or group name
  final String senderId;
  final String senderName;
  final String content;
  final String type;
  final String? mediaUrl;
  final DateTime timestamp;
  final bool isGroup;

  StarredMessage({
    required this.messageId,
    required this.chatId,
    required this.chatTitle,
    required this.senderId,
    required this.senderName,
    required this.content,
    required this.type,
    this.mediaUrl,
    required this.timestamp,
    this.isGroup = false,
  });

  Map<String, dynamic> toJson() => {
    'messageId': messageId,
    'chatId': chatId,
    'chatTitle': chatTitle,
    'senderId': senderId,
    'senderName': senderName,
    'content': content,
    'type': type,
    if (mediaUrl != null) 'mediaUrl': mediaUrl,
    'timestamp': timestamp.toIso8601String(),
    'isGroup': isGroup,
  };

  factory StarredMessage.fromJson(Map<String, dynamic> json) => StarredMessage(
    messageId: json['messageId']?.toString() ?? '',
    chatId: json['chatId']?.toString() ?? '',
    chatTitle: json['chatTitle']?.toString() ?? 'Sohbet',
    senderId: json['senderId']?.toString() ?? '',
    senderName: json['senderName']?.toString() ?? '',
    content: json['content']?.toString() ?? '',
    type: json['type']?.toString() ?? 'text',
    mediaUrl: json['mediaUrl']?.toString(),
    timestamp: DateTime.tryParse(json['timestamp']?.toString() ?? '') ?? DateTime.now(),
    isGroup: json['isGroup'] == true,
  );
}

class StarredMessagesService {
  static const String _prefKey = 'talknex_starred_messages_v1';
  static final Map<String, StarredMessage> _cache = {};
  static bool _isInitialized = false;

  /// ValueNotifier fired whenever star status changes (so widgets can update reactively)
  static final ValueNotifier<int> starNotifier = ValueNotifier<int>(0);

  /// Initialize and load all starred messages from SharedPreferences into memory
  static Future<void> init() async {
    if (_isInitialized) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final rawList = prefs.getStringList(_prefKey) ?? [];
      _cache.clear();
      for (final str in rawList) {
        try {
          final decoded = jsonDecode(str);
          if (decoded is Map<String, dynamic>) {
            final item = StarredMessage.fromJson(decoded);
            if (item.messageId.isNotEmpty) {
              _cache[item.messageId] = item;
            }
          }
        } catch (_) {}
      }
      _isInitialized = true;
    } catch (e) {
      debugPrint('[STARRED SERVICE INIT ERR] $e');
    }
  }

  /// Instantaneous synchronous check if a message is starred
  static bool isStarred(String messageId) {
    if (!_isInitialized) {
      // Trigger lazy init in background
      init();
    }
    return _cache.containsKey(messageId);
  }

  /// Toggle star status for a message
  static Future<bool> toggleStar(StarredMessage item) async {
    await init();
    bool newlyStarred = false;
    if (_cache.containsKey(item.messageId)) {
      _cache.remove(item.messageId);
      newlyStarred = false;
    } else {
      _cache[item.messageId] = item;
      newlyStarred = true;
    }

    await _saveToDisk();
    starNotifier.value++;
    return newlyStarred;
  }

  /// Remove star from a message
  static Future<void> removeStar(String messageId) async {
    await init();
    if (_cache.containsKey(messageId)) {
      _cache.remove(messageId);
      await _saveToDisk();
      starNotifier.value++;
    }
  }

  /// Get list of starred messages (optionally filtered by chatId)
  static List<StarredMessage> getStarredMessages({String? chatId}) {
    if (!_isInitialized) {
      init();
    }
    final items = _cache.values.toList();
    if (chatId != null && chatId.isNotEmpty) {
      items.retainWhere((m) => m.chatId == chatId);
    }
    items.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return items;
  }

  static Future<void> _saveToDisk() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final serializedList = _cache.values.map((item) => jsonEncode(item.toJson())).toList();
      await prefs.setStringList(_prefKey, serializedList);
    } catch (e) {
      debugPrint('[STARRED SERVICE SAVE ERR] $e');
    }
  }
}
