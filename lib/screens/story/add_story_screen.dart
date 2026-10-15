import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../../constants/app_colors.dart';
import '../../models/user_model.dart';
import '../../services/custom_auth_service.dart';
import '../../services/custom_chat_service.dart';
import '../chat/photo_editor_screen.dart';

class AddStoryScreen extends StatefulWidget {
  final UserModel currentUser;

  const AddStoryScreen({super.key, required this.currentUser});

  @override
  State<AddStoryScreen> createState() => _AddStoryScreenState();
}

class _AddStoryScreenState extends State<AddStoryScreen> {
  final ImagePicker _picker = ImagePicker();
  final TextEditingController _captionController = TextEditingController();
  final CustomChatService _chatService = CustomChatService();
  File? _selectedImage;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    // Auto prompt picker on open
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pickImage(ImageSource.gallery);
    });
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? pickedFile = await _picker.pickImage(
        source: source,
        maxWidth: 1440,
        maxHeight: 1440,
        imageQuality: 85,
      );

      if (pickedFile != null) {
        final editorResult = await Navigator.push<PhotoEditorResult>(
          context,
          MaterialPageRoute(
            builder: (_) => PhotoEditorScreen(imageFile: File(pickedFile.path)),
          ),
        );

        if (editorResult != null) {
          setState(() {
            _selectedImage = editorResult.file;
            if (editorResult.caption.isNotEmpty) {
              _captionController.text = editorResult.caption;
            }
          });
        } else if (_selectedImage == null) {
          Navigator.pop(context);
        }
      } else if (_selectedImage == null) {
        Navigator.pop(context);
      }
    } catch (e) {
      debugPrint('Error picking image: $e');
      if (_selectedImage == null) {
        Navigator.pop(context);
      }
    }
  }

  Future<void> _uploadAndPublishStory() async {
    if (_selectedImage == null) return;

    setState(() {
      _isLoading = true;
    });

    try {
      final authService = Provider.of<CustomAuthService>(context, listen: false);
      final uploadedUrl = await authService.uploadImage(_selectedImage!.path);

      if (uploadedUrl == null) {
        throw Exception('Resim sunucuya yüklenemedi');
      }

      final myUid = int.tryParse(widget.currentUser.uid) ?? 0;
      final success = await _chatService.createStory(
        userId: myUid,
        mediaUrl: uploadedUrl,
        caption: _captionController.text.trim(),
        mediaType: 'image',
      );

      if (!mounted) return;

      setState(() {
        _isLoading = false;
      });

      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Durumunuz başarıyla paylaşıldı!'),
            backgroundColor: AppColors.primaryLight,
            behavior: SnackBarBehavior.floating,
          ),
        );
        Navigator.pop(context, true);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Hikaye oluşturulurken hata oluştu.'),
            backgroundColor: AppColors.callRed,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Hata: $e'),
            backgroundColor: AppColors.callRed,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _captionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.photo_library, color: Colors.white),
            onPressed: _isLoading ? null : () => _pickImage(ImageSource.gallery),
          ),
          IconButton(
            icon: const Icon(Icons.camera_alt, color: Colors.white),
            onPressed: _isLoading ? null : () => _pickImage(ImageSource.camera),
          ),
        ],
      ),
      body: _selectedImage == null
          ? const Center(child: CircularProgressIndicator(color: AppColors.primaryLight))
          : Stack(
              fit: StackFit.expand,
              children: [
                // Preview Image
                Center(
                  child: Image.file(
                    _selectedImage!,
                    fit: BoxFit.contain,
                  ),
                ),

                // Bottom Caption & Send
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
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
                    child: SafeArea(
                      child: Row(
                        children: [
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              decoration: BoxDecoration(
                                color: AppColors.surface.withOpacity(0.85),
                                borderRadius: BorderRadius.circular(24),
                                border: Border.all(color: AppColors.surfaceLight),
                              ),
                              child: TextField(
                                controller: _captionController,
                                style: const TextStyle(color: AppColors.textPrimary),
                                maxLines: 3,
                                minLines: 1,
                                decoration: const InputDecoration(
                                  hintText: 'Başlık ekleyin...',
                                  hintStyle: TextStyle(color: AppColors.textSecondary),
                                  border: InputBorder.none,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          FloatingActionButton(
                            backgroundColor: AppColors.primaryLight,
                            onPressed: _isLoading ? null : _uploadAndPublishStory,
                            child: _isLoading
                                ? const SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                                  )
                                : const Icon(Icons.send, color: Colors.white),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
