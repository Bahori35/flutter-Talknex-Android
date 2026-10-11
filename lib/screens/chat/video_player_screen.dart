import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../../constants/app_colors.dart';

class VideoPlayerScreen extends StatefulWidget {
  final String videoUrl;
  final String title;
  final String senderId;
  final String receiverId;

  const VideoPlayerScreen({
    super.key,
    required this.videoUrl,
    this.title = 'Video',
    this.senderId = '',
    this.receiverId = '',
  });

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  late VideoPlayerController _videoPlayerController;
  ChewieController? _chewieController;
  bool _hasError = false;
  String _errorMessage = '';

  @override
  void initState() {
    super.initState();
    _initializePlayer();
  }

  Future<void> _initializePlayer() async {
    try {
      final url = widget.videoUrl;
      File? localVideoFile;

      // 1. Check if user already has the local file path saved
      try {
        final prefs = await SharedPreferences.getInstance();
        final savedPath = prefs.getString('vfile_${url.hashCode}');
        if (savedPath != null && File(savedPath).existsSync()) {
          localVideoFile = File(savedPath);
        }
      } catch (_) {}

      // 2. Check standard persistent video_cache directory
      if (localVideoFile == null) {
        try {
          final dir = await getApplicationDocumentsDirectory();
          final cacheFile = File(p.join(dir.path, 'video_cache', '${url.hashCode}.mp4'));
          if (cacheFile.existsSync() && cacheFile.lengthSync() > 0) {
            localVideoFile = cacheFile;
          }
        } catch (_) {}
      }

      // 3. Initialize from local file (0 network usage) or stream via network
      if (localVideoFile != null && localVideoFile.existsSync()) {
        _videoPlayerController = VideoPlayerController.file(localVideoFile);
      } else {
        final uri = Uri.parse(url);
        _videoPlayerController = VideoPlayerController.networkUrl(uri);
      }

      await _videoPlayerController.initialize();

      _chewieController = ChewieController(
        videoPlayerController: _videoPlayerController,
        autoPlay: true,
        looping: false,
        aspectRatio: _videoPlayerController.value.aspectRatio > 0
            ? _videoPlayerController.value.aspectRatio
            : 16 / 9,
        materialProgressColors: ChewieProgressColors(
          playedColor: AppColors.accent,
          handleColor: AppColors.primaryLight,
          backgroundColor: Colors.white24,
          bufferedColor: Colors.white38,
        ),
        placeholder: Container(
          color: Colors.black,
          child: const Center(
            child: CircularProgressIndicator(color: AppColors.accent),
          ),
        ),
        autoInitialize: true,
        errorBuilder: (context, errorMessage) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                'Video oynatılırken bir hata oluştu:\n$errorMessage',
                style: const TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
            ),
          );
        },
      );

      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      debugPrint('[VIDEO PLAYER ERR] $e');
      if (mounted) {
        setState(() {
          _hasError = true;
          _errorMessage = e.toString();
        });
      }
    }
  }

  @override
  void dispose() {
    _chewieController?.dispose();
    _videoPlayerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          widget.title,
          style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: _hasError
              ? Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.error_outline_rounded, color: AppColors.callRed, size: 50),
                      const SizedBox(height: 12),
                      const Text(
                        'Video Yüklenemedi',
                        style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _errorMessage,
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                )
              : _chewieController != null && _chewieController!.videoPlayerController.value.isInitialized
                  ? Chewie(controller: _chewieController!)
                  : const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CircularProgressIndicator(color: AppColors.accent),
                        SizedBox(height: 14),
                        Text(
                          'Video yükleniyor...',
                          style: TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                      ],
                    ),
        ),
      ),
    );
  }
}
