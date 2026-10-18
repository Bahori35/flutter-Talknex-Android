import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../../../constants/app_colors.dart';
import '../../../models/user_model.dart';
import '../../../services/custom_auth_service.dart';
import '../../../services/custom_chat_service.dart';

class MusicStoryCreator extends StatefulWidget {
  final UserModel currentUser;

  const MusicStoryCreator({super.key, required this.currentUser});

  @override
  State<MusicStoryCreator> createState() => _MusicStoryCreatorState();
}

class _MusicStoryCreatorState extends State<MusicStoryCreator> with SingleTickerProviderStateMixin {
  final GlobalKey _repaintKey = GlobalKey();
  final CustomChatService _chatService = CustomChatService();
  final AudioPlayer _audioPlayer = AudioPlayer();

  File? _selectedAudioFile;
  String _trackTitle = 'Müzik Parçası Seçin';
  String _artistName = 'Cihazınızdan seçin';
  File? _backgroundImage;
  bool _isPlaying = false;
  bool _isLoading = false;

  late AnimationController _rotationController;

  int _selectedGradientIndex = 0;
  final List<List<Color>> _gradients = [
    [const Color(0xFF1a2a6c), const Color(0xFFb21f1f), const Color(0xFFfdbb2d)],
    [const Color(0xFF8A2387), const Color(0xFFE94057)],
    [const Color(0xFF00c6ff), const Color(0xFF0072ff)],
    [const Color(0xFF11998e), const Color(0xFF38ef7d)],
    [const Color(0xFF232526), const Color(0xFF414345)],
  ];

  @override
  void initState() {
    super.initState();
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    );

    _audioPlayer.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() => _isPlaying = false);
        _rotationController.stop();
      }
    });
  }

  Future<void> _pickAudioFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
        allowMultiple: false,
      );

      if (result != null && result.files.single.path != null) {
        final path = result.files.single.path!;
        final name = result.files.single.name;
        final cleanName = name.replaceAll(RegExp(r'\.(mp3|m4a|wav|aac)$', caseSensitive: false), '');

        await _audioPlayer.stop();
        setState(() {
          _selectedAudioFile = File(path);
          _trackTitle = cleanName;
          _artistName = widget.currentUser.displayName;
          _isPlaying = false;
        });
        _rotationController.reset();
      }
    } catch (e) {
      debugPrint('Error picking audio: $e');
    }
  }

  Future<void> _pickBackgroundImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (picked != null) {
      setState(() {
        _backgroundImage = File(picked.path);
      });
    }
  }

  Future<void> _togglePlayPause() async {
    if (_selectedAudioFile == null) return;

    if (_isPlaying) {
      await _audioPlayer.pause();
      _rotationController.stop();
      setState(() => _isPlaying = false);
    } else {
      await _audioPlayer.play(DeviceFileSource(_selectedAudioFile!.path));
      _rotationController.repeat();
      setState(() => _isPlaying = true);
    }
  }

  Future<void> _publishMusicStory() async {
    if (_selectedAudioFile == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Lütfen bir müzik veya ses parçası seçin.'),
          backgroundColor: AppColors.callRed,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      await _audioPlayer.stop();

      // 1. Capture visual story card to image
      final boundary = _repaintKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      String? bgImageUrl;
      if (boundary != null) {
        final ui.Image image = await boundary.toImage(pixelRatio: 2.0);
        final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
        if (byteData != null) {
          final tempDir = await getTemporaryDirectory();
          final bgFile = File('${tempDir.path}/music_story_bg_${DateTime.now().millisecondsSinceEpoch}.png');
          await bgFile.writeAsBytes(byteData.buffer.asUint8List(), flush: true);

          final authService = Provider.of<CustomAuthService>(context, listen: false);
          bgImageUrl = await authService.uploadImage(bgFile.path);
        }
      }

      // 2. Upload audio file
      final authService = Provider.of<CustomAuthService>(context, listen: false);
      final audioUrl = await authService.uploadFile(_selectedAudioFile!.path);

      if (audioUrl == null) throw Exception('Müzik dosyası yüklenemedi');

      // 3. Create story
      final myUid = int.tryParse(widget.currentUser.uid) ?? 0;
      final success = await _chatService.createStory(
        userId: myUid,
        mediaUrl: audioUrl,
        caption: '🎵 $_trackTitle',
        mediaType: 'audio',
      );

      if (!mounted) return;

      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Müzik durumu paylaşıldı!'),
            backgroundColor: AppColors.primaryLight,
            behavior: SnackBarBehavior.floating,
          ),
        );
        Navigator.pop(context, true);
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
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    _rotationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final gradient = _gradients[_selectedGradientIndex];

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Captured Story Screen
          RepaintBoundary(
            key: _repaintKey,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Background (Image or Gradient)
                if (_backgroundImage != null)
                  Image.file(_backgroundImage!, fit: BoxFit.cover)
                else
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: gradient,
                      ),
                    ),
                  ),

                // Dark gradient overlay
                Container(
                  color: Colors.black.withValues(alpha: 0.4),
                ),

                // Center Spinning Vinyl & Music Badge
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Vinyl Disc
                      RotationTransition(
                        turns: _rotationController,
                        child: Container(
                          width: 140,
                          height: 140,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.black,
                            border: Border.all(color: Colors.white24, width: 4),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.5),
                                blurRadius: 20,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          child: Center(
                            child: Container(
                              width: 50,
                              height: 50,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: AppColors.primaryGradient,
                              ),
                              child: const Icon(Icons.music_note_rounded, color: Colors.white, size: 28),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),

                      // Music Track Card
                      Container(
                        margin: const EdgeInsets.symmetric(horizontal: 32),
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.white24),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.audiotrack_rounded, color: AppColors.accent, size: 24),
                            const SizedBox(width: 10),
                            Flexible(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    _trackTitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                                  ),
                                  Text(
                                    _artistName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(color: Colors.white70, fontSize: 12),
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
              ],
            ),
          ),

          // Top Header
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
                    // Change Background image
                    IconButton(
                      icon: const Icon(Icons.image_outlined, color: Colors.white),
                      tooltip: 'Arka Plan Resmi',
                      onPressed: _pickBackgroundImage,
                    ),
                    // Cycle gradient
                    IconButton(
                      icon: const Icon(Icons.palette_rounded, color: Colors.white),
                      tooltip: 'Renk Değiştir',
                      onPressed: () => setState(() => _selectedGradientIndex = (_selectedGradientIndex + 1) % _gradients.length),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Bottom Bar (Pick Music, Play, Send)
          Positioned(
            bottom: 24,
            left: 20,
            right: 20,
            child: SafeArea(
              child: Row(
                children: [
                  // Pick Music Button
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white.withValues(alpha: 0.2),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                        elevation: 0,
                      ),
                      icon: const Icon(Icons.library_music_rounded, color: Colors.white),
                      label: Text(
                        _selectedAudioFile == null ? 'Müzik Seç' : 'Müziği Değiştir',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                      onPressed: _pickAudioFile,
                    ),
                  ),
                  const SizedBox(width: 12),

                  // Play / Pause Preview
                  if (_selectedAudioFile != null) ...[
                    GestureDetector(
                      onTap: _togglePlayPause,
                      child: Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 8),
                          ],
                        ),
                        child: Icon(
                          _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                          color: Colors.black,
                          size: 28,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],

                  // Send Story Button
                  FloatingActionButton(
                    backgroundColor: AppColors.primaryLight,
                    onPressed: _isLoading ? null : _publishMusicStory,
                    child: _isLoading
                        ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : const Icon(Icons.send_rounded, color: Colors.white),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
