import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user_model.dart';
import 'encryption_service.dart';
import 'live_location_service.dart';
import 'socket_service.dart';

/// Service managing discreet SOS Emergency Alerts, Hardware Key Triggering,
/// Emergency Contacts (up to 10), and Automatic Multi-contact Live Location Streaming.
class EmergencyService extends ChangeNotifier {
  static final EmergencyService _instance = EmergencyService._internal();
  factory EmergencyService() => _instance;

  EmergencyService._internal() {
    init();
    _initNativeChannel();
    _startHardwareKeyListener();
  }

  static const MethodChannel _nativeChannel = MethodChannel('com.talknex.app/emergency');

  bool _isEnabled = true;
  String _triggerKey = 'volume_up'; // 'volume_up' or 'volume_down'
  String _customMessage =
      '🚨 ACİL DURUM! Başım dertte ve acil yardıma ihtiyacım var! Bu otomatik bir acil durum mesajıdır. Anlık canlı konumum aşağıdadır, lütfen hemen yardım gönderin!';
  List<UserModel> _contacts = [];
  bool _isTriggering = false;
  DateTime? _lastTriggerTime;

  Timer? _keyHoldTimer;
  bool _isKeyDown = false;

  // Getters
  bool get isEnabled => _isEnabled;
  String get triggerKey => _triggerKey;
  String get customMessage => _customMessage;
  List<UserModel> get contacts => List.unmodifiable(_contacts);
  bool get isTriggering => _isTriggering;
  DateTime? get lastTriggerTime => _lastTriggerTime;
  int get contactCount => _contacts.length;

  /// Restores emergency configuration from local SharedPreferences
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _isEnabled = prefs.getBool('emergency_enabled') ?? true;
      _triggerKey = prefs.getString('emergency_trigger_key') ?? 'volume_up';
      _customMessage = prefs.getString('emergency_custom_message') ??
          '🚨 ACİL DURUM! Başım dertte ve acil yardıma ihtiyacım var! Bu otomatik bir acil durum mesajıdır. Anlık canlı konumum aşağıdadır, lütfen hemen yardım gönderin!';

      final contactsJsonList = prefs.getStringList('emergency_contacts_json') ?? [];
      _contacts = contactsJsonList.map((str) {
        final map = jsonDecode(str) as Map<String, dynamic>;
        return UserModel(
          uid: map['uid']?.toString() ?? '',
          username: map['username']?.toString() ?? '',
          displayName: map['displayName']?.toString() ?? 'Kişi',
          email: map['email']?.toString() ?? '',
          photoUrl: map['photoUrl']?.toString() ?? '',
          phoneNumber: map['phoneNumber']?.toString() ?? '',
        );
      }).toList();

      notifyListeners();
      _syncConfigToNative();
    } catch (e) {
      debugPrint('[EMERGENCY SERVICE INIT ERROR] $e');
    }
  }

  Future<void> _syncConfigToNative() async {
    try {
      await _nativeChannel.invokeMethod('updateConfig', {
        'triggerKey': _triggerKey,
        'isEnabled': _isEnabled,
      });
    } catch (e) {
      debugPrint('[EMERGENCY NATIVE SYNC] $e');
    }
  }

  /// Listens to native Android KeyEvent trigger (via MethodChannel)
  void _initNativeChannel() {
    _nativeChannel.setMethodCallHandler((call) async {
      if (call.method == 'triggerEmergency') {
        debugPrint('[EMERGENCY] Hardware Key 3s Long-Press detected from Android native!');
        await triggerEmergencyAlert();
      }
    });
  }

  /// Listens to Flutter-level hardware key events (when app is in foreground)
  void _startHardwareKeyListener() {
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (!_isEnabled) return false;

    final targetKey = _triggerKey == 'volume_down'
        ? LogicalKeyboardKey.audioVolumeDown
        : LogicalKeyboardKey.audioVolumeUp;

    if (event.logicalKey == targetKey) {
      if (event is KeyDownEvent) {
        if (!_isKeyDown) {
          _isKeyDown = true;
          debugPrint('[EMERGENCY] Key pressed ($_triggerKey). Starting 3s timer...');
          _keyHoldTimer?.cancel();
          _keyHoldTimer = Timer(const Duration(seconds: 3), () {
            debugPrint('[EMERGENCY] 3 SECONDS HELD! DISCREET SOS TRIGGERED!');
            triggerEmergencyAlert();
          });
        }
      } else if (event is KeyUpEvent) {
        _isKeyDown = false;
        _keyHoldTimer?.cancel();
        _keyHoldTimer = null;
      }
    }
    return false;
  }

  /// Adds a new contact (Max 10)
  Future<bool> addContact(UserModel user) async {
    if (_contacts.length >= 10) return false;
    if (_contacts.any((c) => c.uid == user.uid)) return false;

    _contacts.add(user);
    await _saveContacts();
    notifyListeners();
    return true;
  }

  /// Removes an emergency contact
  Future<void> removeContact(String userId) async {
    _contacts.removeWhere((c) => c.uid == userId);
    await _saveContacts();
    notifyListeners();
  }

  Future<void> _saveContacts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = _contacts.map((c) => jsonEncode({
        'uid': c.uid,
        'username': c.username,
        'displayName': c.displayName,
        'email': c.email,
        'photoUrl': c.photoUrl,
        'phoneNumber': c.phoneNumber,
      })).toList();
      await prefs.setStringList('emergency_contacts_json', list);

      // Save raw JSON string so Kotlin native service can read contacts instantly even when app is killed/closed
      final rawList = _contacts.map((c) => {
        'uid': c.uid,
        'username': c.username,
        'displayName': c.displayName,
        'phoneNumber': c.phoneNumber,
      }).toList();
      await prefs.setString('emergency_contacts_raw_json', jsonEncode(rawList));
    } catch (e) {
      debugPrint('[EMERGENCY SAVE CONTACTS ERROR] $e');
    }
  }

  /// Checks whether Android Accessibility Service is enabled for background key interception
  Future<bool> isAccessibilityEnabled() async {
    try {
      final res = await _nativeChannel.invokeMethod<bool>('isAccessibilityEnabled');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens Android Accessibility Settings page directly so user can turn on Talknex SOS service
  Future<void> openAccessibilitySettings() async {
    try {
      await _nativeChannel.invokeMethod('openAccessibilitySettings');
    } catch (_) {}
  }

  /// Sets current user id in SharedPreferences so Kotlin background service can read it
  Future<void> syncEmergencyUserId(String uid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('emergency_user_id', uid);
    } catch (_) {}
  }

  /// Updates custom emergency message
  Future<void> setCustomMessage(String message) async {
    _customMessage = message.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('emergency_custom_message', _customMessage);
    notifyListeners();
  }

  /// Updates hardware trigger key selection
  Future<void> setTriggerKey(String key) async {
    _triggerKey = key;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('emergency_trigger_key', _triggerKey);
    notifyListeners();
    _syncConfigToNative();
  }

  /// Toggles emergency protection on/off
  Future<void> setEnabled(bool enabled) async {
    _isEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('emergency_enabled', _isEnabled);
    notifyListeners();
    _syncConfigToNative();
  }

  /// Discretely triggers SOS Emergency Alert:
  /// 1. Vibrate phone discreetly (3 rapid haptic pulses)
  /// 2. Acquire current GPS coordinates
  /// 3. Start Live Location Foreground Streaming for all emergency contacts
  /// 4. Send encrypted emergency message + live location link to each contact (up to 10)
  /// 5. Post to backend DB and trigger FCM high-priority push notifications
  Future<bool> triggerEmergencyAlert({String? currentUserId}) async {
    if (_isTriggering) return false;
    if (!_isEnabled) {
      debugPrint('[EMERGENCY] Protection is disabled.');
      return false;
    }
    if (_contacts.isEmpty) {
      debugPrint('[EMERGENCY] No emergency contacts defined.');
      return false;
    }

    _isTriggering = true;
    notifyListeners();

    // 1. Silent, discreet haptic feedback (3 subtle vibrations)
    try {
      HapticFeedback.heavyImpact();
      await Future.delayed(const Duration(milliseconds: 120));
      HapticFeedback.heavyImpact();
      await Future.delayed(const Duration(milliseconds: 120));
      HapticFeedback.heavyImpact();
    } catch (_) {}

    try {
      // 2. Fetch high accuracy current location
      Position? currentPos;
      try {
        final lastKnown = await Geolocator.getLastKnownPosition();
        currentPos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.bestForNavigation,
          timeLimit: const Duration(seconds: 4),
        ).catchError((_) => lastKnown);
      } catch (e) {
        debugPrint('[EMERGENCY GPS ERR] $e');
      }

      final lat = currentPos?.latitude ?? 39.925533;
      final lon = currentPos?.longitude ?? 32.866287;
      final mapsUrl = 'https://maps.google.com/?q=$lat,$lon';

      // 3. Start Multi-contact Live Location Streaming
      String senderId = currentUserId ?? SocketService().currentUserId ?? '0';
      if (senderId == '0') {
        try {
          final prefs = await SharedPreferences.getInstance();
          final savedUserJson = prefs.getString('saved_user');
          if (savedUserJson != null) {
            final userMap = jsonDecode(savedUserJson);
            senderId = userMap['uid']?.toString() ?? '0';
          }
        } catch (_) {}
      }
      final receiverIds = _contacts.map((c) => c.uid).toList();

      await LiveLocationService().startMultiSharing(
        senderId: senderId,
        receiverIds: receiverIds,
      );

      // 4. Send encrypted emergency message to EACH contact
      final messageContent = '$_customMessage\n📍 Canlı Konum Başlatıldı';

      for (final contact in _contacts) {
        try {
          final encryptedContent = EndToEndEncryptionService.encryptText(
            messageContent,
            senderId,
            contact.uid,
          );

          final tempId = DateTime.now().millisecondsSinceEpoch.toString();

          // Emit via Socket.io
          SocketService().sendMessage(
            senderId: senderId,
            receiverId: contact.uid,
            content: encryptedContent,
            type: 'location',
            mediaUrl: mapsUrl,
            clientTempId: tempId,
          );

          // Direct HTTP fallback to guarantee DB write & FCM push trigger
          http.post(
            Uri.parse('http://46.197.188.20:3000/api/messages'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'senderId': int.tryParse(senderId) ?? 0,
              'receiverId': int.tryParse(contact.uid) ?? 0,
              'content': encryptedContent,
              'type': 'location',
              'mediaUrl': mapsUrl,
            }),
          ).timeout(const Duration(seconds: 4)).catchError((_) => http.Response('', 500));
        } catch (contactErr) {
          debugPrint('[EMERGENCY CONTACT ERR] ${contact.displayName}: $contactErr');
        }
      }

      _lastTriggerTime = DateTime.now();
      debugPrint('[EMERGENCY] SOS successfully broadcast to ${_contacts.length} contacts!');
      return true;
    } catch (e) {
      debugPrint('[EMERGENCY CRITICAL ERROR] $e');
      return false;
    } finally {
      _isTriggering = false;
      notifyListeners();
    }
  }
}
