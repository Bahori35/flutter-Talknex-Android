import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
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

  void _startCurrentStory() {
    _animController.stop();
    _animController.reset();

    final group = widget.storyGroups[_currentGroupIndex];
    if (_currentStoryIndex < group.stories.length) {
      final story = group.stories[_currentStoryIndex];
      // Mark as viewed
      final viewerId = int.tryParse(widget.currentUser.uid) ?? 0;
      if (viewerId > 0 && story.userId != viewerId) {
        _chatService.markStoryViewed(story.id, viewerId);
      }
      _animController.forward();
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
  }

  void _resumeStory() {
    setState(() {
      _isPaused = false;
    });
    _animController.forward();
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
            // Story Media (Image)
            if (currentStory != null)
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
            if (currentStory != null && currentStory.caption.isNotEmpty)
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
