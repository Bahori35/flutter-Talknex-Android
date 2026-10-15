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
  int _selectedClipIndex = 0;

  VideoPlayerController? _activeController;
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
      _selectedClipIndex = 0;
    });

    await _initControllerForCurrentClip();
  }

  Future<void> _initControllerForCurrentClip() async {
    final oldController = _activeController;
    _activeController = null;
    await oldController?.pause();
    await oldController?.dispose();

    if (_clips.isEmpty || _selectedClipIndex >= _clips.length) return;

    final currentClip = _clips[_selectedClipIndex];
    final controller = VideoPlayerController.file(currentClip.file);

    try {
      await controller.initialize();
      controller.setVolume(_isMuted ? 0.0 : 1.0);
      controller.setLooping(false);

      if (currentClip.totalDuration == Duration.zero) {
        currentClip.totalDuration = controller.value.duration;
        currentClip.endTrim = controller.value.duration;
      }

      controller.addListener(() {
        if (!mounted || _activeController != controller) return;
        final pos = controller.value.position;
        if (pos >= currentClip.endTrim) {
          controller.seekTo(currentClip.startTrim);
          if (!_isPlaying) {
            controller.pause();
          }
        }
        setState(() {});
      });

      await controller.seekTo(currentClip.startTrim);

      if (mounted) {
        setState(() {
          _activeController = controller;
          _isPlaying = false;
        });
      }
    } catch (e) {
      debugPrint('[VIDEO CONTROLLER INIT ERR] $e');
    }
  }

  @override
  void dispose() {
    _activeController?.dispose();
    _captionController.dispose();
    super.dispose();
  }

  Duration get _totalMergedDuration {
    Duration total = Duration.zero;
    for (final c in _clips) {
      total += c.trimmedDuration;
    }
    return total;
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
    if (_activeController == null) return;
    setState(() {
      if (_activeController!.value.isPlaying) {
        _activeController!.pause();
        _isPlaying = false;
      } else {
        final currentClip = _clips[_selectedClipIndex];
        if (_activeController!.value.position >= currentClip.endTrim) {
          _activeController!.seekTo(currentClip.startTrim);
        }
        _activeController!.play();
        _isPlaying = true;
      }
    });
  }

  void _toggleMute() {
    setState(() {
      _isMuted = !_isMuted;
      _activeController?.setVolume(_isMuted ? 0.0 : 1.0);
    });
  }

  Future<void> _switchActiveClip(int index) async {
    if (index == _selectedClipIndex && _activeController != null) return;
    setState(() {
      _selectedClipIndex = index;
    });
    await _initControllerForCurrentClip();
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

      setState(() {
        _clips.add(newClip);
        _selectedClipIndex = _clips.length - 1;
      });

      await _initControllerForCurrentClip();
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
    setState(() {
      _clips.removeAt(index);
      if (_selectedClipIndex >= _clips.length) {
        _selectedClipIndex = _clips.length - 1;
      }
    });
    _initControllerForCurrentClip();
  }

  // --- EXPORT & MERGE ---

  Future<void> _processAndExport() async {
    if (_isProcessing || _clips.isEmpty) return;

    setState(() {
      _isProcessing = true;
      _processingProgress = 0.0;
      _processingStatus = 'Hazırlanıyor...';
    });

    try {
      _activeController?.pause();
      final tempDir = await getTemporaryDirectory();

      List<String> processedClipPaths = [];

      // Step 1: Trim each clip if necessary
      for (int i = 0; i < _clips.length; i++) {
        final clip = _clips[i];
        final startMs = clip.startTrim.inMilliseconds;
        final endMs = clip.endTrim.inMilliseconds;
        final totalMs = clip.totalDuration.inMilliseconds;

        final isTrimmed = (startMs > 100 || (totalMs - endMs) > 100);

        setState(() {
          _processingStatus = 'Klip ${i + 1}/${_clips.length} işleniyor...';
          _processingProgress = (i / (_clips.length + 1)) * 0.7;
        });

        if (isTrimmed) {
          final outTrimPath = p.join(
            tempDir.path,
            'trim_${i}_${DateTime.now().millisecondsSinceEpoch}.mp4',
          );

          final builder = VideoEditorBuilder(videoPath: clip.file.path)
              .trim(startTimeMs: startMs, endTimeMs: endMs);

          final resultPath = await builder.export(outputPath: outTrimPath);
          processedClipPaths.add(resultPath ?? clip.file.path);
        } else {
          processedClipPaths.add(clip.file.path);
        }
      }

      String finalVideoPath;

      // Step 2: Merge if multiple clips, or apply mute
      if (processedClipPaths.length > 1) {
        setState(() {
          _processingStatus = '${processedClipPaths.length} video birleştiriliyor...';
          _processingProgress = 0.75;
        });

        final outMergePath = p.join(
          tempDir.path,
          'merged_${DateTime.now().millisecondsSinceEpoch}.mp4',
        );

        var mergeBuilder = VideoEditorBuilder(videoPath: processedClipPaths[0])
            .merge(otherVideoPaths: processedClipPaths.sublist(1));

        if (_isMuted) {
          mergeBuilder = mergeBuilder.removeAudio();
        }

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
        // Only 1 clip
        if (_isMuted) {
          final outMutePath = p.join(
            tempDir.path,
            'muted_${DateTime.now().millisecondsSinceEpoch}.mp4',
          );
          final muteResult = await VideoEditorBuilder(videoPath: processedClipPaths[0])
              .removeAudio()
              .export(outputPath: outMutePath);
          finalVideoPath = muteResult ?? processedClipPaths[0];
        } else {
          finalVideoPath = processedClipPaths[0];
        }
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
      debugPrint('[VIDEO EXPORT ERR] $e');
      if (mounted) {
        // Fallback: If merge fails for some unexpected device reason, send first clip
        if (_clips.isNotEmpty) {
          Navigator.pop(
            context,
            VideoEditorResult(
              file: _clips.first.file,
              caption: _captionController.text.trim(),
            ),
          );
        } else {
          setState(() => _isProcessing = false);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentClip = (_clips.isNotEmpty && _selectedClipIndex < _clips.length)
        ? _clips[_selectedClipIndex]
        : null;

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
                      // Duration badge
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
                            const Icon(Icons.timer_outlined, color: AppColors.accent, size: 15),
                            const SizedBox(width: 4),
                            Text(
                              _formatDuration(_totalMergedDuration),
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ),
                ),

                // Video Player Center Preview
                Expanded(
                  child: Center(
                    child: _activeController != null && _activeController!.value.isInitialized
                        ? GestureDetector(
                            onTap: _togglePlayPause,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                AspectRatio(
                                  aspectRatio: _activeController!.value.aspectRatio,
                                  child: VideoPlayer(_activeController!),
                                ),
                                // Center Play / Pause Icon Button
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
                              ],
                            ),
                          )
                        : const CircularProgressIndicator(color: AppColors.accent),
                  ),
                ),

                // Trimming Timeline Slider for selected clip
                if (currentClip != null && currentClip.totalDuration.inMilliseconds > 0)
                  Container(
                    color: const Color(0xFF121B20),
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Trim info row
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.content_cut_rounded, color: AppColors.accent, size: 16),
                                const SizedBox(width: 6),
                                Text(
                                  'Klip ${_selectedClipIndex + 1} Kesme Aralığı:',
                                  style: const TextStyle(color: Colors.white70, fontSize: 12.5),
                                ),
                              ],
                            ),
                            Text(
                              '${_formatDuration(currentClip.startTrim)} - ${_formatDuration(currentClip.endTrim)} (${_formatDuration(currentClip.trimmedDuration)})',
                              style: const TextStyle(
                                color: AppColors.accent,
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                        // Range Slider
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            activeTrackColor: AppColors.accent,
                            inactiveTrackColor: Colors.white24,
                            thumbColor: Colors.white,
                            rangeThumbShape: const RoundRangeSliderThumbShape(enabledThumbRadius: 9),
                            trackHeight: 4,
                            overlayColor: AppColors.accent.withOpacity(0.2),
                          ),
                          child: RangeSlider(
                            min: 0.0,
                            max: currentClip.totalDuration.inMilliseconds.toDouble(),
                            values: RangeValues(
                              currentClip.startTrim.inMilliseconds.toDouble().clamp(0.0, currentClip.totalDuration.inMilliseconds.toDouble()),
                              currentClip.endTrim.inMilliseconds.toDouble().clamp(0.0, currentClip.totalDuration.inMilliseconds.toDouble()),
                            ),
                            onChanged: (RangeValues values) {
                              setState(() {
                                currentClip.startTrim = Duration(milliseconds: values.start.toInt());
                                currentClip.endTrim = Duration(milliseconds: values.end.toInt());
                              });
                              _activeController?.seekTo(currentClip.startTrim);
                            },
                          ),
                        ),
                      ],
                    ),
                  ),

                // Multi-Video Clips Carousel (Birleştirilecek Videolar)
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
                                'Birleştirilecek Videolar (${_clips.length})',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                          Text(
                            _clips.length > 1 ? 'Sırayla Birleştirilecek' : 'Tek Video',
                            style: const TextStyle(color: Colors.white54, fontSize: 11.5),
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
                            // Add Clip Card
                            if (idx == _clips.length) {
                              return GestureDetector(
                                onTap: _pickAndAddVideo,
                                child: Container(
                                  width: 85,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF1F2C34),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(color: AppColors.accent.withOpacity(0.6), width: 1.5),
                                  ),
                                  child: const Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.add_circle_outline_rounded, color: AppColors.accent, size: 22),
                                      SizedBox(height: 4),
                                      Text(
                                        '+ Video Ekle',
                                        style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            }

                            final clip = _clips[idx];
                            final isSel = idx == _selectedClipIndex;

                            return GestureDetector(
                              onTap: () => _switchActiveClip(idx),
                              child: Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  Container(
                                    width: 85,
                                    padding: const EdgeInsets.all(6),
                                    decoration: BoxDecoration(
                                      color: isSel ? const Color(0xFF263843) : const Color(0xFF1F2C34),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: isSel ? AppColors.accent : Colors.white12,
                                        width: isSel ? 2 : 1,
                                      ),
                                    ),
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                          Icons.movie_creation_outlined,
                                          color: isSel ? AppColors.accent : Colors.white70,
                                          size: 20,
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          'Klip ${idx + 1}',
                                          style: TextStyle(
                                            color: isSel ? Colors.white : Colors.white70,
                                            fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                                            fontSize: 11.5,
                                          ),
                                        ),
                                        Text(
                                          _formatDuration(clip.trimmedDuration),
                                          style: const TextStyle(
                                            color: AppColors.accent,
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  // Remove clip (X) button if multiple clips
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
                  color: Colors.black.withOpacity(0.85),
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
                      border: Border.all(color: AppColors.accent.withOpacity(0.4)),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.6),
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
                          style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
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
                          style: const TextStyle(color: AppColors.accent, fontSize: 13, fontWeight: FontWeight.bold),
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
