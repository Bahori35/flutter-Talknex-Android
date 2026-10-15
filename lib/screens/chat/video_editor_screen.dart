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
  Duration _bgMusicEndTrim = Duration.zero;
  int _activeEditorTab = 0; // 0: Video Kırp, 1: Şarkı Kırp, 2: Ses Mikseri

  Duration get _bgMusicTrimmedDuration {
    if (_bgMusicEndTrim <= _bgMusicStartTrim) return Duration.zero;
    return _bgMusicEndTrim - _bgMusicStartTrim;
  }

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
    final musicWindow = _bgMusicTrimmedDuration;
    if (musicWindow > Duration.zero) {
      final offset = targetPos.inMilliseconds % musicWindow.inMilliseconds;
      _bgMusicPlayer?.seek(_bgMusicStartTrim + Duration(milliseconds: offset));
    } else {
      _bgMusicPlayer?.seek(_bgMusicStartTrim);
    }
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
        final musicWindow = _bgMusicTrimmedDuration;
        if (musicWindow > Duration.zero) {
          final offset = _currentMergedPosition.inMilliseconds % musicWindow.inMilliseconds;
          _bgMusicPlayer?.seek(_bgMusicStartTrim + Duration(milliseconds: offset));
        } else {
          _bgMusicPlayer?.seek(_bgMusicStartTrim);
        }
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


  void _setMusicTrimRange(Duration start, Duration end, {bool immediate = false}) {
    setState(() {
      _bgMusicStartTrim = start;
      _bgMusicEndTrim = end;
    });
    final musicWindow = _bgMusicTrimmedDuration;
    final target = _isPlaying
        ? (_bgMusicStartTrim + ((musicWindow.inMilliseconds > 0)
            ? Duration(milliseconds: _currentMergedPosition.inMilliseconds % musicWindow.inMilliseconds)
            : Duration.zero))
        : _bgMusicStartTrim;
    if (immediate) {
      _musicSeekDebounceTimer?.cancel();
      _bgMusicPlayer?.seek(target);
    } else {
      _debouncedMusicSeek(target);
    }
  }

  void _alignMusicWithVideo() {
    if (_bgMusicTotalDuration <= Duration.zero || _totalMergedDuration <= Duration.zero) return;
    setState(() {
      final neededDur = _totalMergedDuration;
      if (_bgMusicStartTrim + neededDur <= _bgMusicTotalDuration) {
        _bgMusicEndTrim = _bgMusicStartTrim + neededDur;
      } else {
        _bgMusicStartTrim = Duration.zero;
        _bgMusicEndTrim = neededDur <= _bgMusicTotalDuration ? neededDur : _bgMusicTotalDuration;
      }
    });
    _setMusicTrimRange(_bgMusicStartTrim, _bgMusicEndTrim, immediate: true);
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

      final defaultEnd = (musicDur > Duration.zero) ? musicDur : const Duration(seconds: 30);
      setState(() {
        _bgMusicFile = pickedFile;
        _bgMusicName = name;
        _bgMusicPlayer = player;
        _bgMusicTotalDuration = musicDur;
        _bgMusicStartTrim = Duration.zero;
        _bgMusicEndTrim = defaultEnd;
        _activeEditorTab = 1; // Direct user to the music trimming tab!
      });

      player.onDurationChanged.listen((d) {
        if (mounted && d > Duration.zero && _bgMusicTotalDuration != d) {
          setState(() {
            _bgMusicTotalDuration = d;
            if (_bgMusicEndTrim == Duration.zero || _bgMusicEndTrim > d) {
              _bgMusicEndTrim = d;
            }
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
      _bgMusicEndTrim = Duration.zero;
      _activeEditorTab = 0;
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
            'audioTrackEndMs': _bgMusicEndTrim.inMilliseconds,
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
      backgroundColor: const Color(0xFF0B1014),
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                // 1. Sleek Glass Header Bar
                _buildHeaderBar(currentMerged, totalMerged),

                // 2. Center Video Canvas Viewport (Rounded studio frame with overlays)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: Center(
                      child: isInitialized
                          ? _buildVideoCanvas(currentMerged, totalMerged)
                          : const Center(
                              child: CircularProgressIndicator(
                                color: AppColors.accent,
                                strokeWidth: 3,
                              ),
                            ),
                    ),
                  ),
                ),

                // 3. Merged Timeline Scrubber
                if (totalMerged.inMilliseconds > 0)
                  _buildMergedTimelineScrubber(currentMerged, totalMerged),

                // 4. Studio Segmented Mode Switcher (Klip Kırp / Şarkı Kırp / Mikser)
                _buildStudioTabBar(),

                // 5. Active Tool Panel (Switches smoothly between tabs)
                Container(
                  color: const Color(0xFF131D24),
                  constraints: const BoxConstraints(minHeight: 110),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    child: _buildActiveTabContent(selectedClip),
                  ),
                ),

                // 6. Multi-Video Clips Carousel
                _buildClipsCarousel(),

                // 7. Bottom Bar (Caption Input + Send FAB)
                _buildBottomBar(),
              ],
            ),

            // Fullscreen Processing Overlay
            if (_isProcessing) _buildProcessingOverlay(),
          ],
        ),
      ),
    );
  }

  // --- UI COMPONENT: HEADER BAR ---
  Widget _buildHeaderBar(Duration currentMerged, Duration totalMerged) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: const BoxDecoration(
        color: Color(0xFF0E161B),
        border: Border(bottom: BorderSide(color: Colors.white10)),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.close_rounded, color: Colors.white, size: 24),
            onPressed: () => Navigator.pop(context),
            tooltip: 'Kapat',
          ),
          const SizedBox(width: 4),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Stüdyo Video Düzenleyici',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.3,
                ),
              ),
              Text(
                '${_clips.length} Klip • ${_formatDuration(totalMerged)}',
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const Spacer(),
          // Mute Toggle Icon Button
          IconButton(
            icon: Icon(
              _isMuted || _videoVolume == 0.0
                  ? Icons.volume_off_rounded
                  : Icons.volume_up_rounded,
              color: (_isMuted || _videoVolume == 0.0) ? AppColors.callRed : Colors.white70,
              size: 22,
            ),
            tooltip: _isMuted ? 'Sesi Aç' : 'Sesi Kapat',
            onPressed: _toggleMute,
          ),
          // Total Duration Pill
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: const Color(0xFF1B2730),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.accent.withValues(alpha: 0.4)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.timer_outlined, color: AppColors.accent, size: 14),
                const SizedBox(width: 4),
                Text(
                  '${_formatDuration(currentMerged)} / ${_formatDuration(totalMerged)}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- UI COMPONENT: VIDEO CANVAS VIEWPORT ---
  Widget _buildVideoCanvas(Duration currentMerged, Duration totalMerged) {
    final activeController = _controllers[_playingClipIndex];
    if (activeController == null || !activeController.value.isInitialized) {
      return const SizedBox.shrink();
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.8),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: GestureDetector(
        onTap: _togglePlayPause,
        child: Stack(
          alignment: Alignment.center,
          children: [
            AspectRatio(
              aspectRatio: activeController.value.aspectRatio,
              child: VideoPlayer(activeController),
            ),

            // Play / Pause Glass Overlay
            AnimatedOpacity(
              opacity: _isPlaying ? 0.0 : 0.9,
              duration: const Duration(milliseconds: 200),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white30, width: 2),
                ),
                child: const Icon(
                  Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 44,
                ),
              ),
            ),

            // Floating Top Overlay (Clip Tag & Music Pill)
            Positioned(
              top: 10,
              left: 10,
              right: 10,
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.75),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppColors.accent.withValues(alpha: 0.5)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.auto_awesome_motion_rounded,
                            color: AppColors.accent, size: 13),
                        const SizedBox(width: 5),
                        Text(
                          _clips.length > 1
                              ? 'Klip ${_playingClipIndex + 1}/${_clips.length}'
                              : 'Önizleme',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  // Floating Music Badge (Tap opens song trim tab)
                  GestureDetector(
                    onTap: () {
                      if (_bgMusicFile == null) {
                        _pickMusic();
                      } else {
                        setState(() => _activeEditorTab = 1);
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: _bgMusicFile != null
                            ? AppColors.accent.withValues(alpha: 0.92)
                            : Colors.black.withValues(alpha: 0.75),
                        borderRadius: BorderRadius.circular(14),
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
                            size: 13,
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
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Floating Bottom Overlay (Quick Replay Button)
            Positioned(
              bottom: 10,
              right: 10,
              child: GestureDetector(
                onTap: () {
                  _seekMergedPosition(Duration.zero);
                  if (!_isPlaying) _togglePlayPause();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.75),
                    borderRadius: BorderRadius.circular(14),
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
            ),
          ],
        ),
      ),
    );
  }

  // --- UI COMPONENT: MERGED TIMELINE SCRUBBER ---
  Widget _buildMergedTimelineScrubber(Duration currentMerged, Duration totalMerged) {
    return Container(
      color: const Color(0xFF0F171B),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      child: Row(
        children: [
          Text(
            _formatDuration(currentMerged),
            style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: AppColors.accent,
                inactiveTrackColor: Colors.white12,
                thumbColor: AppColors.accent,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                trackHeight: 3,
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
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
            style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  // --- UI COMPONENT: STUDIO SEGMENTED MODE SWITCHER ---
  Widget _buildStudioTabBar() {
    return Container(
      color: const Color(0xFF101920),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: _buildStudioTabItem(
              tabIndex: 0,
              icon: Icons.content_cut_rounded,
              label: 'Klip Kırp',
              badgeText: null,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _buildStudioTabItem(
              tabIndex: 1,
              icon: Icons.music_note_rounded,
              label: 'Şarkı Kırp',
              badgeText: _bgMusicFile != null ? 'Aktif' : null,
              hasHighlight: _bgMusicFile != null,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _buildStudioTabItem(
              tabIndex: 2,
              icon: Icons.tune_rounded,
              label: 'Ses Mikseri',
              badgeText: null,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStudioTabItem({
    required int tabIndex,
    required IconData icon,
    required String label,
    String? badgeText,
    bool hasHighlight = false,
  }) {
    final isSelected = _activeEditorTab == tabIndex;
    return GestureDetector(
      onTap: () {
        setState(() => _activeEditorTab = tabIndex);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.accent.withValues(alpha: 0.2)
              : const Color(0xFF18232B),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected
                ? AppColors.accent
                : (hasHighlight ? AppColors.accent.withValues(alpha: 0.4) : Colors.white12),
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 15,
              color: isSelected ? AppColors.accent : (hasHighlight ? AppColors.accent : Colors.white70),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? Colors.white : Colors.white70,
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
              ),
            ),
            if (badgeText != null) ...[
              const SizedBox(width: 5),
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  color: AppColors.accent,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // --- ACTIVE TAB CONTENT DISPATCHER ---
  Widget _buildActiveTabContent(VideoClipItem? selectedClip) {
    switch (_activeEditorTab) {
      case 0:
        return _buildVideoTrimmingPanel(selectedClip);
      case 1:
        return _buildMusicTrimmingPanel();
      case 2:
        return _buildAudioMixerPanel();
      default:
        return _buildVideoTrimmingPanel(selectedClip);
    }
  }

  // --- TAB 0: VIDEO TRIMMING PANEL (DUAL RANGE SLIDER) ---
  Widget _buildVideoTrimmingPanel(VideoClipItem? selectedClip) {
    if (selectedClip == null || selectedClip.totalDuration <= Duration.zero) {
      return const SizedBox(
        height: 110,
        child: Center(
          child: Text('Kırpılacak klip bulunamadı.', style: TextStyle(color: Colors.white54)),
        ),
      );
    }

    final maxDur = selectedClip.totalDuration.inMilliseconds.toDouble();
    final startVal = selectedClip.startTrim.inMilliseconds
        .toDouble()
        .clamp(0.0, maxDur > 0 ? maxDur : 1.0);
    final endVal = selectedClip.endTrim.inMilliseconds
        .toDouble()
        .clamp(startVal, maxDur > 0 ? maxDur : 1.0);

    return Container(
      key: const ValueKey('tab_video_trim'),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
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
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.accent.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.accent.withValues(alpha: 0.4)),
                    ),
                    child: Text(
                      '${_formatDuration(selectedClip.startTrim)} - ${_formatDuration(selectedClip.endTrim)} (${_formatDuration(selectedClip.trimmedDuration)})',
                      style: const TextStyle(
                        color: AppColors.accent,
                        fontWeight: FontWeight.bold,
                        fontSize: 11.5,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        selectedClip.startTrim = Duration.zero;
                        selectedClip.endTrim = selectedClip.totalDuration;
                      });
                      _debouncedVideoSeek(_selectedClipIndex, Duration.zero);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.white12,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        'Sıfırla',
                        style: TextStyle(color: Colors.white70, fontSize: 10.5, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 6),
          // RangeSlider with filmstrip track design
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: AppColors.accent,
              inactiveTrackColor: Colors.white24,
              thumbColor: Colors.white,
              rangeThumbShape: const RoundRangeSliderThumbShape(enabledThumbRadius: 8),
              trackHeight: 5,
              overlayColor: AppColors.accent.withValues(alpha: 0.25),
            ),
            child: RangeSlider(
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
                  final musicWindow = _bgMusicTrimmedDuration;
                  if (musicWindow > Duration.zero) {
                    _bgMusicPlayer?.seek(
                      _bgMusicStartTrim + Duration(
                        milliseconds: _currentMergedPosition.inMilliseconds % musicWindow.inMilliseconds,
                      ),
                    );
                  }
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  // --- TAB 1: MUSIC TRIMMING PANEL (DUAL HANDLE RANGE SLIDER + WAVEFORM) ---
  Widget _buildMusicTrimmingPanel() {
    if (_bgMusicFile == null) {
      return Container(
        key: const ValueKey('tab_music_empty'),
        padding: const EdgeInsets.all(14),
        child: GestureDetector(
          onTap: _pickMusic,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
            decoration: BoxDecoration(
              color: AppColors.accent.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: AppColors.accent.withValues(alpha: 0.6),
                width: 1.2,
              ),
            ),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.library_music_rounded, color: AppColors.accent, size: 22),
                SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '➕ Arka Plan Şarkısı / Ses Parçası Ekle',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'MP3 veya ses seçip baştan ve sondan dilediğiniz gibi kırpın.',
                      style: TextStyle(color: Colors.white54, fontSize: 11),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    final maxMusicDur = _bgMusicTotalDuration.inMilliseconds.toDouble();
    final effectiveMax = maxMusicDur > 0 ? maxMusicDur : 30000.0;
    final startMs = _bgMusicStartTrim.inMilliseconds.toDouble().clamp(0.0, effectiveMax);
    final endMs = (_bgMusicEndTrim > Duration.zero ? _bgMusicEndTrim.inMilliseconds.toDouble() : effectiveMax)
        .clamp(startMs, effectiveMax);

    return Container(
      key: const ValueKey('tab_music_trim_active'),
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header: Song name, duration, Change & Remove buttons
          Row(
            children: [
              const Icon(Icons.audiotrack_rounded, color: AppColors.accent, size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _bgMusicName ?? 'Müzik Parçası',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 12.5,
                  ),
                ),
              ),
              // Videoyla Eşitle Button
              GestureDetector(
                onTap: _alignMusicWithVideo,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.accent.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.accent.withValues(alpha: 0.5)),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.auto_fix_high_rounded, color: AppColors.accent, size: 12),
                      SizedBox(width: 4),
                      Text(
                        'Videoyla Eşitle',
                        style: TextStyle(
                          color: AppColors.accent,
                          fontSize: 10.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),
              // Change song
              GestureDetector(
                onTap: _pickMusic,
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.swap_horiz_rounded, color: Colors.white70, size: 19),
                ),
              ),
              // Delete song
              GestureDetector(
                onTap: _removeMusic,
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.delete_outline_rounded, color: AppColors.callRed, size: 19),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),

          // Simulated Audio Waveform Bar Visualizer
          _buildSimulatedWaveform(
            total: _bgMusicTotalDuration > Duration.zero ? _bgMusicTotalDuration : const Duration(seconds: 30),
            start: _bgMusicStartTrim,
            end: _bgMusicEndTrim > _bgMusicStartTrim ? _bgMusicEndTrim : _bgMusicTotalDuration,
          ),

          // DUAL HANDLE RANGE SLIDER (TRIM FROM BOTH START & END)
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: AppColors.accent,
              inactiveTrackColor: Colors.white24,
              thumbColor: Colors.white,
              rangeThumbShape: const RoundRangeSliderThumbShape(enabledThumbRadius: 8),
              trackHeight: 4,
              overlayColor: AppColors.accent.withValues(alpha: 0.2),
            ),
            child: RangeSlider(
              min: 0.0,
              max: effectiveMax,
              values: RangeValues(startMs, endMs),
              onChanged: (RangeValues values) {
                _setMusicTrimRange(
                  Duration(milliseconds: values.start.toInt()),
                  Duration(milliseconds: values.end.toInt()),
                  immediate: false,
                );
              },
              onChangeEnd: (RangeValues values) {
                _setMusicTrimRange(
                  Duration(milliseconds: values.start.toInt()),
                  Duration(milliseconds: values.end.toInt()),
                  immediate: true,
                );
              },
            ),
          ),

          // Range Duration Info Bar
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Başlangıç: ${_formatDuration(_bgMusicStartTrim)}',
                style: const TextStyle(color: Colors.white70, fontSize: 10.5, fontWeight: FontWeight.bold),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'Kırpılan: ${_formatDuration(_bgMusicTrimmedDuration)}',
                  style: const TextStyle(color: AppColors.accent, fontSize: 10.5, fontWeight: FontWeight.bold),
                ),
              ),
              Text(
                'Bitiş: ${_formatDuration(_bgMusicEndTrim > Duration.zero ? _bgMusicEndTrim : _bgMusicTotalDuration)}',
                style: const TextStyle(color: Colors.white70, fontSize: 10.5, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // Waveform Bar Graphic Visualizer
  Widget _buildSimulatedWaveform({
    required Duration total,
    required Duration start,
    required Duration end,
  }) {
    const int barCount = 38;
    const List<double> wavePattern = [
      0.3, 0.5, 0.8, 0.4, 0.9, 0.6, 0.7, 1.0, 0.85, 0.45, 0.75, 0.95,
      0.65, 0.5, 0.8, 0.9, 0.35, 0.6, 0.75, 1.0, 0.8, 0.55, 0.7, 0.9,
      0.4, 0.65, 0.85, 0.7, 0.5, 0.95, 0.8, 0.6, 0.45, 0.75, 0.9, 0.6, 0.4, 0.7
    ];

    final totalMs = total.inMilliseconds > 0 ? total.inMilliseconds : 1;
    final startRatio = (start.inMilliseconds / totalMs).clamp(0.0, 1.0);
    final endRatio = (end.inMilliseconds / totalMs).clamp(startRatio, 1.0);

    return Container(
      height: 24,
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: List.generate(barCount, (idx) {
          final barRatio = idx / (barCount - 1);
          final inRange = barRatio >= startRatio && barRatio <= endRatio;
          final heightFactor = wavePattern[idx % wavePattern.length];
          return Container(
            width: 3,
            height: (heightFactor * 22).clamp(4.0, 22.0),
            decoration: BoxDecoration(
              color: inRange ? AppColors.accent : Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          );
        }),
      ),
    );
  }

  // --- TAB 2: AUDIO MIXER PANEL (PRESETS & DUAL FADERS) ---
  Widget _buildAudioMixerPanel() {
    return Container(
      key: const ValueKey('tab_mixer'),
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Quick Presets Row
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildPresetChip(
                  label: 'Orijinal Video',
                  icon: Icons.videocam_rounded,
                  isActive: !_isMuted && _videoVolume == 1.0 && (_bgMusicFile == null || _bgMusicVolume == 0.0),
                  onTap: () {
                    _setVideoVolume(1.0);
                    _setBgMusicVolume(0.0);
                  },
                ),
                const SizedBox(width: 8),
                _buildPresetChip(
                  label: 'Dengeli (%50 / %50)',
                  icon: Icons.balance_rounded,
                  isActive: !_isMuted && _videoVolume == 0.5 && _bgMusicVolume == 0.5,
                  onTap: () {
                    _setVideoVolume(0.5);
                    _setBgMusicVolume(0.5);
                  },
                ),
                const SizedBox(width: 8),
                _buildPresetChip(
                  label: 'Müzik %85',
                  icon: Icons.music_note_rounded,
                  isActive: _videoVolume <= 0.2 && _bgMusicVolume >= 0.8,
                  onTap: () {
                    _setVideoVolume(0.15);
                    _setBgMusicVolume(0.85);
                  },
                ),
                const SizedBox(width: 8),
                _buildPresetChip(
                  label: 'Sessiz Video',
                  icon: Icons.volume_off_rounded,
                  isActive: _isMuted || _videoVolume == 0.0,
                  onTap: () {
                    _setVideoVolume(0.0);
                    _setBgMusicVolume(1.0);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),

          // Fader 1: Original Video Volume
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
                  size: 18,
                ),
              ),
              const SizedBox(width: 6),
              const Text(
                'Video Sesi:',
                style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold),
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
              Text(
                _isMuted || _videoVolume == 0.0 ? 'Sessiz' : '%${(_videoVolume * 100).round()}',
                style: TextStyle(
                  color: _isMuted || _videoVolume == 0.0 ? AppColors.callRed : AppColors.accent,
                  fontSize: 10.5,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),

          // Fader 2: Background Music Volume
          Row(
            children: [
              Icon(
                Icons.music_note_rounded,
                color: _bgMusicFile != null ? AppColors.accent : Colors.white30,
                size: 18,
              ),
              const SizedBox(width: 6),
              const Text(
                'Müzik Sesi:',
                style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold),
              ),
              Expanded(
                child: _bgMusicFile != null
                    ? SliderTheme(
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
                      )
                    : Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: GestureDetector(
                          onTap: _pickMusic,
                          child: const Text(
                            '+ Müzik ekleyin',
                            style: TextStyle(color: AppColors.accent, fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
              ),
              if (_bgMusicFile != null)
                Text(
                  '%${(_bgMusicVolume * 100).round()}',
                  style: const TextStyle(
                    color: AppColors.accent,
                    fontSize: 10.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  // --- UI COMPONENT: MULTI-VIDEO CLIPS CAROUSEL ---
  Widget _buildClipsCarousel() {
    return Container(
      color: const Color(0xFF162027),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Icon(Icons.layers_rounded, color: AppColors.accent, size: 15),
                  const SizedBox(width: 6),
                  Text(
                    'Birleştirilen Klipler (${_clips.length})',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              Text(
                _clips.length > 1 ? '▶ Sıralı Kesintisiz Oynatma' : 'Tek Klip',
                style: const TextStyle(color: AppColors.accent, fontSize: 10.5, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 56,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _clips.length + 1,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, idx) {
                // Add Clip Card
                if (idx == _clips.length) {
                  return GestureDetector(
                    onTap: _pickAndAddVideo,
                    child: Container(
                      width: 84,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1B2730),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: AppColors.accent.withValues(alpha: 0.6),
                          width: 1.2,
                        ),
                      ),
                      child: const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.add_circle_outline_rounded,
                              color: AppColors.accent, size: 18),
                          SizedBox(height: 2),
                          Text(
                            '+ Video Ekle',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 10.5,
                              fontWeight: FontWeight.bold,
                            ),
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
                        width: 84,
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                        decoration: BoxDecoration(
                          color: isCurrentSelected
                              ? const Color(0xFF243642)
                              : const Color(0xFF1B2730),
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
                                      color: AppColors.accent, size: 12),
                                Text(
                                  'Klip ${idx + 1}',
                                  style: TextStyle(
                                    color: isCurrentPlaying ? AppColors.accent : Colors.white,
                                    fontWeight: isCurrentPlaying || isCurrentSelected
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _formatDuration(clip.trimmedDuration),
                              style: TextStyle(
                                color: isCurrentPlaying ? AppColors.accent : Colors.white70,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Delete Clip Badge (if > 1 clip)
                      if (_clips.length > 1)
                        Positioned(
                          top: -5,
                          right: -5,
                          child: GestureDetector(
                            onTap: () => _removeClip(idx),
                            child: Container(
                              padding: const EdgeInsets.all(3),
                              decoration: const BoxDecoration(
                                color: AppColors.callRed,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.close, color: Colors.white, size: 11),
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
    );
  }

  // --- UI COMPONENT: BOTTOM ACTION BAR ---
  Widget _buildBottomBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      color: const Color(0xFF0C1318),
      child: Row(
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF1B2730),
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
                      style: const TextStyle(color: Colors.white, fontSize: 13.5),
                      decoration: const InputDecoration(
                        hintText: 'Bir başlık ekleyin...',
                        hintStyle: TextStyle(color: Colors.white54, fontSize: 13.5),
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          // Send Glowing FAB
          GestureDetector(
            onTap: _isProcessing ? null : _processAndExport,
            child: Container(
              width: 46,
              height: 46,
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
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.send_rounded, color: Colors.white, size: 20),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- UI COMPONENT: PROCESSING OVERLAY ---
  Widget _buildProcessingOverlay() {
    return Container(
      color: Colors.black87,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          margin: const EdgeInsets.symmetric(horizontal: 32),
          decoration: BoxDecoration(
            color: const Color(0xFF1B2730),
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
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
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
                  color: AppColors.accent,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
