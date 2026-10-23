import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/ai_message_model.dart';
import '../models/ai_reminder_model.dart';
import '../models/ai_weather_model.dart';
import 'notification_service.dart';
import 'package:http/http.dart' as http;

class AiAssistantService {
  static final ValueNotifier<int> notifier = ValueNotifier<int>(0);

  static final List<AiMessageModel> _messages = [];
  static final List<AiReminderModel> _reminders = [];
  static final Map<String, Timer> _activeTimers = {};

  static bool _isInitialized = false;
  static const String _prefKeyMessages = 'talknex_ai_chat_messages_v2';
  static const String _prefKeyReminders = 'talknex_ai_reminders_v2';
  static const String _prefKeyGeminiKey = 'talknex_gemini_api_key_v1';
  static const String _prefKeyGroqKey = 'talknex_groq_api_key_v1';
  static const String _prefKeyActiveProvider = 'talknex_active_ai_provider_v1';
  static const String _prefKeyUserName = 'talknex_ai_user_name_v1';
  static const String _prefKeyWorkingGeminiModel = 'talknex_working_gemini_model_v1';
  static const String _prefKeyWorkingGroqModel = 'talknex_working_groq_model_v1';

  static String? _userName;
  static String? get userName => _userName;

  static String? _geminiApiKey;
  static String? get geminiApiKey => _geminiApiKey;
  static bool get hasGeminiApiKey => _geminiApiKey != null && _geminiApiKey!.trim().isNotEmpty;

  static String? _workingGeminiModel;
  static String? get workingGeminiModel => _workingGeminiModel;

  static String? _groqApiKey;
  static String? get groqApiKey => _groqApiKey;
  static bool get hasGroqApiKey => _groqApiKey != null && _groqApiKey!.trim().isNotEmpty;

  static String? _workingGroqModel;
  static String? get workingGroqModel => _workingGroqModel;

  static String? _lastGeminiError;
  static String? get lastGeminiError => _lastGeminiError;

  static String? _lastGroqError;
  static String? get lastGroqError => _lastGroqError;

  static String? get lastAiError => _lastGroqError ?? _lastGeminiError;

  static String _activeProvider = 'auto'; // 'gemini', 'groq', or 'auto'
  static String get activeProvider => _activeProvider;

  static bool get isRealAiConnected => hasGeminiApiKey || hasGroqApiKey;

  static String get activeAiModelLabel {
    final bool useGroq = (_activeProvider == 'groq' && hasGroqApiKey) ||
        (hasGroqApiKey && !hasGeminiApiKey);
    if (useGroq) {
      final model = _workingGroqModel ?? 'llama-3.3-70b';
      final shortName = model.contains('70b')
          ? 'Llama 3.3 70B'
          : (model.contains('8b') ? 'Llama 3.1 8B' : 'Llama');
      return 'Groq ($shortName) Aktif ⚡';
    }
    if (hasGeminiApiKey) {
      final model = _workingGeminiModel ?? 'gemini-1.5-flash';
      final shortName = model.replaceFirst('gemini-', '');
      return 'Gemini ($shortName) Aktif ✨';
    }
    return '⚡ Gerçek Yapay Zekayı Bağla';
  }

  static Future<void> setActiveProvider(String provider) async {
    _activeProvider = provider;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKeyActiveProvider, provider);
    notifier.value++;
  }

  static String cleanGeminiKey(String raw) {
    String clean = raw.trim().replaceAll('"', '').replaceAll("'", '').replaceAll('`', '').replaceAll(' ', '');
    if (clean.toLowerCase().startsWith('bearer')) {
      clean = clean.substring(6).trim();
    }
    return clean;
  }

  static Future<void> setGeminiApiKey(String? key, [String? model]) async {
    final prefs = await SharedPreferences.getInstance();
    if (key == null || key.trim().isEmpty) {
      _geminiApiKey = null;
      _workingGeminiModel = null;
      await prefs.remove(_prefKeyGeminiKey);
      await prefs.remove(_prefKeyWorkingGeminiModel);
    } else {
      final cleanKey = cleanGeminiKey(key);
      _geminiApiKey = cleanKey;
      _activeProvider = 'gemini';
      if (model != null && model.isNotEmpty) {
        _workingGeminiModel = model;
        await prefs.setString(_prefKeyWorkingGeminiModel, model);
      }
      await prefs.setString(_prefKeyGeminiKey, cleanKey);
      await prefs.setString(_prefKeyActiveProvider, 'gemini');
    }
    notifier.value++;
  }

  static String cleanGroqKey(String raw) {
    String clean = raw.trim().replaceAll('"', '').replaceAll("'", '').replaceAll('`', '').replaceAll(' ', '');
    if (clean.toLowerCase().startsWith('bearer')) {
      clean = clean.substring(6).trim();
    }
    return clean;
  }

  static Future<void> setGroqApiKey(String? key, [String? model]) async {
    final prefs = await SharedPreferences.getInstance();
    if (key == null || key.trim().isEmpty) {
      _groqApiKey = null;
      _workingGroqModel = null;
      await prefs.remove(_prefKeyGroqKey);
      await prefs.remove(_prefKeyWorkingGroqModel);
    } else {
      final cleanKey = cleanGroqKey(key);
      _groqApiKey = cleanKey;
      _activeProvider = 'groq';
      if (model != null && model.isNotEmpty) {
        _workingGroqModel = model;
        await prefs.setString(_prefKeyWorkingGroqModel, model);
      }
      await prefs.setString(_prefKeyGroqKey, cleanKey);
      await prefs.setString(_prefKeyActiveProvider, 'groq');
    }
    notifier.value++;
  }

  static Future<bool> testGeminiApiKey(String apiKey) async {
    final res = await testGeminiApiKeyDetails(apiKey);
    return res['success'] == true;
  }

  /// Robust Gemini key verification with dynamic ModelService probing and real error reporting
  static Future<Map<String, dynamic>> testGeminiApiKeyDetails(String apiKey) async {
    final cleanKey = cleanGeminiKey(apiKey);

    if (cleanKey.isEmpty) {
      return {'success': false, 'message': 'Lütfen bir anahtar girin veya panodan yapıştırın.', 'key': ''};
    }

    if (cleanKey.length < 25) {
      return {
        'success': false,
        'message': 'Girdiğiniz anahtar çok kısa (Google Gemini anahtarları AIzaSy ile başlar ve ~39 karakterdir).',
        'key': cleanKey
      };
    }

    // 1. Probe Google's ModelService directly (/v1beta/models) to discover supported models for this exact key
    try {
      final listUrl = Uri.parse('https://generativelanguage.googleapis.com/v1beta/models?key=$cleanKey');
      final listRes = await http.get(listUrl).timeout(const Duration(seconds: 12));

      if (listRes.statusCode == 200) {
        final decoded = jsonDecode(utf8.decode(listRes.bodyBytes));
        if (decoded is Map && decoded.containsKey('models')) {
          final modelsList = decoded['models'] as List?;
          String bestModel = 'gemini-1.5-flash';
          if (modelsList != null && modelsList.isNotEmpty) {
            final valid = <String>[];
            for (final m in modelsList) {
              final name = m['name']?.toString() ?? '';
              final methods = (m['supportedGenerationMethods'] as List?)?.map((e) => e.toString()).toList() ?? [];
              if (methods.contains('generateContent')) {
                final modelId = name.startsWith('models/') ? name.substring(7) : name;
                valid.add(modelId);
              }
            }
            if (valid.contains('gemini-1.5-flash')) {
              bestModel = 'gemini-1.5-flash';
            } else if (valid.contains('gemini-2.0-flash')) {
              bestModel = 'gemini-2.0-flash';
            } else if (valid.contains('gemini-1.5-pro')) {
              bestModel = 'gemini-1.5-pro';
            } else if (valid.isNotEmpty) {
              bestModel = valid.first;
            }
          }
          _workingGeminiModel = bestModel;
          return {
            'success': true,
            'message': '✅ Gemini ($bestModel) başarıyla doğrulandı! Gerçek Yapay Zeka Devrede 🚀',
            'key': cleanKey,
            'model': bestModel,
          };
        }
      } else {
        try {
          final decoded = jsonDecode(utf8.decode(listRes.bodyBytes));
          final msg = decoded['error']?['message']?.toString() ?? '';
          if (listRes.statusCode == 400 || msg.contains('API_KEY_INVALID') || msg.contains('not valid')) {
            return {
              'success': false,
              'message': '❌ Google: API anahtarı geçersiz. Lütfen kopyaladığınız anahtarı kontrol edin.',
              'key': cleanKey
            };
          }
          if (listRes.statusCode == 403 || msg.contains('PERMISSION_DENIED') || msg.contains('SERVICE_DISABLED') || msg.contains('blocked')) {
            return {
              'success': false,
              'message': '❌ Bu anahtarda Generative Language API aktif değil (HTTP 403).\n👉 Lütfen anahtarı Google Cloud yerine doğrudan aistudio.google.com/apikey üzerinden oluşturun.',
              'key': cleanKey
            };
          }
          if (listRes.statusCode == 429) {
            return {
              'success': true,
              'message': '✅ Anahtar geçerli (Anlık kota sınırı tespit edildi). Kaydedildi!',
              'key': cleanKey,
              'model': 'gemini-1.5-flash',
            };
          }
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('[GEMINI PROBE] Error: $e');
    }

    // 2. Direct generateContent test with standard models
    final models = ['gemini-1.5-flash', 'gemini-1.5-pro', 'gemini-2.0-flash'];
    String? lastError;

    for (final model in models) {
      try {
        final url = Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$cleanKey',
        );
        final response = await http.post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'contents': [
              {
                'role': 'user',
                'parts': [{'text': 'Ping'}]
              }
            ],
            'generationConfig': {'maxOutputTokens': 10}
          }),
        ).timeout(const Duration(seconds: 10));

        if (response.statusCode == 200) {
          _workingGeminiModel = model;
          return {
            'success': true,
            'message': '✅ Gemini ($model) başarıyla doğrulandı! Gerçek Yapay Zeka Devrede 🚀',
            'key': cleanKey,
            'model': model,
          };
        } else if (response.statusCode == 429) {
          _workingGeminiModel = model;
          return {
            'success': true,
            'message': '✅ Anahtar geçerli (Anlık kota sınırı tespit edildi). Kaydedildi!',
            'key': cleanKey,
            'model': model,
          };
        } else {
          try {
            final decoded = jsonDecode(utf8.decode(response.bodyBytes));
            final msg = decoded['error']?['message']?.toString() ?? 'Hata kodu: ${response.statusCode}';
            lastError = msg;
            if (response.statusCode == 400 && (msg.contains('API_KEY_INVALID') || msg.contains('not valid'))) {
              return {
                'success': false,
                'message': '❌ Google: API anahtarı geçersiz. Lütfen kopyaladığınız anahtarı kontrol edin.',
                'key': cleanKey
              };
            }
            if (response.statusCode == 403 || msg.contains('PERMISSION_DENIED') || msg.contains('blocked')) {
              return {
                'success': false,
                'message': '❌ Bu anahtarda Generative Language servisi aktif değil (HTTP 403).\n👉 Lütfen anahtarı aistudio.google.com/apikey adresinden oluşturun.',
                'key': cleanKey
              };
            }
          } catch (_) {
            lastError = 'HTTP ${response.statusCode}';
          }
        }
      } catch (e) {
        lastError = e.toString();
      }
    }

    return {
      'success': false,
      'message': '❌ Anahtar doğrulanamadı: ${lastError ?? "Bağlantı kurulamadı"}.\n👉 Lütfen internet bağlantınızı ve aistudio.google.com/apikey adresinden aldığınız anahtarı kontrol edin.',
      'key': cleanKey
    };
  }

  /// Robust Groq key verification (Dynamic Model Discovery + Fallbacks)
  static Future<Map<String, dynamic>> testGroqApiKeyDetails(String apiKey) async {
    final cleanKey = cleanGroqKey(apiKey);

    if (cleanKey.isEmpty) {
      return {'success': false, 'message': 'Lütfen bir Groq anahtarı girin veya panodan yapıştırın.', 'key': ''};
    }

    if (!cleanKey.startsWith('gsk_')) {
      return {
        'success': false,
        'message': 'Groq API anahtarları "gsk_" ile başlar. Lütfen console.groq.com/keys adresinden aldığınız anahtarı kontrol edin.',
        'key': cleanKey
      };
    }

    // 1. Probe Groq's Models API to dynamically discover active models for this key
    try {
      final modelsUrl = Uri.parse('https://api.groq.com/openai/v1/models');
      final modelsRes = await http.get(
        modelsUrl,
        headers: {
          'Authorization': 'Bearer $cleanKey',
          'User-Agent': 'Talknex/1.0 (Android)',
          'Accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 10));

      if (modelsRes.statusCode == 200) {
        final decoded = jsonDecode(utf8.decode(modelsRes.bodyBytes));
        if (decoded is Map && decoded['data'] is List) {
          final list = (decoded['data'] as List).map((e) => e['id']?.toString() ?? '').toList();
          String best = 'llama-3.3-70b-versatile';
          if (list.contains('llama-3.3-70b-versatile')) {
            best = 'llama-3.3-70b-versatile';
          } else if (list.contains('llama-3.1-8b-instant')) {
            best = 'llama-3.1-8b-instant';
          } else if (list.isNotEmpty) {
            best = list.firstWhere((id) => id.contains('llama'), orElse: () => list.first);
          }
          _workingGroqModel = best;
          return {
            'success': true,
            'message': '✅ Groq ($best) başarıyla doğrulandı! LPU Süper Hızı Devrede ⚡',
            'key': cleanKey,
            'model': best,
          };
        }
      } else if (modelsRes.statusCode == 401) {
        return {
          'success': false,
          'message': '❌ Groq: Geçersiz API Anahtarı (HTTP 401). Lütfen console.groq.com/keys üzerinden anahtarınızı kontrol edin.',
          'key': cleanKey
        };
      }
    } catch (e) {
      debugPrint('[GROQ PROBE] Error: $e');
    }

    // 2. Direct chat completion test with standard models
    final models = ['llama-3.3-70b-versatile', 'llama-3.1-8b-instant'];
    String? lastError;

    for (final model in models) {
      try {
        final url = Uri.parse('https://api.groq.com/openai/v1/chat/completions');
        final response = await http.post(
          url,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $cleanKey',
            'User-Agent': 'Talknex/1.0 (Android)',
            'Accept': 'application/json',
          },
          body: jsonEncode({
            'model': model,
            'messages': [
              {'role': 'user', 'content': 'Ping'}
            ],
            'max_tokens': 10,
          }),
        ).timeout(const Duration(seconds: 12));

        if (response.statusCode == 200) {
          _workingGroqModel = model;
          return {
            'success': true,
            'message': '✅ Groq ($model) başarıyla doğrulandı! LPU Süper Hızı Devrede ⚡',
            'key': cleanKey,
            'model': model,
          };
        } else if (response.statusCode == 429) {
          _workingGroqModel = model;
          return {
            'success': true,
            'message': '✅ Anahtar geçerli (Anlık kota sınırı tespit edildi). Kaydedildi!',
            'key': cleanKey,
            'model': model,
          };
        } else {
          try {
            final decoded = jsonDecode(utf8.decode(response.bodyBytes));
            final msg = decoded['error']?['message']?.toString() ?? 'Hata kodu: ${response.statusCode}';
            lastError = msg;
            if (response.statusCode == 401) {
              return {
                'success': false,
                'message': '❌ Groq: Geçersiz API Anahtarı. Lütfen console.groq.com/keys üzerinden aldığınız anahtarı kontrol edin.',
                'key': cleanKey
              };
            }
          } catch (_) {
            lastError = 'HTTP ${response.statusCode}';
          }
        }
      } catch (e) {
        lastError = e.toString();
      }
    }

    return {
      'success': false,
      'message': '❌ Groq doğrulanamadı: ${lastError ?? "Bağlantı kurulamadı"}.\n👉 Lütfen console.groq.com/keys üzerinden yeni bir anahtar alıp deneyin.',
      'key': cleanKey
    };
  }

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
      try {
        await initializeDateFormatting('tr_TR', null);
        await initializeDateFormatting('tr', null);
      } catch (_) {}
      try {
        await NotificationService().init();
      } catch (_) {}
      final prefs = await SharedPreferences.getInstance();

      // Load User Name
      _userName = prefs.getString(_prefKeyUserName);

      // Load Gemini API Key & cached working model
      _geminiApiKey = prefs.getString(_prefKeyGeminiKey);
      _workingGeminiModel = prefs.getString(_prefKeyWorkingGeminiModel);

      // Load Groq API Key & cached working model
      _groqApiKey = prefs.getString(_prefKeyGroqKey);
      _workingGroqModel = prefs.getString(_prefKeyWorkingGroqModel);

      // Load Active Provider
      _activeProvider = prefs.getString(_prefKeyActiveProvider) ?? 'auto';

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
                'Senin kişisel yapay zeka asistanınım. Günlük planlarını, toplantılarını bana söyleyebilir veya güncel hava durumunu sorabilirsin.\n\n'
                'Örneğin:\n'
                '• "Bugün İstanbul\'da hava durumu nasıl?" 🌤️\n'
                '• "Yarın saat 14:00\'te toplantım var, 30 dakika önce hatırlat" ⏰\n'
                '• "Kadıköy hava nasıl?" ☀️\n'
                '• "Aktif planlarımı göster" 📋\n\n'
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
            '📅 Plan Saati: ${reminder.formattedEventTimeSimple} ($leadText)\n\n'
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
        text: 'Sohbet temizlendi. Nasıl yardımcı olabilirim? 🤖✨',
        timestamp: DateTime.now(),
      ),
    );
    await _persistMessages();
    notifier.value++;
  }

  /// Detects and remembers user's name when they introduce themselves
  static void _checkAndLearnUserName(String text) {
    final regexes = [
      RegExp(r'(?:benim\s+adım|adım|ismim)\s+([a-zA-ZçÇğĞıİöÖşŞüÜ]+)', caseSensitive: false),
      RegExp(r'(?:bana\s+)([a-zA-ZçÇğĞıİöÖşŞüÜ]+)(?:\s+de|\s+diyebilirsin)', caseSensitive: false),
    ];

    for (final reg in regexes) {
      final match = reg.firstMatch(text);
      if (match != null) {
        final candidate = match.group(1)?.trim();
        if (candidate != null &&
            candidate.length >= 2 &&
            !['ne', 'neydi', 'var', 'yok', 'bir', 'bu', 'şu', 'sen', 'ben', 've', 'ile', 'nasıl'].contains(candidate.toLowerCase())) {
          _userName = candidate[0].toUpperCase() + candidate.substring(1).toLowerCase();
          SharedPreferences.getInstance().then((p) => p.setString(_prefKeyUserName, _userName!));
          break;
        }
      }
    }
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

    // 1. Learn user's name if they introduced themselves
    _checkAndLearnUserName(text);

    // =========================================================================
    // 1. GERÇEK YAPAY ZEKA (GEMINI VEYA GROQ) BAĞLIYSA:
    // HİÇBİR HAZIR/ŞABLON MESAJ ÖNE GEÇMEZ. TÜM SORULARI DOĞRUDAN YAPAY ZEKA YANITLAR!
    // =========================================================================
    if (isRealAiConnected) {
      _lastGeminiError = null;
      _lastGroqError = null;

      // Kullanıcı açıkça hatırlatıcı/alarm istediyse arka planda bildirimi kur,
      // cevabı ise yine yapay zekanın doğal zekası versin!
      AiReminderModel? createdReminder;
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
          createdReminder = reminder;
        }
      }

      // Kullanıcı hava durumu soruyorsa, canlı hava verisini arka planda çekip
      // yapay zekaya bağlam (context) olarak verelim; yapay zeka kendi aklıyla anlatsın!
      String promptForAi = text;
      if (_isWeatherQuery(textLower)) {
        final city = _extractCityForWeather(text);
        if (city != null && city.isNotEmpty) {
          try {
            final w = await _fetchWeatherData(city);
            if (w != null) {
              promptForAi = '$text\n\n[Sistem Canlı Bilgisi: ${w.location} için hava şu an ${w.temp}°C, hissedilen ${w.feelsLike}°C, nem %${w.humidity}, rüzgar ${w.windSpeed} km/s, durum: ${w.description}. Bu canlı bilgiyi kullanarak kullanıcıya samimi, akıllı ve doğal bir Türkçe ile yanıt ver.]';
            }
          } catch (_) {}
        }
      }

      // Kullanıcı hatırlatıcılarını soruyorsa, aktif planlarını yapay zekaya aktar
      if (_isListingRemindersQuery(textLower)) {
        final active = activeReminders;
        final listStr = active.isEmpty
            ? 'Şu anda kayıtlı aktif bir hatırlatıcı bulunmuyor.'
            : active.map((r) => '• ${r.title} (${r.formattedEventTimeSimple})').join('\n');
        promptForAi = '$text\n\n[Sistem Canlı Bilgisi: Kullanıcının kayıtlı planları:\n$listStr\nBu bilgileri kullanarak kullanıcıya yardımcı ol.]';
      }

      final bool preferGroq = (_activeProvider == 'groq' && hasGroqApiKey) ||
          (hasGroqApiKey && !hasGeminiApiKey);

      String? groqError;
      String? geminiError;

      if (preferGroq) {
        // 1. Öncelik Groq (Llama 3.3 / 3.1)
        final groqReply = await _callGroqApi(promptForAi);
        if (groqReply != null && groqReply.isNotEmpty) {
          return AiMessageModel(
            id: const Uuid().v4(),
            sender: 'ai',
            text: groqReply,
            timestamp: DateTime.now(),
            reminder: createdReminder,
            actionType: createdReminder != null ? 'reminder_created' : null,
          );
        }
        groqError = _lastGroqError;

        // Groq başarısız olursa Gemini'ye geç
        if (hasGeminiApiKey) {
          final geminiReply = await _callGeminiApi(promptForAi);
          if (geminiReply != null && geminiReply.isNotEmpty) {
            return AiMessageModel(
              id: const Uuid().v4(),
              sender: 'ai',
              text: geminiReply,
              timestamp: DateTime.now(),
              reminder: createdReminder,
              actionType: createdReminder != null ? 'reminder_created' : null,
            );
          }
          geminiError = _lastGeminiError;
        }
      } else {
        // 1. Öncelik Gemini (1.5 Flash / 2.0 Flash)
        if (hasGeminiApiKey) {
          final geminiReply = await _callGeminiApi(promptForAi);
          if (geminiReply != null && geminiReply.isNotEmpty) {
            return AiMessageModel(
              id: const Uuid().v4(),
              sender: 'ai',
              text: geminiReply,
              timestamp: DateTime.now(),
              reminder: createdReminder,
              actionType: createdReminder != null ? 'reminder_created' : null,
            );
          }
          geminiError = _lastGeminiError;
        }

        // Gemini başarısız olursa Groq'a geç
        if (hasGroqApiKey) {
          final groqReply = await _callGroqApi(promptForAi);
          if (groqReply != null && groqReply.isNotEmpty) {
            return AiMessageModel(
              id: const Uuid().v4(),
              sender: 'ai',
              text: groqReply,
              timestamp: DateTime.now(),
              reminder: createdReminder,
              actionType: createdReminder != null ? 'reminder_created' : null,
            );
          }
          groqError = _lastGroqError;
        }
      }

      // Her iki sağlayıcı da veya seçili sağlayıcı başarısız olduysa:
      // Hataları karıştırmadan, net ve şeffaf şekilde kullanıcıya aktar!
      final activeProviderName = preferGroq ? 'Groq LPU (Llama)' : 'Google Gemini';
      final primaryError = preferGroq ? groqError : geminiError;
      final secondaryError = preferGroq ? geminiError : groqError;
      final secondaryProviderName = preferGroq ? 'Google Gemini' : 'Groq LPU';
      final bool hadSecondary = preferGroq ? hasGeminiApiKey : hasGroqApiKey;

      final buffer = StringBuffer();
      buffer.writeln('⚠️ **$activeProviderName Bağlantı Hatası**\n');
      buffer.writeln('Bağlı olan yapay zeka servisine ($activeProviderName) ulaşılamadı:');
      buffer.writeln('📌 **Detay:** ${primaryError ?? "Sunucu yanıt vermedi."}\n');

      if (hadSecondary && secondaryError != null && secondaryError.isNotEmpty) {
        buffer.writeln('Yedek servis ($secondaryProviderName) da otomatik denendi ancak yanıt alınamadı:');
        buffer.writeln('📌 **Yedek Servis Detayı:** $secondaryError\n');
      }

      buffer.writeln('💡 **Çözüm Adımları:**');
      buffer.writeln('• Sağ üstteki ayarlar simgesinden API anahtarınızı kontrol edin veya test edin.');
      if (preferGroq && !hasGeminiApiKey) {
        buffer.writeln('• Alternatif olarak aistudio.google.com/apikey üzerinden ücretsiz Gemini anahtarı ekleyebilirsiniz.');
      } else if (!preferGroq && !hasGroqApiKey) {
        buffer.writeln('• Alternatif olarak console.groq.com/keys üzerinden ücretsiz Groq anahtarı ekleyebilirsiniz.');
      } else {
        buffer.writeln('• Ayarlar menüsünden diğer sağlayıcıyı (${preferGroq ? "Google Gemini ✨" : "Groq LPU ⚡"}) seçebilirsiniz.');
      }

      return AiMessageModel(
        id: const Uuid().v4(),
        sender: 'ai',
        text: buffer.toString().trim(),
        timestamp: DateTime.now(),
        actionType: 'error',
      );
    }

    // =========================================================================
    // 2. YALNIZCA GERÇEK YAPAY ZEKA BAĞLI DEĞİLSE (HİÇ API ANAHTARI YOKSA):
    // Çevrimdışı kurallar, hava kartı ve yerel şablonlar devreye girer.
    // =========================================================================

    // A. Hatırlatıcıları listeleme
    if (_isListingRemindersQuery(textLower)) {
      return _generateRemindersListResponse();
    }

    // B. Hatırlatıcıları iptal etme
    if (_isCancelReminderQuery(textLower)) {
      return _handleCancelReminderQuery(textLower);
    }

    // C. Hatırlatıcı kurma
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

        final eventTimeStr = reminder.formattedEventTime;
        final leadStr = reminder.leadMinutes > 0 ? '${reminder.leadMinutes} dakika önce' : 'tam vaktinde';
        final alertTimeStr = reminder.formattedReminderTime;

        final responseText = 'Planını başarıyla kaydettim ve hatırlatıcını kurdum ⏰\n\n'
            '📌 **Plan:** ${reminder.title}\n'
            '📅 **Tarih & Saat:** $eventTimeStr\n'
            '🔔 **Hatırlatma Vakti:** $alertTimeStr ($leadStr)\n\n'
            'Zamanı geldiğinde sana bildirim ile haber vereceğim! 🎯';

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

    // D. Hava durumu
    if (_isWeatherQuery(textLower)) {
      final weatherResponse = await _handleWeatherQuery(text);
      if (weatherResponse != null) {
        return weatherResponse;
      }
    }

    // E. Ücretsiz bulut AI (Pollinations)
    final freeAiReply = await _callFreeCloudAi(text);
    if (freeAiReply != null && freeAiReply.isNotEmpty) {
      return AiMessageModel(
        id: const Uuid().v4(),
        sender: 'ai',
        text: freeAiReply,
        timestamp: DateTime.now(),
      );
    }

    // F. Yerel şablon yanıtları
    final reply = _generateConversationalResponse(text);
    return AiMessageModel(
      id: const Uuid().v4(),
      sender: 'ai',
      text: reply,
      timestamp: DateTime.now(),
    );
  }


  /// Zero-setup free cloud AI: Fast direct GET requests with model fallback
  static Future<String?> _callFreeCloudAi(String userPrompt) async {
    try {
      final seed = Random().nextInt(999999);
      // Clean and sanitize prompt for URL path usage
      final cleanText = userPrompt.replaceAll(RegExp(r'\s+'), ' ').trim();
      final truncated = cleanText.length > 220 ? cleanText.substring(0, 220) : cleanText;
      final promptWithContext = (_userName != null && _userName!.isNotEmpty)
          ? 'Ben $_userName. $truncated'
          : truncated;
      final encoded = Uri.encodeComponent(promptWithContext);

      final models = ['openai', 'openai-fast'];
      for (final m in models) {
        try {
          final uri = Uri.parse('https://text.pollinations.ai/$encoded?model=$m&seed=$seed');
          final res = await http.get(
            uri,
            headers: {
              'User-Agent': 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36',
              'Accept': 'text/plain, text/html, */*',
            },
          ).timeout(const Duration(seconds: 7));

          if (res.statusCode == 200) {
            final body = utf8.decode(res.bodyBytes).trim();
            if (body.isNotEmpty &&
                !body.contains('Free limit reached') &&
                !body.contains('Payment Required') &&
                !body.contains('"error":') &&
                !body.startsWith('<!DOCTYPE')) {
              return body;
            }
          }
        } catch (e) {
          debugPrint('[FREE AI] GET $m error: $e');
        }
      }

      // Fast fallback to bare endpoint without model query
      try {
        final uri = Uri.parse('https://text.pollinations.ai/$encoded?seed=$seed');
        final res = await http.get(
          uri,
          headers: {
            'User-Agent': 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36',
          },
        ).timeout(const Duration(seconds: 5));

        if (res.statusCode == 200) {
          final body = utf8.decode(res.bodyBytes).trim();
          if (body.isNotEmpty &&
              !body.contains('Free limit reached') &&
              !body.contains('Payment Required') &&
              !body.startsWith('<!DOCTYPE')) {
            return body;
          }
        }
      } catch (e) {
        debugPrint('[FREE AI] GET bare endpoint error: $e');
      }
    } catch (e) {
      debugPrint('[FREE AI] Main Exception: $e');
    }
    return null;
  }

  /// Builds compliant multi-turn message history for Gemini API
  static List<Map<String, dynamic>> _buildGeminiContents(String currentPrompt) {
    final contents = <Map<String, dynamic>>[];

    // Extract past non-action messages (filter out error bubbles and system cards)
    final past = _messages.where((m) =>
      m.actionType != 'welcome' &&
      m.actionType != 'reminder_created' &&
      m.actionType != 'weather' &&
      m.actionType != 'error' &&
      !m.text.startsWith('⚠️') &&
      m.text.trim().isNotEmpty
    ).toList();

    // If the last message in past is the current prompt, remove it so it's appended fresh
    if (past.isNotEmpty && past.last.sender == 'user' && past.last.text.trim() == currentPrompt.trim()) {
      past.removeLast();
    }

    final recent = past.length > 8 ? past.sublist(past.length - 8) : past;

    String? lastRole;
    for (final msg in recent) {
      final role = msg.sender == 'ai' ? 'model' : 'user';
      if (role == lastRole) continue;

      contents.add({
        'role': role,
        'parts': [{'text': msg.text.trim()}],
      });
      lastRole = role;
    }

    // If the last role was already user, remove it so currentPrompt takes over
    if (contents.isNotEmpty && lastRole == 'user') {
      contents.removeLast();
    }

    // Append current user prompt
    contents.add({
      'role': 'user',
      'parts': [{'text': currentPrompt.trim()}],
    });

    // Gemini strictly requires the first message to be from 'user'
    while (contents.isNotEmpty && contents.first['role'] != 'user') {
      contents.removeAt(0);
    }

    return contents;
  }

  /// Calls Google Gemini API with fallback across flash and pro models
  static Future<String?> _callGeminiApi(String userPrompt) async {
    final apiKey = _geminiApiKey?.trim();
    if (apiKey == null || apiKey.isEmpty) return null;

    _lastGeminiError = null;

    // If no working model cached yet, probe dynamically
    if (_workingGeminiModel == null || _workingGeminiModel!.isEmpty) {
      try {
        final listUrl = Uri.parse('https://generativelanguage.googleapis.com/v1beta/models?key=$apiKey');
        final listRes = await http.get(listUrl).timeout(const Duration(seconds: 8));
        if (listRes.statusCode == 200) {
          final decoded = jsonDecode(utf8.decode(listRes.bodyBytes));
          if (decoded is Map && decoded.containsKey('models')) {
            final modelsList = decoded['models'] as List?;
            final valid = <String>[];
            if (modelsList != null) {
              for (final m in modelsList) {
                final name = m['name']?.toString() ?? '';
                final methods = (m['supportedGenerationMethods'] as List?)?.map((e) => e.toString()).toList() ?? [];
                if (methods.contains('generateContent')) {
                  final modelId = name.startsWith('models/') ? name.substring(7) : name;
                  valid.add(modelId);
                }
              }
            }
            if (valid.contains('gemini-1.5-flash')) {
              _workingGeminiModel = 'gemini-1.5-flash';
            } else if (valid.contains('gemini-2.0-flash')) {
              _workingGeminiModel = 'gemini-2.0-flash';
            } else if (valid.contains('gemini-1.5-pro')) {
              _workingGeminiModel = 'gemini-1.5-pro';
            } else if (valid.isNotEmpty) {
              _workingGeminiModel = valid.first;
            }
            if (_workingGeminiModel != null) {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString(_prefKeyWorkingGeminiModel, _workingGeminiModel!);
            }
          }
        } else if (listRes.statusCode == 403) {
          _lastGeminiError = 'Google: Bu API anahtarında Generative Language servisi aktif değil (HTTP 403 PERMISSION_DENIED). Lütfen anahtarı Google Cloud yerine aistudio.google.com/apikey adresinden oluşturun.';
          return null;
        } else if (listRes.statusCode == 400 || listRes.statusCode == 401) {
          _lastGeminiError = 'Google: API anahtarı geçersiz (HTTP ${listRes.statusCode}). Lütfen kopyaladığınız anahtarı kontrol edin.';
          return null;
        } else if (listRes.statusCode == 429) {
          _lastGeminiError = 'Google: Anlık kota sınırına ulaşıldı (HTTP 429). Lütfen biraz bekleyin veya Groq kullanın.';
          return null;
        }
      } catch (e) {
        debugPrint('[GEMINI DYNAMIC PROBE] Error: $e');
      }
    }

    final candidateModels = [
      if (_workingGeminiModel != null && _workingGeminiModel!.isNotEmpty) _workingGeminiModel!,
      'gemini-1.5-flash',
      'gemini-1.5-pro',
      'gemini-2.0-flash',
    ];
    final models = candidateModels.toSet().toList();
    final contents = _buildGeminiContents(userPrompt);

    final nameHint = (_userName != null && _userName!.isNotEmpty)
        ? ' Konuştuğun kullanıcının adı: $_userName. Ona ismiyle hitap et.'
        : '';
    final systemPrompt = 'Sen "Talknex Asistan" adında, kullanıcının kişisel yapay zeka asistanısın.$nameHint '
        'Akıllıca, düşünerek, samimi ve son derece yardımsever bir şekilde Türkçe konuşursun. '
        'Kullanıcının her türlü sorusuna (günlük hayat, yemek tarifleri, tavsiye, genel kültür, teknoloji, bilim vb.) '
        'özenle, derinlemesine ve özgün yanıtlar ver. Yanıtlarında Markdown biçimlendirmesini (kalın yazılar, emojiler, liste işaretleri) şık bir şekilde kullan.';

    for (final model in models) {
      try {
        final url = Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey',
        );

        final requestBody = {
          'contents': contents,
          'systemInstruction': {
            'parts': [
              {'text': systemPrompt}
            ]
          },
          'generationConfig': {
            'temperature': 0.7,
            'maxOutputTokens': 1500,
          }
        };

        final response = await http.post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(requestBody),
        ).timeout(const Duration(seconds: 22));

        if (response.statusCode == 200) {
          final decoded = jsonDecode(utf8.decode(response.bodyBytes));
          if (decoded is Map && decoded.containsKey('candidates')) {
            final candidates = decoded['candidates'] as List;
            if (candidates.isNotEmpty) {
              final first = candidates[0];
              final content = first['content'];
              if (content != null && content['parts'] is List) {
                final parts = content['parts'] as List;
                final text = parts.map((p) => p['text']?.toString() ?? '').join();
                if (text.trim().isNotEmpty) {
                  _workingGeminiModel = model;
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setString(_prefKeyWorkingGeminiModel, model);
                  _lastGeminiError = null;
                  return text.trim();
                }
              }
            }
          }
        } else {
          String errMsg = 'HTTP ${response.statusCode}';
          try {
            final decoded = jsonDecode(utf8.decode(response.bodyBytes));
            errMsg = decoded['error']?['message']?.toString() ?? errMsg;
          } catch (_) {}

          debugPrint('[GEMINI] Model $model returned status ${response.statusCode}: $errMsg');

          if (response.statusCode == 400 && (errMsg.contains('API_KEY_INVALID') || errMsg.contains('not valid'))) {
            _lastGeminiError = 'Google: API anahtarı geçersiz (HTTP 400). Lütfen kopyaladığınız anahtarı kontrol edin.';
            break;
          }
          if (response.statusCode == 403 || errMsg.contains('PERMISSION_DENIED') || errMsg.contains('blocked')) {
            _lastGeminiError = 'Google: Bu anahtarda Generative Language servisi aktif değil (HTTP 403). Lütfen anahtarı Google Cloud yerine doğrudan aistudio.google.com/apikey üzerinden oluşturun.';
            break;
          }
          if (response.statusCode == 429) {
            _lastGeminiError = 'Google: Anlık kota sınırına ulaşıldı (HTTP 429). Lütfen biraz bekleyin veya Groq kullanın.';
            break;
          }

          _lastGeminiError = 'Gemini ($model): $errMsg (HTTP ${response.statusCode})';
        }
      } catch (e) {
        _lastGeminiError = 'Gemini ($model) bağlantı hatası: $e';
        debugPrint('[GEMINI] Model $model error: $e');
      }
    }
    return null;
  }

  /// Builds strictly compliant multi-turn message history for Groq / OpenAI Chat API
  static List<Map<String, String>> _buildGroqMessages(String currentPrompt) {
    final msgs = <Map<String, String>>[];
    final nameHint = (_userName != null && _userName!.isNotEmpty)
        ? ' Konuştuğun kullanıcının adı: $_userName. Ona ismiyle hitap et.'
        : '';

    msgs.add({
      'role': 'system',
      'content': 'Sen "Talknex Asistan" adında, kullanıcının kişisel yapay zeka asistanısın.$nameHint '
          'Akıllıca, düşünerek, samimi ve son derece yardımsever bir şekilde Türkçe konuşursun. '
          'Kullanıcının her türlü sorusuna (günlük hayat, yemek tarifleri, tavsiye, genel kültür, teknoloji, bilim vb.) '
          'özenle, derinlemesine ve özgün yanıtlar ver. Yanıtlarında Markdown biçimlendirmesini (kalın yazılar, emojiler, liste işaretleri) şık bir şekilde kullan.',
    });

    // Extract past non-action messages (filter out error bubbles and system cards)
    final past = _messages.where((m) =>
      m.actionType != 'welcome' &&
      m.actionType != 'reminder_created' &&
      m.actionType != 'weather' &&
      m.actionType != 'error' &&
      !m.text.startsWith('⚠️') &&
      m.text.trim().isNotEmpty
    ).toList();

    // If the last message in past is the current prompt, exclude it so we append it cleanly at the end
    if (past.isNotEmpty && past.last.sender == 'user' && past.last.text.trim() == currentPrompt.trim()) {
      past.removeLast();
    }

    final recent = past.length > 8 ? past.sublist(past.length - 8) : past;

    String? lastRole = 'system';
    for (final m in recent) {
      final role = m.sender == 'ai' ? 'assistant' : 'user';
      // Do not allow consecutive same roles
      if (role == lastRole) continue;
      // The first message after system must be user
      if (lastRole == 'system' && role == 'assistant') continue;

      msgs.add({
        'role': role,
        'content': m.text.trim(),
      });
      lastRole = role;
    }

    // If the last added message was already user, remove it so currentPrompt takes over cleanly
    if (lastRole == 'user' && msgs.isNotEmpty) {
      msgs.removeLast();
    }

    // Append current user prompt as final user turn
    msgs.add({
      'role': 'user',
      'content': currentPrompt.trim(),
    });

    return msgs;
  }

  /// Calls Groq API (Llama 3.3 70B & Llama 3.1 8B on Groq LPU)
  static Future<String?> _callGroqApi(String userPrompt) async {
    final apiKey = _groqApiKey?.trim();
    if (apiKey == null || apiKey.isEmpty) return null;

    _lastGroqError = null;

    final candidateModels = [
      if (_workingGroqModel != null && _workingGroqModel!.isNotEmpty) _workingGroqModel!,
      'llama-3.3-70b-versatile',
      'llama-3.1-8b-instant',
    ];
    final models = candidateModels.toSet().toList();
    final messages = _buildGroqMessages(userPrompt);

    for (final model in models) {
      try {
        final url = Uri.parse('https://api.groq.com/openai/v1/chat/completions');
        final response = await http.post(
          url,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
            'User-Agent': 'Talknex/1.0 (Android)',
            'Accept': 'application/json',
          },
          body: jsonEncode({
            'model': model,
            'messages': messages,
            'temperature': 0.7,
            'max_tokens': 1500,
          }),
        ).timeout(const Duration(seconds: 25));

        if (response.statusCode == 200) {
          final decoded = jsonDecode(utf8.decode(response.bodyBytes));
          if (decoded is Map && decoded.containsKey('choices')) {
            final choices = decoded['choices'] as List;
            if (choices.isNotEmpty) {
              final first = choices[0];
              final message = first['message'];
              if (message != null && message['content'] != null) {
                final text = message['content'].toString().trim();
                if (text.isNotEmpty) {
                  _workingGroqModel = model;
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setString(_prefKeyWorkingGroqModel, model);
                  _lastGroqError = null;
                  return text;
                }
              }
            }
          }
        } else {
          String errMsg = 'HTTP ${response.statusCode}';
          try {
            final decoded = jsonDecode(utf8.decode(response.bodyBytes));
            errMsg = decoded['error']?['message']?.toString() ?? errMsg;
          } catch (_) {}

          debugPrint('[GROQ] Model $model returned status ${response.statusCode}: $errMsg');

          if (response.statusCode == 401) {
            _lastGroqError = 'Groq: Geçersiz API Anahtarı (HTTP 401). Lütfen console.groq.com/keys adresinden yeni bir anahtar alın.';
            break;
          }
          if (response.statusCode == 429) {
            _lastGroqError = 'Groq: Anlık istek/token sınırına ulaşıldı (HTTP 429 Rate Limit). Lütfen biraz bekleyin veya Gemini kullanın.';
            break;
          }

          _lastGroqError = 'Groq ($model): $errMsg (HTTP ${response.statusCode})';
        }
      } catch (e) {
        _lastGroqError = 'Groq ($model) bağlantı hatası: $e';
        debugPrint('[GROQ] Model $model error: $e');
      }
    }
    return null;
  }

  // --- Weather Intelligence Engine ---

  static bool _isWeatherQuery(String text) {
    final lower = text.toLowerCase();
    return lower.contains('hava') ||
        lower.contains('havalar') ||
        lower.contains('sıcaklık') ||
        lower.contains('sicaklik') ||
        lower.contains('derece') ||
        lower.contains('yağmur var mı') ||
        lower.contains('yagmur var mi') ||
        lower.contains('kar var mı') ||
        lower.contains('kar var mi');
  }

  static String? _extractCityForWeather(String text) {
    final stopWords = {
      'bugun', 'bugün', 'yarin', 'yarın', 'hava', 'havalar', 'durumu', 'durum', 'durumları',
      'nasil', 'nasıl', 'nedir', 'var', 'mı', 'mi', 'mu', 'mü', 've', 'ile', 'şu', 'su',
      'an', 'şuan', 'suan', 'bana', 'söyle', 'soyle', 'öğren', 'öğrenmek', 'istiyorum',
      'il', 'ilçe', 'ilcesi', 'ilçesi', 'ilçede', 'ilde', 'derece', 'kaç', 'kac', 'olan',
      'bir', 'veya', 'hakkında', 'bilgi', 'ver', 'verir', 'misin', 'misiniz', 'lütfen',
      'şöyle', 'böyle', 'güncel', 'guncel', 'sabah', 'akşam', 'aksam', 'öğle', 'ogle'
    };

    final clean = text.toLowerCase().replaceAll(RegExp(r'[\?\.!,;:]'), ' ').trim();
    final tokens = clean.split(RegExp(r'\s+'));

    for (final t in tokens) {
      if (stopWords.contains(t)) continue;

      if (t.contains("'")) {
        final prefix = t.split("'").first;
        if (!stopWords.contains(prefix) && prefix.length >= 2) {
          return prefix;
        }
      }

      String cand = t;
      for (final suffix in ['nda', 'nde', 'da', 'de', 'ta', 'te']) {
        if (cand.endsWith(suffix) && cand.length - suffix.length >= 3) {
          cand = cand.substring(0, cand.length - suffix.length);
          break;
        }
      }

      if (!stopWords.contains(cand) && cand.length >= 2) {
        return cand;
      }
    }
    return null;
  }

  static Future<AiWeatherModel?> _fetchWeatherData(String cityName) async {
    // 1. Try Open-Meteo first (super accurate & free)
    try {
      final geoUrl = Uri.parse(
        'https://geocoding-api.open-meteo.com/v1/search?name=${Uri.encodeComponent(cityName)}&count=8&language=tr&format=json',
      );
      final geoRes = await http.get(geoUrl, headers: {'User-Agent': 'TalknexAI/1.0'}).timeout(const Duration(seconds: 4));
      if (geoRes.statusCode == 200) {
        final geoData = jsonDecode(geoRes.body);
        final results = geoData['results'];
        if (results is List && results.isNotEmpty) {
          // Prioritize Turkey
          Map<String, dynamic>? selected;
          for (final r in results) {
            final countryCode = (r['country_code'] ?? '').toString().toUpperCase();
            final country = (r['country'] ?? '').toString().toLowerCase();
            if (countryCode == 'TR' || country.contains('türk') || country.contains('turk')) {
              selected = Map<String, dynamic>.from(r);
              break;
            }
          }
          selected ??= Map<String, dynamic>.from(results.first);

          final double lat = (selected['latitude'] as num).toDouble();
          final double lon = (selected['longitude'] as num).toDouble();
          final String name = selected['name'] ?? cityName;
          final String admin1 = selected['admin1'] ?? '';
          final String locStr = (admin1.isNotEmpty && admin1 != name) ? '$name, $admin1' : name;

          final wUrl = Uri.parse(
            'https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon&current=temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m&daily=temperature_2m_max,temperature_2m_min&timezone=auto',
          );
          final wRes = await http.get(wUrl, headers: {'User-Agent': 'TalknexAI/1.0'}).timeout(const Duration(seconds: 4));
          if (wRes.statusCode == 200) {
            final wData = jsonDecode(wRes.body);
            final current = wData['current'] as Map<String, dynamic>;
            final daily = (wData['daily'] as Map<String, dynamic>?) ?? {};

            final weatherCode = (current['weather_code'] as num?)?.toInt() ?? 0;
            final descAndIcon = _wmoToTextAndIcon(weatherCode);

            final maxList = daily['temperature_2m_max'] as List?;
            final minList = daily['temperature_2m_min'] as List?;

            return AiWeatherModel(
              location: locStr,
              temp: (current['temperature_2m'] as num).round(),
              feelsLike: (current['apparent_temperature'] as num).round(),
              humidity: (current['relative_humidity_2m'] as num).round(),
              windSpeed: (current['wind_speed_10m'] as num).round(),
              description: descAndIcon['text']!,
              icon: descAndIcon['icon']!,
              maxTemp: (maxList != null && maxList.isNotEmpty) ? (maxList.first as num).round() : null,
              minTemp: (minList != null && minList.isNotEmpty) ? (minList.first as num).round() : null,
            );
          }
        }
      }
    } catch (e) {
      debugPrint('[AI WEATHER] Open-Meteo error: $e');
    }

    // 2. Fallback to wttr.in
    try {
      final wttrUrl = Uri.parse('https://wttr.in/${Uri.encodeComponent(cityName)}?format=j1&lang=tr');
      final res = await http.get(wttrUrl, headers: {'User-Agent': 'curl/7.68.0'}).timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final current = data['current_condition'][0];
        final langTr = current['lang_tr'] as List?;
        final weatherDesc = current['weatherDesc'] as List?;

        String desc = 'Açık';
        if (langTr != null && langTr.isNotEmpty) {
          desc = langTr[0]['value'] ?? 'Açık';
        } else if (weatherDesc != null && weatherDesc.isNotEmpty) {
          desc = weatherDesc[0]['value'] ?? 'Açık';
        }

        final icon = _descToIcon(desc);
        final formattedLoc = cityName.length > 1
            ? cityName[0].toUpperCase() + cityName.substring(1)
            : cityName.toUpperCase();

        return AiWeatherModel(
          location: formattedLoc,
          temp: int.tryParse(current['temp_C'].toString()) ?? 20,
          feelsLike: int.tryParse(current['FeelsLikeC'].toString()) ?? 20,
          humidity: int.tryParse(current['humidity'].toString()) ?? 50,
          windSpeed: int.tryParse(current['windspeedKmph'].toString()) ?? 5,
          description: desc,
          icon: icon,
        );
      }
    } catch (e) {
      debugPrint('[AI WEATHER] wttr.in error: $e');
    }

    return null;
  }

  static Map<String, String> _wmoToTextAndIcon(int code) {
    switch (code) {
      case 0:
        return {'text': 'Açık ve Güneşli', 'icon': '☀️'};
      case 1:
        return {'text': 'Çoğunlukla Açık', 'icon': '🌤️'};
      case 2:
        return {'text': 'Parçalı Bulutlu', 'icon': '⛅'};
      case 3:
        return {'text': 'Çok Bulutlu / Kapalı', 'icon': '☁️'};
      case 45:
      case 48:
        return {'text': 'Sisli', 'icon': '🌫️'};
      case 51:
      case 53:
      case 55:
        return {'text': 'Hafif Çiseleyen Yağmur', 'icon': '🌦️'};
      case 61:
        return {'text': 'Hafif Yağmurlu', 'icon': '🌧️'};
      case 63:
        return {'text': 'Orta Şiddette Yağmurlu', 'icon': '🌧️'};
      case 65:
        return {'text': 'Kuvvetli Sağanak Yağış', 'icon': '🌧️'};
      case 66:
      case 67:
        return {'text': 'Dondurucu Yağmur', 'icon': '🌨️'};
      case 71:
      case 73:
      case 75:
        return {'text': 'Kar Yağışlı', 'icon': '🌨️'};
      case 77:
        return {'text': 'Kar Taneleri', 'icon': '❄️'};
      case 80:
      case 81:
      case 82:
        return {'text': 'Sağanak Yağış', 'icon': '🌦️'};
      case 85:
      case 86:
        return {'text': 'Yoğun Kar Sağanağı', 'icon': '🌨️'};
      case 95:
      case 96:
      case 99:
        return {'text': 'Gök Gürültülü Fırtına', 'icon': '⛈️'};
      default:
        return {'text': 'Açık ve Bulutlu', 'icon': '🌤️'};
    }
  }

  static String _descToIcon(String desc) {
    final d = desc.toLowerCase();
    if (d.contains('güneş') || d.contains('gunes') || d.contains('açık') || d.contains('acik') || d.contains('sunny') || d.contains('clear')) {
      return '☀️';
    }
    if (d.contains('parçalı') || d.contains('partly')) {
      return '⛅';
    }
    if (d.contains('bulut') || d.contains('cloud') || d.contains('overcast')) {
      return '☁️';
    }
    if (d.contains('fırtına') || d.contains('thunder') || d.contains('gök gürült')) {
      return '⛈️';
    }
    if (d.contains('kar') || d.contains('snow') || d.contains('blizzard')) {
      return '🌨️';
    }
    if (d.contains('yağmur') || d.contains('yagmur') || d.contains('rain') || d.contains('drizzle')) {
      return '🌧️';
    }
    if (d.contains('sis') || d.contains('fog') || d.contains('mist')) {
      return '🌫️';
    }
    return '🌤️';
  }

  static Future<AiMessageModel?> _handleWeatherQuery(String text) async {
    final city = _extractCityForWeather(text);

    if (city == null || city.isEmpty) {
      return AiMessageModel(
        id: const Uuid().v4(),
        sender: 'ai',
        text: 'Hangi şehir veya ilçenin hava durumunu öğrenmek istersin? 🌤️\n\n'
            'Örneğin:\n'
            '• *"Bugün İstanbul\'da hava durumu nasıl?"*\n'
            '• *"Ankara hava durumu"*\n'
            '• *"Kadıköy hava nasıl?"*\n'
            '• *"Alanya hava durumu"*',
        timestamp: DateTime.now(),
      );
    }

    final weather = await _fetchWeatherData(city);
    if (weather == null) {
      return AiMessageModel(
        id: const Uuid().v4(),
        sender: 'ai',
        text: 'Üzgünüm, "$city" için güncel hava durumu bilgilerine şu anda ulaşılamadı. Lütfen il veya ilçe adını doğru yazdığından emin olup tekrar dener misin? 🌤️',
        timestamp: DateTime.now(),
      );
    }

    String tip = '';
    final descLower = weather.description.toLowerCase();
    if (descLower.contains('yağmur') || descLower.contains('sağanak') || descLower.contains('fırtına')) {
      tip = '\n💡 **İpucu:** Dışarı çıkarken şemsiyeni ve yağmurluğunu yanına almayı unutma! ☔';
    } else if (descLower.contains('kar') || weather.temp <= 5) {
      tip = '\n💡 **İpucu:** Hava oldukça soğuk, sıkı giyinmeyi ve sıcak kalmayı ihmal etme! 🧣';
    } else if (weather.temp >= 24) {
      tip = '\n💡 **İpucu:** Dışarıda ılık ve keyifli bir hava var, tadını çıkar! ☀️';
    }

    final dailyStr = (weather.maxTemp != null && weather.minTemp != null)
        ? '• 📈 **Günün En Yükseği:** ${weather.maxTemp}°C  |  📉 **En Düşüğü:** ${weather.minTemp}°C\n'
        : '';

    final responseText = '📍 **${weather.location}** için güncel hava durumu:\n\n'
        'Şu an sıcaklık **${weather.temp}°C** ve hava **${weather.description}** ${weather.icon}.\n\n'
        '• 🌡️ **Hissedilen:** ${weather.feelsLike}°C\n'
        '• 💧 **Nem Oranı:** %${weather.humidity}\n'
        '• 💨 **Rüzgar Hızı:** ${weather.windSpeed} km/s\n'
        '$dailyStr$tip';

    return AiMessageModel(
      id: const Uuid().v4(),
      sender: 'ai',
      text: responseText,
      timestamp: DateTime.now(),
      weather: weather,
      actionType: 'weather_report',
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
    final lower = text.toLowerCase();

    // Must NOT be negated (e.g. "hatırlatma", "haber verme")
    if (lower.contains('hatırlatma') ||
        lower.contains('hatirlatma') ||
        lower.contains('haber verme') ||
        lower.contains('alarm kurma') ||
        lower.contains('uyarma')) {
      return false;
    }

    // Must contain explicit reminder command words
    final triggers = [
      'hatırlat',
      'hatirlat',
      'haber ver',
      'alarm kur',
      'uyar',
      'hatırlatıcı kur',
      'hatirlatici kur',
      'hatırlatıcı ekle',
      'hatirlatici ekle',
      'hatırlatıcı oluştur',
      'hatirlatici olustur',
      'bildirim kur',
      'bildirim gönder',
      'bildirim yolla',
    ];

    return triggers.any((t) => lower.contains(t));
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
      final eventStr = r.formattedEventTimeSimple;
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
        // Pattern 3: 14'te, 15'te, 8'de
        final hourSuffixRegex = RegExp(r'\b(\d{1,2})[\x27\u2019]?(?:te|ta|de|da)\b');
        final hourSuffixMatch = hourSuffixRegex.firstMatch(textLower);
        if (hourSuffixMatch != null) {
          targetHour = int.tryParse(hourSuffixMatch.group(1) ?? '12') ?? 12;
          timeIdentified = true;
        } else {
          // Pattern 4: akşam 8, sabah 9
          final aksamRegex = RegExp(r'akşam\s*(\d{1,2})');
          final aksamMatch = aksamRegex.firstMatch(textLower);
          if (aksamMatch != null) {
            targetHour = int.tryParse(aksamMatch.group(1) ?? '8') ?? 8;
            if (targetHour < 12) targetHour += 12;
            timeIdentified = true;
          }
        }
      }
    }

    // Evening / Night adjustment
    if ((textLower.contains('akşam') || textLower.contains('gece')) && targetHour < 12) {
      targetHour += 12;
    }

    // STRICT: If no specific time was identified by user, DO NOT create a reminder
    if (!timeIdentified) {
      return null;
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
    String cleaned = raw.trim();

    // 1. Remove command / reminder triggers at end or anywhere
    final commandPatterns = [
      RegExp(r'(?:,\s*)?(?:bana\s+|beni\s+)?(?:\d+\s*(?:dakika|dk|saat)\s*(?:önce|once)\s*)?(?:hatırlat[a-z0-9_]*|haber ver[a-z0-9_]*|uyar[a-z0-9_]*|bildir[a-z0-9_]*|kaydet[a-z0-9_]*|not et[a-z0-9_]*).*$', caseSensitive: false),
      RegExp(r'\b(?:bana|beni|bize)\b', caseSensitive: false),
      RegExp(r'\b\d+\s*(?:dakika|dk|saat)\s*(?:önce|once)\b', caseSensitive: false),
      RegExp(r'\byarım saat önce\b|\byarim saat once\b', caseSensitive: false),
      RegExp(r'\b\d+\s*(?:dakika|dk|saat)\s*sonra\b', caseSensitive: false),
    ];
    for (final cp in commandPatterns) {
      cleaned = cleaned.replaceAll(cp, ' ');
    }

    // 2. Remove date expressions
    final datePatterns = [
      RegExp(r'\b(?:yarın|yarin|bugün|bugun|öbür gün|obur gun)\b', caseSensitive: false),
      RegExp(r'\b(?:pazartesi|salı|sali|çarşamba|carsamba|perşembe|persembe|cuma|cumartesi|pazar)(?:[\x27\u2019]?(?:si|sı|ye|ya|e|a|de|da|te|ta))?\b', caseSensitive: false),
      RegExp(r'\b\d{1,2}\s+(?:ocak|şubat|subat|mart|nisan|mayıs|mayis|haziran|temmuz|ağustos|agustos|eylül|eylul|ekim|kasım|kasim|aralık|aralik)(?:[\x27\u2019]?(?:te|ta|de|da|ye|ya|e|a))?\b', caseSensitive: false),
    ];
    for (final dp in datePatterns) {
      cleaned = cleaned.replaceAll(dp, ' ');
    }

    // 3. Remove time expressions INCLUDING their Turkish locative/dative suffixes ('te, 'de, 'ta, 'da, de, da, te, ta, e, a, etc.)
    final timePatterns = [
      // e.g. "saat 14:00'te", "14:00'te", "14:00te", "saat 14:00"
      RegExp(r'\b(?:saat\s*)?\d{1,2}[:.]\d{2}(?:[\x27\u2019]?(?:[td][ea]|[yea]))?\b', caseSensitive: false),
      // e.g. "saat 14'te", "saat 14", "saat 8'de"
      RegExp(r'\bsaat\s*\d{1,2}(?:[\x27\u2019]?(?:[td][ea]|[yea]))?\b', caseSensitive: false),
      // Leftover time suffixes like "'te", "'de", "’te"
      RegExp(r'[\x27\u2019](?:[td][ea]|[yea])\b', caseSensitive: false),
      // Standalone time-of-day indicators
      RegExp(r'\b(?:sabah|öğlen|oglen|akşam|aksam|gece)\b', caseSensitive: false),
    ];
    for (final tp in timePatterns) {
      cleaned = cleaned.replaceAll(tp, ' ');
    }

    // 4. Remove punctuation & quotes
    cleaned = cleaned.replaceAll(RegExp(r'[\x27\x22\u2018\u2019\u201c\u201d]'), ' ');
    cleaned = cleaned.replaceAll(RegExp(r'[,.!?;:_\-–]'), ' ');

    // 5. Clean filler words & verbs
    cleaned = cleaned.replaceAll(RegExp(r'\b(bir|şu|su|olan|diye)\b', caseSensitive: false), ' ');
    cleaned = cleaned.replaceAll(RegExp(r'\b(var|vardır|vardir|olacak|yapılacak|yapilacak)\b', caseSensitive: false), ' ');
    // Remove standalone dangling suffix words (te, de, ta, da)
    cleaned = cleaned.replaceAll(RegExp(r'\b([td][ea])\b', caseSensitive: false), ' ');

    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();

    // 6. Intelligent Fallback for common Turkish reminder keywords if title is empty or too short
    if (cleaned.length < 3) {
      if (lower.contains('doğum günü') || lower.contains('dogum gunu')) return 'Doğum Günü';
      if (lower.contains('toplantı') || lower.contains('toplanti')) return 'Toplantı';
      if (lower.contains('seyahat') || lower.contains('yolculuk') || lower.contains('gezi')) return 'Seyahat';
      if (lower.contains('doktor') || lower.contains('muayene') || lower.contains('hastane')) return 'Doktor Randevusu';
      if (lower.contains('randevu')) return 'Randevu';
      if (lower.contains('sınav') || lower.contains('sinav')) return 'Sınav';
      if (lower.contains('ilaç') || lower.contains('ilac')) return 'İlaç Vakti';
      if (lower.contains('spor') || lower.contains('antrenman') || lower.contains('gym')) return 'Spor / Antrenman';
      if (lower.contains('fırın') || lower.contains('firin')) return 'Fırını Kapatma';
      if (lower.contains('fatura') || lower.contains('ödeme') || lower.contains('odeme')) return 'Fatura Ödemesi';
      if (lower.contains('ders')) return 'Ders Çalışma';
      if (lower.contains('uçuş') || lower.contains('ucus') || lower.contains('uçak') || lower.contains('ucak')) return 'Uçuş';
      if (lower.contains('su')) return 'Su İçme';
      return 'Plan';
    }

    // Capitalize words
    final words = cleaned.split(' ');
    final capitalized = words.where((w) => w.isNotEmpty).map((w) {
      return w[0].toUpperCase() + w.substring(1);
    }).join(' ');

    return capitalized;
  }

  /// Conversational AI Knowledge Engine (clean fallback with memory)
  static String _generateConversationalResponse(String text) {
    final lower = text.toLowerCase();
    final name = (_userName != null && _userName!.isNotEmpty) ? ' $_userName' : '';

    // 0. Name Inquiries
    if (lower.contains('benim adım ne') ||
        lower.contains('adım neydi') ||
        lower.contains('ismim ne') ||
        lower.contains('adımı biliyor musun') ||
        lower.contains('beni tanıyor musun') ||
        lower.contains('ben kimim')) {
      if (_userName != null && _userName!.isNotEmpty) {
        return 'Senin adın **$_userName**! Seni çok iyi hatırlıyorum 😊 Sana nasıl yardımcı olabilirim?';
      } else {
        return 'Henüz bana adını söylemedin. Adın nedir? Sana isminle hitap etmek isterim! 😊';
      }
    }

    // 0.1 Name Introduction
    if (_userName != null && (lower.contains('benim adım') || lower.contains('adım ') || lower.contains('bana '))) {
      return 'Tekrar memnun oldum **$_userName**! İsmini aklımda tutuyorum. Ne hakkında konuşmak istersin? ✨';
    }

    // 1. Identity & Self Intro
    if (lower.contains('sen kimsin') ||
        lower.contains('kimsin') ||
        lower.contains('adın ne') ||
        lower.contains('kendini tanıt') ||
        lower.contains('neler yapabilirsin')) {
      return 'Ben **Talknex Asistan**! 🤖 Talknex iletişim uygulamasının akıllı yapay zeka asistanıyım.\n\n'
          'Seninle dilediğin gibi sohbet edebilir, sorularını yanıtlayabilir, hava durumunu söyleyebilir veya istediğin saatte hatırlatıcı kurabilirim.\n\n'
          'Sana nasıl yardımcı olabilirim$name? 😊';
    }

    // 2. Greetings
    if (lower == 'selam' ||
        lower == 'merhaba' ||
        lower.startsWith('selam') ||
        lower.startsWith('merhaba') ||
        lower == 'hey' ||
        lower == 'slm') {
      final greetings = [
        'Merhaba$name! Nasıl yardımcı olabilirim? 😊',
        'Selam$name! Harika bir gün dilerim, nasılsın? ✨',
        'Merhaba$name! Seni görmek çok güzel, bugün neler yapıyorsun? 🤖',
      ];
      return greetings[Random().nextInt(greetings.length)];
    }

    // 3. How are you
    if (lower.contains('nasılsın') || lower.contains('nasilsin') || lower.contains('ne haber') || lower.contains('naber')) {
      return 'Harikayım$name, teşekkür ederim! Senin günün nasıl geçiyor? Neler yapıyorsun? 🚀';
    }

    // 4. Good morning / night
    if (lower.contains('günaydın') || lower.contains('gunaydin')) {
      return 'Günaydın$name! ☀️ Harika, huzurlu ve keyifli bir gün dilerim!';
    }
    if (lower.contains('iyi geceler') || lower.contains('iyi aksamlar') || lower.contains('iyi akşamlar')) {
      return 'İyi akşamlar$name! Huzurlu ve dinlendirici bir vakit dilerim 🌙✨';
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
        '🚀 "En uzun yolculuklar bile tek bir adımla başlar."\nHedeflerine odaklan ve adım atmaktan asla vazgeçme!',
      ];
      return quotes[Random().nextInt(quotes.length)];
    }

    // 7. Time & Date
    if (lower.contains('saat kaç') || lower.contains('saat kac')) {
      final now = DateTime.now();
      final timeStr = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
      return 'Şu anda saat tam olarak **$timeStr** ⏰';
    }
    if (lower.contains('bugün ayın kaçı') || lower.contains('hangi gündeyiz') || lower.contains('tarih')) {
      final now = DateTime.now();
      const months = ['Ocak', 'Şubat', 'Mart', 'Nisan', 'Mayıs', 'Haziran', 'Temmuz', 'Ağustos', 'Eylül', 'Ekim', 'Kasım', 'Aralık'];
      const days = ['Pazartesi', 'Salı', 'Çarşamba', 'Perşembe', 'Cuma', 'Cumartesi', 'Pazar'];
      final m = months[(now.month - 1).clamp(0, 11)];
      final d = days[(now.weekday - 1).clamp(0, 6)];
      final dateStr = '${now.day} $m ${now.year}, $d';
      return 'Bugün **$dateStr** 📅';
    }

    // 8. Productivity & Time Management Tips
    if (lower.contains('zaman yönetimi') || lower.contains('çalışma') || lower.contains('odaklan') || lower.contains('pomodoro')) {
      return 'Zaman yönetimi ve odaklanma için 3 altın kural 💡:\n\n'
          '1. **Pomodoro Tekniği:** 25 dakika kesintisiz çalış, 5 dakika mola ver. 4 setten sonra 20 dakika uzun mola ver.\n'
          '2. **En Zor Görevi Sabah Yap (Eat That Frog):** Günün enerjisi en yüksekken en zor işi aradan çıkar.\n'
          '3. **Planlarını Organize Et:** Yapacaklarını öncelik sırasına koy ve adım adım tamamla! 🎯';
    }

    // 9. Talknex App Guide
    if (lower.contains('talknex') || lower.contains('uygulama') || lower.contains('özellik')) {
      return 'Talknex, güvenli ve zengin iletişim sunan modern bir mesajlaşma platformudur 🛡️\n\n'
          'Öne çıkan özellikler:\n'
          '• 🌐 **WhatsApp Stili Dil Çevirisi:** Sohbeti veya mesajı istediğin dile anında çevirebilirsin.\n'
          '• 📹 **Sesli ve Görüntülü Arama:** WebRTC destekli yüksek kaliteli görüşmeler.\n'
          '• 💬 **Emojili Tepkiler:** Mesaja basılı tutarak emojilerle tepki verebilirsin.\n'
          '• 🤖 **Talknex Asistan:** Seninle sohbet eder, sorularını yanıtlar, hava durumunu bildirir ve hatırlatıcı kurar!\n\n'
          'Keşfetmek istediğin başka bir özellik var mı?';
    }

    // 10. Thank you
    if (lower.contains('teşekkür') || lower.contains('tesekkur') || lower.contains('sağol') || lower.contains('harikasın')) {
      return 'Rica ederim$name! Her zaman senin için buradayım. Konuşmak istediğin başka bir konu olursa sormaktan çekinme! 😊🌟';
    }

    // 11. Food Decisions & Meal Suggestions
    if (lower.contains('et') && lower.contains('tavuk') &&
        (lower.contains('mi') || lower.contains('mı') || lower.contains('arada') || lower.contains('fikir') || lower.contains('yemek') || lower.contains('hangisi'))) {
      return 'Et mi tavuk mu ikilemi tam bir klasik! İşte karar vermeni kolaylaştıracak rehberim 🍽️:\n\n'
          '🍗 **Tavuk Seçeneği (Hafif ve Rahat):**\n'
          '• Sindirimi çok daha kolaydır, akşam saatlerinde mideyi hiç yormaz.\n'
          '• Izgara tavuk göğsü, fırında sebzeli tavuk veya pratik bir tavuk sote harika ve lezzetli bir seçenektir.\n\n'
          '🥩 **Et Seçeneği (Doyurucu ve Zengin):**\n'
          '• Demir, B12 ve protein deposudur; enerjini anında yükseltir ve uzun süre tok tutar.\n'
          '• Güzel bir anne köftesi, leziz bir et sote veya ızgara et günün yorgunluğunu alır!\n\n'
          '💡 **Tavsiyem:** Eğer hafif ve dinlendirici bir akşam geçirmek istiyorsan **tavuğu**, daha doyurucu ve enerjik bir öğün arıyorsan **eti** tercih et! Yanına da bol yeşillikli bir salata harika gider. Afiyet olsun$name! 😊';
    }

    if (lower.contains('ne yesem') || lower.contains('yemek öner') || lower.contains('yemek ne yap') || lower.contains('akşam yemeği') || lower.contains('aksam yemegi')) {
      return 'Günün menüsü için sana birkaç harika alternatif sunayım 🍲:\n\n'
          '1. 🥗 **Hafif & Pratik:** Fırında sebzeli tavuk veya ton balıklı mısırlı taze bir Akdeniz salatası.\n'
          '2. 🥘 **Geleneksel & Doyurucu:** Yanında tereyağlı pirinç pilavı ile nefis bir kuru fasulye veya anne köftesi.\n'
          '3. 🍝 **Hızlı & Lezzetli:** Kremalı mantarlı makarna veya fırında kaşarlı sebzeli güveç.\n\n'
          'Hangi mutfak tarzı canını çektiriyor$name?';
    }

    if (lower.contains('tatlı') || lower.contains('tatli')) {
      return 'Tatlı krizine en güzel çözümler 🍰:\n\n'
          '• **Hafif:** Sütlaç, magnolia veya muzlu chia puding.\n'
          '• **Klasik:** Sıcak bir sufle veya fıstıklı baklava.\n'
          '• **Sağlıklı:** Yoğurt üzerine bal, ceviz ve taze meyve dilimleri! 🍓';
    }

    // 12. Dilemmas & Decision Making (X mi Y mi)
    final choiceRegex = RegExp(r'([a-zA-ZçğıöşüÇĞİÖŞÜ0-9]+)\s+(?:mi|mı|mu|mü)\s+([a-zA-ZçğıöşüÇĞİÖŞÜ0-9]+)');
    final choiceMatch = choiceRegex.firstMatch(lower);
    if (choiceMatch != null &&
        (lower.contains('arada kaldım') || lower.contains('kararsızım') || lower.contains('hangisi') || lower.contains('fikir ver') || lower.contains('sence'))) {
      final opt1 = choiceMatch.group(1) ?? 'İlk seçenek';
      final opt2 = choiceMatch.group(2) ?? 'İkinci seçenek';
      return '**$opt1** ile **$opt2** arasında kaldıysan karar vermene yardımcı olayım 🤔:\n\n'
          '• **$opt1:** Eğer önceliğin pratiklik, konfor ve hızlı sonuç ise bu seçenek öne çıkıyor.\n'
          '• **$opt2:** Eğer yenilik arıyorsan, uzun vadeli keyif veya farklı bir deneyim istiyorsan bu harika bir tercih!\n\n'
          '💡 İç sesini dinle: İlk aklına gelen hangisi olduysa genelde doğru karardır! Hangisine daha yakınsın$name? ✨';
    }

    if (lower.contains('arada kaldım') || lower.contains('kararsızım') || lower.contains('fikir ver') || lower.contains('tavsiye ver')) {
      return 'Kararsız kaldığın konularda sana objektif bir bakış açısı sunmaktan mutluluk duyarım$name! 🎯\n\n'
          'Seçeneklerini veya aklındaki durumu biraz anlatır mısın? Artıları ve eksileri birlikte değerlendirip en iyi kararı verelim! 💡';
    }

    // 13. Entertainment & Free Time (Boredom, Movies, Books)
    if (lower.contains('sıkıldım') || lower.contains('sikildim') || lower.contains('ne yapabilirim') || lower.contains('yapacak bir şey')) {
      return 'Can sıkıntısını anında dağıtacak 4 harika fikir 🚀:\n\n'
          '1. 🎧 **Yeni Bir Podcast ya da Müzik Keşfet:** İlgi duyduğun bir konuda (bilim, tarih, gizem) 20 dakikalık bir bölüm dinle.\n'
          '2. 🚶 **Kısa Bir Yürüyüş:** Sadece 15 dakikalık bir açık hava yürüyüşü zihnini tamamen yeniler.\n'
          '3. 🎬 **Sürükleyici Bir Dizi/Film:** Aklında bir tür varsa söyle, hemen nokta atışı bir öneri yapayım!\n'
          '4. 📖 **Birkaç Sayfa Kitap Oku:** Telefonu bir kenara bırakıp sayfaların arasında kaybolmak her zaman iyi gelir.\n\n'
          'Hangisi kulağa daha cazip geliyor$name?';
    }

    if (lower.contains('film öner') || lower.contains('film tavsiye') || lower.contains('ne izlesem')) {
      return 'İşte her zevke uygun, mutlaka izlenmesi gereken başyapıtlar 🍿:\n\n'
          '• 🌌 **Bilim Kurgu & Akıl Oyunları:** *Interstellar* veya *Inception*\n'
          '• 🕵️ **Gerilim & Gizem:** *Zodiac* veya *Knives Out*\n'
          '• 🎭 **İlham Verici & Dram:** *The Pursuit of Happyness* veya *Whiplash*\n'
          '• 😂 **Neşeli & Keyifli:** *The Grand Budapest Hotel*\n\n'
          'Hangi türe daha yakınsın? Daha spesifik bir öneri de verebilirim!';
    }

    if (lower.contains('kitap öner') || lower.contains('kitap tavsiye')) {
      return 'Zihnini besleyecek harika kitap önerileri 📚:\n\n'
          '• 🧠 **Kişisel Gelişim & Alışkanlıklar:** *Atomik Alışkanlıklar* - James Clear\n'
          '• 🌍 **Felsefi & Psikolojik Roman:** *Simyacı* - Paulo Coelho veya *İnsanın Anlam Arayışı* - Viktor Frankl\n'
          '• 🚀 **Distopya & Gelecek:** *1984* - George Orwell veya *Cesur Yeni Dünya* - Aldous Huxley';
    }

    // 14. Health & Lifestyle
    if (lower.contains('su iç') || lower.contains('sağlık') || lower.contains('kilo') || lower.contains('diyet') || lower.contains('spor')) {
      return 'Sağlıklı bir yaşam için küçük ama etkili altın kurallar 💧🏃:\n\n'
          '• **Su Tüketimi:** Günde en az 2-2.5 litre su içmeyi ihmal etme. Yanında bir su bardağı bulundur!\n'
          '• **Hareket:** Masa başında uzun süre oturuyorsan her saat başı 2 dakika esneme hareketi yap.\n'
          '• **Dengeli Beslenme:** Paketli gıdalardan uzak durup taze sebze, meyve ve sağlıklı yağlara öncelik ver.\n'
          '• **Uyku:** Her gece 7-8 saat kaliteli uyku, gün içindeki odaklanmanı ve enerjini ikiye katlar! 🌙';
    }

    // 15. Math calculation
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

    // Default intelligent companion reply (contextual & conversational)
    return 'Harika bir soru$name! Bu konuda sana en iyi ve en doğru fikri verebilmem için biraz daha detay paylaşır mısın? Örneğin seçeneklerin neler ya da kafandaki plan tam olarak nedir? Birlikte çözelim! 💡✨';
  }
}
