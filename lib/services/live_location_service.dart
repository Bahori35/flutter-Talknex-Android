import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'socket_service.dart';

/// Singleton service that manages persistent foreground background streaming
/// of the user's live GPS coordinates, independent of any UI widget lifecycle.
class LiveLocationService {
  static final LiveLocationService _instance = LiveLocationService._internal();
  factory LiveLocationService() => _instance;

  LiveLocationService._internal() {
    init();
    // Listen for peer stopped events from Socket to automatically mark their messages as stopped
    _socketService.liveLocationStoppedStream.listen((data) {
      final mId = data['messageId']?.toString();
      if (mId != null && mId.isNotEmpty) {
        markMessageStopped(mId);
      }
      final sId = data['senderId']?.toString();
      if (sId != null && sId.isNotEmpty) {
        _socketService.lastLiveLocations.remove(sId);
      }
    });
  }

  final SocketService _socketService = SocketService();
  StreamSubscription<Position>? _positionSubscription;

  bool _isSharing = false;
  String? _activeSenderId;
  String? _activeReceiverId;
  String? _activeMessageId;
  LatLng? _lastPosition;
  double _lastHeading = 0.0;
  double _lastSpeed = 0.0;
  DateTime? _lastUpdateTime;

  // Set of message IDs that have been ended/stopped (persisted in SharedPreferences)
  final Set<String> _stoppedMessageIds = {};
  // Multiple active receivers (e.g. for Emergency SOS broadcast to up to 10 contacts)
  final Set<String> _activeReceiverIds = {};

  // Broadcast stream controller to notify active UI widgets (LiveLocationScreen, ChatScreen, etc.)
  final StreamController<Position> _positionStreamController = StreamController<Position>.broadcast();
  final StreamController<bool> _sharingStatusController = StreamController<bool>.broadcast();

  // Getters
  bool get isSharing => _isSharing;
  String? get activeSenderId => _activeSenderId;
  String? get activeReceiverId => _activeReceiverId;
  Set<String> get activeReceiverIds => {..._activeReceiverIds, if (_activeReceiverId != null) _activeReceiverId!};
  String? get activeMessageId => _activeMessageId;
  LatLng? get lastPosition => _lastPosition;
  double get lastHeading => _lastHeading;
  double get lastSpeed => _lastSpeed;
  DateTime? get lastUpdateTime => _lastUpdateTime;

  Stream<Position> get onPositionChanged => _positionStreamController.stream;
  Stream<bool> get onSharingStatusChanged => _sharingStatusController.stream;

  bool isSharingWith(String peerId) {
    return _isSharing && (_activeReceiverId == peerId || _activeReceiverIds.contains(peerId));
  }

  /// Starts live location streaming for multiple receivers simultaneously (e.g. Emergency SOS)
  Future<bool> startMultiSharing({
    required String senderId,
    required List<String> receiverIds,
    String? messageId,
  }) async {
    _activeReceiverIds.clear();
    _activeReceiverIds.addAll(receiverIds);
    final firstReceiver = receiverIds.isNotEmpty ? receiverIds.first : '';
    return startSharing(
      senderId: senderId,
      receiverId: firstReceiver,
      messageId: messageId,
    );
  }

  /// Checks if a specific message ID is the currently active live location
  bool isMessageLive(String messageId) {
    if (!_isSharing) return false;
    if (messageId.isNotEmpty && _stoppedMessageIds.contains(messageId)) return false;
    if (_activeMessageId == null || _activeMessageId!.isEmpty) return true;
    if (messageId.isEmpty) return true;
    return _activeMessageId == messageId;
  }

  /// Updates active message ID when server confirms temporary client ID
  void updateActiveMessageId(String oldId, String newId) {
    if (_activeMessageId == oldId) {
      _activeMessageId = newId;
      _stoppedMessageIds.remove(newId);
      _persistState();
      _sharingStatusController.add(_isSharing);
    }
  }

  /// Sets the active message ID
  void setActiveMessageId(String messageId) {
    if (messageId.isNotEmpty && _activeMessageId != messageId) {
      _activeMessageId = messageId;
      _stoppedMessageIds.remove(messageId);
      _persistState();
      _sharingStatusController.add(_isSharing);
    }
  }

  /// Checks if a specific message ID has been stopped / ended
  bool isMessageStopped(String messageId) {
    if (messageId.isEmpty) return false;
    return _stoppedMessageIds.contains(messageId);
  }

  /// Marks a specific message ID as stopped and persists it
  void markMessageStopped(String messageId) {
    if (messageId.isNotEmpty) {
      _stoppedMessageIds.add(messageId);
      _persistStoppedMessageIds();
      _sharingStatusController.add(_isSharing);
    }
  }

  /// Restores session state from SharedPreferences (called on app startup)
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Load all stopped message IDs
      final stoppedList = prefs.getStringList('live_location_stopped_message_ids') ?? [];
      _stoppedMessageIds.addAll(stoppedList);

      // Check if user was actively sharing before app was closed / killed
      final wasSharing = prefs.getBool('live_location_is_sharing') ?? false;
      final savedSender = prefs.getString('live_location_sender_id');
      final savedReceiver = prefs.getString('live_location_receiver_id');
      final savedMsgId = prefs.getString('live_location_active_message_id');

      if (wasSharing && savedSender != null && savedReceiver != null) {
        _activeSenderId = savedSender;
        _activeReceiverId = savedReceiver;
        _activeMessageId = savedMsgId;
        _isSharing = true;

        // Resume foreground position stream so ongoing notification & GPS stay alive
        _startGpsStream();
        _sharingStatusController.add(true);
      }
    } catch (e) {
      debugPrint('[LIVE SERVICE INIT ERROR] $e');
    }
  }

  /// Starts live location streaming with a persistent Android Foreground Service.
  /// Even if the user leaves the chat or minimizes the app, coordinates will
  /// continue to be sent until [stopSharing] is called.
  Future<bool> startSharing({
    required String senderId,
    required String receiverId,
    String? messageId,
  }) async {
    // If previously sharing another message, mark that previous message as ended/stopped!
    if (_activeMessageId != null && _activeMessageId != messageId) {
      _stoppedMessageIds.add(_activeMessageId!);
    }

    // Check location service
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      debugPrint('[LIVE SERVICE] Location services are disabled.');
      return false;
    }

    // Check & request permission
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        debugPrint('[LIVE SERVICE] Location permissions denied.');
        return false;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      debugPrint('[LIVE SERVICE] Location permissions permanently denied.');
      return false;
    }

    // Stop existing GPS stream before starting fresh
    await _stopGpsStream();

    _activeSenderId = senderId;
    _activeReceiverId = receiverId;
    _activeMessageId = messageId;
    _isSharing = true;

    // Ensure this new message is not in stopped list
    if (messageId != null && messageId.isNotEmpty) {
      _stoppedMessageIds.remove(messageId);
    }

    // Persist active state to SharedPreferences
    await _persistState();
    _sharingStatusController.add(true);

    // Fetch immediate current location
    try {
      final initialPos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.bestForNavigation,
        timeLimit: const Duration(seconds: 4),
      ).catchError((_) => null as dynamic);

      if (initialPos != null && _isSharing) {
        _lastPosition = LatLng(initialPos.latitude, initialPos.longitude);
        _lastHeading = initialPos.heading;
        _lastSpeed = initialPos.speed;
        _lastUpdateTime = DateTime.now();

        _emitLocationToAllReceivers(_lastPosition!, _lastHeading, _lastSpeed);

        if (!_positionStreamController.isClosed) {
          _positionStreamController.add(initialPos);
        }
      }
    } catch (e) {
      debugPrint('[LIVE SERVICE] Initial location error: $e');
    }

    return _startGpsStream();
  }

  void _emitLocationToAllReceivers(LatLng pos, double heading, double speed) {
    if (_activeSenderId == null) return;
    final allReceivers = <String>{};
    if (_activeReceiverId != null && _activeReceiverId!.isNotEmpty) {
      allReceivers.add(_activeReceiverId!);
    }
    allReceivers.addAll(_activeReceiverIds);

    for (final rId in allReceivers) {
      _socketService.emitLiveLocationUpdate(
        senderId: _activeSenderId!,
        receiverId: rId,
        latitude: pos.latitude,
        longitude: pos.longitude,
        heading: heading,
        speed: speed,
        messageId: _activeMessageId,
      );
    }
  }

  Future<bool> _startGpsStream() async {
    // Android Foreground Service configuration to guarantee background execution
    LocationSettings locationSettings;
    if (defaultTargetPlatform == TargetPlatform.android) {
      locationSettings = AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 2,
        intervalDuration: const Duration(seconds: 2),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: "Canlı Konum Paylaşılıyor",
          notificationText: "Talknex canlı konumunuzu paylaşıyor...",
          notificationChannelName: "Talknex Canlı Konum",
          notificationIcon: AndroidResource(
            name: 'launcher_icon',
            defType: 'mipmap',
          ),
          enableWakeLock: true,
          setOngoing: true,
        ),
      );
    } else {
      locationSettings = const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 2,
      );
    }

    try {
      _positionSubscription = Geolocator.getPositionStream(
        locationSettings: locationSettings,
      ).listen(
        (Position pos) {
          if (!_isSharing) return;

          _lastPosition = LatLng(pos.latitude, pos.longitude);
          _lastHeading = pos.heading;
          _lastSpeed = pos.speed;
          _lastUpdateTime = DateTime.now();

          _emitLocationToAllReceivers(_lastPosition!, _lastHeading, _lastSpeed);

          if (!_positionStreamController.isClosed) {
            _positionStreamController.add(pos);
          }
        },
        onError: (error) {
          debugPrint('[LIVE SERVICE STREAM ERROR] $error');
        },
      );

      return true;
    } catch (e) {
      debugPrint('[LIVE SERVICE START EXCEPTION, ATTEMPTING FALLBACK] $e');
      try {
        _positionSubscription = Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 2,
          ),
        ).listen(
          (Position pos) {
            if (!_isSharing) return;

            _lastPosition = LatLng(pos.latitude, pos.longitude);
            _lastHeading = pos.heading;
            _lastSpeed = pos.speed;
            _lastUpdateTime = DateTime.now();

            _emitLocationToAllReceivers(_lastPosition!, _lastHeading, _lastSpeed);

            if (!_positionStreamController.isClosed) {
              _positionStreamController.add(pos);
            }
          },
          onError: (error) {
            debugPrint('[LIVE SERVICE FALLBACK STREAM ERROR] $error');
          },
        );
        return true;
      } catch (fErr) {
        debugPrint('[LIVE SERVICE CRITICAL ERROR] $fErr');
        _isSharing = false;
        _sharingStatusController.add(false);
        return false;
      }
    }
  }

  Future<void> _stopGpsStream() async {
    try {
      await _positionSubscription?.cancel();
    } catch (e) {
      debugPrint('[LIVE SERVICE CANCEL ERROR] $e');
    }
    _positionSubscription = null;
  }

  /// Stops live location sharing, closes background service and notification,
  /// permanently marks this message as stopped, and sends a stop signal to peer via socket.
  Future<void> stopSharing({bool notifyServer = true, String? messageId}) async {
    final sId = _activeSenderId;
    final rId = _activeReceiverId;
    final mId = messageId ?? _activeMessageId;

    if (mId != null && mId.isNotEmpty) {
      _stoppedMessageIds.add(mId);
    }
    if (_activeMessageId != null && _activeMessageId!.isNotEmpty) {
      _stoppedMessageIds.add(_activeMessageId!);
    }

    await _stopGpsStream();
    _isSharing = false;

    await _persistState();
    _sharingStatusController.add(false);

    final allReceivers = <String>{};
    if (rId != null && rId.isNotEmpty) allReceivers.add(rId);
    allReceivers.addAll(_activeReceiverIds);

    if (notifyServer && sId != null) {
      for (final rcv in allReceivers) {
        _socketService.emitStopLiveLocation(
          senderId: sId,
          receiverId: rcv,
          messageId: mId,
        );
      }
    }
    _activeReceiverIds.clear();

    _activeSenderId = null;
    _activeReceiverId = null;
    _activeMessageId = null;
  }

  Future<void> _persistState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('live_location_is_sharing', _isSharing);
      if (_isSharing) {
        if (_activeSenderId != null) await prefs.setString('live_location_sender_id', _activeSenderId!);
        if (_activeReceiverId != null) await prefs.setString('live_location_receiver_id', _activeReceiverId!);
        if (_activeMessageId != null) await prefs.setString('live_location_active_message_id', _activeMessageId!);
      } else {
        await prefs.remove('live_location_sender_id');
        await prefs.remove('live_location_receiver_id');
        await prefs.remove('live_location_active_message_id');
      }
      await prefs.setStringList('live_location_stopped_message_ids', _stoppedMessageIds.toList());
    } catch (e) {
      debugPrint('[LIVE SERVICE PERSIST ERROR] $e');
    }
  }

  Future<void> _persistStoppedMessageIds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('live_location_stopped_message_ids', _stoppedMessageIds.toList());
    } catch (e) {
      debugPrint('[LIVE SERVICE PERSIST STOPPED ERROR] $e');
    }
  }
}
