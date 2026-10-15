import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:easy_video_editor/easy_video_editor.dart';
import '../../constants/app_colors.dart';

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
        controller.setVolume(_isMuted ? 0.0 : 1.0);
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

  void _onControllerTick(int clipIndex) {
    if (!mounted || clipIndex != _playingClipIndex) return;
    final controller = _controllers[clipIndex];
    if (controller == null || !controller.value.isInitialized) return;

    final pos = controller.value.position;
    final clip = _clips[clipIndex];

    // Transition smoothly to next clip when current clip reaches endTrim or finishes
    final bool reachedEnd = pos >= clip.endTrim ||
        controller.value.isCompleted ||
        (clip.trimmedDuration > const Duration(milliseconds: 300) &&
            pos > clip.startTrim &&
            (clip.endTrim - pos).inMilliseconds <= 80);

    if (reachedEnd) {
      if (_isPlaying) {
        int nextIndex = clipIndex + 1;
        if (nextIndex >= _clips.length) {
          nextIndex = 0; // Loop back to start
        }
        _transitionToClip(nextIndex);
      } else {
        controller.seekTo(clip.startTrim);
        controller.pause();
      }
    }
    setState(() {});
  }

  void _transitionToClip(int nextIndex) {
    final currentController = _controllers[_playingClipIndex];
    currentController?.pause();
    currentController?.seekTo(_clips[_playingClipIndex].startTrim);

    _playingClipIndex = nextIndex;
    _selectedClipIndex = nextIndex; // Follow along on trimming & carousel

    final nextController = _controllers[nextIndex];
    if (nextController != null && nextController.value.isInitialized) {
      nextController.seekTo(_clips[nextIndex].startTrim);
      if (_isPlaying) {
        nextController.play();
      }
    }
    setState(() {});
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    _captionController.dispose();
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
          final currentClip = _clips[_playingClipIndex];
          if (activeController.value.position >= currentClip.endTrim) {
            activeController.seekTo(currentClip.startTrim);
          }
          activeController.play();
        }
      } else {
        _pauseAllControllers();
      }
    });
  }

  void _pauseAllControllers() {
    for (final c in _controllers.values) {
      if (c.value.isPlaying) c.pause();
    }
  }

  void _toggleMute() {
    setState(() {
      _isMuted = !_isMuted;
      for (final c in _controllers.values) {
        c.setVolume(_isMuted ? 0.0 : 1.0);
      }
    });
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
      // 1. Pause and release active VideoPlayerControllers to free Android MediaCodec hardware slots
      _pauseAllControllers();
      for (final c in _controllers.values) {
        await c.pause();
        await c.dispose();
      }
      _controllers.clear();

      await Future.delayed(const Duration(milliseconds: 250));

      final tempDir = await getTemporaryDirectory();
      List<String> processedClipPaths = [];

      // 2. Trim and standardize each clip to 720p (guarantees identical resolution/codecs for MediaMuxer)
      for (int i = 0; i < _clips.length; i++) {
        final clip = _clips[i];
        final startMs = clip.startTrim.inMilliseconds;
        final endMs = clip.endTrim.inMilliseconds;
        final totalMs = clip.totalDuration.inMilliseconds;

        setState(() {
          _processingStatus = 'Klip ${i + 1}/${_clips.length} hazırlanıyor...';
          _processingProgress = (i / (_clips.length + 1)) * 0.7;
        });

        final outTrimPath = p.join(
          tempDir.path,
          'std_clip_${i}_${DateTime.now().millisecondsSinceEpoch}.mp4',
        );

        final safeStart = (startMs >= 0 && (totalMs == 0 || startMs < totalMs)) ? startMs : 0;
        final safeEnd = (endMs > safeStart)
            ? (totalMs > 0 && endMs > totalMs ? totalMs : endMs)
            : (totalMs > 0 ? totalMs : safeStart + 1000);

        final bool needsTrim = safeStart > 100 || (totalMs > 0 && safeEnd < totalMs - 100);

        var builder = VideoEditorBuilder(videoPath: clip.file.path);
        if (needsTrim) {
          builder = builder.trim(startTimeMs: safeStart, endTimeMs: safeEnd);
        }
        builder = builder.compress(resolution: VideoResolution.p720);

        if (_isMuted) {
          builder = builder.removeAudio();
        }

        final resultPath = await builder.export(
          outputPath: outTrimPath,
          onProgress: (p) {
            if (mounted) {
              final base = (i / (_clips.length + 1)) * 0.7;
              final seg = (1.0 / (_clips.length + 1)) * 0.7;
              setState(() {
                _processingProgress = base + (seg * p);
              });
            }
          },
        );

        processedClipPaths.add(resultPath ?? clip.file.path);
      }

      String finalVideoPath;

      // 3. Merge clips if multiple, or finalize single clip
      if (processedClipPaths.length > 1) {
        setState(() {
          _processingStatus = '${processedClipPaths.length} video birleştiriliyor...';
          _processingProgress = 0.75;
        });

        final outMergePath = p.join(
          tempDir.path,
          'final_merged_${DateTime.now().millisecondsSinceEpoch}.mp4',
        );

        var mergeBuilder = VideoEditorBuilder(videoPath: processedClipPaths[0])
            .merge(otherVideoPaths: processedClipPaths.sublist(1));

        final mergeResult = await mergeBuilder.export(
          outputPath: outMergePath,
          onProgress: (p) {
            if (mounted) {
              setState(() {
                _processingProgress = 0.75 + (p * 0.24);
              });
            }
          },
        );

        finalVideoPath = mergeResult ?? processedClipPaths[0];
      } else {
        // Single clip
        finalVideoPath = processedClipPaths[0];
      }

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
                      // Mute toggle
                      IconButton(
                        icon: Icon(
                          _isMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                          color: _isMuted ? AppColors.callRed : Colors.white,
                          size: 24,
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
                                IndexedStack(
                                  index: _playingClipIndex.clamp(0, _clips.length - 1),
                                  children: [
                                    for (int i = 0; i < _clips.length; i++)
                                      Center(
                                        child: _controllers.containsKey(i) &&
                                                _controllers[i]!.value.isInitialized
                                            ? AspectRatio(
                                                aspectRatio: _controllers[i]!.value.aspectRatio,
                                                child: VideoPlayer(_controllers[i]!),
                                              )
                                            : const SizedBox.shrink(),
                                      ),
                                  ],
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
                                // Overlay info: Currently playing clip tag & Quick Replay
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
                                                  ? 'Birleşik Önizleme: Klip ${_playingClipIndex + 1}/${_clips.length}'
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
                                      if (_clips.length > 1)
                                        GestureDetector(
                                          onTap: () {
                                            _seekMergedPosition(Duration.zero);
                                            if (!_isPlaying) _togglePlayPause();
                                          },
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
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
                                                  'Baştan Oynat',
                                                  style: TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 11.5,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
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
                          child: RangeSlider(
                            min: 0.0,
                            max: selectedClip.totalDuration.inMilliseconds.toDouble(),
                            values: RangeValues(
                              selectedClip.startTrim.inMilliseconds
                                  .toDouble()
                                  .clamp(0.0, selectedClip.totalDuration.inMilliseconds.toDouble()),
                              selectedClip.endTrim.inMilliseconds
                                  .toDouble()
                                  .clamp(0.0, selectedClip.totalDuration.inMilliseconds.toDouble()),
                            ),
                            onChanged: (RangeValues values) {
                              setState(() {
                                selectedClip.startTrim = Duration(milliseconds: values.start.toInt());
                                selectedClip.endTrim = Duration(milliseconds: values.end.toInt());
                              });
                              if (_playingClipIndex == _selectedClipIndex) {
                                _controllers[_selectedClipIndex]?.seekTo(selectedClip.startTrim);
                              }
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
