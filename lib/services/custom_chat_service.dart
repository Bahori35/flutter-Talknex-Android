import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../models/user_model.dart';
import '../models/message_model.dart';
import '../models/story_model.dart';
import '../models/call_model.dart';
import '../models/group_model.dart';
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

  // Get chat history between two users with cursor & limit pagination
  Future<List<MessageModel>> getMessages(String user1, String user2, {int limit = 50, dynamic beforeId, int? offset}) async {
    try {
      String url = '$baseUrl/messages/$user1/$user2?limit=$limit';
      if (beforeId != null) {
        final bId = int.tryParse(beforeId.toString());
        if (bId != null && bId > 0) {
          url += '&beforeId=$bId';
        }
      } else if (offset != null && offset > 0) {
        url += '&offset=$offset';
      }

      final response = await http.get(
        Uri.parse(url),
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
            isDeleted: json['isDeleted'] == 1 || json['isDeleted'] == true || json['is_deleted'] == 1 || json['is_deleted'] == true,
            isEdited: json['isEdited'] == 1 || json['isEdited'] == true || json['is_edited'] == 1 || json['is_edited'] == true,
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
            lastMessage: json['lastMessage'] ?? '',
            lastTime: json['lastTime'] != null && json['lastTime'] != '' ? DateTime.tryParse(json['lastTime'].toString()) : null,
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

  // --- GROUP API METHODS ---
  Future<List<GroupModel>> getMyGroups(String userId) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/groups/my/$userId'),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((json) => GroupModel.fromJson(json)).toList();
      }
    } catch (e) {
      debugPrint('[GROUP] Error getting groups: $e');
    }
    return [];
  }

  Future<Map<String, dynamic>?> createGroup({
    required String name,
    required int createdBy,
    required List<int> memberIds,
    String photoUrl = '',
    String description = '',
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/groups'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'name': name,
          'createdBy': createdBy,
          'memberIds': memberIds,
          'photoUrl': photoUrl,
          'description': description,
        }),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      } else {
        final err = jsonDecode(response.body);
        return {'error': err['error'] ?? 'Grup oluşturulamadı'};
      }
    } catch (e) {
      debugPrint('[GROUP] Create group error: $e');
      return {'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>?> getGroupDetails(int groupId) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/groups/$groupId'),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
    } catch (e) {
      debugPrint('[GROUP] Get details error: $e');
    }
    return null;
  }

  Future<bool> updateGroupInfo({
    required int groupId,
    required int userId,
    String? name,
    String? photoUrl,
    String? description,
  }) async {
    try {
      final Map<String, dynamic> body = {'userId': userId};
      if (name != null) body['name'] = name;
      if (photoUrl != null) body['photoUrl'] = photoUrl;
      if (description != null) body['description'] = description;

      final response = await http.put(
        Uri.parse('$baseUrl/groups/$groupId'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 10));

      return response.statusCode == 200;
    } catch (e) {
      debugPrint('[GROUP] Update error: $e');
      return false;
    }
  }

  Future<Map<String, dynamic>> addGroupMembers({
    required int groupId,
    required int adminUserId,
    required List<int> userIds,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/groups/$groupId/members'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'adminUserId': adminUserId,
          'userIds': userIds,
        }),
      ).timeout(const Duration(seconds: 10));

      return jsonDecode(response.body);
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  Future<bool> updateMemberRole({
    required int groupId,
    required int adminUserId,
    required int targetUserId,
    required String newRole,
  }) async {
    try {
      final response = await http.put(
        Uri.parse('$baseUrl/groups/$groupId/members/role'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'adminUserId': adminUserId,
          'targetUserId': targetUserId,
          'newRole': newRole,
        }),
      ).timeout(const Duration(seconds: 10));

      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  Future<bool> removeGroupMember({
    required int groupId,
    required int targetUserId,
    required int requesterId,
  }) async {
    try {
      final response = await http.delete(
        Uri.parse('$baseUrl/groups/$groupId/members/$targetUserId?requesterId=$requesterId'),
      ).timeout(const Duration(seconds: 10));

      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  Future<Map<String, dynamic>> deleteGroup({
    required int groupId,
    required int userId,
  }) async {
    try {
      final response = await http.delete(
        Uri.parse('$baseUrl/groups/$groupId?userId=$userId'),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        return {'success': true};
      } else {
        final data = jsonDecode(response.body);
        return {'success': false, 'error': data['error'] ?? 'Grup silinemedi'};
      }
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  Future<List<GroupMessageModel>> getGroupMessages(int groupId, String currentUserId, {int limit = 50, dynamic beforeId, int? offset}) async {
    try {
      String url = '$baseUrl/groups/$groupId/messages?userId=$currentUserId&limit=$limit';
      if (beforeId != null) {
        final bId = int.tryParse(beforeId.toString());
        if (bId != null && bId > 0) {
          url += '&beforeId=$bId';
        }
      } else if (offset != null && offset > 0) {
        url += '&offset=$offset';
      }

      final response = await http.get(
        Uri.parse(url),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((json) {
          final map = Map<String, dynamic>.from(json);
          final mType = json['type']?.toString() ?? 'text';
          if (mType != 'poll' && mType != 'event') {
            final rawContent = json['content'] ?? '';
            final decrypted = EndToEndEncryptionService.decryptText(
              rawContent,
              json['senderId'].toString(),
              'group_$groupId',
            );
            map['content'] = decrypted;
          }
          return GroupMessageModel.fromJson(map);
        }).toList();
      }
    } catch (e) {
      debugPrint('[GROUP] Get messages error: $e');
    }
    return [];
  }
}
