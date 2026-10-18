import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
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

class GalleryMediaItem {
  final String path;
  final bool isVideo;
  final int durationMs;
  final String bucketName;

  GalleryMediaItem({
    required this.path,
    required this.isVideo,
    this.durationMs = 0,
    this.bucketName = '',
  });
}

class AlbumCategory {
  final String id;
  final String name;
  final int count;
  final String? coverPath;
  final IconData icon;

  AlbumCategory({
    required this.id,
    required this.name,
    required this.count,
    this.coverPath,
    required this.icon,
  });
}

class AddStoryScreen extends StatefulWidget {
  final UserModel currentUser;

  const AddStoryScreen({super.key, required this.currentUser});

  @override
  State<AddStoryScreen> createState() => _AddStoryScreenState();
}

class _AddStoryScreenState extends State<AddStoryScreen> {
  static const MethodChannel _galleryChannel = MethodChannel('com.safechat.app/gallery');
  final ImagePicker _picker = ImagePicker();
  final CustomChatService _chatService = CustomChatService();

  List<GalleryMediaItem> _allMedia = [];
  List<GalleryMediaItem> _filteredMedia = [];
  String _selectedAlbumId = 'all';
  String _selectedAlbumName = 'Son kullanılanlar';

  bool _isLoadingGallery = true;
  bool _isPublishing = false;
  String _publishingMessage = 'Durum paylaşılıyor...';

  @override
  void initState() {
    super.initState();
    _loadDeviceGalleryMedia();
  }

  Future<void> _loadDeviceGalleryMedia() async {
    setState(() => _isLoadingGallery = true);

    try {
      // 1. Request permissions
      if (Platform.isAndroid) {
        await [
          Permission.photos,
          Permission.videos,
          Permission.storage,
        ].request();
      }

      // 2. Fetch from native MediaStore via method channel
      final List<dynamic>? rawList = await _galleryChannel.invokeListMethod('getGalleryMedia', {'limit': 400});
      final List<GalleryMediaItem> items = [];

      if (rawList != null && rawList.isNotEmpty) {
        for (final entry in rawList) {
          if (entry is Map) {
            final p = entry['path']?.toString();
            if (p != null && File(p).existsSync()) {
              items.add(GalleryMediaItem(
                path: p,
                isVideo: entry['isVideo'] == true,
                durationMs: (entry['durationMs'] as num?)?.toInt() ?? 0,
                bucketName: entry['bucketName']?.toString() ?? '',
              ));
            }
          }
        }
      }

      // 3. Fallback: scan common storage paths if MediaStore returned empty
      if (items.isEmpty && Platform.isAndroid) {
        final commonDirs = [
          {'path': '/storage/emulated/0/DCIM/Camera', 'bucket': 'Camera'},
          {'path': '/storage/emulated/0/Pictures', 'bucket': 'Pictures'},
          {'path': '/storage/emulated/0/Download', 'bucket': 'Download'},
          {'path': '/storage/emulated/0/Movies', 'bucket': 'Movies'},
        ];

        for (final cDir in commonDirs) {
          final dir = Directory(cDir['path']!);
          if (dir.existsSync()) {
            try {
              final files = dir.listSync().whereType<File>().toList();
              for (final f in files) {
                final lower = f.path.toLowerCase();
                if (lower.endsWith('.jpg') || lower.endsWith('.jpeg') || lower.endsWith('.png') || lower.endsWith('.webp')) {
                  items.add(GalleryMediaItem(path: f.path, isVideo: false, bucketName: cDir['bucket']!));
                } else if (lower.endsWith('.mp4') || lower.endsWith('.mkv') || lower.endsWith('.mov')) {
                  items.add(GalleryMediaItem(path: f.path, isVideo: true, bucketName: cDir['bucket']!));
                }
                if (items.length >= 250) break;
              }
            } catch (_) {}
          }
          if (items.length >= 250) break;
        }
      }

      if (mounted) {
        setState(() {
          _allMedia = items;
          _filteredMedia = items;
          _isLoadingGallery = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading gallery: $e');
      if (mounted) {
        setState(() => _isLoadingGallery = false);
      }
    }
  }

  List<AlbumCategory> _buildAlbumList() {
    final List<AlbumCategory> albums = [];

    // 1. Son kullanılanlar (All)
    albums.add(AlbumCategory(
      id: 'all',
      name: 'Son kullanılanlar',
      count: _allMedia.length,
      coverPath: _allMedia.isNotEmpty ? _allMedia.first.path : null,
      icon: Icons.history_rounded,
    ));

    // 2. Kamera
    final cameraItems = _allMedia.where((m) {
      final b = m.bucketName.toLowerCase();
      final p = m.path.toLowerCase();
      return b == 'camera' || b == 'kamera' || p.contains('/dcim/camera');
    }).toList();
    if (cameraItems.isNotEmpty) {
      albums.add(AlbumCategory(
        id: 'camera',
        name: 'Kamera',
        count: cameraItems.length,
        coverPath: cameraItems.first.path,
        icon: Icons.photo_camera_rounded,
      ));
    }

    // 3. İndirilenler (Downloads)
    final downloadItems = _allMedia.where((m) {
      final b = m.bucketName.toLowerCase();
      final p = m.path.toLowerCase();
      return b == 'download' || b == 'downloads' || b == 'indirilenler' || p.contains('/download');
    }).toList();
    if (downloadItems.isNotEmpty) {
      albums.add(AlbumCategory(
        id: 'downloads',
        name: 'İndirilenler',
        count: downloadItems.length,
        coverPath: downloadItems.first.path,
        icon: Icons.download_rounded,
      ));
    }

    // 4. Videolar
    final videoItems = _allMedia.where((m) => m.isVideo).toList();
    if (videoItems.isNotEmpty) {
      albums.add(AlbumCategory(
        id: 'videos',
        name: 'Videolar',
        count: videoItems.length,
        coverPath: videoItems.first.path,
        icon: Icons.videocam_rounded,
      ));
    }

    // 5. Ekran Görüntüleri
    final screenshotItems = _allMedia.where((m) {
      final b = m.bucketName.toLowerCase();
      final p = m.path.toLowerCase();
      return b.contains('screenshot') || p.contains('screenshot') || b.contains('ekran');
    }).toList();
    if (screenshotItems.isNotEmpty) {
      albums.add(AlbumCategory(
        id: 'screenshots',
        name: 'Ekran Görüntüleri',
        count: screenshotItems.length,
        coverPath: screenshotItems.first.path,
        icon: Icons.screenshot_rounded,
      ));
    }

    // 6. WhatsApp Medyaları
    final waItems = _allMedia.where((m) {
      final b = m.bucketName.toLowerCase();
      final p = m.path.toLowerCase();
      return b.contains('whatsapp') || p.contains('whatsapp');
    }).toList();
    if (waItems.isNotEmpty) {
      albums.add(AlbumCategory(
        id: 'whatsapp',
        name: 'WhatsApp',
        count: waItems.length,
        coverPath: waItems.first.path,
        icon: Icons.chat_bubble_outline_rounded,
      ));
    }

    // 7. Other custom folders
    final handledIds = {'all', 'camera', 'downloads', 'videos', 'screenshots', 'whatsapp'};
    final Map<String, List<GalleryMediaItem>> otherBuckets = {};
    for (final item in _allMedia) {
      final b = item.bucketName.trim();
      if (b.isNotEmpty && !handledIds.contains(b.toLowerCase()) && b.toLowerCase() != 'other' && b.toLowerCase() != 'diğer') {
        otherBuckets.putIfAbsent(b, () => []).add(item);
      }
    }

    otherBuckets.forEach((bucketName, bItems) {
      albums.add(AlbumCategory(
        id: 'bucket_$bucketName',
        name: bucketName,
        count: bItems.length,
        coverPath: bItems.first.path,
        icon: Icons.folder_outlined,
      ));
    });

    return albums;
  }

  void _selectAlbum(AlbumCategory album) {
    setState(() {
      _selectedAlbumId = album.id;
      _selectedAlbumName = album.name;

      if (album.id == 'all') {
        _filteredMedia = _allMedia;
      } else if (album.id == 'camera') {
        _filteredMedia = _allMedia.where((m) {
          final b = m.bucketName.toLowerCase();
          final p = m.path.toLowerCase();
          return b == 'camera' || b == 'kamera' || p.contains('/dcim/camera');
        }).toList();
      } else if (album.id == 'downloads') {
        _filteredMedia = _allMedia.where((m) {
          final b = m.bucketName.toLowerCase();
          final p = m.path.toLowerCase();
          return b == 'download' || b == 'downloads' || b == 'indirilenler' || p.contains('/download');
        }).toList();
      } else if (album.id == 'videos') {
        _filteredMedia = _allMedia.where((m) => m.isVideo).toList();
      } else if (album.id == 'screenshots') {
        _filteredMedia = _allMedia.where((m) {
          final b = m.bucketName.toLowerCase();
          final p = m.path.toLowerCase();
          return b.contains('screenshot') || p.contains('screenshot') || b.contains('ekran');
        }).toList();
      } else if (album.id == 'whatsapp') {
        _filteredMedia = _allMedia.where((m) {
          final b = m.bucketName.toLowerCase();
          final p = m.path.toLowerCase();
          return b.contains('whatsapp') || p.contains('whatsapp');
        }).toList();
      } else if (album.id.startsWith('bucket_')) {
        final bName = album.id.substring(7);
        _filteredMedia = _allMedia.where((m) => m.bucketName == bName).toList();
      }
    });
  }

  void _showAlbumBottomSheet() {
    final albums = _buildAlbumList();

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E2128),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Sheet Drag Handle
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 10, bottom: 8),
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Albümler',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const Divider(color: Colors.white12, height: 1),

              // Album List
              Expanded(
                child: ListView.builder(
                  itemCount: albums.length,
                  itemBuilder: (context, idx) {
                    final album = albums[idx];
                    final isSelected = album.id == _selectedAlbumId;

                    return ListTile(
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: album.coverPath != null && File(album.coverPath!).existsSync()
                            ? Image.file(
                                File(album.coverPath!),
                                width: 44,
                                height: 44,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => Container(
                                  width: 44,
                                  height: 44,
                                  color: Colors.white12,
                                  child: Icon(album.icon, color: Colors.white70),
                                ),
                              )
                            : Container(
                                width: 44,
                                height: 44,
                                color: Colors.white12,
                                child: Icon(album.icon, color: Colors.white70),
                              ),
                      ),
                      title: Text(
                        album.name,
                        style: TextStyle(
                          color: isSelected ? AppColors.accent : Colors.white,
                          fontSize: 15,
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                        ),
                      ),
                      subtitle: Text(
                        '${album.count} öğe',
                        style: const TextStyle(color: Colors.white54, fontSize: 13),
                      ),
                      trailing: isSelected
                          ? const Icon(Icons.check_circle_rounded, color: AppColors.accent, size: 22)
                          : null,
                      onTap: () {
                        Navigator.pop(ctx);
                        _selectAlbum(album);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // 1. OPEN CAMERA
  Future<void> _openCamera() async {
    final result = await Navigator.push<CameraCaptureResult>(
      context,
      MaterialPageRoute(
        builder: (_) => const CameraScreen(),
      ),
    );

    if (result == null || !mounted) return;

    if (result.isVideo) {
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
      await _publishMediaStory(result.file, result.caption, isVideo: false);
    }
  }

  // 2. TAP A GALLERY PHOTO ITEM
  Future<void> _onTapPhotoItem(String filePath) async {
    final editorResult = await Navigator.push<PhotoEditorResult>(
      context,
      MaterialPageRoute(
        builder: (_) => PhotoEditorScreen(imageFile: File(filePath)),
      ),
    );

    if (editorResult != null && mounted) {
      await _publishMediaStory(editorResult.file, editorResult.caption, isVideo: false);
    }
  }

  // 3. TAP A GALLERY VIDEO ITEM
  Future<void> _onTapVideoItem(String filePath) async {
    final editedVideo = await Navigator.push<VideoEditorResult>(
      context,
      MaterialPageRoute(
        builder: (_) => VideoEditorScreen(initialVideoFile: File(filePath)),
      ),
    );

    if (editedVideo != null && mounted) {
      await _publishMediaStory(editedVideo.file, editedVideo.caption, isVideo: true);
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
      _isPublishing = true;
      _publishingMessage = isVideo ? 'Video durumu yükleniyor...' : 'Fotoğraf durumu yükleniyor...';
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
      if (mounted) setState(() => _isPublishing = false);
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

  String _formatDuration(int ms) {
    final sec = (ms / 1000).round();
    final m = sec ~/ 60;
    final s = (sec % 60).toString().padLeft(2, '0');
    return '$m:$s';
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
                // Top Drag Handle & Title Bar (WhatsApp Style)
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
                const SizedBox(height: 10),

                // Top Action Buttons (Metin, Müzik, Yerleşim, Ses) - Preserved
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
                const SizedBox(height: 14),

                // Album Selector Header: "Son kullanılanlar ▼" / "İndirilenler ▼" (WhatsApp style)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                  child: GestureDetector(
                    onTap: _showAlbumBottomSheet,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _selectedAlbumName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16.5,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(
                          Icons.keyboard_arrow_down_rounded,
                          color: Colors.white70,
                          size: 24,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 6),

                // Gallery Grid (Top Left: Camera, Remaining: Filtered Device Photos & Videos)
                Expanded(
                  child: _isLoadingGallery
                      ? const Center(
                          child: CircularProgressIndicator(color: AppColors.primaryLight),
                        )
                      : GridView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: 3,
                            mainAxisSpacing: 3,
                          ),
                          // 1st item is always Camera, rest are filtered gallery media
                          itemCount: 1 + _filteredMedia.length,
                          itemBuilder: (context, index) {
                            // 1. TOP-LEFT CAMERA TILE (index 0)
                            if (index == 0) {
                              return GestureDetector(
                                onTap: _openCamera,
                                child: Container(
                                  color: const Color(0xFF181B20),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: const [
                                      Icon(
                                        Icons.camera_alt_outlined,
                                        color: Color(0xFF00D757), // WhatsApp Camera Green
                                        size: 38,
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
                              );
                            }

                            // 2. REAL DEVICE GALLERY MEDIA ITEMS (index 1 to N)
                            final mediaItem = _filteredMedia[index - 1];
                            return GestureDetector(
                              onTap: () {
                                if (mediaItem.isVideo) {
                                  _onTapVideoItem(mediaItem.path);
                                } else {
                                  _onTapPhotoItem(mediaItem.path);
                                }
                              },
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  // Image / Video Thumbnail
                                  Image.file(
                                    File(mediaItem.path),
                                    fit: BoxFit.cover,
                                    cacheWidth: 320,
                                    errorBuilder: (_, __, ___) => Container(
                                      color: const Color(0xFF1E2128),
                                      child: const Icon(Icons.broken_image, color: Colors.white24),
                                    ),
                                  ),

                                  // Video Badge (Duration & Icon)
                                  if (mediaItem.isVideo)
                                    Positioned(
                                      bottom: 6,
                                      left: 6,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: Colors.black.withValues(alpha: 0.65),
                                          borderRadius: BorderRadius.circular(6),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(Icons.videocam_rounded, color: Colors.white, size: 14),
                                            if (mediaItem.durationMs > 0) ...[
                                              const SizedBox(width: 4),
                                              Text(
                                                _formatDuration(mediaItem.durationMs),
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ],
                                          ],
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

            // Bottom Right Floating Multi-Select Button (WhatsApp Album icon)
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

            // Loading / Publishing Overlay
            if (_isPublishing)
              Container(
                color: Colors.black87,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(color: AppColors.primaryLight),
                      const SizedBox(height: 16),
                      Text(
                        _publishingMessage,
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
}
