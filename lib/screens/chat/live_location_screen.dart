import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../constants/app_colors.dart';
import '../../models/user_model.dart';
import '../../services/socket_service.dart';

class LiveLocationScreen extends StatefulWidget {
  final LatLng initialPosition;
  final UserModel peerUser;
  final UserModel currentUser;
  final bool isMyLiveLocation;
  final String? messageId;
  final VoidCallback? onStopSharing;

  const LiveLocationScreen({
    super.key,
    required this.initialPosition,
    required this.peerUser,
    required this.currentUser,
    required this.isMyLiveLocation,
    this.messageId,
    this.onStopSharing,
  });

  @override
  State<LiveLocationScreen> createState() => _LiveLocationScreenState();
}

class _LiveLocationScreenState extends State<LiveLocationScreen> with TickerProviderStateMixin {
  final MapController _mapController = MapController();
  final SocketService _socketService = SocketService();
  
  late LatLng _peerLocation;
  LatLng? _myLocation;
  double _heading = 0.0;
  double _speed = 0.0;
  bool _isLiveActive = true;
  bool _isFollowing = true;
  double _currentZoom = 16.5;
  DateTime _lastUpdate = DateTime.now();
  StreamSubscription<Position>? _myGpsSubscription;
  AnimationController? _pulseController;
  Timer? _autoRecenterTimer;
  Timer? _countdownTimer;
  int _autoRecenterSecondsLeft = 4;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    // 1. Check if we already have newer cached live coordinates in SocketService
    final trackedUid = widget.isMyLiveLocation ? widget.currentUser.uid : widget.peerUser.uid;
    final cached = _socketService.lastLiveLocations[trackedUid];
    if (cached != null) {
      final lat = (cached['latitude'] as num?)?.toDouble();
      final lon = (cached['longitude'] as num?)?.toDouble();
      if (lat != null && lon != null) {
        _peerLocation = LatLng(lat, lon);
        _heading = (cached['heading'] as num?)?.toDouble() ?? 0.0;
        _speed = (cached['speed'] as num?)?.toDouble() ?? 0.0;
      } else {
        _peerLocation = widget.initialPosition;
      }
    } else {
      _peerLocation = widget.initialPosition;
    }

    // 2. Track own GPS location (and if sender, actively update avatar position on map)
    _trackMyGps();

    // 3. Listen to real-time live location updates from Socket (for recipient)
    _socketService.onLiveLocationUpdate = (data) {
      final senderId = data['senderId']?.toString();
      if (senderId == widget.peerUser.uid) {
        final lat = (data['latitude'] as num?)?.toDouble();
        final lon = (data['longitude'] as num?)?.toDouble();
        final heading = (data['heading'] as num?)?.toDouble() ?? 0.0;
        final speed = (data['speed'] as num?)?.toDouble() ?? 0.0;

        if (lat != null && lon != null && mounted) {
          final newPos = LatLng(lat, lon);
          setState(() {
            _peerLocation = newPos;
            _heading = heading;
            _speed = speed;
            _lastUpdate = DateTime.now();
            _isLiveActive = true;
          });
          // Auto-center recipient camera on moving sender
          if (!widget.isMyLiveLocation && _isFollowing) {
            _mapController.move(newPos, _currentZoom);
          }
        }
      }
    };

    _socketService.onLiveLocationStopped = (data) {
      final senderId = data['senderId']?.toString();
      if (senderId == widget.peerUser.uid && mounted) {
        setState(() {
          _isLiveActive = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${widget.peerUser.displayName} canlı konum paylaşımını durdurdu.'),
            backgroundColor: AppColors.surfaceLight,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    };
  }

  void _trackMyGps() async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 5),
      ).catchError((_) => null as dynamic);

      if (pos != null && mounted) {
        final newPos = LatLng(pos.latitude, pos.longitude);
        setState(() {
          _myLocation = newPos;
          if (widget.isMyLiveLocation) {
            _peerLocation = newPos;
            _heading = pos.heading;
            _speed = pos.speed;
            _lastUpdate = DateTime.now();
          }
        });
        if (widget.isMyLiveLocation && _isFollowing) {
          _mapController.move(newPos, _currentZoom);
        }
      }

      _myGpsSubscription = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 2,
        ),
      ).listen((Position position) {
        if (mounted) {
          final newPos = LatLng(position.latitude, position.longitude);
          setState(() {
            _myLocation = newPos;
            if (widget.isMyLiveLocation) {
              _peerLocation = newPos;
              _heading = position.heading;
              _speed = position.speed;
              _lastUpdate = DateTime.now();
            }
          });

          if (widget.isMyLiveLocation) {
            // Auto-center sender camera on own moving vehicle / position
            if (_isFollowing) {
              _mapController.move(newPos, _currentZoom);
            }
            if (_isLiveActive) {
              _socketService.emitLiveLocationUpdate(
                senderId: widget.currentUser.uid,
                receiverId: widget.peerUser.uid,
                latitude: position.latitude,
                longitude: position.longitude,
                heading: position.heading,
                speed: position.speed,
                messageId: widget.messageId,
              );
            }
          }
        }
      });
    } catch (e) {
      debugPrint('[LIVE GPS ERROR] $e');
    }
  }

  void _onPositionChanged(MapCamera camera, bool hasGesture) {
    _currentZoom = camera.zoom;
    if (hasGesture) {
      if (_isFollowing) {
        setState(() {
          _isFollowing = false;
          _autoRecenterSecondsLeft = 4;
        });
      }
      _startAutoRecenterTimer();
    }
  }

  void _startAutoRecenterTimer() {
    _autoRecenterTimer?.cancel();
    _countdownTimer?.cancel();

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _isFollowing) {
        timer.cancel();
        return;
      }
      if (_autoRecenterSecondsLeft > 1) {
        setState(() {
          _autoRecenterSecondsLeft--;
        });
      } else {
        timer.cancel();
      }
    });

    _autoRecenterTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && !_isFollowing) {
        _resumeAutoFollow();
      }
    });
  }

  void _resumeAutoFollow() {
    _autoRecenterTimer?.cancel();
    _countdownTimer?.cancel();
    _autoRecenterTimer = null;
    _countdownTimer = null;
    if (mounted) {
      setState(() {
        _isFollowing = true;
      });
      _mapController.move(_peerLocation, _currentZoom);
    }
  }

  void _zoomIn() {
    _currentZoom = (_currentZoom + 1).clamp(4.0, 19.0);
    _mapController.move(_peerLocation, _currentZoom);
  }

  void _zoomOut() {
    _currentZoom = (_currentZoom - 1).clamp(4.0, 19.0);
    _mapController.move(_peerLocation, _currentZoom);
  }

  void _stopSharingAction() {
    _autoRecenterTimer?.cancel();
    _countdownTimer?.cancel();
    _myGpsSubscription?.cancel();
    _myGpsSubscription = null;
    setState(() {
      _isLiveActive = false;
    });
    _socketService.emitStopLiveLocation(
      senderId: widget.currentUser.uid,
      receiverId: widget.peerUser.uid,
      messageId: widget.messageId,
    );
    widget.onStopSharing?.call();
    Navigator.pop(context);
  }

  @override
  void dispose() {
    _autoRecenterTimer?.cancel();
    _countdownTimer?.cancel();
    _pulseController?.dispose();
    _myGpsSubscription?.cancel();
    if (_socketService.onLiveLocationUpdate != null) {
      _socketService.onLiveLocationUpdate = null;
    }
    if (_socketService.onLiveLocationStopped != null) {
      _socketService.onLiveLocationStopped = null;
    }
    super.dispose();
  }

  void _reCenterToMe() {
    if (_myLocation != null) {
      setState(() {
        _isFollowing = false;
      });
      _mapController.move(_myLocation!, _currentZoom);
      _startAutoRecenterTimer();
    }
  }

  void _openInGoogleMaps() async {
    final url = Uri.parse('https://maps.google.com/?q=${_peerLocation.latitude},${_peerLocation.longitude}');
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }

  String _buildStatusSubtitle() {
    if (!_isLiveActive) {
      return 'Paylaşım sona erdi';
    }
    if (widget.isMyLiveLocation) {
      if (_speed > 0.8) {
        final kmh = (_speed * 3.6).toStringAsFixed(0);
        return 'Hareket halinde • $kmh km/s';
      }
      return 'Canlı yayında';
    } else {
      String distText = '';
      if (_myLocation != null) {
        final dMeters = Geolocator.distanceBetween(
          _myLocation!.latitude,
          _myLocation!.longitude,
          _peerLocation.latitude,
          _peerLocation.longitude,
        );
        distText = dMeters >= 1000
            ? ' • ${(dMeters / 1000).toStringAsFixed(1)} km uzakta'
            : ' • ${dMeters.round()} m uzakta';
      }
      if (_speed > 0.8) {
        final kmh = (_speed * 3.6).toStringAsFixed(0);
        return '$kmh km/s$distText';
      }
      return 'Canlı yayında$distText';
    }
  }

  @override
  Widget build(BuildContext context) {
    final activeUser = widget.isMyLiveLocation ? widget.currentUser : widget.peerUser;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 1,
        title: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: AppColors.surfaceLight,
              backgroundImage: CachedNetworkImageProvider(activeUser.photoUrl),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.isMyLiveLocation ? 'Canlı Konumunuz' : '${activeUser.displayName} - Canlı Konum',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: _isLiveActive ? AppColors.onlineGreen : AppColors.textSecondary,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        _buildStatusSubtitle(),
                        style: TextStyle(
                          fontSize: 11.5,
                          color: _isLiveActive ? AppColors.onlineGreen : AppColors.textSecondary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.open_in_new_rounded, color: AppColors.primaryLight),
            tooltip: 'Haritada Aç',
            onPressed: _openInGoogleMaps,
          ),
        ],
      ),
      body: Stack(
        children: [
          // Fullscreen Flutter Map
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _peerLocation,
              initialZoom: _currentZoom,
              maxZoom: 19.0,
              minZoom: 4.0,
              onPositionChanged: _onPositionChanged,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.talknex.app',
                tileBuilder: (context, tileWidget, tile) {
                  return ColorFiltered(
                    colorFilter: const ColorFilter.matrix([
                      0.85, 0,    0,    0, -20,
                      0,    0.85, 0,    0, -20,
                      0,    0,    0.85, 0, -20,
                      0,    0,    0,    1,   0,
                    ]),
                    child: tileWidget,
                  );
                },
              ),
              MarkerLayer(
                markers: [
                  // My own location marker if viewing peer
                  if (!widget.isMyLiveLocation && _myLocation != null)
                    Marker(
                      point: _myLocation!,
                      width: 32,
                      height: 32,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.blue.withOpacity(0.25),
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: Container(
                            width: 16,
                            height: 16,
                            decoration: BoxDecoration(
                              color: Colors.blueAccent,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 2.5),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.blueAccent.withOpacity(0.4),
                                  blurRadius: 6,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),

                  // Live moving user avatar pin with pulse ring & pointer
                  Marker(
                    point: _peerLocation,
                    width: 74,
                    height: 84,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Avatar Bubble Pin
                        Stack(
                          alignment: Alignment.center,
                          children: [
                            // Pulsing radar ring around live avatar
                            if (_isLiveActive && _pulseController != null)
                              AnimatedBuilder(
                                animation: _pulseController!,
                                builder: (context, child) {
                                  final val = _pulseController!.value;
                                  return Container(
                                    width: 52 + (val * 16),
                                    height: 52 + (val * 16),
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: AppColors.onlineGreen.withOpacity(1.0 - val),
                                        width: 2.0,
                                      ),
                                    ),
                                  );
                                },
                              ),

                            Container(
                              width: 52,
                              height: 52,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: _isLiveActive ? AppColors.onlineGreen : const Color(0xFFFF5722),
                                  width: 3.5,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: (_isLiveActive ? AppColors.onlineGreen : const Color(0xFFFF5722)).withOpacity(0.5),
                                    blurRadius: 14,
                                    spreadRadius: 2,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              ),
                              child: ClipOval(
                                child: CachedNetworkImage(
                                  imageUrl: activeUser.photoUrl,
                                  fit: BoxFit.cover,
                                  placeholder: (_, __) => Container(color: AppColors.surfaceLight),
                                  errorWidget: (_, __, ___) => const Icon(Icons.person, color: Colors.white),
                                ),
                              ),
                            ),
                          ],
                        ),
                        // Pin downward arrow indicator
                        CustomPaint(
                          size: const Size(14, 8),
                          painter: _TrianglePainter(
                            color: _isLiveActive ? AppColors.onlineGreen : const Color(0xFFFF5722),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),

          // Top Status Pill (Shows Auto-Tracking status or Recenter countdown)
          Positioned(
            top: 12,
            left: 16,
            right: 16,
            child: Center(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: _isFollowing
                    ? Container(
                        key: const ValueKey('following_badge'),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                        decoration: BoxDecoration(
                          color: const Color(0xFF16231D).withOpacity(0.92),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: AppColors.onlineGreen.withOpacity(0.6), width: 1.2),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.35),
                              blurRadius: 8,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(
                                color: AppColors.onlineGreen,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              widget.isMyLiveLocation
                                  ? 'Otomatik Takip: Konumunuz Merkezde'
                                  : 'Otomatik Takip: ${widget.peerUser.displayName} Merkezde',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                                fontSize: 12.5,
                              ),
                            ),
                          ],
                        ),
                      )
                    : GestureDetector(
                        key: const ValueKey('recenter_badge'),
                        onTap: _resumeAutoFollow,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                          decoration: BoxDecoration(
                            color: const Color(0xFF2E2214).withOpacity(0.95),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: const Color(0xFFFF9800), width: 1.5),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.4),
                                blurRadius: 8,
                                offset: const Offset(0, 3),
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.my_location_rounded, color: Color(0xFFFF9800), size: 16),
                              const SizedBox(width: 8),
                              Text(
                                'Yeniden Ortala ($_autoRecenterSecondsLeft sn)',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
              ),
            ),
          ),

          // Floating Action Buttons (Zoom Controls & Recenter Button)
          Positioned(
            right: 16,
            bottom: widget.isMyLiveLocation ? 100 : 36,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Zoom In / Out Buttons (Perfect for in-car hands-free control)
                Container(
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppColors.cardBorder),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.3),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.add_rounded, color: Colors.white, size: 22),
                        onPressed: _zoomIn,
                        tooltip: 'Yakınlaştır',
                      ),
                      Container(height: 1, width: 30, color: Colors.white12),
                      IconButton(
                        icon: const Icon(Icons.remove_rounded, color: Colors.white, size: 22),
                        onPressed: _zoomOut,
                        tooltip: 'Uzaklaştır',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // My own location button for receiver
                if (!widget.isMyLiveLocation && _myLocation != null) ...[
                  FloatingActionButton.small(
                    heroTag: 'my_loc_btn',
                    backgroundColor: AppColors.surface,
                    foregroundColor: Colors.blueAccent,
                    tooltip: 'Benim Konumum',
                    onPressed: _reCenterToMe,
                    child: const Icon(Icons.person_pin_circle_outlined),
                  ),
                  const SizedBox(height: 10),
                ],

                // Recenter / Follow FAB
                FloatingActionButton(
                  heroTag: 'peer_loc_btn',
                  backgroundColor: _isFollowing ? AppColors.onlineGreen : AppColors.surface,
                  foregroundColor: _isFollowing ? Colors.white : AppColors.textPrimary,
                  tooltip: 'Ortala ve Takip Et',
                  onPressed: _resumeAutoFollow,
                  child: Icon(
                    widget.isMyLiveLocation ? Icons.my_location_rounded : Icons.person_pin_circle_rounded,
                    size: 26,
                  ),
                ),
              ],
            ),
          ),

          // Bottom Bar for Stopping Live Location (if it is my live location)
          if (widget.isMyLiveLocation && _isLiveActive)
            Positioned(
              left: 16,
              right: 16,
              bottom: 20,
              child: SafeArea(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: AppColors.cardBorder),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.35),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: AppColors.onlineGreen.withOpacity(0.15),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.sensors_rounded, color: AppColors.onlineGreen, size: 22),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Canlı Konum Paylaşılıyor',
                              style: TextStyle(
                                color: AppColors.textPrimary,
                                fontWeight: FontWeight.bold,
                                fontSize: 13.5,
                              ),
                            ),
                            Text(
                              'Karşı taraf anlık hareketlerinizi görüyor',
                              style: TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 11.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      ElevatedButton(
                        onPressed: _stopSharingAction,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.callRed,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: const Text('Durdur', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TrianglePainter extends CustomPainter {
  final Color color;

  _TrianglePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
