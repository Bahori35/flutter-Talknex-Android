import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:video_player/video_player.dart';
import 'package:audioplayers/audioplayers.dart';
import '../../constants/app_colors.dart';
import '../../models/story_model.dart';
import '../../models/user_model.dart';
import '../../services/custom_chat_service.dart';
import '../../widgets/app_avatar.dart';

class StoryViewScreen extends StatefulWidget {
  final List<UserStoryGroup> storyGroups;
  final int initialGroupIndex;
  final UserModel currentUser;
  final VoidCallback? onStoryDeletedOrUpdated;

  const StoryViewScreen({
    super.key,
    required this.storyGroups,
    required this.initialGroupIndex,
    required this.currentUser,
    this.onStoryDeletedOrUpdated,
  });

  @override
  State<StoryViewScreen> createState() => _StoryViewScreenState();
}

class _StoryViewScreenState extends State<StoryViewScreen> with SingleTickerProviderStateMixin {
  late PageController _pageController;
  late int _currentGroupIndex;
  int _currentStoryIndex = 0;
  late AnimationController _animController;
  final CustomChatService _chatService = CustomChatService();
  bool _isPaused = false;

  VideoPlayerController? _videoController;
  AudioPlayer? _audioPlayer;
  bool _isVideoLoading = false;

  @override
  void initState() {
    super.initState();
    _currentGroupIndex = widget.initialGroupIndex;
    _pageController = PageController(initialPage: _currentGroupIndex);

    _animController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    );

    _animController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _nextStory();
      }
    });

    _startCurrentStory();
  }

  Future<void> _disposeMediaControllers() async {
    try {
      await _videoController?.pause();
      await _videoController?.dispose();
    } catch (_) {}
    _videoController = null;

    try {
      await _audioPlayer?.stop();
      await _audioPlayer?.dispose();
    } catch (_) {}
    _audioPlayer = null;
  }

  Future<void> _startCurrentStory() async {
    _animController.stop();
    _animController.reset();

    await _disposeMediaControllers();

    final group = widget.storyGroups[_currentGroupIndex];
    if (_currentStoryIndex < group.stories.length) {
      final story = group.stories[_currentStoryIndex];

      // Mark as viewed
      final viewerId = int.tryParse(widget.currentUser.uid) ?? 0;
      if (viewerId > 0 && story.userId != viewerId) {
        _chatService.markStoryViewed(story.id, viewerId);
      }

      final isVideo = story.mediaType == 'video' || story.mediaUrl.endsWith('.mp4');
      final isAudio = story.mediaType == 'audio' || story.mediaUrl.endsWith('.m4a') || story.mediaUrl.endsWith('.mp3');

      if (isVideo) {
        setState(() => _isVideoLoading = true);
        try {
          final uri = Uri.parse(story.mediaUrl);
          _videoController = VideoPlayerController.networkUrl(uri);
          await _videoController!.initialize();
          final duration = _videoController!.value.duration;
          _animController.duration = duration > Duration.zero ? duration : const Duration(seconds: 10);
          await _videoController!.play();
          if (mounted) setState(() => _isVideoLoading = false);
        } catch (e) {
          debugPrint('Story video error: $e');
          _animController.duration = const Duration(seconds: 5);
          if (mounted) setState(() => _isVideoLoading = false);
        }
      } else if (isAudio) {
        try {
          _audioPlayer = AudioPlayer();
          _animController.duration = const Duration(seconds: 15);
          await _audioPlayer!.play(UrlSource(story.mediaUrl));
          _audioPlayer!.onDurationChanged.listen((dur) {
            if (mounted && dur > Duration.zero) {
              _animController.duration = dur;
            }
          });
        } catch (e) {
          debugPrint('Story audio error: $e');
          _animController.duration = const Duration(seconds: 5);
        }
      } else {
        _animController.duration = const Duration(seconds: 5);
      }

      if (mounted) {
        _animController.forward();
      }
    }
  }

  void _nextStory() {
    final group = widget.storyGroups[_currentGroupIndex];
    if (_currentStoryIndex < group.stories.length - 1) {
      setState(() {
        _currentStoryIndex++;
      });
      _startCurrentStory();
    } else {
      // Go to next user's story group
      if (_currentGroupIndex < widget.storyGroups.length - 1) {
        setState(() {
          _currentGroupIndex++;
          _currentStoryIndex = 0;
        });
        _pageController.animateToPage(
          _currentGroupIndex,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
        _startCurrentStory();
      } else {
        // Finished all stories
        Navigator.pop(context);
      }
    }
  }

  void _prevStory() {
    if (_currentStoryIndex > 0) {
      setState(() {
        _currentStoryIndex--;
      });
      _startCurrentStory();
    } else {
      // Go to previous user's story group
      if (_currentGroupIndex > 0) {
        setState(() {
          _currentGroupIndex--;
          _currentStoryIndex = widget.storyGroups[_currentGroupIndex].stories.length - 1;
        });
        _pageController.animateToPage(
          _currentGroupIndex,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
        _startCurrentStory();
      } else {
        _startCurrentStory();
      }
    }
  }

  void _pauseStory() {
    setState(() {
      _isPaused = true;
    });
    _animController.stop();
    _videoController?.pause();
    _audioPlayer?.pause();
  }

  void _resumeStory() {
    setState(() {
      _isPaused = false;
    });
    _animController.forward();
    _videoController?.play();
    _audioPlayer?.resume();
  }

  void _deleteStory(StoryItem story) async {
    _pauseStory();
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Hikayeyi Sil', style: TextStyle(color: AppColors.textPrimary)),
        content: const Text('Bu hikayeyi silmek istediğinize emin misiniz?', style: TextStyle(color: AppColors.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('İptal', style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sil', style: TextStyle(color: AppColors.callRed, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      final myId = int.tryParse(widget.currentUser.uid) ?? 0;
      await _chatService.deleteStory(story.id, myId);
      widget.onStoryDeletedOrUpdated?.call();
      if (!mounted) return;
      Navigator.pop(context);
    } else {
      _resumeStory();
    }
  }

  String _formatTimeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'Az önce';
    if (diff.inMinutes < 60) return '${diff.inMinutes} dakika önce';
    if (diff.inHours < 24) return '${diff.inHours} saat önce';
    return '${diff.inDays} gün önce';
  }

  @override
  void dispose() {
    _disposeMediaControllers();
    _animController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentGroup = widget.storyGroups[_currentGroupIndex];
    final stories = currentGroup.stories;
    final currentStory = stories.isNotEmpty && _currentStoryIndex < stories.length
        ? stories[_currentStoryIndex]
        : null;

    final isMyStory = currentGroup.userId.toString() == widget.currentUser.uid;
    final isVideo = currentStory != null && (currentStory.mediaType == 'video' || currentStory.mediaUrl.endsWith('.mp4'));
    final isAudio = currentStory != null && (currentStory.mediaType == 'audio' || currentStory.mediaUrl.endsWith('.m4a') || currentStory.mediaUrl.endsWith('.mp3'));

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onLongPressStart: (_) => _pauseStory(),
        onLongPressEnd: (_) => _resumeStory(),
        onTapUp: (details) {
          final width = MediaQuery.of(context).size.width;
          if (details.globalPosition.dx < width / 3) {
            _prevStory();
          } else {
            _nextStory();
          }
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 1. VIDEO STORY
            if (currentStory != null && isVideo) ...[
              if (_videoController != null && _videoController!.value.isInitialized)
                Center(
                  child: AspectRatio(
                    aspectRatio: _videoController!.value.aspectRatio,
                    child: VideoPlayer(_videoController!),
                  ),
                )
              else
                const Center(child: CircularProgressIndicator(color: AppColors.primaryLight)),
            ]
            // 2. AUDIO / MUSIC / VOICE STORY
            else if (currentStory != null && isAudio) ...[
              Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF8A2387), Color(0xFFE94057), Color(0xFFF27121)],
                  ),
                ),
                child: Center(
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 32),
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.music_note_rounded, color: Colors.white, size: 54),
                        const SizedBox(height: 16),
                        Text(
                          currentStory.caption.isNotEmpty ? currentStory.caption : 'Sesli Durum',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: List.generate(12, (idx) {
                            return Container(
                              width: 3.5,
                              height: (12.0 + (idx % 3 == 0 ? 24 : 10)),
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
            ]
            // 3. IMAGE / TEXT / COLLAGE STORY
            else if (currentStory != null) ...[
              Center(
                child: CachedNetworkImage(
                  imageUrl: currentStory.mediaUrl,
                  fit: BoxFit.contain,
                  placeholder: (context, url) => const Center(
                    child: CircularProgressIndicator(color: AppColors.primaryLight),
                  ),
                  errorWidget: (context, url, error) => const Center(
                    child: Icon(Icons.broken_image, color: Colors.white54, size: 64),
                  ),
                ),
              ),
            ],

            // Top Gradient Overlay for readability
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                height: 140,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withOpacity(0.85),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),

            // Bottom Gradient for Caption
            if (currentStory != null && currentStory.caption.isNotEmpty && !isAudio)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 30),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Colors.black.withOpacity(0.9),
                        Colors.transparent,
                      ],
                    ),
                  ),
                  child: Text(
                    currentStory.caption,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      shadows: [
                        Shadow(blurRadius: 4, color: Colors.black),
                      ],
                    ),
                  ),
                ),
              ),

            // Progress Indicators & Header
            SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Progress Bars
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    child: Row(
                      children: List.generate(stories.length, (index) {
                        return Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2.0),
                            child: AnimatedBuilder(
                              animation: _animController,
                              builder: (context, child) {
                                double value = 0.0;
                                if (index < _currentStoryIndex) {
                                  value = 1.0;
                                } else if (index == _currentStoryIndex) {
                                  value = _animController.value;
                                }
                                return LinearProgressIndicator(
                                  value: value,
                                  backgroundColor: Colors.white.withOpacity(0.3),
                                  valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                                  minHeight: 3.0,
                                );
                              },
                            ),
                          ),
                        );
                      }),
                    ),
                  ),

                  // User Info Header
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: Row(
                      children: [
                        AppAvatar(
                          radius: 20,
                          imageUrl: currentGroup.userPhotoUrl,
                          name: currentGroup.displayName,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                isMyStory ? 'Benim Durumum' : currentGroup.displayName,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                              ),
                              if (currentStory != null)
                                Text(
                                  _formatTimeAgo(currentStory.createdAt),
                                  style: TextStyle(
                                    color: Colors.white.withOpacity(0.75),
                                    fontSize: 12,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        if (isMyStory && currentStory != null) ...[
                          Row(
                            children: [
                              const Icon(Icons.remove_red_eye, color: Colors.white70, size: 16),
                              const SizedBox(width: 4),
                              Text(
                                '${currentStory.viewCount}',
                                style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline, color: Colors.white70),
                            onPressed: () => _deleteStory(currentStory),
                          ),
                        ],
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white, size: 26),
                          onPressed: () => Navigator.pop(context),
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
    );
  }
}
