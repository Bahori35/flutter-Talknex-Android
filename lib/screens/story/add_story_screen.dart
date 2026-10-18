import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../../constants/app_colors.dart';
import '../../models/user_model.dart';
import '../../services/custom_auth_service.dart';
import '../../services/custom_chat_service.dart';
import '../chat/camera_screen.dart';
import '../chat/photo_editor_screen.dart';
import '../chat/video_editor_screen.dart';
import 'widgets/text_story_creator.dart';
import 'widgets/voice_story_creator.dart';
import 'widgets/layout_story_creator.dart';
import 'widgets/music_story_creator.dart';

enum MediaFilter { all, photos, videos }

class AddStoryScreen extends StatefulWidget {
  final UserModel currentUser;

  const AddStoryScreen({super.key, required this.currentUser});

  @override
  State<AddStoryScreen> createState() => _AddStoryScreenState();
}

class _AddStoryScreenState extends State<AddStoryScreen> {
  final ImagePicker _picker = ImagePicker();
  final CustomChatService _chatService = CustomChatService();

  MediaFilter _currentFilter = MediaFilter.all;
  bool _isLoading = false;
  String _loadingMessage = 'Durum paylaşılıyor...';

  // 1. OPEN CAMERA (Photo or Video)
  Future<void> _openCamera() async {
    final result = await Navigator.push<CameraCaptureResult>(
      context,
      MaterialPageRoute(
        builder: (_) => const CameraScreen(),
      ),
    );

    if (result == null || !mounted) return;

    if (result.isVideo) {
      // Open video editor for captured video
      final editedVideo = await Navigator.push<VideoEditorResult>(
        context,
        MaterialPageRoute(
          builder: (_) => VideoEditorScreen(initialVideoFile: result.file),
        ),
      );
      if (editedVideo != null && mounted) {
        await _publishMediaStory(
          editedVideo.file,
          editedVideo.caption.isNotEmpty ? editedVideo.caption : result.caption,
          isVideo: true,
        );
      } else if (mounted) {
        await _publishMediaStory(result.file, result.caption, isVideo: true);
      }
    } else {
      // Photo taken -> already processed in PhotoEditorScreen inside CameraScreen
      await _publishMediaStory(result.file, result.caption, isVideo: false);
    }
  }

  // 2. OPEN GALLERY FOR PHOTO
  Future<void> _pickPhotoFromGallery() async {
    try {
      final picked = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 90);
      if (picked == null || !mounted) return;

      final editorResult = await Navigator.push<PhotoEditorResult>(
        context,
        MaterialPageRoute(
          builder: (_) => PhotoEditorScreen(imageFile: File(picked.path)),
        ),
      );

      if (editorResult != null && mounted) {
        await _publishMediaStory(editorResult.file, editorResult.caption, isVideo: false);
      }
    } catch (e) {
      debugPrint('Error picking photo: $e');
    }
  }

  // 3. OPEN GALLERY FOR VIDEO
  Future<void> _pickVideoFromGallery() async {
    try {
      final picked = await _picker.pickVideo(source: ImageSource.gallery);
      if (picked == null || !mounted) return;

      final editedVideo = await Navigator.push<VideoEditorResult>(
        context,
        MaterialPageRoute(
          builder: (_) => VideoEditorScreen(initialVideoFile: File(picked.path)),
        ),
      );

      if (editedVideo != null && mounted) {
        await _publishMediaStory(editedVideo.file, editedVideo.caption, isVideo: true);
      } else if (mounted) {
        await _publishMediaStory(File(picked.path), '', isVideo: true);
      }
    } catch (e) {
      debugPrint('Error picking video: $e');
    }
  }

  // 4. MULTI-PHOTO SELECTION
  Future<void> _pickMultiPhotos() async {
    try {
      final pickedList = await _picker.pickMultiImage(imageQuality: 88);
      if (pickedList.isEmpty || !mounted) return;

      for (final xFile in pickedList) {
        await _publishMediaStory(File(xFile.path), '', isVideo: false);
      }
    } catch (e) {
      debugPrint('Error picking multi images: $e');
    }
  }

  // PUBLISH STORY TO SERVER
  Future<void> _publishMediaStory(File file, String caption, {required bool isVideo}) async {
    setState(() {
      _isLoading = true;
      _loadingMessage = isVideo ? 'Video durumu yükleniyor...' : 'Fotoğraf durumu yükleniyor...';
    });

    try {
      final authService = Provider.of<CustomAuthService>(context, listen: false);
      final uploadedUrl = await authService.uploadFile(file.path);

      if (uploadedUrl == null) {
        throw Exception('Dosya sunucuya yüklenemedi');
      }

      final myUid = int.tryParse(widget.currentUser.uid) ?? 0;
      final success = await _chatService.createStory(
        userId: myUid,
        mediaUrl: uploadedUrl,
        caption: caption,
        mediaType: isVideo ? 'video' : 'image',
      );

      if (!mounted) return;

      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(isVideo ? 'Video durumunuz paylaşıldı!' : 'Fotoğraf durumunuz paylaşıldı!'),
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
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // 5. OPEN CREATORS
  Future<void> _openTextCreator() async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => TextStoryCreator(currentUser: widget.currentUser)),
    );
    if (result == true && mounted) Navigator.pop(context, true);
  }

  Future<void> _openMusicCreator() async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => MusicStoryCreator(currentUser: widget.currentUser)),
    );
    if (result == true && mounted) Navigator.pop(context, true);
  }

  Future<void> _openLayoutCreator() async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => LayoutStoryCreator(currentUser: widget.currentUser)),
    );
    if (result == true && mounted) Navigator.pop(context, true);
  }

  Future<void> _openVoiceCreator() async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => VoiceStoryCreator(currentUser: widget.currentUser)),
    );
    if (result == true && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121418),
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Top Drag Handle & Title Bar (Matching WhatsApp Screenshot)
                Center(
                  child: Container(
                    margin: const EdgeInsets.only(top: 8, bottom: 4),
                    width: 38,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.close_rounded, color: Colors.white, size: 26),
                        onPressed: () => Navigator.pop(context),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'Durum ekleyin',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // Action Row (Metin, Müzik, Yerleşim, Ses) - Identical to WhatsApp
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildActionCircle(
                        icon: Icons.edit_rounded,
                        label: 'Metin',
                        onTap: _openTextCreator,
                      ),
                      _buildActionCircle(
                        icon: Icons.music_note_rounded,
                        label: 'Müzik',
                        onTap: _openMusicCreator,
                      ),
                      _buildActionCircle(
                        icon: Icons.dashboard_customize_rounded,
                        label: 'Yerleşim',
                        onTap: _openLayoutCreator,
                      ),
                      _buildActionCircle(
                        icon: Icons.mic_rounded,
                        label: 'Ses',
                        onTap: _openVoiceCreator,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                // Dropdown Header: "Son kullanılanlar ▼"
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                  child: PopupMenuButton<MediaFilter>(
                    color: const Color(0xFF1E2128),
                    offset: const Offset(0, 30),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    onSelected: (val) => setState(() => _currentFilter = val),
                    itemBuilder: (ctx) => [
                      const PopupMenuItem(
                        value: MediaFilter.all,
                        child: Text('Son kullanılanlar (Tümü)', style: TextStyle(color: Colors.white)),
                      ),
                      const PopupMenuItem(
                        value: MediaFilter.photos,
                        child: Text('Fotoğraflar', style: TextStyle(color: Colors.white)),
                      ),
                      const PopupMenuItem(
                        value: MediaFilter.videos,
                        child: Text('Videolar', style: TextStyle(color: Colors.white)),
                      ),
                    ],
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _getFilterLabel(),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(Icons.arrow_drop_down_rounded, color: Colors.white70, size: 24),
                      ],
                    ),
                  ),
                ),

                // Media Grid
                Expanded(
                  child: GridView.count(
                    crossAxisCount: 3,
                    crossAxisSpacing: 3,
                    mainAxisSpacing: 3,
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    children: [
                      // 1. KAMERA TILE (Matching green camera icon in user screenshot)
                      GestureDetector(
                        onTap: _openCamera,
                        child: Container(
                          color: const Color(0xFF181B20),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: const [
                              Icon(
                                Icons.camera_alt_outlined,
                                color: Color(0xFF00D757), // WhatsApp Camera Green
                                size: 36,
                              ),
                              SizedBox(height: 8),
                              Text(
                                'Kamera',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      // 2. FOTOĞRAF GALERİSİ TILE
                      if (_currentFilter != MediaFilter.videos)
                        GestureDetector(
                          onTap: _pickPhotoFromGallery,
                          child: Container(
                            color: const Color(0xFF181B20),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: const [
                                Icon(
                                  Icons.photo_library_outlined,
                                  color: AppColors.accent,
                                  size: 36,
                                ),
                                SizedBox(height: 8),
                                Text(
                                  'Fotoğraf',
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),

                      // 3. VİDEO GALERİSİ TILE
                      if (_currentFilter != MediaFilter.photos)
                        GestureDetector(
                          onTap: _pickVideoFromGallery,
                          child: Container(
                            color: const Color(0xFF181B20),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: const [
                                Icon(
                                  Icons.videocam_outlined,
                                  color: Color(0xFFFF5252),
                                  size: 38,
                                ),
                                SizedBox(height: 8),
                                Text(
                                  'Video',
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),

                      // Quick Helper Tiles to pick specific types
                      _buildQuickActionTile(
                        icon: Icons.edit_note_rounded,
                        title: 'Metin Yaz',
                        color: Colors.purpleAccent,
                        onTap: _openTextCreator,
                      ),
                      _buildQuickActionTile(
                        icon: Icons.mic_external_on_rounded,
                        title: 'Ses Kaydet',
                        color: Colors.orangeAccent,
                        onTap: _openVoiceCreator,
                      ),
                      _buildQuickActionTile(
                        icon: Icons.auto_awesome_mosaic_rounded,
                        title: 'Kolaj Yap',
                        color: Colors.tealAccent,
                        onTap: _openLayoutCreator,
                      ),
                    ],
                  ),
                ),
              ],
            ),

            // Bottom Right Floating Multi-Select Button (WhatsApp style album icon)
            Positioned(
              bottom: 24,
              right: 20,
              child: GestureDetector(
                onTap: _pickMultiPhotos,
                child: Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: const Color(0xFF262A34),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white24, width: 1.5),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.4),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.collections_rounded,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
              ),
            ),

            // Loading Overlay
            if (_isLoading)
              Container(
                color: Colors.black87,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(color: AppColors.primaryLight),
                      const SizedBox(height: 16),
                      Text(
                        _loadingMessage,
                        style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
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

  String _getFilterLabel() {
    switch (_currentFilter) {
      case MediaFilter.photos:
        return 'Fotoğraflar';
      case MediaFilter.videos:
        return 'Videolar';
      case MediaFilter.all:
      default:
        return 'Son kullanılanlar';
    }
  }

  Widget _buildActionCircle({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: const Color(0xFF232730),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white12, width: 1),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2),
                  blurRadius: 6,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Icon(icon, color: Colors.white, size: 24),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickActionTile({
    required IconData icon,
    required String title,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        color: const Color(0xFF181B20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 34),
            const SizedBox(height: 8),
            Text(
              title,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
