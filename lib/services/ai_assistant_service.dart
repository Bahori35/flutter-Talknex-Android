import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/ai_message_model.dart';
import '../models/ai_reminder_model.dart';
import 'notification_service.dart';

class AiAssistantService {
  static final ValueNotifier<int> notifier = ValueNotifier<int>(0);

  static final List<AiMessageModel> _messages = [];
  static final List<AiReminderModel> _reminders = [];
  static final Map<String, Timer> _activeTimers = {};

  static bool _isInitialized = false;
  static const String _prefKeyMessages = 'talknex_ai_chat_messages_v2';
  static const String _prefKeyReminders = 'talknex_ai_reminders_v2';

  static List<AiMessageModel> get messages => List.unmodifiable(_messages);
  static List<AiReminderModel> get reminders => List.unmodifiable(_reminders);

  static List<AiReminderModel> get activeReminders {
    final now = DateTime.now();
    return _reminders.where((r) => !r.isCompleted && r.eventTime.isAfter(now)).toList()
      ..sort((a, b) => a.eventTime.compareTo(b.eventTime));
  }

  static Future<void> init() async {
    if (_isInitialized) return;
    try {
      final prefs = await SharedPreferences.getInstance();

      // Load Reminders
      final remindersRaw = prefs.getString(_prefKeyReminders);
      if (remindersRaw != null && remindersRaw.isNotEmpty) {
        final decoded = jsonDecode(remindersRaw);
        if (decoded is List) {
          _reminders.clear();
          for (final item in decoded) {
            _reminders.add(AiReminderModel.fromJson(item));
          }
        }
      }

      // Schedule active timers
      final now = DateTime.now();
      for (final r in _reminders) {
        if (!r.isCompleted) {
          if (r.reminderTime.isAfter(now)) {
            _scheduleTimer(r);
          }
        }
      }

      // Load Messages
      final messagesRaw = prefs.getString(_prefKeyMessages);
      if (messagesRaw != null && messagesRaw.isNotEmpty) {
        final decoded = jsonDecode(messagesRaw);
        if (decoded is List) {
          _messages.clear();
          for (final item in decoded) {
            _messages.add(AiMessageModel.fromJson(item));
          }
        }
      }

      // Initial welcome message if empty
      if (_messages.isEmpty) {
        _messages.add(
          AiMessageModel(
            id: const Uuid().v4(),
            sender: 'ai',
            text: 'Merhaba! Ben Talknex Asistan 🤖\n\n'
                'Senin kişisel yapay zeka asistanınım. Günlük planlarını, toplantılarını ve randevularını bana söyleyebilirsin.\n\n'
                'Örneğin:\n'
                '• "Yarın saat 14:00\'te toplantım var, 30 dakika önce hatırlat"\n'
                '• "Bugün akşam 20:00\'de maç var, 15 dk önce haber ver"\n'
                '• "20 dakika sonra fırını kapatmamı hatırlat"\n'
                '• "Aktif planlarımı göster"\n\n'
                'Ayrıca aklına takılan her şeyi sorabilir, benimle sohbet de edebilirsin! Nasıl yardımcı olabilirim? ✨',
            timestamp: DateTime.now(),
          ),
        );
      }

      _isInitialized = true;
      notifier.value++;
    } catch (e) {
      debugPrint('[AI ASSISTANT] Init error: $e');
    }
  }

  static Future<void> _persistMessages() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = jsonEncode(_messages.map((m) => m.toJson()).toList());
      await prefs.setString(_prefKeyMessages, data);
    } catch (_) {}
  }

  static Future<void> _persistReminders() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = jsonEncode(_reminders.map((r) => r.toJson()).toList());
      await prefs.setString(_prefKeyReminders, data);
    } catch (_) {}
  }

  static void _scheduleTimer(AiReminderModel reminder) {
    _activeTimers[reminder.id]?.cancel();
    final now = DateTime.now();
    final duration = reminder.reminderTime.difference(now);

    if (duration.isNegative || duration == Duration.zero) {
      _triggerReminder(reminder);
      return;
    }

    _activeTimers[reminder.id] = Timer(duration, () {
      _triggerReminder(reminder);
    });
  }

  static Future<void> _triggerReminder(AiReminderModel reminder) async {
    reminder.isCompleted = true;
    await _persistReminders();
    _activeTimers.remove(reminder.id);

    // Show Notification
    final notifId = reminder.id.hashCode & 0x7FFFFFFF;
    final leadText = reminder.leadMinutes > 0 ? '${reminder.leadMinutes} dakika sonra' : 'şimdi';
    await NotificationService().showReminderNotification(
      id: notifId,
      title: '⏰ Hatırlatıcı: ${reminder.title}',
      body: 'Planlanan saat: ${reminder.formattedReminderTime} ($leadText başlayacak).',
    );

    // Add notification message to AI chat
    _messages.add(
      AiMessageModel(
        id: const Uuid().v4(),
        sender: 'ai',
        text: '⏰ **HATIRLATICI BİLDİRİMİ!**\n\n'
            '📌 **${reminder.title}** planınızın vakti yaklaştı!\n'
            '📅 Plan Saati: ${DateFormat('HH:mm').format(reminder.eventTime)} ($leadText)\n\n'
            'Hazırlanmayı unutmayın! 🎯',
        timestamp: DateTime.now(),
        actionType: 'reminder_alert',
        reminder: reminder,
      ),
    );
    await _persistMessages();
    notifier.value++;
  }

  /// Cancel a reminder
  static Future<bool> cancelReminder(String reminderId) async {
    _activeTimers[reminderId]?.cancel();
    _activeTimers.remove(reminderId);

    final index = _reminders.indexWhere((r) => r.id == reminderId);
    if (index != -1) {
      _reminders.removeAt(index);
      await _persistReminders();
      notifier.value++;
      return true;
    }
    return false;
  }

  /// Trigger test notification immediately for a reminder
  static Future<void> testTriggerReminder(AiReminderModel reminder) async {
    final notifId = reminder.id.hashCode & 0x7FFFFFFF;
    await NotificationService().showReminderNotification(
      id: notifId,
      title: '🔔 Test Bildirimi: ${reminder.title}',
      body: 'Planlanan etkinlik: ${reminder.formattedEventTime}',
    );
  }

  /// Clear chat history
  static Future<void> clearHistory() async {
    _messages.clear();
    _messages.add(
      AiMessageModel(
        id: const Uuid().v4(),
        sender: 'ai',
        text: 'Sohbet temizlendi. Yeni bir plan oluşturmak veya konuşmak için mesaj gönderebilirsin! 🤖✨',
        timestamp: DateTime.now(),
      ),
    );
    await _persistMessages();
    notifier.value++;
  }

  /// Main method: user sends a message to Talknex AI Assistant
  static Future<AiMessageModel> handleUserMessage(String userPrompt) async {
    final promptTrimmed = userPrompt.trim();
    if (promptTrimmed.isEmpty) {
      throw Exception('Mesaj boş olamaz');
    }

    // 1. Add user message
    final userMsg = AiMessageModel(
      id: const Uuid().v4(),
      sender: 'user',
      text: promptTrimmed,
      timestamp: DateTime.now(),
    );
    _messages.add(userMsg);
    await _persistMessages();
    notifier.value++;

    // 2. Process query with AI brain
    final aiResponse = await _processWithAiBrain(promptTrimmed);

    _messages.add(aiResponse);
    await _persistMessages();
    notifier.value++;

    return aiResponse;
  }

  /// Intelligent Brain: NLP Reminder Extractor + Conversational AI
  static Future<AiMessageModel> _processWithAiBrain(String text) async {
    final textLower = text.toLowerCase();

    // A. Check if user is asking to list reminders
    if (_isListingRemindersQuery(textLower)) {
      return _generateRemindersListResponse();
    }

    // B. Check if user is asking to cancel reminders
    if (_isCancelReminderQuery(textLower)) {
      return _handleCancelReminderQuery(textLower);
    }

    // C. Check if user wants to schedule a plan / reminder
    if (_isSchedulingQuery(textLower)) {
      final parsed = _parseReminderDetails(text);
      if (parsed != null) {
        final reminder = AiReminderModel(
          id: const Uuid().v4(),
          title: parsed['title'],
          eventTime: parsed['eventTime'],
          leadMinutes: parsed['leadMinutes'],
          reminderTime: parsed['reminderTime'],
          createdAt: DateTime.now(),
        );

        _reminders.add(reminder);
        await _persistReminders();
        _scheduleTimer(reminder);

        final eventTimeStr = DateFormat('d MMMM yyyy, HH:mm', 'tr').format(reminder.eventTime);
        final leadStr = reminder.leadMinutes > 0 ? '${reminder.leadMinutes} dakika önce' : 'tam vaktinde';
        final alertTimeStr = DateFormat('HH:mm').format(reminder.reminderTime);

        final responseText = 'Harika! Planını başarıyla kaydettim ve hatırlatıcını kurdum ⏰\n\n'
            '📌 **Plan:** ${reminder.title}\n'
            '📅 **Tarih & Saat:** $eventTimeStr\n'
            '🔔 **Hatırlatma Vakti:** $alertTimeStr ($leadStr)\n\n'
            'Belirttiğin saatte sana bildirim göndereceğim. Başka bir planın var mı? 😊';

        return AiMessageModel(
          id: const Uuid().v4(),
          sender: 'ai',
          text: responseText,
          timestamp: DateTime.now(),
          reminder: reminder,
          actionType: 'reminder_created',
        );
      }
    }

    // D. Conversational Engine (Small Talk & Knowledge Base)
    final reply = _generateConversationalResponse(text);
    return AiMessageModel(
      id: const Uuid().v4(),
      sender: 'ai',
      text: reply,
      timestamp: DateTime.now(),
    );
  }

  static bool _isListingRemindersQuery(String text) {
    final triggers = [
      'hatırlatıcılarım',
      'hatirlaticilarim',
      'hatırlatıcılarımı göster',
      'planlarım',
      'planlarim',
      'planlarımı göster',
      'neler var',
      'aktif planlar',
      'bugün ne var',
      'hatırlatıcı listesi',
    ];
    return triggers.any((t) => text.contains(t));
  }

  static bool _isCancelReminderQuery(String text) {
    final triggers = ['iptal et', 'sil', 'kaldır', 'hatırlatıcıyı sil', 'planı sil', 'hepsini temizle'];
    return triggers.any((t) => text.contains(t));
  }

  static bool _isSchedulingQuery(String text) {
    final triggers = [
      'hatırlat',
      'hatirlat',
      'haber ver',
      'alarm kur',
      'uyar',
      'planım var',
      'randevum var',
      'yapıcam',
      'yapacağım',
      'toplantım var',
      'unutma',
      'hatırlatıcı kur',
    ];
    return triggers.any((t) => text.contains(t));
  }

  static AiMessageModel _generateRemindersListResponse() {
    final active = activeReminders;
    if (active.isEmpty) {
      return AiMessageModel(
        id: const Uuid().v4(),
        sender: 'ai',
        text: 'Şu an yaklaşan aktif bir planın veya hatırlatıcın bulunmuyor 📅\n\n'
            'Yeni bir plan eklemek için örneğin:\n'
            '"Yarın saat 15:00\'te toplantım var, 30 dakika önce hatırlat" diyebilirsin!',
        timestamp: DateTime.now(),
      );
    }

    final sb = StringBuffer();
    sb.writeln('📋 **Yaklaşan ${active.length} Adet Planın Bulunuyor:**\n');

    for (int i = 0; i < active.length; i++) {
      final r = active[i];
      final eventStr = DateFormat('d MMMM HH:mm', 'tr').format(r.eventTime);
      final leadStr = r.leadMinutes > 0 ? '(${r.leadMinutes} dk önce)' : '';
      sb.writeln('${i + 1}. **${r.title}**');
      sb.writeln('   📅 $eventStr $leadStr');
      sb.writeln('   ⏳ ${r.remainingTimeText}\n');
    }

    sb.write('İstediğin hatırlatıcıyı iptal etmek için bana söyleyebilirsin.');

    return AiMessageModel(
      id: const Uuid().v4(),
      sender: 'ai',
      text: sb.toString().trim(),
      timestamp: DateTime.now(),
      actionType: 'reminder_list',
    );
  }

  static AiMessageModel _handleCancelReminderQuery(String text) {
    if (text.contains('hepsini') || text.contains('tümünü')) {
      for (final t in _activeTimers.values) {
        t.cancel();
      }
      _activeTimers.clear();
      _reminders.clear();
      _persistReminders();

      return AiMessageModel(
        id: const Uuid().v4(),
        sender: 'ai',
        text: 'Tüm hatırlatıcıların ve planların başarıyla temizlendi 🗑️✨',
        timestamp: DateTime.now(),
      );
    }

    final active = activeReminders;
    if (active.isEmpty) {
      return AiMessageModel(
        id: const Uuid().v4(),
        sender: 'ai',
        text: 'İptal edilecek aktif bir hatırlatıcı bulunamadı.',
        timestamp: DateTime.now(),
      );
    }

    // Try finding matching reminder by title
    AiReminderModel? target;
    for (final r in active) {
      if (text.contains(r.title.toLowerCase())) {
        target = r;
        break;
      }
    }

    target ??= active.last;
    cancelReminder(target.id);

    return AiMessageModel(
      id: const Uuid().v4(),
      sender: 'ai',
      text: '📌 **"${target.title}"** planı için kurulan hatırlatıcı başarıyla iptal edildi! 👍',
      timestamp: DateTime.now(),
    );
  }

  /// NLP: Parse date, time, lead time and event title from Turkish text
  static Map<String, dynamic>? _parseReminderDetails(String text) {
    final textLower = text.toLowerCase();
    final now = DateTime.now();

    // 1. Lead Time extraction
    int leadMinutes = 0;
    final leadRegex = RegExp(r'(\d+)\s*(dakika|dk)\s*(önce|once)', caseSensitive: false);
    final leadMatch = leadRegex.firstMatch(textLower);
    if (leadMatch != null) {
      leadMinutes = int.tryParse(leadMatch.group(1) ?? '0') ?? 0;
    } else if (textLower.contains('yarım saat önce') || textLower.contains('yarim saat once')) {
      leadMinutes = 30;
    } else {
      final hourLeadRegex = RegExp(r'(\d+)\s*(saat)\s*(önce|once)', caseSensitive: false);
      final hourMatch = hourLeadRegex.firstMatch(textLower);
      if (hourMatch != null) {
        leadMinutes = (int.tryParse(hourMatch.group(1) ?? '1') ?? 1) * 60;
      }
    }

    // 2. Relative time check: e.g. "20 dakika sonra", "1 saat sonra"
    final relRegex = RegExp(r'(\d+)\s*(dakika|dk)\s*sonra', caseSensitive: false);
    final relMatch = relRegex.firstMatch(textLower);
    if (relMatch != null) {
      final minutesLater = int.tryParse(relMatch.group(1) ?? '10') ?? 10;
      final eventTime = now.add(Duration(minutes: minutesLater));
      final title = _extractCleanTitle(text, textLower);
      return {
        'title': title,
        'eventTime': eventTime,
        'leadMinutes': leadMinutes,
        'reminderTime': eventTime.subtract(Duration(minutes: leadMinutes)),
      };
    }

    final relHourRegex = RegExp(r'(\d+)\s*saat\s*sonra', caseSensitive: false);
    final relHourMatch = relHourRegex.firstMatch(textLower);
    if (relHourMatch != null) {
      final hoursLater = int.tryParse(relHourMatch.group(1) ?? '1') ?? 1;
      final eventTime = now.add(Duration(hours: hoursLater));
      final title = _extractCleanTitle(text, textLower);
      return {
        'title': title,
        'eventTime': eventTime,
        'leadMinutes': leadMinutes,
        'reminderTime': eventTime.subtract(Duration(minutes: leadMinutes)),
      };
    }

    // 3. Date extraction
    DateTime targetDate = DateTime(now.year, now.month, now.day);
    if (textLower.contains('yarın') || textLower.contains('yarin')) {
      targetDate = targetDate.add(const Duration(days: 1));
    } else if (textLower.contains('öbür gün') || textLower.contains('obur gun')) {
      targetDate = targetDate.add(const Duration(days: 2));
    } else {
      final weekdays = {
        'pazartesi': 1,
        'salı': 2,
        'sali': 2,
        'çarşamba': 3,
        'carsamba': 3,
        'perşembe': 4,
        'persembe': 4,
        'cuma': 5,
        'cumartesi': 6,
        'pazar': 7,
      };

      for (final entry in weekdays.entries) {
        if (textLower.contains(entry.key)) {
          int daysToAdd = entry.value - now.weekday;
          if (daysToAdd <= 0) daysToAdd += 7;
          targetDate = targetDate.add(Duration(days: daysToAdd));
          break;
        }
      }
    }

    // 4. Time extraction
    int targetHour = 12;
    int targetMinute = 0;
    bool timeIdentified = false;

    // Pattern 1: HH:MM or HH.MM (e.g. 15:30, 09.00)
    final timeExactRegex = RegExp(r'(?:saat\s*)?(\d{1,2})[:\.](\d{2})');
    final timeExactMatch = timeExactRegex.firstMatch(textLower);
    if (timeExactMatch != null) {
      targetHour = int.tryParse(timeExactMatch.group(1) ?? '12') ?? 12;
      targetMinute = int.tryParse(timeExactMatch.group(2) ?? '0') ?? 0;
      timeIdentified = true;
    } else {
      // Pattern 2: saat 8'de, saat 15'te, saat 3'te
      final hourRegex = RegExp(r'saat\s*(\d{1,2})');
      final hourMatch = hourRegex.firstMatch(textLower);
      if (hourMatch != null) {
        targetHour = int.tryParse(hourMatch.group(1) ?? '12') ?? 12;
        timeIdentified = true;
      } else {
        // Pattern 3: akşam 8, sabah 9
        final aksamRegex = RegExp(r'akşam\s*(\d{1,2})');
        final aksamMatch = aksamRegex.firstMatch(textLower);
        if (aksamMatch != null) {
          targetHour = int.tryParse(aksamMatch.group(1) ?? '8') ?? 8;
          if (targetHour < 12) targetHour += 12;
          timeIdentified = true;
        }
      }
    }

    // Evening / Night adjustment
    if ((textLower.contains('akşam') || textLower.contains('gece')) && targetHour < 12) {
      targetHour += 12;
    }

    // If no specific time identified, default to default meeting/plan time (10:00 or 14:00)
    if (!timeIdentified) {
      targetHour = now.hour < 12 ? 14 : 19;
    }

    DateTime eventTime = DateTime(
      targetDate.year,
      targetDate.month,
      targetDate.day,
      targetHour,
      targetMinute,
    );

    // If event time passed today, push to tomorrow
    if (eventTime.isBefore(now)) {
      eventTime = eventTime.add(const Duration(days: 1));
    }

    // Calculate reminder time with lead
    final reminderTime = eventTime.subtract(Duration(minutes: leadMinutes));
    final title = _extractCleanTitle(text, textLower);

    return {
      'title': title,
      'eventTime': eventTime,
      'leadMinutes': leadMinutes,
      'reminderTime': reminderTime,
    };
  }

  static String _extractCleanTitle(String raw, String lower) {
    String cleaned = raw;
    final removals = [
      RegExp(r'bana\s+\d+\s*(dakika|dk|saat)\s*(önce|once)\s*(hatırlat|haber ver)', caseSensitive: false),
      RegExp(r'\d+\s*(dakika|dk|saat)\s*(önce|once)\s*(hatırlat|haber ver)', caseSensitive: false),
      RegExp(r'\d+\s*(dakika|dk|saat)\s*(önce|once)', caseSensitive: false),
      RegExp(r'\d+\s*(dakika|dk|saat)\s*sonra', caseSensitive: false),
      RegExp(r'yarım saat önce', caseSensitive: false),
      RegExp(r'hatırlat.*', caseSensitive: false),
      RegExp(r'haber ver.*', caseSensitive: false),
      RegExp(r'uyar.*', caseSensitive: false),
      RegExp(r'bana', caseSensitive: false),
      RegExp(r'planım var', caseSensitive: false),
      RegExp(r'pilannım var', caseSensitive: false),
      RegExp(r'randevum var', caseSensitive: false),
      RegExp(r'toplantım var', caseSensitive: false),
      RegExp(r'yarın', caseSensitive: false),
      RegExp(r'bugün', caseSensitive: false),
      RegExp(r'saat\s*\d{1,2}[:.]\d{2}', caseSensitive: false),
      RegExp(r'saat\s*\d{1,2}', caseSensitive: false),
      RegExp(r'akşam', caseSensitive: false),
      RegExp(r'sabah', caseSensitive: false),
      RegExp(r'öğlen', caseSensitive: false),
    ];

    for (final r in removals) {
      cleaned = cleaned.replaceAll(r, ' ');
    }

    cleaned = cleaned.replaceAll(RegExp(r'[,.!?]'), ' ').trim();
    cleaned = cleaned.replaceAll("'", ' ');
    cleaned = cleaned.replaceAll('"', ' ');
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ');

    if (cleaned.isEmpty || cleaned.length < 2) {
      if (lower.contains('toplantı')) return 'Toplantı';
      if (lower.contains('ilaç')) return 'İlaç Vakti';
      if (lower.contains('spor')) return 'Spor Egzersizi';
      if (lower.contains('doktor')) return 'Doktor Randevusu';
      if (lower.contains('fırın')) return 'Fırını Kapatma';
      if (lower.contains('fatura')) return 'Fatura Ödemesi';
      if (lower.contains('su')) return 'Su İçme';
      return 'Plan';
    }

    // Capitalize first letter
    return cleaned[0].toUpperCase() + cleaned.substring(1);
  }

  /// Conversational AI Knowledge Engine
  static String _generateConversationalResponse(String text) {
    final lower = text.toLowerCase();

    // 1. Identity & Self Intro
    if (lower.contains('sen kimsin') ||
        lower.contains('kimsin') ||
        lower.contains('adın ne') ||
        lower.contains('kendini tanıt') ||
        lower.contains('neler yapabilirsin')) {
      return 'Ben **Talknex Asistan**! 🤖 Talknex iletişim uygulamasının akıllı yapay zeka asistanıyım.\n\n'
          'Sana şu konularda yardımcı olabilirim:\n'
          '⏰ **Plan & Hatırlatıcı:** "Yarın saat 14:00\'te toplantım var, 30 dakika önce hatırlat" dersen tam vaktinde bildirim gönderirim.\n'
          '💬 **Sohbet & Tavsiye:** Günün her saati seninle konuşabilir, moral verebilir, önerilerde bulunabilirim.\n'
          '🧠 **Bilgi & Hesaplama:** Matematiksel hesaplar, zaman yönetimi veya genel soruları yanıtlayabilirim.\n'
          '📱 **Uygulama Rehberi:** Talknex özellikleri hakkında merak ettiğin her şeyi açıklayabilirim.\n\n'
          'Senin için ne yapabilirim? 😊';
    }

    // 2. Greetings
    if (lower == 'selam' ||
        lower == 'merhaba' ||
        lower.startsWith('selam') ||
        lower.startsWith('merhaba') ||
        lower == 'hey' ||
        lower == 'slm') {
      final greetings = [
        'Merhaba! Sana nasıl yardımcı olabilirim? Bugün aklında bir plan var mı? 😊',
        'Selam! Harika bir gün dilerim. Planlarını hatırlatmamı ister misin yoksa biraz sohbet mi edelim? ✨',
        'Merhaba! Seni görmek çok güzel. Bugün senin için ne yapabilirim? 🤖',
      ];
      return greetings[Random().nextInt(greetings.length)];
    }

    // 3. How are you
    if (lower.contains('nasılsın') || lower.contains('nasilsin') || lower.contains('ne haber') || lower.contains('naber')) {
      return 'Harikayım, teşekkür ederim! Senin günün nasıl geçiyor? Planladığın bir etkinlik veya konuşmak istediğin bir konu varsa buradayım! 🚀';
    }

    // 4. Good morning / night
    if (lower.contains('günaydın') || lower.contains('gunaydin')) {
      return 'Günaydın! ☀️ Harika, üretken ve keyifli bir gün dilerim. Bugünkü planlarını bana söyle, hiçbirini unutmamanı sağlayayım!';
    }
    if (lower.contains('iyi geceler') || lower.contains('iyi aksamlar') || lower.contains('iyi akşamlar')) {
      return 'İyi akşamlar! Huzurlu ve dinlendirici bir vakit dilerim. Yarın için kurmak istediğin bir hatırlatıcı olursa buradayım 🌙✨';
    }

    // 5. Jokes & Fun
    if (lower.contains('fıkra') || lower.contains('fikra') || lower.contains('espri') || lower.contains('güldür')) {
      final jokes = [
        'Yapay zekaya sormuşlar: "Neden kahve içmiyorsun?"\nDemiş ki: "Java beni zaten ayakta tutuyor!" ☕😄',
        'Temel bir gün uçağa binmiş. Yanındaki adama sormuş:\n- Hemşerim nereye gidiyorsun?\nAdam: "İstanbul\'a."\nTemel gülmüş:\n- Vay canına, teknolojiye bak! Sen arkada ben önde gidiyoruz ama ikimiz de İstanbul\'a varıyoruz! 😂',
        'Bir bilgisayarın en sevdiği mevsim hangisidir?\nTabii ki "Windows" mevsimi! 🖥️😄',
      ];
      return jokes[Random().nextInt(jokes.length)];
    }

    // 6. Motivation & Quotes
    if (lower.contains('motive') || lower.contains('motivasyon') || lower.contains('moral') || lower.contains('günün sözü')) {
      final quotes = [
        '✨ "Gelecek, bugünden hazırlananlara aittir." - Malcolm X\nBugün attığın her küçük adım, yarınki büyük başarına giden yoldur!',
        '🌟 "Başlamak için harika olmak zorunda değilsin, ama harika olmak için başlamak zorundasın."\nBugün hedeflerine bir adım daha yaklaşmaya ne dersin?',
        '🚀 "En uzun yolculuklar bile tek bir adımla başlar."\nPlanlarını aksatma, yapman gerekenleri bana hatırlat ve hedefine odaklan!',
      ];
      return quotes[Random().nextInt(quotes.length)];
    }

    // 7. Time & Date
    if (lower.contains('saat kaç') || lower.contains('saat kac')) {
      final timeStr = DateFormat('HH:mm:ss').format(DateTime.now());
      return 'Şu anda saat tam olarak **$timeStr** ⏰';
    }
    if (lower.contains('bugün ayın kaçı') || lower.contains('hangi gündeyiz') || lower.contains('tarih')) {
      final dateStr = DateFormat('d MMMM yyyy, EEEE', 'tr').format(DateTime.now());
      return 'Bugün **$dateStr** 📅';
    }

    // 8. Productivity & Time Management Tips
    if (lower.contains('zaman yönetimi') || lower.contains('çalışma') || lower.contains('odaklan') || lower.contains('pomodoro')) {
      return 'Zaman yönetimi ve odaklanma için 3 altın kural 💡:\n\n'
          '1. **Pomodoro Tekniği:** 25 dakika kesintisiz çalış, 5 dakika mola ver. 4 setten sonra 20 dakika uzun mola ver.\n'
          '2. **En Zor Görevi Sabah Yap (Eat That Frog):** Günün enerjisi en yüksekken en zor işi aradan çıkar.\n'
          '3. **Planlarını Hatırlatıcıya Bırak:** Aklını doldurmak yerine planlarını bana söyle, ben sana zamanı gelince haber vereyim! 🎯';
    }

    // 9. Talknex App Guide
    if (lower.contains('talknex') || lower.contains('uygulama') || lower.contains('özellik')) {
      return 'Talknex, güvenli ve zengin iletişim sunan modern bir mesajlaşma platformudur 🛡️\n\n'
          'Öne çıkan özellikler:\n'
          '• 🌐 **WhatsApp Stili Dil Çevirisi:** Sohbeti veya mesajı istediğin dile anında çevirebilirsin.\n'
          '• 📹 **Sesli ve Görüntülü Arama:** WebRTC destekli yüksek kaliteli görüşmeler.\n'
          '• 💬 **Emojili Tepkiler:** Mesaja basılı tutarak emojilerle tepki verebilirsin.\n'
          '• 🤖 **Talknex Asistan:** Seninle sohbet eder, planlarını hatırlar ve bildirim yollar!\n\n'
          'Keşfetmek istediğin başka bir özellik var mı?';
    }

    // 10. Thank you
    if (lower.contains('teşekkür') || lower.contains('tesekkur') || lower.contains('sağol') || lower.contains('harikasın')) {
      return 'Rica ederim! Her zaman senin için buradayım. Başka bir planın veya sorun olursa sormaktan çekinme! 😊🌟';
    }

    // 11. Math calculation
    final mathRegex = RegExp(r'(\d+)\s*([\+\-\*\/xX])\s*(\d+)');
    final mathMatch = mathRegex.firstMatch(lower);
    if (mathMatch != null) {
      final n1 = double.tryParse(mathMatch.group(1) ?? '0') ?? 0;
      final op = mathMatch.group(2) ?? '+';
      final n2 = double.tryParse(mathMatch.group(3) ?? '0') ?? 0;
      double result = 0;
      if (op == '+') result = n1 + n2;
      if (op == '-') result = n1 - n2;
      if (op == '*' || op == 'x' || op == 'X') result = n1 * n2;
      if (op == '/' && n2 != 0) result = n1 / n2;
      final resStr = result % 1 == 0 ? result.toInt().toString() : result.toStringAsFixed(2);
      return 'Hesaplama sonucu: **$resStr** 🔢';
    }

    // Default intelligent companion reply
    return 'Bunu anladım! Talknex Asistan olarak her zaman yanındayım. 🤖✨\n\n'
        'Eğer bir planın veya etkinliğin varsa bana şu şekilde söyleyebilirsin:\n'
        '👉 *"Yarın saat 14:00\'te toplantım var, 30 dakika önce hatırlat"*\n\n'
        'Senin için hatırlatıcı kurayım veya sormak istediğin başka bir konuyu yanıtlayayım!';
  }
}
