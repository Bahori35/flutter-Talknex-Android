import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../../../constants/app_colors.dart';
import '../../../models/user_model.dart';
import '../../../services/custom_auth_service.dart';
import '../../../services/custom_chat_service.dart';
import '../../chat/photo_editor_screen.dart';

enum CollageType { vertical2, horizontal2, grid3, grid4 }

class LayoutStoryCreator extends StatefulWidget {
  final UserModel currentUser;

  const LayoutStoryCreator({super.key, required this.currentUser});

  @override
  State<LayoutStoryCreator> createState() => _LayoutStoryCreatorState();
}

class _LayoutStoryCreatorState extends State<LayoutStoryCreator> {
  final ImagePicker _picker = ImagePicker();
  final GlobalKey _repaintKey = GlobalKey();
  final CustomChatService _chatService = CustomChatService();

  CollageType _currentType = CollageType.grid4;
  final List<File?> _photos = [null, null, null, null];
  bool _isLoading = false;

  int get _requiredCount {
    switch (_currentType) {
      case CollageType.vertical2:
      case CollageType.horizontal2:
        return 2;
      case CollageType.grid3:
        return 3;
      case CollageType.grid4:
        return 4;
    }
  }

  Future<void> _pickCellPhoto(int index) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_library_rounded, color: AppColors.accent),
                title: const Text('Galeriden Seç', style: TextStyle(color: AppColors.textPrimary)),
                onTap: () => Navigator.pop(ctx, ImageSource.gallery),
              ),
              ListTile(
                leading: const Icon(Icons.camera_alt_rounded, color: AppColors.primaryLight),
                title: const Text('Kamerayla Çek', style: TextStyle(color: AppColors.textPrimary)),
                onTap: () => Navigator.pop(ctx, ImageSource.camera),
              ),
            ],
          ),
        ),
      ),
    );

    if (source == null) return;

    final picked = await _picker.pickImage(source: source, imageQuality: 88);
    if (picked != null) {
      setState(() {
        _photos[index] = File(picked.path);
      });
    }
  }

  Future<File?> _renderCollageToFile() async {
    final boundary = _repaintKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return null;

    final ui.Image image = await boundary.toImage(pixelRatio: 2.5);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) return null;

    final tempDir = await getTemporaryDirectory();
    final file = File('${tempDir.path}/collage_${DateTime.now().millisecondsSinceEpoch}.png');
    await file.writeAsBytes(byteData.buffer.asUint8List(), flush: true);
    return file;
  }

  Future<void> _openPhotoEditorOnCollage() async {
    final file = await _renderCollageToFile();
    if (file == null || !mounted) return;

    final result = await Navigator.push<PhotoEditorResult>(
      context,
      MaterialPageRoute(
        builder: (_) => PhotoEditorScreen(imageFile: file),
      ),
    );

    if (result != null && mounted) {
      _uploadAndPublish(result.file, result.caption);
    }
  }

  Future<void> _publishDirect() async {
    final file = await _renderCollageToFile();
    if (file == null) return;
    _uploadAndPublish(file, '');
  }

  Future<void> _uploadAndPublish(File file, String caption) async {
    setState(() => _isLoading = true);
    try {
      final authService = Provider.of<CustomAuthService>(context, listen: false);
      final uploadedUrl = await authService.uploadImage(file.path);
      if (uploadedUrl == null) throw Exception('Yükleme başarısız');

      final myUid = int.tryParse(widget.currentUser.uid) ?? 0;
      final success = await _chatService.createStory(
        userId: myUid,
        mediaUrl: uploadedUrl,
        caption: caption,
        mediaType: 'image',
      );

      if (!mounted) return;
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Yerleşim durumu paylaşıldı!'),
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

  Widget _buildCell(int index) {
    final photo = _photos[index];
    return Expanded(
      child: GestureDetector(
        onTap: () => _pickCellPhoto(index),
        child: Container(
          margin: const EdgeInsets.all(2.5),
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E24),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white24, width: 1),
          ),
          child: photo != null
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(7),
                  child: Image.file(photo, fit: BoxFit.cover, width: double.infinity, height: double.infinity),
                )
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: const [
                    Icon(Icons.add_photo_alternate_rounded, color: Colors.white60, size: 36),
                    SizedBox(height: 6),
                    Text('Fotoğraf Ekle', style: TextStyle(color: Colors.white60, fontSize: 12)),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildCollageLayout() {
    switch (_currentType) {
      case CollageType.vertical2:
        return Row(
          children: [
            _buildCell(0),
            _buildCell(1),
          ],
        );
      case CollageType.horizontal2:
        return Column(
          children: [
            _buildCell(0),
            _buildCell(1),
          ],
        );
      case CollageType.grid3:
        return Column(
          children: [
            _buildCell(0),
            Expanded(
              child: Row(
                children: [
                  _buildCell(1),
                  _buildCell(2),
                ],
              ),
            ),
          ],
        );
      case CollageType.grid4:
      default:
        return Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  _buildCell(0),
                  _buildCell(1),
                ],
              ),
            ),
            Expanded(
              child: Row(
                children: [
                  _buildCell(2),
                  _buildCell(3),
                ],
              ),
            ),
          ],
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool hasAtLeastOne = _photos.take(_requiredCount).any((p) => p != null);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Yerleşim Düzeni', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
        actions: [
          if (hasAtLeastOne) ...[
            IconButton(
              icon: const Icon(Icons.edit_rounded, color: AppColors.accent),
              tooltip: 'Filtre / Efekt Düzenle',
              onPressed: _openPhotoEditorOnCollage,
            ),
            IconButton(
              icon: _isLoading
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.send_rounded, color: AppColors.primaryLight),
              tooltip: 'Paylaş',
              onPressed: _isLoading ? null : _publishDirect,
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          // Collage Canvas
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: RepaintBoundary(
                key: _repaintKey,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: _buildCollageLayout(),
                ),
              ),
            ),
          ),

          // Bottom Preset Selector
          SafeArea(
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 12),
              color: AppColors.surface,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildPresetButton(CollageType.grid4, Icons.grid_view_rounded, '2x2 Izgara'),
                  _buildPresetButton(CollageType.grid3, Icons.view_quilt_rounded, '3\'lü Izgara'),
                  _buildPresetButton(CollageType.vertical2, Icons.view_column_rounded, '2 Dikey'),
                  _buildPresetButton(CollageType.horizontal2, Icons.view_stream_rounded, '2 Yatay'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPresetButton(CollageType type, IconData icon, String label) {
    final isSelected = _currentType == type;
    return GestureDetector(
      onTap: () => setState(() => _currentType = type),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: isSelected ? AppColors.accent.withValues(alpha: 0.25) : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: isSelected ? AppColors.accent : Colors.white24),
            ),
            child: Icon(icon, color: isSelected ? AppColors.accent : Colors.white70, size: 24),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: isSelected ? AppColors.accent : Colors.white60,
              fontSize: 11,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }
}
