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

        final eventTimeStr = reminder.formattedEventTime;
        final leadStr = reminder.leadMinutes > 0 ? '${reminder.leadMinutes} dakika önce' : 'tam vaktinde';
        final alertTimeStr = reminder.formattedReminderTime;

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

    // D. Check if user is asking for weather
    if (_isWeatherQuery(textLower)) {
      final weatherResponse = await _handleWeatherQuery(text);
      if (weatherResponse != null) {
        return weatherResponse;
      }
    }

    // E. Conversational Engine (Small Talk & Knowledge Base)
    final reply = _generateConversationalResponse(text);
    return AiMessageModel(
      id: const Uuid().v4(),
      sender: 'ai',
      text: reply,
      timestamp: DateTime.now(),
    );
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
    final triggers = [
      'hatırlat',
      'hatirlat',
      'haber ver',
      'alarm kur',
      'uyar',
      'planım var',
      'planim var',
      'planlama',
      'randevum var',
      'randevu',
      'yapıcam',
      'yapacağım',
      'toplantım var',
      'toplantı',
      'toplanti',
      'doğum günü',
      'dogum gunu',
      'seyahat',
      'uçuş',
      'ucus',
      'buluşma',
      'bulusma',
      'sınav',
      'sinav',
      'unutma',
      'hatırlatıcı kur',
      'hatirlatici kur',
      'hatırlatıcı',
      'hatirlatici',
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

    // If no specific time identified, default to default meeting/plan time (10:00 or 14:00)
    if (!timeIdentified) {
      if (textLower.contains('doğum günü') || textLower.contains('dogum gunu')) {
        targetHour = 10;
        targetMinute = 0;
      } else {
        targetHour = now.hour < 12 ? 14 : 19;
      }
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
          '🌤️ **Hava Durumu:** "Bugün İstanbul\'da hava durumu nasıl?" veya "Ankara hava nasıl?" dersen anlık sıcaklık, hissedilen, nem ve rüzgar bilgilerini söylerim.\n'
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
