import 'package:intl/intl.dart';

class AiReminderModel {
  final String id;
  final String title;
  final DateTime eventTime;
  final int leadMinutes;
  final DateTime reminderTime;
  bool isCompleted;
  final DateTime createdAt;

  AiReminderModel({
    required this.id,
    required this.title,
    required this.eventTime,
    required this.leadMinutes,
    required this.reminderTime,
    this.isCompleted = false,
    required this.createdAt,
  });

  static const List<String> _turkishMonths = [
    'Ocak', 'Şubat', 'Mart', 'Nisan', 'Mayıs', 'Haziran',
    'Temmuz', 'Ağustos', 'Eylül', 'Ekim', 'Kasım', 'Aralık'
  ];

  String get formattedEventTime {
    try {
      final mIndex = (eventTime.month - 1).clamp(0, 11);
      final m = _turkishMonths[mIndex];
      final hh = eventTime.hour.toString().padLeft(2, '0');
      final mm = eventTime.minute.toString().padLeft(2, '0');
      return '${eventTime.day} $m ${eventTime.year}, $hh:$mm';
    } catch (_) {
      return '${eventTime.day}.${eventTime.month}.${eventTime.year} ${eventTime.hour.toString().padLeft(2, '0')}:${eventTime.minute.toString().padLeft(2, '0')}';
    }
  }

  String get formattedEventTimeSimple {
    try {
      final mIndex = (eventTime.month - 1).clamp(0, 11);
      final m = _turkishMonths[mIndex];
      final hh = eventTime.hour.toString().padLeft(2, '0');
      final mm = eventTime.minute.toString().padLeft(2, '0');
      return '${eventTime.day} $m $hh:$mm';
    } catch (_) {
      return '${eventTime.day}.${eventTime.month} ${eventTime.hour.toString().padLeft(2, '0')}:${eventTime.minute.toString().padLeft(2, '0')}';
    }
  }

  String get formattedReminderTime {
    try {
      final hh = reminderTime.hour.toString().padLeft(2, '0');
      final mm = reminderTime.minute.toString().padLeft(2, '0');
      return '$hh:$mm';
    } catch (_) {
      return '${reminderTime.hour}:${reminderTime.minute}';
    }
  }

  String get leadTimeText {
    if (leadMinutes <= 0) return 'Tam vaktinde';
    if (leadMinutes == 30) return '30 dakika önce';
    if (leadMinutes == 60) return '1 saat önce';
    if (leadMinutes == 120) return '2 saat önce';
    if (leadMinutes < 60) return '$leadMinutes dk önce';
    return '${leadMinutes ~/ 60} saat önce';
  }

  String get remainingTimeText {
    final now = DateTime.now();
    if (reminderTime.isBefore(now)) return 'Vakti geçti';
    final diff = reminderTime.difference(now);
    if (diff.inDays > 0) return '${diff.inDays} gün kaldı';
    if (diff.inHours > 0) return '${diff.inHours} saat ${diff.inMinutes % 60} dk kaldı';
    if (diff.inMinutes > 0) return '${diff.inMinutes} dakika kaldı';
    return '${diff.inSeconds} saniye kaldı';
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'eventTime': eventTime.toIso8601String(),
    'leadMinutes': leadMinutes,
    'reminderTime': reminderTime.toIso8601String(),
    'isCompleted': isCompleted,
    'createdAt': createdAt.toIso8601String(),
  };

  factory AiReminderModel.fromJson(Map<String, dynamic> json) => AiReminderModel(
    id: json['id'] ?? '',
    title: json['title'] ?? 'Plan',
    eventTime: DateTime.tryParse(json['eventTime'] ?? '') ?? DateTime.now(),
    leadMinutes: json['leadMinutes'] ?? 0,
    reminderTime: DateTime.tryParse(json['reminderTime'] ?? '') ?? DateTime.now(),
    isCompleted: json['isCompleted'] ?? false,
    createdAt: DateTime.tryParse(json['createdAt'] ?? '') ?? DateTime.now(),
  );
}
