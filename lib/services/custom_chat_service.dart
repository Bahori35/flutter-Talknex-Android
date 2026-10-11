import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../models/user_model.dart';
import '../models/message_model.dart';
import '../models/story_model.dart';
import '../models/call_model.dart';
import 'custom_auth_service.dart';
import 'encryption_service.dart';

class CustomChatService {
  static const String baseUrl = CustomAuthService.baseUrl;

  // Get all registered users from Python / MariaDB server
  Future<List<UserModel>> getUsers(String currentUserId) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/users?currentUserId=$currentUserId'),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((json) {
          return UserModel(
            uid: json['id'].toString(),
            username: json['username'] ?? '',
            email: '${json['username']}@custom.server',
            displayName: json['displayName'] ?? json['username'] ?? 'User',
            photoUrl: json['photoUrl'] ?? '',
            status: json['status'] ?? 'Hey there! I am using this app.',
            isOnline: json['isOnline'] == 1 || json['isOnline'] == true,
          );
        }).toList();
      }
    } catch (e) {
      debugPrint('Error fetching users from custom server: $e');
    }
    return [];
  }

  // Get chat history between two users
  Future<List<MessageModel>> getMessages(String user1, String user2) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/messages/$user1/$user2'),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((json) {
          final typeStr = json['type'] ?? json['message_type'] ?? 'text';
          final msgType = MessageType.values.firstWhere(
            (e) => e.name == typeStr,
            orElse: () => MessageType.text,
          );

          final rawContent = json['content'] ?? '';
          final decryptedContent = EndToEndEncryptionService.decryptText(
            rawContent,
            json['senderId'].toString(),
            json['receiverId'].toString(),
          );

          return MessageModel(
            id: json['id'].toString(),
            senderId: json['senderId'].toString(),
            receiverId: json['receiverId'].toString(),
            content: decryptedContent,
            type: msgType,
            timestamp: DateTime.tryParse(json['timestamp'] ?? '') ?? DateTime.now(),
            isDelivered: json['isDelivered'] == 1 || json['isDelivered'] == true || json['isRead'] == 1 || json['isRead'] == true,
            isRead: json['isRead'] == 1 || json['isRead'] == true,
            mediaUrl: json['mediaUrl'],
          );
        }).toList();
      }
    } catch (e) {
      debugPrint('Error fetching messages: $e');
    }
    return [];
  }

  // --- STORY SERVICE METHODS ---
  Future<List<UserStoryGroup>> getStories(String currentUserId) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/stories?currentUserId=$currentUserId'),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((json) => UserStoryGroup.fromJson(json)).toList();
      }
    } catch (e) {
      debugPrint('Error fetching stories: $e');
    }
    return [];
  }

  Future<bool> createStory({
    required int userId,
    required String mediaUrl,
    String caption = '',
    String mediaType = 'image',
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/stories'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'userId': userId,
          'mediaUrl': mediaUrl,
          'caption': caption,
          'mediaType': mediaType,
        }),
      ).timeout(const Duration(seconds: 10));

      return response.statusCode == 200;
    } catch (e) {
      debugPrint('Error creating story: $e');
      return false;
    }
  }

  Future<void> markStoryViewed(int storyId, int viewerId) async {
    try {
      await http.post(
        Uri.parse('$baseUrl/stories/view'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'storyId': storyId,
          'viewerId': viewerId,
        }),
      ).timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('Error marking story view: $e');
    }
  }

  Future<bool> deleteStory(int storyId, int userId) async {
    try {
      final response = await http.delete(
        Uri.parse('$baseUrl/stories/$storyId?userId=$userId'),
      ).timeout(const Duration(seconds: 10));
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('Error deleting story: $e');
      return false;
    }
  }

  // --- CONTACTS SYNC METHOD ---
  Future<List<UserModel>> syncContacts({
    required int userId,
    required List<Map<String, String>> contacts,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/users/sync-contacts'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'userId': userId,
          'contacts': contacts,
        }),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((json) {
          return UserModel(
            uid: json['id'].toString(),
            username: json['username'] ?? '',
            email: '${json['username']}@custom.server',
            displayName: json['displayName'] ?? json['username'] ?? 'User',
            photoUrl: json['photoUrl'] ?? '',
            phoneNumber: json['phoneNumber'] ?? '',
            status: json['status'] ?? 'Hey there! I am using this app.',
            isOnline: json['isOnline'] == 1 || json['isOnline'] == true,
          );
        }).toList();
      }
    } catch (e) {
      debugPrint('Error syncing contacts: $e');
    }
    return [];
  }

  // --- CALL LOGS API METHODS ---
  Future<bool> saveCallLog({
    required int callerId,
    required int receiverId,
    required String callType,
    required String callStatus,
    int durationSeconds = 0,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/calls/logs'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'callerId': callerId,
          'receiverId': receiverId,
          'callType': callType,
          'callStatus': callStatus,
          'durationSeconds': durationSeconds,
        }),
      ).timeout(const Duration(seconds: 5));
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('[CALL LOG] Error saving log: $e');
      return false;
    }
  }

  Future<List<CallModel>> getCallLogs(String userId) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/calls/logs/$userId'),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((json) => CallModel.fromJson(json)).toList();
      }
    } catch (e) {
      debugPrint('[CALL LOG] Error fetching logs: $e');
    }
    return [];
  }
}
