import 'package:cloud_firestore/cloud_firestore.dart';
import '../utils/media_url_helper.dart';
import 'message_envelope.dart';
import '../services/starred_messages_service.dart';

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
  final ReplyMetadata? replyTo;
  final bool isForwarded;
  final bool isStarred;

  String? get replyToText => replyTo?.text;
  String? get replyToSender => replyTo?.sender;
  String? get replyToId => replyTo?.id;
  String? get replyToType => replyTo?.type;

  factory MessageModel({
    required String id,
    required String senderId,
    String? senderName,
    required String receiverId,
    required String content,
    MessageType type = MessageType.text,
    required DateTime timestamp,
    bool isDelivered = false,
    bool isRead = false,
    String? mediaUrl,
    bool isDeleted = false,
    bool isEdited = false,
    String? originalContent,
    ReplyMetadata? replyTo,
    bool isForwarded = false,
    bool isStarred = false,
  }) {
    final unpacked = MessageEnvelope.unpack(content);
    final effectiveReply = replyTo ?? unpacked.replyTo;
    final effectiveForwarded = isForwarded || unpacked.isForwarded;
    final effectiveStarred = isStarred || StarredMessagesService.isStarred(id);

    return MessageModel._(
      id: id,
      senderId: senderId,
      senderName: senderName,
      receiverId: receiverId,
      content: unpacked.text,
      type: type,
      timestamp: timestamp,
      isDelivered: isDelivered,
      isRead: isRead,
      mediaUrl: formatMediaUrl(mediaUrl),
      isDeleted: isDeleted,
      isEdited: isEdited,
      originalContent: originalContent,
      replyTo: effectiveReply,
      isForwarded: effectiveForwarded,
      isStarred: effectiveStarred,
    );
  }

  const MessageModel._({
    required this.id,
    required this.senderId,
    this.senderName,
    required this.receiverId,
    required this.content,
    this.type = MessageType.text,
    required this.timestamp,
    this.isDelivered = false,
    this.isRead = false,
    this.mediaUrl,
    this.isDeleted = false,
    this.isEdited = false,
    this.originalContent,
    this.replyTo,
    this.isForwarded = false,
    this.isStarred = false,
  });

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
      if (replyTo != null) 'replyTo': replyTo!.toJson(),
      'isForwarded': isForwarded,
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

    final rawContent = map['content']?.toString() ?? '';
    final unpacked = MessageEnvelope.unpack(rawContent);

    ReplyMetadata? reply = unpacked.replyTo;
    if (reply == null && map['replyTo'] is Map) {
      reply = ReplyMetadata.fromJson(Map<String, dynamic>.from(map['replyTo']));
    }

    final isFwd = unpacked.isForwarded || map['isForwarded'] == 1 || map['isForwarded'] == true;
    final starred = map['isStarred'] == true || StarredMessagesService.isStarred(docId);

    return MessageModel(
      id: docId,
      senderId: map['senderId']?.toString() ?? '',
      senderName: map['senderName'],
      receiverId: map['receiverId']?.toString() ?? '',
      content: unpacked.text,
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
      replyTo: reply,
      isForwarded: isFwd,
      isStarred: starred,
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
    ReplyMetadata? replyTo,
    bool? isForwarded,
    bool? isStarred,
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
      replyTo: replyTo ?? this.replyTo,
      isForwarded: isForwarded ?? this.isForwarded,
      isStarred: isStarred ?? this.isStarred,
    );
  }
}
