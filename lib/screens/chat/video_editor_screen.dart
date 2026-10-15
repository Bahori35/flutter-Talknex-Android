import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:audioplayers/audioplayers.dart';
import '../../constants/app_colors.dart';

const MethodChannel _nativeVideoChannel = MethodChannel('com.safechat.app/video');

/// The result returned when video editing is completed
class VideoEditorResult {
  final File file;
  final String caption;

  VideoEditorResult({
    required this.file,
    required this.caption,
  });
}

class VideoClipItem {
  final String id;
  final File file;
  Duration totalDuration;
  Duration startTrim;
  Duration endTrim;

  VideoClipItem({
    required this.id,
    required this.file,
    required this.totalDuration,
    required this.startTrim,
    required this.endTrim,
  });

  Duration get trimmedDuration {
    if (endTrim <= startTrim) return Duration.zero;
    return endTrim - startTrim;
  }
}

class VideoEditorScreen extends StatefulWidget {
  final File initialVideoFile;

  const VideoEditorScreen({
    super.key,
    required this.initialVideoFile,
  });

  @override
  State<VideoEditorScreen> createState() => _VideoEditorScreenState();
}

class _VideoEditorScreenState extends State<VideoEditorScreen> {
  final ImagePicker _picker = ImagePicker();
  final TextEditingController _captionController = TextEditingController();

  final List<VideoClipItem> _clips = [];
  final Map<int, VideoPlayerController> _controllers = {};

  int _playingClipIndex = 0; // The clip currently active on the player
  int _selectedClipIndex = 0; // The clip currently selected for trimming
  bool _isPlaying = false;
  bool _isMuted = false;
  double _videoVolume = 1.0; // 0.0 to 1.0

  // Background Audio / Music Track
  File? _bgMusicFile;
  String? _bgMusicName;
  double _bgMusicVolume = 0.7; // 0.0 to 1.0
  AudioPlayer? _bgMusicPlayer;
  Duration _bgMusicTotalDuration = Duration.zero;
  Duration _bgMusicStartTrim = Duration.zero;

  bool _isProcessing = false;
  double _processingProgress = 0.0;
  String _processingStatus = '';

  @override
  void initState() {
    super.initState();
    _initFirstClip();
  }

  Future<void> _initFirstClip() async {
    final firstClip = VideoClipItem(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      file: widget.initialVideoFile,
      totalDuration: Duration.zero,
      startTrim: Duration.zero,
      endTrim: Duration.zero,
    );

    setState(() {
      _clips.add(firstClip);
      _playingClipIndex = 0;
      _selectedClipIndex = 0;
    });

    await _initAllControllers();
  }

  Future<void> _initAllControllers() async {
    for (int i = 0; i < _clips.length; i++) {
      if (_controllers.containsKey(i)) continue;
      final clip = _clips[i];
      final controller = VideoPlayerController.file(clip.file);

      try {
        await controller.initialize();
        controller.setVolume(_isMuted ? 0.0 : _videoVolume);
        controller.setLooping(false);

        if (clip.totalDuration == Duration.zero) {
          clip.totalDuration = controller.value.duration;
          clip.endTrim = controller.value.duration;
        }

        final clipIndex = i;
        controller.addListener(() => _onControllerTick(clipIndex));
        _controllers[i] = controller;
      } catch (e) {
        debugPrint('[INIT CONTROLLER ERR FOR CLIP $i] $e');
      }
    }

    if (mounted) {
      setState(() {});
    }
  }

  bool _isTransitioning = false;
  Timer? _videoSeekDebounceTimer;
  Timer? _musicSeekDebounceTimer;

  void _debouncedVideoSeek(int clipIndex, Duration target) {
    _videoSeekDebounceTimer?.cancel();
    _videoSeekDebounceTimer = Timer(const Duration(milliseconds: 60), () {
      if (mounted && _controllers.containsKey(clipIndex)) {
        final c = _controllers[clipIndex];
        if (c != null && c.value.isInitialized) {
          c.seekTo(target);
        }
      }
    });
  }

  void _debouncedMusicSeek(Duration target) {
    _musicSeekDebounceTimer?.cancel();
    _musicSeekDebounceTimer = Timer(const Duration(milliseconds: 60), () {
      if (mounted) {
        _bgMusicPlayer?.seek(target);
      }
    });
  }

  void _onControllerTick(int clipIndex) {
    if (!mounted || _isTransitioning || clipIndex != _playingClipIndex) return;
    final controller = _controllers[clipIndex];
    if (controller == null || !controller.value.isInitialized) return;

    final pos = controller.value.position;
    if (clipIndex >= _clips.length) return;
    final clip = _clips[clipIndex];

    // Smooth transition to next clip when current clip reaches endTrim or finishes
    final bool reachedEnd = pos >= clip.endTrim || controller.value.isCompleted;

    if (reachedEnd && !_isTransitioning) {
      _isTransitioning = true;
      if (_isPlaying) {
        int nextIndex = clipIndex + 1;
        if (nextIndex >= _clips.length) {
          nextIndex = 0; // Loop back to start
        }
        _transitionToClip(nextIndex);
      } else {
        controller.pause();
        controller.seekTo(clip.startTrim).then((_) {
          if (mounted) {
            _isTransitioning = false;
          }
        });
      }
      return;
    }

    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _transitionToClip(int nextIndex) async {
    _isTransitioning = true;
    try {
      final currentController = _controllers[_playingClipIndex];
      await currentController?.pause();
      if (_playingClipIndex < _clips.length) {
        await currentController?.seekTo(_clips[_playingClipIndex].startTrim);
      }

      if (!mounted) return;

      setState(() {
        _playingClipIndex = nextIndex;
      });

      final nextController = _controllers[nextIndex];
      if (nextController != null && nextController.value.isInitialized && nextIndex < _clips.length) {
        await nextController.seekTo(_clips[nextIndex].startTrim);
        if (_isPlaying && mounted) {
          await nextController.play();
        }
      }

      if (nextIndex == 0 && mounted) {
        await _bgMusicPlayer?.seek(_bgMusicStartTrim);
      }
    } catch (e) {
      debugPrint('[TRANSITION ERR] $e');
    } finally {
      await Future.delayed(const Duration(milliseconds: 150));
      if (mounted) {
        _isTransitioning = false;
      }
    }
  }

  @override
  void dispose() {
    _videoSeekDebounceTimer?.cancel();
    _musicSeekDebounceTimer?.cancel();
    for (final c in _controllers.values) {
      c.dispose();
    }
    _captionController.dispose();
    _bgMusicPlayer?.stop();
    _bgMusicPlayer?.dispose();
    super.dispose();
  }

  // --- MERGED TIMELINE CALCULATIONS ---

  Duration get _totalMergedDuration {
    Duration total = Duration.zero;
    for (final c in _clips) {
      total += c.trimmedDuration;
    }
    return total;
  }

  Duration get _currentMergedPosition {
    Duration pos = Duration.zero;
    for (int i = 0; i < _clips.length; i++) {
      if (i < _playingClipIndex) {
        pos += _clips[i].trimmedDuration;
      } else if (i == _playingClipIndex) {
        final controller = _controllers[i];
        if (controller != null && controller.value.isInitialized) {
          final clipPos = controller.value.position;
          final offsetInClip = clipPos - _clips[i].startTrim;
          if (offsetInClip > Duration.zero) {
            final dur = _clips[i].trimmedDuration;
            pos += (offsetInClip > dur) ? dur : offsetInClip;
          }
        }
        break;
      }
    }
    return pos;
  }

  void _seekMergedPosition(Duration targetPos) {
    _bgMusicPlayer?.seek(_bgMusicStartTrim + targetPos);
    Duration accumulated = Duration.zero;
    for (int i = 0; i < _clips.length; i++) {
      final clipDur = _clips[i].trimmedDuration;
      if (targetPos <= accumulated + clipDur || i == _clips.length - 1) {
        final offsetInsideClip = targetPos - accumulated;
        final targetClipPos = _clips[i].startTrim +
            (offsetInsideClip < Duration.zero
                ? Duration.zero
                : (offsetInsideClip > clipDur ? clipDur : offsetInsideClip));

        if (_playingClipIndex != i) {
          _controllers[_playingClipIndex]?.pause();
          _playingClipIndex = i;
          _selectedClipIndex = i;
        }

        final targetController = _controllers[i];
        if (targetController != null && targetController.value.isInitialized) {
          targetController.seekTo(targetClipPos);
          if (_isPlaying) {
            targetController.play();
          }
        }
        setState(() {});
        break;
      }
      accumulated += clipDur;
    }
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) {
      final hours = d.inHours.toString().padLeft(2, '0');
      return '$hours:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  void _togglePlayPause() {
    if (_controllers.isEmpty) return;
    setState(() {
      _isPlaying = !_isPlaying;
      if (_isPlaying) {
        // If near end of entire merged video, restart from the very beginning
        if (_totalMergedDuration > Duration.zero &&
            _currentMergedPosition >= _totalMergedDuration - const Duration(milliseconds: 200)) {
          _seekMergedPosition(Duration.zero);
        }
        final activeController = _controllers[_playingClipIndex];
        if (activeController != null && activeController.value.isInitialized) {
          if (_playingClipIndex < _clips.length) {
            final currentClip = _clips[_playingClipIndex];
            if (activeController.value.position >= currentClip.endTrim) {
              activeController.seekTo(currentClip.startTrim).then((_) {
                if (_isPlaying && mounted) activeController.play();
              });
            } else {
              activeController.play();
            }
          } else {
            activeController.play();
          }
        }
        _bgMusicPlayer?.seek(_bgMusicStartTrim + _currentMergedPosition);
        _bgMusicPlayer?.resume();
      } else {
        _pauseAllControllers();
      }
    });
  }

  void _pauseAllControllers() {
    for (final c in _controllers.values) {
      if (c.value.isPlaying) c.pause();
    }
    _bgMusicPlayer?.pause();
  }

  void _toggleMute() {
    setState(() {
      _isMuted = !_isMuted;
      final targetVolume = _isMuted ? 0.0 : (_videoVolume > 0 ? _videoVolume : 1.0);
      if (!_isMuted && _videoVolume == 0.0) {
        _videoVolume = 1.0;
      }
      for (final c in _controllers.values) {
        c.setVolume(targetVolume);
      }
    });
  }

  void _setVideoVolume(double volume) {
    setState(() {
      _videoVolume = volume.clamp(0.0, 1.0);
      _isMuted = (_videoVolume == 0.0);
      for (final c in _controllers.values) {
        c.setVolume(_isMuted ? 0.0 : _videoVolume);
      }
    });
  }

  void _setBgMusicVolume(double volume) {
    setState(() {
      _bgMusicVolume = volume.clamp(0.0, 1.0);
      _bgMusicPlayer?.setVolume(_bgMusicVolume);
    });
  }

  double _calcMaxMusicStartTrim() {
    if (_bgMusicTotalDuration > _totalMergedDuration && _totalMergedDuration > Duration.zero) {
      return (_bgMusicTotalDuration - _totalMergedDuration).inMilliseconds.toDouble();
    } else if (_bgMusicTotalDuration.inMilliseconds > 0) {
      return _bgMusicTotalDuration.inMilliseconds.toDouble();
    }
    return 60000.0;
  }

  void _setMusicStartTrim(Duration startOffset, {bool immediate = false}) {
    setState(() {
      _bgMusicStartTrim = startOffset;
    });
    final target = _isPlaying
        ? (_bgMusicStartTrim + _currentMergedPosition)
        : _bgMusicStartTrim;
    if (immediate) {
      _musicSeekDebounceTimer?.cancel();
      _bgMusicPlayer?.seek(target);
    } else {
      _debouncedMusicSeek(target);
    }
  }

  Future<void> _pickMusic() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['mp3', 'm4a', 'aac', 'wav', 'ogg', 'opus', 'flac', 'wma'],
      );
      if (result == null || result.files.single.path == null) return;

      final pickedFile = File(result.files.single.path!);
      final name = result.files.single.name;

      await _bgMusicPlayer?.stop();
      await _bgMusicPlayer?.dispose();

      final player = AudioPlayer();
      // Disable Android AudioFocus arbitration so AudioPlayer and VideoPlayer can play simultaneously!
      await player.setAudioContext(
        AudioContext(
          android: const AudioContextAndroid(
            isSpeakerphoneOn: false,
            stayAwake: false,
            contentType: AndroidContentType.music,
            usageType: AndroidUsageType.media,
            audioFocus: AndroidAudioFocus.none,
          ),
        ),
      );
      await player.setReleaseMode(ReleaseMode.loop);
      await player.setSource(DeviceFileSource(pickedFile.path));
      await player.setVolume(_bgMusicVolume);

      Duration musicDur = Duration.zero;
      try {
        final d = await player.getDuration();
        if (d != null && d > Duration.zero) {
          musicDur = d;
        }
      } catch (_) {}

      setState(() {
        _bgMusicFile = pickedFile;
        _bgMusicName = name;
        _bgMusicPlayer = player;
        _bgMusicTotalDuration = musicDur;
        _bgMusicStartTrim = Duration.zero;
      });

      player.onDurationChanged.listen((d) {
        if (mounted && d > Duration.zero && _bgMusicTotalDuration != d) {
          setState(() {
            _bgMusicTotalDuration = d;
          });
        }
      });

      if (_isPlaying) {
        await _bgMusicPlayer?.seek(_bgMusicStartTrim + _currentMergedPosition);
        await _bgMusicPlayer?.resume();
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.music_note_rounded, color: AppColors.accent, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Müzik eklendi: $name',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            backgroundColor: const Color(0xFF1F2C34),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      debugPrint('[PICK MUSIC ERR] $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Ses dosyası seçilirken hata oluştu: $e'),
            backgroundColor: AppColors.callRed,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _removeMusic() async {
    try {
      await _bgMusicPlayer?.stop();
      await _bgMusicPlayer?.dispose();
    } catch (_) {}

    setState(() {
      _bgMusicFile = null;
      _bgMusicName = null;
      _bgMusicPlayer = null;
      _bgMusicTotalDuration = Duration.zero;
      _bgMusicStartTrim = Duration.zero;
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Arka plan müziği kaldırıldı.'),
          backgroundColor: AppColors.surfaceLight,
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  void _openAudioMixerSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            final effectiveVideoVol = _isMuted ? 0.0 : _videoVolume;
            return Container(
              decoration: const BoxDecoration(
                color: Color(0xFF141D22),
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                border: Border(
                  top: BorderSide(color: Colors.white12, width: 1),
                ),
              ),
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              child: SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Handle Bar
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Header
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.tune_rounded, color: AppColors.accent, size: 22),
                            SizedBox(width: 8),
                            Text(
                              'Ses ve Müzik Mikseri',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 17,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        IconButton(
                          icon: const Icon(Icons.close_rounded, color: Colors.white70),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Quick Preset Chips
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _buildPresetChip(
                            label: 'Orijinal Video',
                            icon: Icons.videocam_rounded,
                            isActive: !_isMuted && _videoVolume == 1.0 && _bgMusicFile == null,
                            onTap: () {
                              setSheetState(() {
                                _setVideoVolume(1.0);
                              });
                              setState(() {});
                            },
                          ),
                          const SizedBox(width: 8),
                          _buildPresetChip(
                            label: 'Dengeli (%50 / %50)',
                            icon: Icons.balance_rounded,
                            isActive: !_isMuted && _videoVolume == 0.5 && _bgMusicVolume == 0.5,
                            onTap: () {
                              setSheetState(() {
                                _setVideoVolume(0.5);
                                _setBgMusicVolume(0.5);
                              });
                              setState(() {});
                            },
                          ),
                          const SizedBox(width: 8),
                          _buildPresetChip(
                            label: 'Müzik Öncelikli',
                            icon: Icons.music_note_rounded,
                            isActive: _videoVolume <= 0.2 && _bgMusicVolume >= 0.8,
                            onTap: () {
                              setSheetState(() {
                                _setVideoVolume(0.15);
                                _setBgMusicVolume(0.85);
                              });
                              setState(() {});
                            },
                          ),
                          const SizedBox(width: 8),
                          _buildPresetChip(
                            label: 'Sadece Müzik',
                            icon: Icons.volume_off_rounded,
                            isActive: _isMuted || _videoVolume == 0.0,
                            onTap: () {
                              setSheetState(() {
                                _setVideoVolume(0.0);
                                _setBgMusicVolume(1.0);
                              });
                              setState(() {});
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // --- VIDEO AUDIO CARD ---
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1F2C34),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    _isMuted || _videoVolume == 0.0
                                        ? Icons.volume_off_rounded
                                        : Icons.videocam_rounded,
                                    color: _isMuted || _videoVolume == 0.0
                                        ? AppColors.callRed
                                        : AppColors.accent,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 8),
                                  const Text(
                                    'Orijinal Video Sesi',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: (_isMuted || _videoVolume == 0.0)
                                      ? AppColors.callRed.withValues(alpha: 0.2)
                                      : AppColors.accent.withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  _isMuted || _videoVolume == 0.0
                                      ? 'Sessiz'
                                      : '%${(effectiveVideoVol * 100).round()}',
                                  style: TextStyle(
                                    color: (_isMuted || _videoVolume == 0.0)
                                        ? AppColors.callRed
                                        : AppColors.accent,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              IconButton(
                                icon: Icon(
                                  _isMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                                  color: _isMuted ? AppColors.callRed : Colors.white70,
                                  size: 22,
                                ),
                                onPressed: () {
                                  setSheetState(() {
                                    _toggleMute();
                                  });
                                  setState(() {});
                                },
                              ),
                              Expanded(
                                child: SliderTheme(
                                  data: SliderTheme.of(context).copyWith(
                                    activeTrackColor: AppColors.accent,
                                    inactiveTrackColor: Colors.white24,
                                    thumbColor: AppColors.accent,
                                    overlayColor: AppColors.accent.withValues(alpha: 0.2),
                                    trackHeight: 4,
                                  ),
                                  child: Slider(
                                    min: 0.0,
                                    max: 1.0,
                                    value: _isMuted ? 0.0 : _videoVolume,
                                    onChanged: (val) {
                                      setSheetState(() {
                                        _setVideoVolume(val);
                                      });
                                      setState(() {});
                                    },
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),

                    // --- BACKGROUND MUSIC CARD ---
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1F2C34),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: _bgMusicFile != null
                              ? AppColors.accent.withValues(alpha: 0.4)
                              : Colors.white12,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Row(
                                children: [
                                  Icon(Icons.music_note_rounded,
                                      color: AppColors.accent, size: 20),
                                  SizedBox(width: 8),
                                  Text(
                                    'Arka Plan Müziği',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                              if (_bgMusicFile != null)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: AppColors.accent.withValues(alpha: 0.2),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    '%${(_bgMusicVolume * 100).round()}',
                                    style: const TextStyle(
                                      color: AppColors.accent,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 10),

                          if (_bgMusicFile == null)
                            InkWell(
                              onTap: () async {
                                await _pickMusic();
                                setSheetState(() {});
                                setState(() {});
                              },
                              borderRadius: BorderRadius.circular(12),
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.05),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: AppColors.accent.withValues(alpha: 0.5),
                                  ),
                                ),
                                child: const Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.add_circle_outline_rounded,
                                        color: AppColors.accent, size: 20),
                                    SizedBox(width: 8),
                                    Text(
                                      'Cihazdan Müzik veya Ses Seç',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          else ...[
                            // Selected music file row
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              decoration: BoxDecoration(
                                color: Colors.black38,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.audiotrack_rounded,
                                      color: AppColors.accent, size: 18),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      _bgMusicName ?? 'Müzik Parçası',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                  // Change music button
                                  TextButton(
                                    onPressed: () async {
                                      await _pickMusic();
                                      setSheetState(() {});
                                      setState(() {});
                                    },
                                    style: TextButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(horizontal: 8),
                                      minimumSize: Size.zero,
                                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    ),
                                    child: const Text(
                                      'Değiştir',
                                      style: TextStyle(color: AppColors.accent, fontSize: 12),
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  // Remove music button
                                  GestureDetector(
                                    onTap: () async {
                                      await _removeMusic();
                                      setSheetState(() {});
                                      setState(() {});
                                    },
                                    child: const Icon(Icons.delete_outline_rounded,
                                        color: AppColors.callRed, size: 20),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 8),
                            // Music volume slider
                            Row(
                              children: [
                                const Icon(Icons.volume_down_rounded,
                                    color: Colors.white70, size: 20),
                                Expanded(
                                  child: SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      activeTrackColor: AppColors.accent,
                                      inactiveTrackColor: Colors.white24,
                                      thumbColor: AppColors.accent,
                                      overlayColor: AppColors.accent.withValues(alpha: 0.2),
                                      trackHeight: 4,
                                    ),
                                    child: Slider(
                                      min: 0.0,
                                      max: 1.0,
                                      value: _bgMusicVolume,
                                      onChanged: (val) {
                                        setSheetState(() {
                                          _setBgMusicVolume(val);
                                        });
                                        setState(() {});
                                      },
                                    ),
                                  ),
                                ),
                                const Icon(Icons.volume_up_rounded,
                                    color: Colors.white70, size: 20),
                              ],
                            ),
                            const SizedBox(height: 12),
                            // Music Trimming / Start Offset Section
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              decoration: BoxDecoration(
                                color: const Color(0xFF141D22),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: Colors.white12),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      const Row(
                                        children: [
                                          Icon(Icons.content_cut_rounded,
                                              color: AppColors.accent, size: 16),
                                          SizedBox(width: 6),
                                          Text(
                                            'Şarkı Kesme / Başlangıç Aralığı',
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 12.5,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ],
                                      ),
                                      if (_bgMusicTotalDuration > Duration.zero)
                                        Text(
                                          'Toplam: ${_formatDuration(_bgMusicTotalDuration)}',
                                          style: const TextStyle(
                                            color: Colors.white54,
                                            fontSize: 11,
                                          ),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    'Çalınacak Aralık: ${_formatDuration(_bgMusicStartTrim)} - ${_formatDuration(_bgMusicStartTrim + _totalMergedDuration)} (Video: ${_formatDuration(_totalMergedDuration)})',
                                    style: const TextStyle(
                                      color: AppColors.accent,
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Builder(
                                    builder: (context) {
                                      final maxTrim = _calcMaxMusicStartTrim();
                                      final currentMs = _bgMusicStartTrim.inMilliseconds
                                          .toDouble()
                                          .clamp(0.0, maxTrim > 0 ? maxTrim : 1.0);
                                      return SliderTheme(
                                        data: SliderTheme.of(context).copyWith(
                                          activeTrackColor: AppColors.accent,
                                          inactiveTrackColor: Colors.white24,
                                          thumbColor: AppColors.accent,
                                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                                          trackHeight: 3.5,
                                        ),
                                        child: Slider(
                                          min: 0.0,
                                          max: maxTrim > 0 ? maxTrim : 1.0,
                                          value: currentMs,
                                          onChanged: maxTrim > 0
                                              ? (val) {
                                                  setSheetState(() {
                                                    _setMusicStartTrim(Duration(milliseconds: val.toInt()), immediate: false);
                                                  });
                                                  setState(() {});
                                                }
                                              : null,
                                          onChangeEnd: maxTrim > 0
                                              ? (val) {
                                                  setSheetState(() {
                                                    _setMusicStartTrim(Duration(milliseconds: val.toInt()), immediate: true);
                                                  });
                                                  setState(() {});
                                                }
                                              : null,
                                        ),
                                      );
                                    },
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildPresetChip({
    required String label,
    required IconData icon,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isActive ? AppColors.accent : const Color(0xFF1F2C34),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isActive ? AppColors.accent : Colors.white24,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14,
              color: isActive ? Colors.white : Colors.white70,
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color: isActive ? Colors.white : Colors.white70,
                fontSize: 11.5,
                fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickChip(String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: const Color(0xFF1F2C34),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white24),
        ),
        child: Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 10.5, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  void _selectClipForTrimming(int index) {
    setState(() {
      _selectedClipIndex = index;
      _playingClipIndex = index;
    });
    final controller = _controllers[index];
    if (controller != null && controller.value.isInitialized) {
      controller.seekTo(_clips[index].startTrim);
      if (_isPlaying) {
        controller.play();
      }
    }
  }

  Future<void> _pickAndAddVideo() async {
    try {
      final XFile? file = await _picker.pickVideo(
        source: ImageSource.gallery,
        maxDuration: const Duration(minutes: 5),
      );
      if (file == null) return;

      final tempController = VideoPlayerController.file(File(file.path));
      await tempController.initialize();
      final duration = tempController.value.duration;
      await tempController.dispose();

      final newClip = VideoClipItem(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        file: File(file.path),
        totalDuration: duration,
        startTrim: Duration.zero,
        endTrim: duration,
      );

      final newIndex = _clips.length;
      setState(() {
        _clips.add(newClip);
        _selectedClipIndex = newIndex;
        // Keep merged playback active from start
        _playingClipIndex = 0;
      });

      await _initAllControllers();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${_clips.length} video birleştirildi. Kesintisiz izlemek için oynatın.'),
            backgroundColor: AppColors.surfaceLight,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
            action: SnackBarAction(
              label: 'Baştan Oynat',
              textColor: AppColors.accent,
              onPressed: () {
                _seekMergedPosition(Duration.zero);
                if (!_isPlaying) _togglePlayPause();
              },
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint('[ADD VIDEO CLIP ERR] $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Video eklenirken bir hata oluştu.'),
            backgroundColor: AppColors.callRed,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  void _removeClip(int index) {
    if (_clips.length <= 1) return;

    final controller = _controllers.remove(index);
    controller?.pause();
    controller?.dispose();

    setState(() {
      _clips.removeAt(index);
      // Re-map controllers map keys
      final Map<int, VideoPlayerController> remapped = {};
      int newKey = 0;
      for (final c in _controllers.values) {
        remapped[newKey] = c;
        newKey++;
      }
      _controllers.clear();
      _controllers.addAll(remapped);

      if (_selectedClipIndex >= _clips.length) {
        _selectedClipIndex = _clips.length - 1;
      }
      if (_playingClipIndex >= _clips.length) {
        _playingClipIndex = 0;
      }
    });

    final currentController = _controllers[_playingClipIndex];
    if (currentController != null && currentController.value.isInitialized) {
      currentController.seekTo(_clips[_playingClipIndex].startTrim);
      if (_isPlaying) currentController.play();
    }
  }

  // --- EXPORT & MERGE (CRASH-PROOF & 720P STANDARDIZED) ---

  Future<void> _processAndExport() async {
    if (_isProcessing || _clips.isEmpty) return;

    setState(() {
      _isProcessing = true;
      _processingProgress = 0.0;
      _processingStatus = 'Hazırlanıyor...';
    });

    try {
      // 1. Pause and release active VideoPlayerControllers & audio player to free Android MediaCodec hardware slots
      _pauseAllControllers();
      await _bgMusicPlayer?.stop();
      for (final c in _controllers.values) {
        await c.pause();
        await c.dispose();
      }
      _controllers.clear();

      await Future.delayed(const Duration(milliseconds: 300));

      setState(() {
        _processingStatus = _clips.length > 1
            ? '${_clips.length} video birleştiriliyor...'
            : 'Video işleniyor...';
        _processingProgress = 0.5;
      });

      final videoPaths = _clips.map((c) => c.file.path).toList();
      final Map<String, int> trimStarts = {};
      final Map<String, int> trimEnds = {};
      final Map<String, int> totalDurations = {};

      for (final clip in _clips) {
        trimStarts[clip.file.path] = clip.startTrim.inMilliseconds;
        trimEnds[clip.file.path] = clip.endTrim.inMilliseconds;
        totalDurations[clip.file.path] = clip.totalDuration.inMilliseconds;
      }

      // Call native crash-proof Media3 video processor
      String? resultPath;
      try {
        resultPath = await _nativeVideoChannel.invokeMethod<String>(
          'mergeAndProcessVideos',
          {
            'videoPaths': videoPaths,
            'isMuted': _isMuted || _videoVolume == 0.0,
            'videoVolume': _isMuted ? 0.0 : _videoVolume,
            'audioTrackPath': _bgMusicFile?.path,
            'audioTrackVolume': _bgMusicVolume,
            'audioTrackStartMs': _bgMusicStartTrim.inMilliseconds,
            'trimStarts': trimStarts,
            'trimEnds': trimEnds,
            'totalDurations': totalDurations,
          },
        );
      } catch (nativeErr) {
        debugPrint('[NATIVE VIDEO PROCESSING ERR] $nativeErr');
        if (_clips.length > 1) {
          rethrow;
        }
      }

      if (_clips.length > 1 && (resultPath == null || !File(resultPath).existsSync())) {
        throw Exception('Videolar birleştirilemedi.');
      }

      final finalVideoPath = (resultPath != null && File(resultPath).existsSync())
          ? resultPath
          : _clips[0].file.path;

      if (!mounted) return;

      Navigator.pop(
        context,
        VideoEditorResult(
          file: File(finalVideoPath),
          caption: _captionController.text.trim(),
        ),
      );
    } catch (e) {
      debugPrint('[VIDEO EXPORT CRASH PREVENTED] $e');
      if (mounted) {
        await _initAllControllers();
        if (!mounted) return;
        setState(() => _isProcessing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Video işlenirken bir hata oluştu: $e'),
            backgroundColor: AppColors.callRed,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedClip = (_clips.isNotEmpty && _selectedClipIndex < _clips.length)
        ? _clips[_selectedClipIndex]
        : null;

    final totalMerged = _totalMergedDuration;
    final currentMerged = _currentMergedPosition;
    final isInitialized = _clips.isNotEmpty &&
        _controllers.containsKey(_playingClipIndex) &&
        _controllers[_playingClipIndex]!.value.isInitialized;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                // Top Bar
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  color: Colors.black87,
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.close_rounded, color: Colors.white, size: 26),
                        onPressed: () => Navigator.pop(context),
                      ),
                      const SizedBox(width: 4),
                      const Text(
                        'Video Düzenle',
                        style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
                      ),
                      const Spacer(),
                      // Prominent Ses & Müzik Labeled Button
                      GestureDetector(
                        onTap: _openAudioMixerSheet,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: _bgMusicFile != null
                                ? AppColors.accent.withValues(alpha: 0.25)
                                : const Color(0xFF1F2C34),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: _bgMusicFile != null ? AppColors.accent : Colors.white30,
                              width: 1.2,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.music_note_rounded,
                                color: _bgMusicFile != null ? AppColors.accent : Colors.white,
                                size: 16,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                _bgMusicFile != null
                                    ? 'Müzik (%${(_bgMusicVolume * 100).round()})'
                                    : '🎵 Ses & Müzik',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      // Mute toggle
                      IconButton(
                        icon: Icon(
                          _isMuted || _videoVolume == 0.0
                              ? Icons.volume_off_rounded
                              : Icons.volume_up_rounded,
                          color: (_isMuted || _videoVolume == 0.0) ? AppColors.callRed : Colors.white,
                          size: 22,
                        ),
                        tooltip: _isMuted ? 'Sesi Aç' : 'Sesi Kapat',
                        onPressed: _toggleMute,
                      ),
                      // Merged Total Duration Badge
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1F2C34),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.white12),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.movie_filter_rounded, color: AppColors.accent, size: 15),
                            const SizedBox(width: 4),
                            Text(
                              '${_formatDuration(currentMerged)} / ${_formatDuration(totalMerged)}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 12.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ),
                ),

                // Unified Continuous Merged Video Player Center Preview (IndexedStack for instant switching)
                Expanded(
                  child: Center(
                    child: isInitialized
                        ? GestureDetector(
                            onTap: _togglePlayPause,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                Builder(
                                  builder: (context) {
                                    final activeController = _controllers[_playingClipIndex];
                                    if (activeController != null && activeController.value.isInitialized) {
                                      return AspectRatio(
                                        aspectRatio: activeController.value.aspectRatio,
                                        child: VideoPlayer(activeController),
                                      );
                                    }
                                    return const SizedBox.shrink();
                                  },
                                ),
                                // Play / Pause Indicator
                                AnimatedOpacity(
                                  opacity: _isPlaying ? 0.0 : 0.85,
                                  duration: const Duration(milliseconds: 200),
                                  child: Container(
                                    padding: const EdgeInsets.all(16),
                                    decoration: BoxDecoration(
                                      color: Colors.black54,
                                      shape: BoxShape.circle,
                                      border: Border.all(color: Colors.white24, width: 2),
                                    ),
                                    child: const Icon(
                                      Icons.play_arrow_rounded,
                                      color: Colors.white,
                                      size: 42,
                                    ),
                                  ),
                                ),
                                // Overlay info: Currently playing clip tag & Floating Music Pill
                                Positioned(
                                  top: 12,
                                  left: 12,
                                  right: 12,
                                  child: Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                        decoration: BoxDecoration(
                                          color: Colors.black.withValues(alpha: 0.7),
                                          borderRadius: BorderRadius.circular(16),
                                          border: Border.all(color: AppColors.accent.withValues(alpha: 0.6)),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(Icons.auto_awesome_motion_rounded,
                                                color: AppColors.accent, size: 14),
                                            const SizedBox(width: 6),
                                            Text(
                                              _clips.length > 1
                                                  ? 'Klip ${_playingClipIndex + 1}/${_clips.length}'
                                                  : 'Önizleme',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 11.5,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const Spacer(),
                                      // FLOATING MUSIC PILL (DIRECTLY ACCESSIBLE OVER VIDEO)
                                      GestureDetector(
                                        onTap: _bgMusicFile == null ? _pickMusic : _openAudioMixerSheet,
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                          decoration: BoxDecoration(
                                            color: _bgMusicFile != null
                                                ? AppColors.accent.withValues(alpha: 0.9)
                                                : Colors.black.withValues(alpha: 0.75),
                                            borderRadius: BorderRadius.circular(16),
                                            border: Border.all(
                                              color: AppColors.accent,
                                              width: 1.2,
                                            ),
                                            boxShadow: [
                                              BoxShadow(
                                                color: AppColors.accent.withValues(alpha: 0.35),
                                                blurRadius: 6,
                                              ),
                                            ],
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                _bgMusicFile != null
                                                    ? Icons.audiotrack_rounded
                                                    : Icons.library_music_rounded,
                                                color: _bgMusicFile != null ? Colors.white : AppColors.accent,
                                                size: 14,
                                              ),
                                              const SizedBox(width: 5),
                                              ConstrainedBox(
                                                constraints: const BoxConstraints(maxWidth: 110),
                                                child: Text(
                                                  _bgMusicFile != null
                                                      ? (_bgMusicName ?? 'Müzik')
                                                      : '🎵 + Müzik Ekle',
                                                  overflow: TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 11.5,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                      if (_clips.length > 1) ...[
                                        const SizedBox(width: 6),
                                        GestureDetector(
                                          onTap: () {
                                            _seekMergedPosition(Duration.zero);
                                            if (!_isPlaying) _togglePlayPause();
                                          },
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF1F2C34).withValues(alpha: 0.9),
                                              borderRadius: BorderRadius.circular(16),
                                              border: Border.all(color: Colors.white24),
                                            ),
                                            child: const Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(Icons.replay_rounded, color: AppColors.accent, size: 14),
                                                SizedBox(width: 4),
                                                Text(
                                                  'Baştan',
                                                  style: TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          )
                        : const CircularProgressIndicator(color: AppColors.accent),
                  ),
                ),

                // UNIFIED MERGED TIMELINE SCRUBBER (Scrub entire merged sequence)
                if (totalMerged.inMilliseconds > 0)
                  Container(
                    color: const Color(0xFF0F171B),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                    child: Row(
                      children: [
                        Text(
                          _formatDuration(currentMerged),
                          style: const TextStyle(color: Colors.white70, fontSize: 11.5),
                        ),
                        Expanded(
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              activeTrackColor: AppColors.accent,
                              inactiveTrackColor: Colors.white24,
                              thumbColor: AppColors.accent,
                              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                              trackHeight: 3,
                            ),
                            child: Slider(
                              min: 0.0,
                              max: totalMerged.inMilliseconds.toDouble(),
                              value: currentMerged.inMilliseconds
                                  .toDouble()
                                  .clamp(0.0, totalMerged.inMilliseconds.toDouble()),
                              onChanged: (val) {
                                _seekMergedPosition(Duration(milliseconds: val.toInt()));
                              },
                            ),
                          ),
                        ),
                        Text(
                          _formatDuration(totalMerged),
                          style: const TextStyle(color: Colors.white70, fontSize: 11.5),
                        ),
                      ],
                    ),
                  ),

                // DIRECT ON-SCREEN AUDIO & MUSIC TOOLBAR (PROMINENT & ALWAYS VISIBLE)
                Container(
                  color: const Color(0xFF141D22),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Header & Quick Presets
                      Row(
                        children: [
                          const Icon(Icons.tune_rounded, color: AppColors.accent, size: 16),
                          const SizedBox(width: 6),
                          const Text(
                            'Ses & Mikser',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 12.5,
                            ),
                          ),
                          const Spacer(),
                          _buildQuickChip('Dengeli %50', () {
                            _setVideoVolume(0.5);
                            _setBgMusicVolume(0.5);
                          }),
                          const SizedBox(width: 4),
                          _buildQuickChip('Müzik %85', () {
                            _setVideoVolume(0.15);
                            _setBgMusicVolume(0.85);
                          }),
                          const SizedBox(width: 4),
                          _buildQuickChip('Sessiz', () {
                            _setVideoVolume(0.0);
                            _setBgMusicVolume(1.0);
                          }),
                        ],
                      ),
                      const SizedBox(height: 4),

                      // Row 1: Ana Video Sesi Slider
                      Row(
                        children: [
                          GestureDetector(
                            onTap: _toggleMute,
                            child: Icon(
                              _isMuted || _videoVolume == 0.0
                                  ? Icons.volume_off_rounded
                                  : Icons.videocam_rounded,
                              color: _isMuted || _videoVolume == 0.0
                                  ? AppColors.callRed
                                  : AppColors.accent,
                              size: 19,
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Text(
                            'Video Sesi:',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 11.5,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Expanded(
                            child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                activeTrackColor: AppColors.accent,
                                inactiveTrackColor: Colors.white24,
                                thumbColor: AppColors.accent,
                                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                                trackHeight: 3,
                              ),
                              child: Slider(
                                min: 0.0,
                                max: 1.0,
                                value: _isMuted ? 0.0 : _videoVolume,
                                onChanged: (val) {
                                  _setVideoVolume(val);
                                },
                              ),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: (_isMuted || _videoVolume == 0.0)
                                  ? AppColors.callRed.withValues(alpha: 0.2)
                                  : AppColors.accent.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              _isMuted || _videoVolume == 0.0
                                  ? 'Sessiz'
                                  : '%${((_isMuted ? 0.0 : _videoVolume) * 100).round()}',
                              style: TextStyle(
                                color: (_isMuted || _videoVolume == 0.0)
                                    ? AppColors.callRed
                                    : AppColors.accent,
                                fontSize: 10.5,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),

                      // Row 2: Arka Plan Müziği
                      if (_bgMusicFile == null)
                        GestureDetector(
                          onTap: _pickMusic,
                          child: Container(
                            margin: const EdgeInsets.only(top: 4),
                            padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 12),
                            decoration: BoxDecoration(
                              color: AppColors.accent.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: AppColors.accent.withValues(alpha: 0.6),
                                width: 1.2,
                              ),
                            ),
                            child: const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.add_circle_outline_rounded,
                                    color: AppColors.accent, size: 16),
                                SizedBox(width: 6),
                                Text(
                                  '➕ Arka Plan Müziği / Ses Parçası Ekle (MP3, M4A)',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      else
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.music_note_rounded,
                                      color: AppColors.accent, size: 18),
                                  const SizedBox(width: 6),
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(maxWidth: 80),
                                    child: Text(
                                      _bgMusicName ?? 'Müzik',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: SliderTheme(
                                      data: SliderTheme.of(context).copyWith(
                                        activeTrackColor: AppColors.accent,
                                        inactiveTrackColor: Colors.white24,
                                        thumbColor: AppColors.accent,
                                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                                        trackHeight: 3,
                                      ),
                                      child: Slider(
                                        min: 0.0,
                                        max: 1.0,
                                        value: _bgMusicVolume,
                                        onChanged: (val) {
                                          _setBgMusicVolume(val);
                                        },
                                      ),
                                    ),
                                  ),
                                  Text(
                                    '%${(_bgMusicVolume * 100).round()}',
                                    style: const TextStyle(
                                      color: AppColors.accent,
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  GestureDetector(
                                    onTap: _pickMusic,
                                    child: const Padding(
                                      padding: EdgeInsets.symmetric(horizontal: 4),
                                      child: Icon(Icons.swap_horiz_rounded,
                                          color: AppColors.accent, size: 18),
                                    ),
                                  ),
                                  GestureDetector(
                                    onTap: _removeMusic,
                                    child: const Padding(
                                      padding: EdgeInsets.symmetric(horizontal: 4),
                                      child: Icon(Icons.close_rounded,
                                          color: AppColors.callRed, size: 18),
                                    ),
                                  ),
                                ],
                              ),
                              Padding(
                                padding: const EdgeInsets.only(top: 3),
                                child: Row(
                                  children: [
                                    const Icon(Icons.content_cut_rounded,
                                        color: AppColors.accent, size: 14),
                                    const SizedBox(width: 4),
                                    Text(
                                      'Kes: ${_formatDuration(_bgMusicStartTrim)} - ${_formatDuration(_bgMusicStartTrim + _totalMergedDuration)}',
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    Expanded(
                                      child: Builder(
                                        builder: (context) {
                                          final maxTrim = _calcMaxMusicStartTrim();
                                          final currentMs = _bgMusicStartTrim.inMilliseconds
                                              .toDouble()
                                              .clamp(0.0, maxTrim > 0 ? maxTrim : 1.0);
                                          return SliderTheme(
                                            data: SliderTheme.of(context).copyWith(
                                              activeTrackColor: AppColors.accent,
                                              inactiveTrackColor: Colors.white24,
                                              thumbColor: AppColors.accent,
                                              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                                              trackHeight: 2.5,
                                            ),
                                            child: Slider(
                                              min: 0.0,
                                              max: maxTrim > 0 ? maxTrim : 1.0,
                                              value: currentMs,
                                              onChanged: maxTrim > 0
                                                  ? (val) {
                                                      _setMusicStartTrim(Duration(milliseconds: val.toInt()), immediate: false);
                                                    }
                                                  : null,
                                              onChangeEnd: maxTrim > 0
                                                  ? (val) {
                                                      _setMusicStartTrim(Duration(milliseconds: val.toInt()), immediate: true);
                                                    }
                                                  : null,
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                    if (_bgMusicTotalDuration > Duration.zero)
                                      Text(
                                        _formatDuration(_bgMusicTotalDuration),
                                        style: const TextStyle(
                                          color: Colors.white38,
                                          fontSize: 10,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),

                // Trimming Timeline Slider for selected clip
                if (selectedClip != null && selectedClip.totalDuration.inMilliseconds > 0)
                  Container(
                    color: const Color(0xFF141D22),
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Selected clip trim info
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.content_cut_rounded, color: AppColors.accent, size: 15),
                                const SizedBox(width: 6),
                                Text(
                                  'Klip ${_selectedClipIndex + 1} Kesme Aralığı:',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                            Text(
                              '${_formatDuration(selectedClip.startTrim)} - ${_formatDuration(selectedClip.endTrim)} (${_formatDuration(selectedClip.trimmedDuration)})',
                              style: const TextStyle(
                                color: AppColors.accent,
                                fontWeight: FontWeight.bold,
                                fontSize: 12.5,
                              ),
                            ),
                          ],
                        ),
                        // Range Slider for In-Out Points
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            activeTrackColor: AppColors.accent,
                            inactiveTrackColor: Colors.white24,
                            thumbColor: Colors.white,
                            rangeThumbShape: const RoundRangeSliderThumbShape(enabledThumbRadius: 8),
                            trackHeight: 4,
                            overlayColor: AppColors.accent.withValues(alpha: 0.2),
                          ),
                          child: Builder(
                            builder: (context) {
                              final maxDur = selectedClip.totalDuration.inMilliseconds.toDouble();
                              final startVal = selectedClip.startTrim.inMilliseconds
                                  .toDouble()
                                  .clamp(0.0, maxDur > 0 ? maxDur : 1.0);
                              final endVal = selectedClip.endTrim.inMilliseconds
                                  .toDouble()
                                  .clamp(startVal, maxDur > 0 ? maxDur : 1.0);

                              return RangeSlider(
                                min: 0.0,
                                max: maxDur > 0 ? maxDur : 1.0,
                                values: RangeValues(startVal, endVal),
                                onChanged: (RangeValues values) {
                                  setState(() {
                                    selectedClip.startTrim = Duration(milliseconds: values.start.toInt());
                                    selectedClip.endTrim = Duration(milliseconds: values.end.toInt());
                                  });
                                  if (_playingClipIndex == _selectedClipIndex) {
                                    _debouncedVideoSeek(_selectedClipIndex, selectedClip.startTrim);
                                  }
                                },
                                onChangeEnd: (RangeValues values) {
                                  if (_playingClipIndex == _selectedClipIndex) {
                                    _videoSeekDebounceTimer?.cancel();
                                    _controllers[_selectedClipIndex]?.seekTo(selectedClip.startTrim);
                                    _bgMusicPlayer?.seek(_bgMusicStartTrim + _currentMergedPosition);
                                  }
                                },
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),

                // Multi-Video Clips Carousel
                Container(
                  color: const Color(0xFF182229),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.layers_rounded, color: AppColors.accent, size: 16),
                              const SizedBox(width: 6),
                              Text(
                                'Birleştirilen Klipler (${_clips.length})',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                          Text(
                            _clips.length > 1
                                ? '▶ Arka arkaya kesintisiz oynatılır'
                                : 'Tek Video',
                            style: const TextStyle(
                                color: AppColors.accent, fontSize: 11.5, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 64,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: _clips.length + 1,
                          separatorBuilder: (_, __) => const SizedBox(width: 8),
                          itemBuilder: (context, idx) {
                            // Add Clip Button
                            if (idx == _clips.length) {
                              return GestureDetector(
                                onTap: _pickAndAddVideo,
                                child: Container(
                                  width: 88,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF1F2C34),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                        color: AppColors.accent.withValues(alpha: 0.6), width: 1.5),
                                  ),
                                  child: const Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.add_circle_outline_rounded,
                                          color: AppColors.accent, size: 22),
                                      SizedBox(height: 4),
                                      Text(
                                        '+ Video Ekle',
                                        style: TextStyle(
                                            color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            }

                            final clip = _clips[idx];
                            final isCurrentPlaying = (idx == _playingClipIndex);
                            final isCurrentSelected = (idx == _selectedClipIndex);

                            return GestureDetector(
                              onTap: () => _selectClipForTrimming(idx),
                              child: Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  Container(
                                    width: 88,
                                    padding: const EdgeInsets.all(6),
                                    decoration: BoxDecoration(
                                      color: isCurrentSelected
                                          ? const Color(0xFF263843)
                                          : const Color(0xFF1F2C34),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: isCurrentPlaying
                                            ? AppColors.accent
                                            : (isCurrentSelected ? Colors.white60 : Colors.white12),
                                        width: isCurrentPlaying ? 2 : 1,
                                      ),
                                    ),
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            if (isCurrentPlaying && _isPlaying)
                                              const Icon(Icons.play_arrow_rounded,
                                                  color: AppColors.accent, size: 14),
                                            Text(
                                              'Klip ${idx + 1}',
                                              style: TextStyle(
                                                color: isCurrentPlaying ? AppColors.accent : Colors.white,
                                                fontWeight: isCurrentPlaying || isCurrentSelected
                                                    ? FontWeight.bold
                                                    : FontWeight.normal,
                                                fontSize: 11.5,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 3),
                                        Text(
                                          _formatDuration(clip.trimmedDuration),
                                          style: TextStyle(
                                            color: isCurrentPlaying ? AppColors.accent : Colors.white70,
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  // Delete clip (X) button if multiple clips
                                  if (_clips.length > 1)
                                    Positioned(
                                      top: -6,
                                      right: -6,
                                      child: GestureDetector(
                                        onTap: () => _removeClip(idx),
                                        child: Container(
                                          padding: const EdgeInsets.all(3),
                                          decoration: const BoxDecoration(
                                            color: AppColors.callRed,
                                            shape: BoxShape.circle,
                                          ),
                                          child: const Icon(Icons.close, color: Colors.white, size: 12),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),

                // Bottom Bar (Caption + Send)
                Container(
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
                  color: Colors.black.withValues(alpha: 0.85),
                  child: Row(
                    children: [
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1F2C34),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: Colors.white12),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.edit_note_rounded, color: AppColors.accent, size: 20),
                              const SizedBox(width: 8),
                              Expanded(
                                child: TextField(
                                  controller: _captionController,
                                  style: const TextStyle(color: Colors.white, fontSize: 14),
                                  decoration: const InputDecoration(
                                    hintText: 'Bir başlık ekleyin...',
                                    hintStyle: TextStyle(color: Colors.white54, fontSize: 14),
                                    border: InputBorder.none,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      // Send FAB
                      GestureDetector(
                        onTap: _isProcessing ? null : _processAndExport,
                        child: Container(
                          width: 48,
                          height: 48,
                          decoration: const BoxDecoration(
                            gradient: AppColors.primaryGradient,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.accent,
                                blurRadius: 8,
                                offset: Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Center(
                            child: _isProcessing
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                  )
                                : const Icon(Icons.send_rounded, color: Colors.white, size: 22),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            // Fullscreen Processing / Merging Overlay
            if (_isProcessing)
              Container(
                color: Colors.black87,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                    margin: const EdgeInsets.symmetric(horizontal: 32),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1F2C34),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: AppColors.accent.withValues(alpha: 0.4)),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.6),
                          blurRadius: 16,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 44,
                          height: 44,
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            color: AppColors.accent,
                          ),
                        ),
                        const SizedBox(height: 18),
                        Text(
                          _processingStatus,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: LinearProgressIndicator(
                            value: _processingProgress.clamp(0.0, 1.0),
                            backgroundColor: Colors.white12,
                            valueColor: const AlwaysStoppedAnimation<Color>(AppColors.accent),
                            minHeight: 6,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '%${(_processingProgress * 100).round()}',
                          style: const TextStyle(
                              color: AppColors.accent, fontSize: 13, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
