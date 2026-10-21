import 'dart:convert';

class ReplyMetadata {
  final String id;
  final String sender;
  final String text;
  final String type;

  const ReplyMetadata({
    required this.id,
    required this.sender,
    required this.text,
    this.type = 'text',
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'sender': sender,
    'text': text,
    'type': type,
  };

  factory ReplyMetadata.fromJson(Map<String, dynamic> json) => ReplyMetadata(
    id: json['id']?.toString() ?? '',
    sender: json['sender']?.toString() ?? '',
    text: json['text']?.toString() ?? '',
    type: json['type']?.toString() ?? 'text',
  );
}

class MessageEnvelope {
  static String pack({
    required String text,
    ReplyMetadata? replyTo,
    bool isForwarded = false,
  }) {
    if (replyTo == null && !isForwarded) {
      return text;
    }
    return jsonEncode({
      '_k': 'talknex_msg',
      'text': text,
      if (replyTo != null) 'replyTo': replyTo.toJson(),
      if (isForwarded) 'isForwarded': true,
    });
  }

  static ({String text, ReplyMetadata? replyTo, bool isForwarded}) unpack(String raw) {
    if (raw.startsWith('{') && raw.contains('"_k":"talknex_msg"')) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic> && decoded['_k'] == 'talknex_msg') {
          ReplyMetadata? reply;
          if (decoded['replyTo'] is Map) {
            reply = ReplyMetadata.fromJson(Map<String, dynamic>.from(decoded['replyTo']));
          }
          return (
            text: decoded['text']?.toString() ?? '',
            replyTo: reply,
            isForwarded: decoded['isForwarded'] == true,
          );
        }
      } catch (_) {}
    }
    return (text: raw, replyTo: null, isForwarded: false);
  }
}
