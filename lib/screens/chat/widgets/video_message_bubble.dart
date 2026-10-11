import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../../../constants/app_colors.dart';
import '../../../services/encryption_service.dart';
import '../video_player_screen.dart';

class VideoMessageBubble extends StatefulWidget {
  final String videoUrl;
  final String title;
  final String senderId;
  final String receiverId;

  const VideoMessageBubble({
    super.key,
    required this.videoUrl,
    required this.title,
    required this.senderId,
    required this.receiverId,
  });

  @override
  State<VideoMessageBubble> createState() => _VideoMessageBubbleState();
}

class _VideoMessageBubbleState extends State<VideoMessageBubble> {
  // Global memory cache of extracted video files, controllers, and durations
  static final Map<String, String> _cachedFilePaths = {};
  static final Map<String, String> _cachedDurations = {};
  static final Map<String, VideoPlayerController> _persistentControllers = {};

  VideoPlayerController? _controller;
  String _durationText = '';
  bool _isProcessing = true;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _loadOrGenerateThumbnail();
  }

  @override
  void didUpdateWidget(covariant VideoMessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoUrl != widget.videoUrl) {
      _controller = null;
      _durationText = '';
      _isProcessing = true;
      _hasError = false;
      _loadOrGenerateThumbnail();
    }
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    if (duration.inHours > 0) {
      return '${twoDigits(duration.inHours)}:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  Future<void> _loadOrGenerateThumbnail() async {
    final url = widget.videoUrl;

    // 1. Check if controller already exists in memory pool
    if (_persistentControllers.containsKey(url)) {
      final existingController = _persistentControllers[url]!;
      if (existingController.value.isInitialized) {
        if (mounted) {
          setState(() {
            _controller = existingController;
            _durationText = _cachedDurations[url] ?? _formatDuration(existingController.value.duration);
            _isProcessing = false;
          });
        }
        return;
      }
    }

    // 2. Check local memory/disk file cache (e.g. sender's original file or downloaded file)
    String? localFilePath = _cachedFilePaths[url];
    String? cachedDuration = _cachedDurations[url];

    if (localFilePath == null || !File(localFilePath).existsSync()) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final savedFile = prefs.getString('vfile_${url.hashCode}');
        final savedDur = prefs.getString('vdur_${url.hashCode}');
        if (savedFile != null && File(savedFile).existsSync()) {
          localFilePath = savedFile;
          _cachedFilePaths[url] = savedFile;
        }
        if (savedDur != null && savedDur.isNotEmpty) {
          cachedDuration = savedDur;
          _cachedDurations[url] = savedDur;
        }
      } catch (e) {
        debugPrint('[PREF CACHE CHECK ERR] $e');
      }
    }

    // If local file is found on phone storage, initialize directly from disk with ZERO network usage!
    if (localFilePath != null && File(localFilePath).existsSync()) {
      try {
        final fileController = VideoPlayerController.file(File(localFilePath));
        await fileController.initialize();
        _persistentControllers[url] = fileController;
        final dur = cachedDuration ?? _formatDuration(fileController.value.duration);
        _cachedDurations[url] = dur;

        if (mounted) {
          setState(() {
            _controller = fileController;
            _durationText = dur;
            _isProcessing = false;
          });
        }
        return;
      } catch (e) {
        debugPrint('[LOCAL FILE CONTROLLER ERR] $e');
      }
    }

    // 3. For remote URL: download first or initialize controller once and cache locally
    try {
      // Try to save remote file into persistent app directory so subsequent opens read from disk
      VideoPlayerController controller;
      
      try {
        final dir = await getApplicationDocumentsDirectory();
        final cacheDir = Directory(p.join(dir.path, 'video_cache'));
        if (!cacheDir.existsSync()) {
          cacheDir.createSync(recursive: true);
        }
        final cachedTargetFile = File(p.join(cacheDir.path, '${url.hashCode}.mp4'));
        
        if (cachedTargetFile.existsSync() && cachedTargetFile.lengthSync() > 0) {
          controller = VideoPlayerController.file(cachedTargetFile);
          await controller.initialize();
          _cachedFilePaths[url] = cachedTargetFile.path;
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('vfile_${url.hashCode}', cachedTargetFile.path);
        } else {
          // Download encrypted file from server, then decrypt locally
          final uri = Uri.parse(url);
          final rawEncryptedFile = File(p.join(cacheDir.path, '${url.hashCode}.enc'));
          final res = await HttpClient().getUrl(uri).then((req) => req.close());
          if (res.statusCode == 200) {
            final sink = rawEncryptedFile.openWrite();
            await res.pipe(sink);
            await EndToEndEncryptionService.decryptFile(
              rawEncryptedFile,
              widget.senderId,
              widget.receiverId,
              cachedTargetFile.path,
            );
            try {
              if (await rawEncryptedFile.exists()) await rawEncryptedFile.delete();
            } catch (_) {}

            controller = VideoPlayerController.file(cachedTargetFile);
            await controller.initialize();
            _cachedFilePaths[url] = cachedTargetFile.path;
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('vfile_${url.hashCode}', cachedTargetFile.path);
          } else {
            // Fallback
            controller = VideoPlayerController.networkUrl(uri);
            await controller.initialize();
          }
        }
      } catch (err) {
        debugPrint('[VIDEO CACHE/DECRYPT ERR] $err');
        final uri = Uri.parse(url);
        controller = VideoPlayerController.networkUrl(uri);
        await controller.initialize();
      }

      _controller = controller;
      _persistentControllers[url] = controller;

      if (controller.value.duration.inSeconds > 1) {
        await controller.seekTo(const Duration(seconds: 1));
      }

      final durText = _formatDuration(controller.value.duration);
      _cachedDurations[url] = durText;

      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('vdur_${url.hashCode}', durText);
      } catch (_) {}

      if (mounted) {
        setState(() {
          _durationText = durText;
          _isProcessing = false;
        });
      }
    } catch (e) {
      debugPrint('[VIDEO THUMB INITIALIZE ERR] $e');
      if (mounted) {
        setState(() {
          _hasError = true;
          _isProcessing = false;
        });
      }
    }
  }

  @override
  void dispose() {
    // Keep initialized controller in memory pool so scrolling/re-entering does not re-fetch
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => VideoPlayerScreen(
              videoUrl: widget.videoUrl,
              title: widget.title,
              senderId: widget.senderId,
              receiverId: widget.receiverId,
            ),
          ),
        );
      },
      child: Container(
        height: 210,
        width: double.infinity,
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          alignment: Alignment.center,
          fit: StackFit.expand,
          children: [
            // Display video frame from initialized controller
            if (_controller != null && _controller!.value.isInitialized)
              FittedBox(
                fit: BoxFit.cover,
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  width: _controller!.value.size.width > 0 ? _controller!.value.size.width : 300,
                  height: _controller!.value.size.height > 0 ? _controller!.value.size.height : 200,
                  child: VideoPlayer(_controller!),
                ),
              )
            else if (_hasError)
              Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFF1F1C2C), Color(0xFF928DAB)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: const Center(
                  child: Icon(Icons.movie_creation_outlined, color: Colors.white38, size: 48),
                ),
              )
            else
              Container(
                color: Colors.black26,
                child: const Center(
                  child: CircularProgressIndicator(color: AppColors.accent, strokeWidth: 2),
                ),
              ),

            // Semi-transparent dark overlay for high contrast
            Container(
              color: Colors.black.withOpacity(0.28),
            ),

            // Center Play Button with glass glow
            Center(
              child: Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black.withOpacity(0.55),
                  border: Border.all(color: Colors.white.withOpacity(0.8), width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.4),
                      blurRadius: 12,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 36),
              ),
            ),

            // Duration badge at bottom right
            if (_durationText.isNotEmpty)
              Positioned(
                bottom: 8,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.75),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.videocam_rounded, color: Colors.white, size: 12),
                      const SizedBox(width: 4),
                      Text(
                        _durationText,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // Top left video badge
            Positioned(
              top: 8,
              left: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.65),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.play_circle_filled_rounded, color: AppColors.accent, size: 12),
                    SizedBox(width: 4),
                    Text(
                      'Video',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
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
