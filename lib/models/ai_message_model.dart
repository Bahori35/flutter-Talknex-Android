import 'ai_reminder_model.dart';

class AiMessageModel {
  final String id;
  final String sender; // 'user' or 'ai'
  final String text;
  final DateTime timestamp;
  final AiReminderModel? reminder;
  final String? actionType;

  AiMessageModel({
    required this.id,
    required this.sender,
    required this.text,
    required this.timestamp,
    this.reminder,
    this.actionType,
  });

  bool get isUser => sender == 'user';
  bool get isAi => sender == 'ai';

  Map<String, dynamic> toJson() => {
    'id': id,
    'sender': sender,
    'text': text,
    'timestamp': timestamp.toIso8601String(),
    if (reminder != null) 'reminder': reminder!.toJson(),
    if (actionType != null) 'actionType': actionType,
  };

  factory AiMessageModel.fromJson(Map<String, dynamic> json) => AiMessageModel(
    id: json['id'] ?? '',
    sender: json['sender'] ?? 'ai',
    text: json['text'] ?? '',
    timestamp: DateTime.tryParse(json['timestamp'] ?? '') ?? DateTime.now(),
    reminder: json['reminder'] != null ? AiReminderModel.fromJson(json['reminder']) : null,
    actionType: json['actionType'],
  );
}
