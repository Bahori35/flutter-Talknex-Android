import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../../../constants/app_colors.dart';
import '../../../services/encryption_service.dart';
import '../../../utils/media_url_helper.dart';

class AudioMessageBubble extends StatefulWidget {
  final String audioUrl;
  final String senderId;
  final String receiverId;
  final bool isMe;

  const AudioMessageBubble({
    super.key,
    required this.audioUrl,
    required this.senderId,
    required this.receiverId,
    required this.isMe,
  });

  @override
  State<AudioMessageBubble> createState() => _AudioMessageBubbleState();
}

class _AudioMessageBubbleState extends State<AudioMessageBubble> {
  // Global player coordinator: only one voice note plays at a time
  static String? _activePlayingUrl;
  static final List<VoidCallback> _activeStopListeners = [];

  late final AudioPlayer _player;
  bool _isPlaying = false;
  bool _isLoading = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  double _playbackRate = 1.0;
  String? _localFilePath;

  StreamSubscription? _posSub;
  StreamSubscription? _durSub;
  StreamSubscription? _completeSub;
  StreamSubscription? _stateSub;

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();
    _setupPlayerListeners();
  }

  void _setupPlayerListeners() {
    _posSub = _player.onPositionChanged.listen((p) {
      if (mounted) {
        setState(() {
          _position = p;
        });
      }
    });

    _durSub = _player.onDurationChanged.listen((d) {
      if (mounted && d > Duration.zero) {
        setState(() {
          _duration = d;
        });
      }
    });

    _completeSub = _player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _isPlaying = false;
          _position = Duration.zero;
        });
      }
    });

    _stateSub = _player.onPlayerStateChanged.listen((state) {
      if (mounted) {
        setState(() {
          _isPlaying = state == PlayerState.playing;
        });
      }
    });
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _durSub?.cancel();
    _completeSub?.cancel();
    _stateSub?.cancel();
    _player.stop();
    _player.dispose();
    super.dispose();
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  Future<String?> _resolveLocalFile() async {
    if (_localFilePath != null && File(_localFilePath!).existsSync()) {
      return _localFilePath;
    }

    final rawUrl = widget.audioUrl.trim();
    if (rawUrl.isEmpty) return null;

    // Check if it's already an existing local file
    if (File(rawUrl).existsSync()) {
      _localFilePath = rawUrl;
      return _localFilePath;
    }

    final formattedUrl = formatMediaUrl(rawUrl);

    try {
      final cacheDir = await getTemporaryDirectory();
      final voiceDir = Directory(p.join(cacheDir.path, 'voice_cache'))..createSync(recursive: true);
      final cachedTarget = File(p.join(voiceDir.path, '${formattedUrl.hashCode}.m4a'));

      if (cachedTarget.existsSync() && cachedTarget.lengthSync() > 100) {
        _localFilePath = cachedTarget.path;
        return _localFilePath;
      }

      // Download from server
      final uri = Uri.parse(formattedUrl);
      final rawEncFile = File(p.join(voiceDir.path, '${formattedUrl.hashCode}.enc'));
      final response = await http.get(uri).timeout(const Duration(seconds: 35));

      if (response.statusCode == 200 && response.bodyBytes.length > 16) {
        await rawEncFile.writeAsBytes(response.bodyBytes, flush: true);

        // Try decrypting with E2EE
        try {
          await EndToEndEncryptionService.decryptFile(
            rawEncFile,
            widget.senderId,
            widget.receiverId,
            cachedTarget.path,
          );
        } catch (_) {
          // If decryption fails or not encrypted, copy body directly
          await cachedTarget.writeAsBytes(response.bodyBytes, flush: true);
        }

        try {
          if (rawEncFile.existsSync()) await rawEncFile.delete();
        } catch (_) {}

        if (cachedTarget.existsSync() && cachedTarget.lengthSync() > 100) {
          _localFilePath = cachedTarget.path;
          return _localFilePath;
        }
      }
    } catch (e) {
      debugPrint('[AUDIO RESOLVE ERR] $e');
    }

    return null;
  }

  Future<void> _togglePlayPause() async {
    if (_isPlaying) {
      await _player.pause();
      setState(() => _isPlaying = false);
      return;
    }

    // Stop any other active voice note
    for (final cb in _activeStopListeners) {
      cb();
    }
    _activeStopListeners.clear();
    _activePlayingUrl = widget.audioUrl;
    _activeStopListeners.add(() {
      if (mounted && _isPlaying) {
        _player.pause();
        setState(() => _isPlaying = false);
      }
    });

    setState(() => _isLoading = true);
    final filePath = await _resolveLocalFile();
    setState(() => _isLoading = false);

    if (filePath == null || !File(filePath).existsSync()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Ses mesajı yüklenemedi.'),
            backgroundColor: AppColors.callRed,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    try {
      await _player.setPlaybackRate(_playbackRate);
      await _player.play(DeviceFileSource(filePath));
      setState(() => _isPlaying = true);
    } catch (e) {
      debugPrint('[AUDIO PLAY ERR] $e');
    }
  }

  void _cyclePlaybackRate() {
    setState(() {
      if (_playbackRate == 1.0) {
        _playbackRate = 1.5;
      } else if (_playbackRate == 1.5) {
        _playbackRate = 2.0;
      } else {
        _playbackRate = 1.0;
      }
    });
    _player.setPlaybackRate(_playbackRate);
  }

  @override
  Widget build(BuildContext context) {
    final double maxMs = _duration.inMilliseconds > 0 ? _duration.inMilliseconds.toDouble() : 1.0;
    final double curMs = _position.inMilliseconds.toDouble().clamp(0.0, maxMs);

    return Container(
      width: 250,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Play / Pause Circle Button
          GestureDetector(
            onTap: _togglePlayPause,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: widget.isMe
                    ? Colors.white.withValues(alpha: 0.22)
                    : AppColors.accent.withValues(alpha: 0.18),
                shape: BoxShape.circle,
                border: Border.all(
                  color: widget.isMe ? Colors.white38 : AppColors.accent,
                  width: 1.5,
                ),
              ),
              child: Center(
                child: _isLoading
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: widget.isMe ? Colors.white : AppColors.accent,
                        ),
                      )
                    : Icon(
                        _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                        color: widget.isMe ? Colors.white : AppColors.accent,
                        size: 26,
                      ),
              ),
            ),
          ),
          const SizedBox(width: 8),

          // Waveform Scrubber & Timer & Speed
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Scrubber Slider
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: widget.isMe ? Colors.white : AppColors.accent,
                    inactiveTrackColor: Colors.white24,
                    thumbColor: widget.isMe ? Colors.white : AppColors.accent,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                    trackHeight: 3,
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
                  ),
                  child: Slider(
                    min: 0.0,
                    max: maxMs,
                    value: curMs,
                    onChanged: (val) {
                      _player.seek(Duration(milliseconds: val.toInt()));
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // Time indicator
                      Text(
                        _formatDuration(_position > Duration.zero ? _position : _duration),
                        style: TextStyle(
                          color: widget.isMe ? Colors.white70 : AppColors.textSecondary,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      // Speed pill (1x, 1.5x, 2x)
                      GestureDetector(
                        onTap: _cyclePlaybackRate,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${_playbackRate == 1.0 ? '1' : _playbackRate.toString()}x',
                            style: TextStyle(
                              color: widget.isMe ? Colors.white : AppColors.accent,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),

          // WhatsApp Style Mic Badge
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: widget.isMe ? Colors.white12 : AppColors.accent.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.mic_rounded,
              color: widget.isMe ? Colors.white70 : AppColors.accent,
              size: 18,
            ),
          ),
        ],
      ),
    );
  }
}
