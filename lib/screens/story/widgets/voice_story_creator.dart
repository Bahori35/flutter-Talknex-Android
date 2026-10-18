import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../../../constants/app_colors.dart';
import '../../../models/user_model.dart';
import '../../../services/custom_auth_service.dart';
import '../../../services/custom_chat_service.dart';
import '../../../services/voice_record_service.dart';

class VoiceStoryCreator extends StatefulWidget {
  final UserModel currentUser;

  const VoiceStoryCreator({super.key, required this.currentUser});

  @override
  State<VoiceStoryCreator> createState() => _VoiceStoryCreatorState();
}

class _VoiceStoryCreatorState extends State<VoiceStoryCreator> with SingleTickerProviderStateMixin {
  final GlobalKey _repaintKey = GlobalKey();
  final CustomChatService _chatService = CustomChatService();
  final AudioPlayer _audioPlayer = AudioPlayer();

  bool _isRecording = false;
  bool _hasRecorded = false;
  bool _isPlaying = false;
  bool _isLoading = false;

  int _recordSeconds = 0;
  Timer? _recordTimer;
  Timer? _ampTimer;
  double _amplitude = 0.0;
  String? _recordedFilePath;
  int _audioDurationMs = 0;

  Duration _playPosition = Duration.zero;
  Duration _playTotal = Duration.zero;
  StreamSubscription? _posSub;
  StreamSubscription? _compSub;

  int _selectedGradientIndex = 0;
  final List<List<Color>> _gradients = [
    [const Color(0xFF654ea3), const Color(0xFFeaafc8)], // Violet Rose
    [const Color(0xFF11998e), const Color(0xFF38ef7d)], // Emerald
    [const Color(0xFF8A2387), const Color(0xFFE94057)], // Sunset
    [const Color(0xFF00c6ff), const Color(0xFF0072ff)], // Ocean Blue
    [const Color(0xFFe65c00), const Color(0xFFF9D423)], // Amber Sun
    [const Color(0xFF232526), const Color(0xFF414345)], // Dark Obsidian
  ];

  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);

    _posSub = _audioPlayer.onPositionChanged.listen((p) {
      if (mounted) setState(() => _playPosition = p);
    });

    _compSub = _audioPlayer.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _isPlaying = false;
          _playPosition = Duration.zero;
        });
      }
    });
  }

  void _cycleGradient() {
    setState(() {
      _selectedGradientIndex = (_selectedGradientIndex + 1) % _gradients.length;
    });
  }

  Future<void> _startRecording() async {
    final granted = await VoiceRecordService.requestPermission();
    if (!granted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Ses kaydı için mikrofon izni gereklidir.'),
            backgroundColor: AppColors.callRed,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    final path = await VoiceRecordService.startRecording();
    if (path == null) return;

    setState(() {
      _isRecording = true;
      _hasRecorded = false;
      _recordSeconds = 0;
      _recordedFilePath = null;
    });

    _recordTimer?.cancel();
    _recordTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() {
        _recordSeconds++;
      });
      if (_recordSeconds >= 30) {
        _stopRecording();
      }
    });

    _ampTimer?.cancel();
    _ampTimer = Timer.periodic(const Duration(milliseconds: 120), (t) async {
      final amp = await VoiceRecordService.getAmplitude();
      if (!mounted) return;
      setState(() {
        _amplitude = (amp / 32768.0).clamp(0.1, 1.0);
      });
    });
  }

  Future<void> _stopRecording() async {
    _recordTimer?.cancel();
    _ampTimer?.cancel();

    final result = await VoiceRecordService.stopRecording();
    if (result != null && File(result.filePath).existsSync()) {
      setState(() {
        _isRecording = false;
        _hasRecorded = true;
        _recordedFilePath = result.filePath;
        _audioDurationMs = result.durationMs;
        _playTotal = Duration(milliseconds: result.durationMs);
        _playPosition = Duration.zero;
      });
    } else {
      setState(() {
        _isRecording = false;
        _hasRecorded = false;
      });
    }
  }

  Future<void> _deleteRecording() async {
    await _audioPlayer.stop();
    if (_recordedFilePath != null && File(_recordedFilePath!).existsSync()) {
      try {
        await File(_recordedFilePath!).delete();
      } catch (_) {}
    }
    setState(() {
      _hasRecorded = false;
      _recordedFilePath = null;
      _isPlaying = false;
      _recordSeconds = 0;
      _playPosition = Duration.zero;
    });
  }

  Future<void> _togglePlayback() async {
    if (_recordedFilePath == null) return;

    if (_isPlaying) {
      await _audioPlayer.pause();
      setState(() => _isPlaying = false);
    } else {
      await _audioPlayer.play(DeviceFileSource(_recordedFilePath!));
      setState(() => _isPlaying = true);
    }
  }

  String _formatTimer(int sec) {
    final m = (sec ~/ 60).toString().padLeft(2, '0');
    final s = (sec % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _publishVoiceStory() async {
    if (_recordedFilePath == null || !File(_recordedFilePath!).existsSync()) return;

    setState(() => _isLoading = true);

    try {
      // 1. Capture the background canvas with visualizer to image
      final boundary = _repaintKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      String? bgImageUrl;
      if (boundary != null) {
        final ui.Image image = await boundary.toImage(pixelRatio: 2.0);
        final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
        if (byteData != null) {
          final tempDir = await getTemporaryDirectory();
          final bgFile = File('${tempDir.path}/voice_story_bg_${DateTime.now().millisecondsSinceEpoch}.png');
          await bgFile.writeAsBytes(byteData.buffer.asUint8List(), flush: true);

          final authService = Provider.of<CustomAuthService>(context, listen: false);
          bgImageUrl = await authService.uploadImage(bgFile.path);
        }
      }

      // 2. Upload audio file
      final authService = Provider.of<CustomAuthService>(context, listen: false);
      final audioUrl = await authService.uploadFile(_recordedFilePath!);

      if (audioUrl == null) {
        throw Exception('Ses dosyası sunucuya yüklenemedi');
      }

      // 3. Create story (mediaUrl is audioUrl, or fallback to bgImageUrl)
      final myUid = int.tryParse(widget.currentUser.uid) ?? 0;
      final durationStr = _formatTimer((_audioDurationMs / 1000).round());
      final success = await _chatService.createStory(
        userId: myUid,
        mediaUrl: audioUrl,
        caption: '🎤 Sesli Durum ($durationStr)',
        mediaType: 'audio',
      );

      if (!mounted) return;

      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Sesli durum başarıyla paylaşıldı!'),
            backgroundColor: AppColors.primaryLight,
            behavior: SnackBarBehavior.floating,
          ),
        );
        Navigator.pop(context, true);
      } else {
        throw Exception('Durum kaydedilemedi');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Hata: $e'),
            backgroundColor: AppColors.callRed,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  void dispose() {
    _recordTimer?.cancel();
    _ampTimer?.cancel();
    _posSub?.cancel();
    _compSub?.cancel();
    _pulseController.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentGradient = _gradients[_selectedGradientIndex];

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Captured Background & Voice Card
          RepaintBoundary(
            key: _repaintKey,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: currentGradient,
                ),
              ),
              child: Center(
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 24),
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: Colors.white24, width: 1.5),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.25),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.mic_rounded, color: Colors.white, size: 48),
                      const SizedBox(height: 12),
                      Text(
                        _isRecording
                            ? _formatTimer(_recordSeconds)
                            : (_hasRecorded ? _formatTimer((_audioDurationMs / 1000).round()) : 'Sesli Durum'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _isRecording
                            ? 'Kaydediliyor (Maks 30 sn)...'
                            : (_hasRecorded ? 'Dinlemek için oynatın' : 'Kaydetmek için mikrofona dokunun'),
                        style: const TextStyle(color: Colors.white70, fontSize: 13),
                      ),
                      const SizedBox(height: 16),

                      // Waveform Visualizer
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(15, (idx) {
                          double height = 12.0;
                          if (_isRecording) {
                            height = (12.0 + (idx % 2 == 0 ? _amplitude * 32 : (1.0 - _amplitude) * 24)).clamp(8.0, 44.0);
                          } else if (_isPlaying) {
                            height = (14.0 + (idx % 3 == 0 ? 24 : 10)).toDouble();
                          }
                          return Container(
                            width: 3.5,
                            height: height,
                            margin: const EdgeInsets.symmetric(horizontal: 2.5),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          );
                        }),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Top Header Controls
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.close_rounded, color: Colors.white, size: 28),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white70, width: 2),
                        ),
                        child: const Icon(Icons.palette_rounded, color: Colors.white, size: 20),
                      ),
                      tooltip: 'Renk Değiştir',
                      onPressed: _cycleGradient,
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Bottom Control Area (Record / Play / Delete / Send)
          Positioned(
            bottom: 30,
            left: 24,
            right: 24,
            child: SafeArea(
              child: _hasRecorded
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        // Delete / Re-record
                        IconButton(
                          icon: const Icon(Icons.delete_outline_rounded, color: Colors.white, size: 30),
                          tooltip: 'Yeniden Kaydet',
                          onPressed: _deleteRecording,
                        ),
                        // Play / Pause Preview
                        GestureDetector(
                          onTap: _togglePlayback,
                          child: Container(
                            width: 58,
                            height: 58,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.3),
                                  blurRadius: 10,
                                ),
                              ],
                            ),
                            child: Icon(
                              _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                              color: Colors.black,
                              size: 34,
                            ),
                          ),
                        ),
                        // Send Story
                        FloatingActionButton(
                          backgroundColor: AppColors.primaryLight,
                          onPressed: _isLoading ? null : _publishVoiceStory,
                          child: _isLoading
                              ? const SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                                )
                              : const Icon(Icons.send_rounded, color: Colors.white),
                        ),
                      ],
                    )
                  : Center(
                      child: GestureDetector(
                        onTap: _isRecording ? _stopRecording : _startRecording,
                        child: AnimatedBuilder(
                          animation: _pulseController,
                          builder: (context, child) {
                            return Container(
                              width: 74,
                              height: 74,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: _isRecording ? AppColors.callRed : Colors.white,
                                boxShadow: [
                                  BoxShadow(
                                    color: (_isRecording ? AppColors.callRed : Colors.white).withValues(alpha: 0.4),
                                    blurRadius: _isRecording ? 16 + _pulseController.value * 8 : 10,
                                    spreadRadius: _isRecording ? _pulseController.value * 4 : 2,
                                  ),
                                ],
                              ),
                              child: Icon(
                                _isRecording ? Icons.stop_rounded : Icons.mic_rounded,
                                color: _isRecording ? Colors.white : Colors.black,
                                size: 36,
                              ),
                            );
                          },
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
