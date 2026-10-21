import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TranslationService {
  static final ValueNotifier<int> notifier = ValueNotifier<int>(0);

  // In-memory cache for translations: "text_targetLang" -> translatedText
  static final Map<String, String> _textCache = {};

  // Per-message translated text: "messageId_targetLang" -> translatedText
  static final Map<String, String> _messageTranslations = {};

  // Per-message override: messageId -> true if user tapped "Orijinali Göster"
  static final Set<String> _showOriginalForMessage = {};

  // Per-message manual translate toggle: messageId -> true if user manually clicked "Çevir"
  static final Set<String> _manuallyTranslatedMessages = {};

  // In-flight translation requests to avoid duplicate network calls
  static final Map<String, Future<String?>> _inFlightTranslations = {};

  // Auto-translate enabled per chat: chatId -> bool
  static final Map<String, bool> _chatAutoTranslate = {};

  // Target language per chat: chatId -> langCode (e.g., 'tr')
  static final Map<String, String> _chatTargetLanguage = {};

  // Global default target language across chats
  static String _globalTargetLanguage = 'tr';

  static bool _isInitialized = false;

  static const Map<String, String> supportedLanguages = {
    'tr': 'Türkçe',
    'en': 'İngilizce',
    'de': 'Almanca',
    'fr': 'Fransızca',
    'es': 'İspanyolca',
    'ru': 'Rusça',
    'ar': 'Arapça',
    'it': 'İtalyanca',
    'pt': 'Portekizce',
    'az': 'Azerbaycan Türkçesi',
    'nl': 'Felemenkçe',
    'zh-CN': 'Çince',
    'ja': 'Japonca',
    'ko': 'Korece',
    'fa': 'Farsça',
    'uk': 'Ukraynaca',
    'hi': 'Hintçe',
    'el': 'Yunanca',
  };

  static String getLanguageName(String code) {
    return supportedLanguages[code] ?? code;
  }

  static Future<void> init() async {
    if (_isInitialized) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _globalTargetLanguage = prefs.getString('talknex_global_target_lang') ?? 'tr';

      final keys = prefs.getKeys();
      for (final key in keys) {
        if (key.startsWith('autotranslate_enabled_')) {
          final chatId = key.substring('autotranslate_enabled_'.length);
          _chatAutoTranslate[chatId] = prefs.getBool(key) ?? false;
        } else if (key.startsWith('autotranslate_target_')) {
          final chatId = key.substring('autotranslate_target_'.length);
          _chatTargetLanguage[chatId] = prefs.getString(key) ?? _globalTargetLanguage;
        }
      }
      _isInitialized = true;
    } catch (e) {
      debugPrint('[TRANSLATION] Init error: $e');
    }
  }

  static bool isChatAutoTranslateEnabled(String chatId) {
    return _chatAutoTranslate[chatId] ?? false;
  }

  static String getChatTargetLanguage(String chatId) {
    return _chatTargetLanguage[chatId] ?? _globalTargetLanguage;
  }

  static Future<void> setChatAutoTranslate(String chatId, bool enabled, {String? targetLang}) async {
    _chatAutoTranslate[chatId] = enabled;
    if (targetLang != null && targetLang.isNotEmpty) {
      _chatTargetLanguage[chatId] = targetLang;
      _globalTargetLanguage = targetLang;
    }
    notifier.value++;

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('autotranslate_enabled_$chatId', enabled);
      if (targetLang != null && targetLang.isNotEmpty) {
        await prefs.setString('autotranslate_target_$chatId', targetLang);
        await prefs.setString('talknex_global_target_lang', targetLang);
      }
    } catch (e) {
      debugPrint('[TRANSLATION] Persist error: $e');
    }
  }

  static Future<void> disableAutoTranslate(String chatId) async {
    await setChatAutoTranslate(chatId, false);
  }

  /// Check if a message should currently be displayed in translated form
  static bool shouldShowTranslated({
    required String messageId,
    required String chatId,
  }) {
    final isAuto = isChatAutoTranslateEnabled(chatId);
    final isManual = _manuallyTranslatedMessages.contains(messageId);
    final forcedOriginal = _showOriginalForMessage.contains(messageId);

    if (forcedOriginal) return false;
    if (isManual) return true;
    if (isAuto) return true;
    return false;
  }

  /// Check if translation has already been retrieved and cached for this message and language
  static bool hasTranslationForMessage(String messageId, String targetLang) {
    return _messageTranslations.containsKey('${messageId}_$targetLang');
  }

  /// Get the translated string for a message in a specific target language
  static String? getMessageTranslation(String messageId, String targetLang) {
    return _messageTranslations['${messageId}_$targetLang'];
  }

  /// Toggle between showing original and showing translation for a specific message
  static void toggleOriginalMessage(String messageId) {
    if (_showOriginalForMessage.contains(messageId)) {
      _showOriginalForMessage.remove(messageId);
    } else {
      _showOriginalForMessage.add(messageId);
    }
    notifier.value++;
  }

  /// Manual translate option from message long-press / options sheet
  static Future<void> toggleManualTranslate({
    required String messageId,
    required String text,
    required String chatId,
    String? targetLang,
  }) async {
    final effectiveLang = targetLang ?? getChatTargetLanguage(chatId);

    // If currently showing translated, toggle to original
    if (shouldShowTranslated(messageId: messageId, chatId: chatId)) {
      _showOriginalForMessage.add(messageId);
      _manuallyTranslatedMessages.remove(messageId);
      notifier.value++;
      return;
    }

    // Otherwise, user wants to see translation
    _showOriginalForMessage.remove(messageId);
    _manuallyTranslatedMessages.add(messageId);
    notifier.value++;

    // Fetch translation if not already in cache for effectiveLang
    await translateForMessage(messageId: messageId, text: text, targetLang: effectiveLang);
  }

  /// Fetch and store translation for a specific message and target language
  static Future<String?> translateForMessage({
    required String messageId,
    required String text,
    required String targetLang,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;

    final msgLangKey = '${messageId}_$targetLang';
    final textCacheKey = '${trimmed}_$targetLang';

    if (_textCache.containsKey(textCacheKey)) {
      final translated = _textCache[textCacheKey]!;
      _messageTranslations[msgLangKey] = translated;
      notifier.value++;
      return translated;
    }

    final translated = await translateText(trimmed, targetLang: targetLang);
    if (translated != null) {
      _messageTranslations[msgLangKey] = translated;
      notifier.value++;
    }
    return translated;
  }

  /// Core Google Translate API call with caching and request coalescing
  static Future<String?> translateText(String text, {String targetLang = 'tr'}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return text;
    final cacheKey = '${trimmed}_$targetLang';
    if (_textCache.containsKey(cacheKey)) {
      return _textCache[cacheKey];
    }

    if (_inFlightTranslations.containsKey(cacheKey)) {
      return await _inFlightTranslations[cacheKey];
    }

    final future = _fetchTranslation(trimmed, targetLang);
    _inFlightTranslations[cacheKey] = future;

    try {
      final result = await future;
      if (result != null) {
        _textCache[cacheKey] = result;
      }
      return result;
    } finally {
      _inFlightTranslations.remove(cacheKey);
    }
  }

  static Future<String?> _fetchTranslation(String text, String targetLang) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 8);
    try {
      final uri = Uri.parse(
        'https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=$targetLang&dt=t&q=${Uri.encodeComponent(text)}',
      );
      final request = await client.getUrl(uri);
      request.headers.set('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)');
      final response = await request.close().timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        final responseBody = await response.transform(utf8.decoder).join();
        final decoded = jsonDecode(responseBody);
        if (decoded is List && decoded.isNotEmpty && decoded[0] is List) {
          final sentences = decoded[0] as List;
          final buffer = StringBuffer();
          for (final item in sentences) {
            if (item is List && item.isNotEmpty && item[0] != null) {
              buffer.write(item[0].toString());
            }
          }
          final translated = buffer.toString().trim();
          if (translated.isNotEmpty) {
            return translated;
          }
        }
      }
    } catch (e) {
      debugPrint('[TRANSLATE] Error translating "$text" to $targetLang: $e');
    } finally {
      client.close();
    }
    return null;
  }
}
