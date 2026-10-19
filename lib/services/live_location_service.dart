import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'socket_service.dart';

/// Singleton service that manages persistent foreground background streaming
/// of the user's live GPS coordinates, independent of any UI widget lifecycle.
class LiveLocationService {
  static final LiveLocationService _instance = LiveLocationService._internal();
  factory LiveLocationService() => _instance;
  LiveLocationService._internal();

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

  // Broadcast stream controller to notify active UI widgets (LiveLocationScreen, ChatScreen, etc.)
  final StreamController<Position> _positionStreamController = StreamController<Position>.broadcast();
  final StreamController<bool> _sharingStatusController = StreamController<bool>.broadcast();

  // Getters
  bool get isSharing => _isSharing;
  String? get activeSenderId => _activeSenderId;
  String? get activeReceiverId => _activeReceiverId;
  String? get activeMessageId => _activeMessageId;
  LatLng? get lastPosition => _lastPosition;
  double get lastHeading => _lastHeading;
  double get lastSpeed => _lastSpeed;
  DateTime? get lastUpdateTime => _lastUpdateTime;

  Stream<Position> get onPositionChanged => _positionStreamController.stream;
  Stream<bool> get onSharingStatusChanged => _sharingStatusController.stream;

  bool isSharingWith(String peerId) {
    return _isSharing && _activeReceiverId == peerId;
  }

  /// Starts live location streaming with a persistent Android Foreground Service.
  /// Even if the user leaves the chat or minimizes the app, coordinates will
  /// continue to be sent until [stopSharing] is called.
  Future<bool> startSharing({
    required String senderId,
    required String receiverId,
    String? messageId,
  }) async {
    // If already sharing with this exact receiver, just update messageId if needed
    if (_isSharing && _activeReceiverId == receiverId && _positionSubscription != null) {
      if (messageId != null) {
        _activeMessageId = messageId;
      }
      return true;
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

    // Cancel existing stream before starting fresh
    await stopSharing(notifyServer: false);

    _activeSenderId = senderId;
    _activeReceiverId = receiverId;
    _activeMessageId = messageId;
    _isSharing = true;
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

        _socketService.emitLiveLocationUpdate(
          senderId: _activeSenderId!,
          receiverId: _activeReceiverId!,
          latitude: initialPos.latitude,
          longitude: initialPos.longitude,
          heading: initialPos.heading,
          speed: initialPos.speed,
          messageId: _activeMessageId,
        );

        if (!_positionStreamController.isClosed) {
          _positionStreamController.add(initialPos);
        }
      }
    } catch (e) {
      debugPrint('[LIVE SERVICE] Initial location error: $e');
    }

    // Android Foreground Service configuration to guarantee background execution
    LocationSettings locationSettings;
    if (defaultTargetPlatform == TargetPlatform.android) {
      locationSettings = AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 2,
        intervalDuration: const Duration(seconds: 2),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: "Canlı Konum Paylaşılıyor",
          notificationText: "SafeChat canlı konumunuzu paylaşıyor...",
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

          _socketService.emitLiveLocationUpdate(
            senderId: _activeSenderId!,
            receiverId: _activeReceiverId!,
            latitude: pos.latitude,
            longitude: pos.longitude,
            heading: pos.heading,
            speed: pos.speed,
            messageId: _activeMessageId,
          );

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
      debugPrint('[LIVE SERVICE START EXCEPTION] $e');
      _isSharing = false;
      _sharingStatusController.add(false);
      return false;
    }
  }

  /// Stops live location sharing, closes background service and notification,
  /// and sends a stop signal to peer via socket.
  Future<void> stopSharing({bool notifyServer = true, String? messageId}) async {
    if (!_isSharing && _positionSubscription == null) return;

    final sId = _activeSenderId;
    final rId = _activeReceiverId;
    final mId = messageId ?? _activeMessageId;

    try {
      await _positionSubscription?.cancel();
    } catch (e) {
      debugPrint('[LIVE SERVICE CANCEL ERROR] $e');
    }
    _positionSubscription = null;
    _isSharing = false;
    _sharingStatusController.add(false);

    if (notifyServer && sId != null && rId != null) {
      _socketService.emitStopLiveLocation(
        senderId: sId,
        receiverId: rId,
        messageId: mId,
      );
    }

    _activeSenderId = null;
    _activeReceiverId = null;
    _activeMessageId = null;
  }
}
