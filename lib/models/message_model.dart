import 'package:cloud_firestore/cloud_firestore.dart';
import '../utils/media_url_helper.dart';

enum MessageType { text, image, video, doc, audio, call, location, gif, sticker, contact }

class MessageModel {
  final String id;
  final String senderId;
  final String? senderName;
  final String receiverId;
  final String content;
  final MessageType type;
  final DateTime timestamp;
  final bool isDelivered;
  final bool isRead;
  final String? mediaUrl;
  final bool isDeleted;
  final bool isEdited;
  final String? originalContent;

  MessageModel({
    required this.id,
    required this.senderId,
    this.senderName,
    required this.receiverId,
    required this.content,
    this.type = MessageType.text,
    required this.timestamp,
    this.isDelivered = false,
    this.isRead = false,
    String? mediaUrl,
    this.isDeleted = false,
    this.isEdited = false,
    this.originalContent,
  }) : mediaUrl = formatMediaUrl(mediaUrl);

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'senderId': senderId,
      'senderName': senderName,
      'receiverId': receiverId,
      'content': content,
      'type': type.name,
      'timestamp': timestamp.toIso8601String(),
      'isDelivered': isDelivered,
      'isRead': isRead,
      'mediaUrl': mediaUrl,
      'isDeleted': isDeleted,
      'isEdited': isEdited,
      'originalContent': originalContent,
    };
  }

  factory MessageModel.fromMap(Map<String, dynamic> map, String docId) {
    DateTime parsedTime = DateTime.now();
    if (map['timestamp'] != null) {
      if (map['timestamp'] is String) {
        parsedTime = DateTime.tryParse(map['timestamp']) ?? DateTime.now();
      } else if (map['timestamp'] is Timestamp) {
        parsedTime = (map['timestamp'] as Timestamp).toDate();
      }
    }

    return MessageModel(
      id: docId,
      senderId: map['senderId']?.toString() ?? '',
      senderName: map['senderName'],
      receiverId: map['receiverId']?.toString() ?? '',
      content: map['content'] ?? '',
      type: MessageType.values.firstWhere(
        (e) => e.name == map['type'],
        orElse: () => MessageType.text,
      ),
      timestamp: parsedTime,
      isDelivered: map['isDelivered'] == 1 || map['isDelivered'] == true || map['isRead'] == 1 || map['isRead'] == true,
      isRead: map['isRead'] == 1 || map['isRead'] == true,
      mediaUrl: map['mediaUrl'],
      isDeleted: map['isDeleted'] == 1 || map['isDeleted'] == true,
      isEdited: map['isEdited'] == 1 || map['isEdited'] == true,
      originalContent: map['originalContent'],
    );
  }

  MessageModel copyWith({
    String? id,
    String? senderId,
    String? senderName,
    String? receiverId,
    String? content,
    MessageType? type,
    DateTime? timestamp,
    bool? isDelivered,
    bool? isRead,
    String? mediaUrl,
    bool? isDeleted,
    bool? isEdited,
    String? originalContent,
  }) {
    return MessageModel(
      id: id ?? this.id,
      senderId: senderId ?? this.senderId,
      senderName: senderName ?? this.senderName,
      receiverId: receiverId ?? this.receiverId,
      content: content ?? this.content,
      type: type ?? this.type,
      timestamp: timestamp ?? this.timestamp,
      isDelivered: isDelivered ?? this.isDelivered,
      isRead: isRead ?? this.isRead,
      mediaUrl: mediaUrl ?? this.mediaUrl,
      isDeleted: isDeleted ?? this.isDeleted,
      isEdited: isEdited ?? this.isEdited,
      originalContent: originalContent ?? this.originalContent,
    );
  }
}

