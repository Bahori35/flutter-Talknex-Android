import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MessageReaction {
  final String userId;
  final String userName;
  final String emoji;
  final DateTime timestamp;

  MessageReaction({
    required this.userId,
    required this.userName,
    required this.emoji,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
    'userId': userId,
    'userName': userName,
    'emoji': emoji,
    'timestamp': timestamp.toIso8601String(),
  };

  factory MessageReaction.fromJson(Map<String, dynamic> json) => MessageReaction(
    userId: json['userId']?.toString() ?? '',
    userName: json['userName']?.toString() ?? '',
    emoji: json['emoji']?.toString() ?? '',
    timestamp: DateTime.tryParse(json['timestamp']?.toString() ?? '') ?? DateTime.now(),
  );
}

class MessageReactionsService {
  static const String _prefKey = 'talknex_reactions_v1';
  // messageId -> (userId -> MessageReaction)
  static final Map<String, Map<String, MessageReaction>> _reactions = {};
  static bool _isInitialized = false;

  /// ValueNotifier fired whenever reaction changes (so widgets can update reactively)
  static final ValueNotifier<int> reactionNotifier = ValueNotifier<int>(0);

  /// Standard popular quick reactions like WhatsApp
  static const List<String> quickReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

  static Future<void> init() async {
    if (_isInitialized) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          _reactions.clear();
          decoded.forEach((msgId, userMap) {
            if (userMap is Map<String, dynamic>) {
              final map = <String, MessageReaction>{};
              userMap.forEach((uId, rData) {
                if (rData is Map<String, dynamic>) {
                  map[uId] = MessageReaction.fromJson(rData);
                }
              });
              _reactions[msgId] = map;
            }
          });
        }
      }
      _isInitialized = true;
    } catch (e) {
      debugPrint('[REACTIONS INIT ERR] $e');
      _isInitialized = true;
    }
  }

  static Future<void> _saveToPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final serialized = <String, dynamic>{};
      _reactions.forEach((msgId, userMap) {
        if (userMap.isNotEmpty) {
          final uMap = <String, dynamic>{};
          userMap.forEach((uId, reaction) {
            uMap[uId] = reaction.toJson();
          });
          serialized[msgId] = uMap;
        }
      });
      await prefs.setString(_prefKey, jsonEncode(serialized));
    } catch (e) {
      debugPrint('[REACTIONS SAVE ERR] $e');
    }
  }

  /// Get all reactions for a specific message
  static List<MessageReaction> getReactions(String messageId) {
    if (!_isInitialized) init();
    final map = _reactions[messageId];
    if (map == null || map.isEmpty) return [];
    return map.values.toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  /// Get grouped emoji counts for a message, sorted by popularity
  static List<({String emoji, int count})> getEmojiCounts(String messageId) {
    final list = getReactions(messageId);
    if (list.isEmpty) return [];
    final map = <String, int>{};
    for (final r in list) {
      map[r.emoji] = (map[r.emoji] ?? 0) + 1;
    }
    return map.entries.map((e) => (emoji: e.key, count: e.value)).toList()
      ..sort((a, b) => b.count.compareTo(a.count));
  }

  /// Check which emoji a specific user reacted with (or null)
  static String? getUserReaction(String messageId, String userId) {
    if (!_isInitialized) init();
    return _reactions[messageId]?[userId]?.emoji;
  }

  /// Toggle or set a reaction from the current user
  /// If user taps the SAME emoji they already reacted with, it is removed (toggled off).
  /// Returns the newly set emoji, or null if removed.
  static Future<String?> toggleReaction({
    required String messageId,
    required String userId,
    required String userName,
    required String emoji,
  }) async {
    if (!_isInitialized) await init();
    if (messageId.isEmpty || userId.isEmpty) return null;

    final currentEmoji = _reactions[messageId]?[userId]?.emoji;
    String? newEmoji;

    if (currentEmoji == emoji) {
      // Toggle off / remove reaction
      _reactions[messageId]?.remove(userId);
      if (_reactions[messageId]?.isEmpty ?? false) {
        _reactions.remove(messageId);
      }
      newEmoji = null;
    } else {
      // Add or update reaction
      _reactions.putIfAbsent(messageId, () => {})[userId] = MessageReaction(
        userId: userId,
        userName: userName,
        emoji: emoji,
        timestamp: DateTime.now(),
      );
      newEmoji = emoji;
    }

    reactionNotifier.value++;
    await _saveToPrefs();
    return newEmoji;
  }

  /// Handle an incoming reaction event from WebSocket
  static Future<void> applyIncomingReaction({
    required String messageId,
    required String userId,
    required String userName,
    required String emoji,
  }) async {
    if (!_isInitialized) await init();
    if (messageId.isEmpty || userId.isEmpty) return;

    if (emoji.isEmpty) {
      // Removed
      _reactions[messageId]?.remove(userId);
      if (_reactions[messageId]?.isEmpty ?? false) {
        _reactions.remove(messageId);
      }
    } else {
      // Added or updated
      _reactions.putIfAbsent(messageId, () => {})[userId] = MessageReaction(
        userId: userId,
        userName: userName.isNotEmpty ? userName : 'Kullanıcı',
        emoji: emoji,
        timestamp: DateTime.now(),
      );
    }

    reactionNotifier.value++;
    await _saveToPrefs();
  }
}
