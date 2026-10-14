import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../constants/app_colors.dart';
import '../../models/call_model.dart';
import '../../models/user_model.dart';
import '../../services/custom_chat_service.dart';
import '../../services/socket_service.dart';
import '../../services/notification_service.dart';
import '../../widgets/app_avatar.dart';

class CallScreen extends StatefulWidget {
  final UserModel currentUser;
  final UserModel peerUser;
  final CallType callType;
  final bool isCaller;
  final Map<String, dynamic>? incomingOffer;

  const CallScreen({
    super.key,
    required this.currentUser,
    required this.peerUser,
    required this.callType,
    required this.isCaller,
    this.incomingOffer,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final SocketService _socketService = SocketService();
  final CustomChatService _chatService = CustomChatService();
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();

  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;

  bool _isMuted = false;
  bool _isVideoOff = false;
  bool _isSpeaker = true;
  bool _hasRemoteStream = false;
  String _callStatusText = 'Bağlanıyor...';

  // Call duration and status tracking
  Timer? _durationTimer;
  int _callDurationSeconds = 0;
  bool _isCallConnected = false;

  final List<RTCIceCandidate> _pendingIceCandidates = [];

  final Map<String, dynamic> _iceServers = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:stun2.l.google.com:19302'},
      {'urls': 'stun:stun3.l.google.com:19302'},
      {'urls': 'stun:stun4.l.google.com:19302'},
    ],
    'sdpSemantics': 'unified-plan',
  };

  final Map<String, dynamic> _config = {
    'mandatory': {},
    'optional': [
      {'DtlsSrtpKeyAgreement': true},
    ],
  };

  @override
  void initState() {
    super.initState();
    _initWebRTC();
  }

  void _startDurationTimer() {
    if (_isCallConnected) return;
    _isCallConnected = true;
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _callDurationSeconds++;
          final minutes = (_callDurationSeconds ~/ 60).toString().padLeft(2, '0');
          final seconds = (_callDurationSeconds % 60).toString().padLeft(2, '0');
          _callStatusText = '$minutes:$seconds';
        });
      }
    });
  }

  void _initWebRTC() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();

    final isVideo = widget.callType == CallType.video;

    // 1. Audio Output Mode
    _isSpeaker = isVideo;
    Helper.setSpeakerphoneOn(_isSpeaker);

    // 2. Capture Local Camera & Audio Stream (Adaptive 1080p Full HD to 480p dynamic scaling)
    try {
      final Map<String, dynamic> constraints = {
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
          'highpassFilter': true,
        },
        'video': isVideo
            ? {
                'facingMode': 'user',
                'mandatory': {
                  'minWidth': '640',
                  'minHeight': '480',
                  'maxWidth': '1920',
                  'maxHeight': '1080',
                  'minFrameRate': '15',
                  'maxFrameRate': '30',
                },
                'optional': [
                  {'googCpuOveruseDetection': true},
                  {'googHighpassFilter': true},
                  {'googNoiseReduction': true},
                ],
              }
            : false,
      };

      _localStream = await navigator.mediaDevices.getUserMedia(constraints);
      _localRenderer.srcObject = _localStream;
    } catch (e) {
      debugPrint('[WEBRTC] Media devices error: $e');
    }

    // 3. Create RTCPeerConnection
    _peerConnection = await createPeerConnection(_iceServers, _config);

    // Track remote incoming audio & video tracks
    _peerConnection?.onTrack = (RTCTrackEvent event) {
      debugPrint('[WEBRTC] Remote Track Received: ${event.track.kind}');
      if (event.streams.isNotEmpty) {
        setState(() {
          _remoteRenderer.srcObject = event.streams[0];
          _hasRemoteStream = true;
        });
        _startDurationTimer();
      }
    };

    // Add local tracks to PeerConnection
    if (_localStream != null) {
      for (var track in _localStream!.getTracks()) {
        await _peerConnection?.addTrack(track, _localStream!);
      }
    }

    // Send local ICE candidates to peer via socket
    _peerConnection?.onIceCandidate = (RTCIceCandidate candidate) {
      _socketService.emitIceCandidate(
        targetUserId: widget.peerUser.uid,
        candidate: candidate.toMap(),
      );
    };

    // Listen for peer ICE candidates
    _socketService.onIceCandidate = (candidateData) async {
      final candidateMap = candidateData['candidate'];
      if (candidateMap != null) {
        final iceCandidate = RTCIceCandidate(
          candidateMap['candidate'],
          candidateMap['sdpMid'],
          candidateMap['sdpMLineIndex'],
        );

        if (_peerConnection != null && _peerConnection!.getRemoteDescription() != null) {
          await _peerConnection?.addCandidate(iceCandidate);
        } else {
          _pendingIceCandidates.add(iceCandidate);
        }
      }
    };

    _socketService.onCallEnded = () {
      debugPrint('[WEBRTC] Peer ended the call, closing call screen...');
      if (mounted) {
        _hangUp(notifyPeer: false);
      }
    };

    // Helper to optimize SDP with dynamic adaptive bitrate (Auto 1080p -> 720p -> 480p)
    // Limits max bandwidth to 1800 kbps (Full HD) while letting WebRTC BWE automatically scale down to 300kbps when internet slows down.
    String _optimizeSdpBitrate(String sdp, bool isVideoCall) {
      if (!isVideoCall) return sdp;
      return sdp.replaceAllMapped(
        RegExp(r'(m=video .*\r\n)'),
        (match) => '${match.group(0)}b=AS:1800\r\n',
      );
    }

    // 4. Negotiate SDP Offer / Answer
    if (widget.isCaller) {
      setState(() {
        _callStatusText = 'Çalıyor...';
      });

      _socketService.onCallAnswered = (answerData) async {
        final answer = answerData['answer'];
        if (answer != null && _peerConnection != null) {
          final desc = RTCSessionDescription(answer['sdp'], answer['type']);
          await _peerConnection?.setRemoteDescription(desc);

          // Drain queued ICE candidates
          for (var candidate in _pendingIceCandidates) {
            await _peerConnection?.addCandidate(candidate);
          }
          _pendingIceCandidates.clear();

          _startDurationTimer();
        }
      };

      RTCSessionDescription offer = await _peerConnection!.createOffer({
        'offerToReceiveAudio': 1,
        'offerToReceiveVideo': isVideo ? 1 : 0,
      });

      // Apply dynamic adaptive bandwidth optimization
      String optimizedSdp = _optimizeSdpBitrate(offer.sdp ?? '', isVideo);
      RTCSessionDescription optimizedOffer = RTCSessionDescription(optimizedSdp, offer.type);

      await _peerConnection!.setLocalDescription(optimizedOffer);

      _socketService.emitCall(
        caller: widget.currentUser,
        receiverId: widget.peerUser.uid,
        offer: optimizedOffer.toMap(),
        callType: isVideo ? 'video' : 'audio',
      );
    } else {
      // Receiver Mode: Answer the incoming offer
      if (widget.incomingOffer != null) {
        final desc = RTCSessionDescription(
          widget.incomingOffer!['sdp'],
          widget.incomingOffer!['type'],
        );
        await _peerConnection?.setRemoteDescription(desc);

        // Drain queued ICE candidates
        for (var candidate in _pendingIceCandidates) {
          await _peerConnection?.addCandidate(candidate);
        }
        _pendingIceCandidates.clear();

        RTCSessionDescription answer = await _peerConnection!.createAnswer({
          'offerToReceiveAudio': 1,
          'offerToReceiveVideo': isVideo ? 1 : 0,
        });

        // Apply dynamic adaptive bandwidth optimization
        String optimizedSdp = _optimizeSdpBitrate(answer.sdp ?? '', isVideo);
        RTCSessionDescription optimizedAnswer = RTCSessionDescription(optimizedSdp, answer.type);

        await _peerConnection!.setLocalDescription(optimizedAnswer);

        _socketService.emitAnswer(
          callerId: widget.peerUser.uid,
          answer: optimizedAnswer.toMap(),
        );

        _startDurationTimer();
      }
    }
  }

  void _toggleSpeaker() {
    setState(() {
      _isSpeaker = !_isSpeaker;
    });
    Helper.setSpeakerphoneOn(_isSpeaker);
  }

  void _toggleMic() {
    setState(() {
      _isMuted = !_isMuted;
    });
    _localStream?.getAudioTracks().forEach((track) {
      track.enabled = !_isMuted;
    });
  }

  void _toggleVideo() {
    setState(() {
      _isVideoOff = !_isVideoOff;
    });
    _localStream?.getVideoTracks().forEach((track) {
      track.enabled = !_isVideoOff;
    });
  }

  void _switchCamera() {
    if (_localStream != null && _localStream!.getVideoTracks().isNotEmpty) {
      Helper.switchCamera(_localStream!.getVideoTracks()[0]);
    }
  }

  bool _isEnding = false;

  void _hangUp({bool notifyPeer = true}) async {
    if (_isEnding) return;
    _isEnding = true;

    _durationTimer?.cancel();
    NotificationService().stopRingtone();
    NotificationService().cancelCallNotification(9999);

    if (notifyPeer) {
      _socketService.emitEndCall(widget.peerUser.uid);
    }

    // Save call log to database (Caller saves the record)
    if (widget.isCaller) {
      final callerId = int.tryParse(widget.currentUser.uid) ?? 0;
      final receiverId = int.tryParse(widget.peerUser.uid) ?? 0;
      final callStatusStr = _isCallConnected
          ? 'ended'
          : (_callDurationSeconds > 0 ? 'accepted' : 'missed');

      _chatService.saveCallLog(
        callerId: callerId,
        receiverId: receiverId,
        callType: widget.callType == CallType.video ? 'video' : 'audio',
        callStatus: callStatusStr,
        durationSeconds: _callDurationSeconds,
      );
    }


    try {
      _localStream?.getTracks().forEach((track) {
        track.stop();
      });
      await _localStream?.dispose();
    } catch (_) {}
    _localStream = null;

    try {
      _localRenderer.srcObject = null;
      _remoteRenderer.srcObject = null;
      await _peerConnection?.close();
    } catch (_) {}
    _peerConnection = null;

    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    _hangUp(notifyPeer: true);
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isVideo = widget.callType == CallType.video;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Stack(
          children: [
            // Video / Audio View
            if (isVideo) ...[
              // Remote Video (or local video full screen until remote joins)
              Positioned.fill(
                child: _hasRemoteStream
                    ? RTCVideoView(
                        _remoteRenderer,
                        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                      )
                    : RTCVideoView(
                        _localRenderer,
                        mirror: true,
                        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                      ),
              ),

              // Local Camera PIP (Only when remote stream is active)
              if (_hasRemoteStream)
                Positioned(
                  right: 20,
                  top: 30,
                  width: 110,
                  height: 160,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white, width: 2),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.4),
                          blurRadius: 10,
                        )
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: RTCVideoView(
                      _localRenderer,
                      mirror: true,
                      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    ),
                  ),
                ),
            ] else ...[
              // Audio Call UI
              Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    AppAvatar(
                      radius: 65,
                      imageUrl: widget.peerUser.photoUrl,
                      name: widget.peerUser.displayName,
                    ),
                    const SizedBox(height: 24),
                    Text(
                      widget.peerUser.displayName,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _callStatusText,
                      style: const TextStyle(
                        fontSize: 16,
                        color: AppColors.primaryLight,
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // Top Caller Info Banner
            Positioned(
              top: 24,
              left: 20,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.peerUser.displayName,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      shadows: [Shadow(color: Colors.black87, blurRadius: 8)],
                    ),
                  ),
                  Text(
                    _callStatusText,
                    style: const TextStyle(
                      fontSize: 14,
                      color: Colors.white70,
                      shadows: [Shadow(color: Colors.black87, blurRadius: 8)],
                    ),
                  ),
                ],
              ),
            ),

            // Bottom Action Controls
            Positioned(
              bottom: 30,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                margin: const EdgeInsets.symmetric(horizontal: 24),
                decoration: BoxDecoration(
                  color: AppColors.surface.withOpacity(0.85),
                  borderRadius: BorderRadius.circular(32),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // Speakerphone / Ahize Toggle
                    IconButton(
                      icon: Icon(
                        _isSpeaker ? Icons.volume_up : Icons.volume_off,
                        color: _isSpeaker ? AppColors.primaryLight : Colors.white,
                        size: 28,
                      ),
                      onPressed: _toggleSpeaker,
                    ),

                    // Mute Audio
                    IconButton(
                      icon: Icon(
                        _isMuted ? Icons.mic_off : Icons.mic,
                        color: _isMuted ? AppColors.callRed : Colors.white,
                        size: 28,
                      ),
                      onPressed: _toggleMic,
                    ),

                    // Toggle Video / Switch Camera
                    if (isVideo) ...[
                      IconButton(
                        icon: Icon(
                          _isVideoOff ? Icons.videocam_off : Icons.videocam,
                          color: _isVideoOff ? AppColors.callRed : Colors.white,
                          size: 28,
                        ),
                        onPressed: _toggleVideo,
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.cameraswitch,
                          color: Colors.white,
                          size: 28,
                        ),
                        onPressed: _switchCamera,
                      ),
                    ],

                    // End Call
                    CircleAvatar(
                      radius: 28,
                      backgroundColor: AppColors.callRed,
                      child: IconButton(
                        icon: const Icon(Icons.call_end, color: Colors.white, size: 28),
                        onPressed: () => _hangUp(notifyPeer: true),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
