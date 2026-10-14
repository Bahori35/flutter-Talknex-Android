import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:image_picker/image_picker.dart';
import '../../constants/app_colors.dart';
import '../../services/custom_auth_service.dart';
import '../../widgets/app_avatar.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late TextEditingController _statusController;
  late TextEditingController _photoController;
  late TextEditingController _phoneController;
  bool _isUploading = false;
  final ImagePicker _picker = ImagePicker();

  // Preset avatar choices (including animated GIFs!)
  final List<String> _avatarPresets = [
    // Animated GIFs
    'https://media.giphy.com/media/26ufdipQqU2lhNA4g/giphy.gif',
    'https://media.giphy.com/media/ICOgUNjpvO0PC/giphy.gif',
    'https://media.giphy.com/media/vFKqnCdLPNOKc/giphy.gif',
    'https://media.giphy.com/media/3o7TKSjRrfIPjeiVyM/giphy.gif',
    // Photos
    'https://images.unsplash.com/photo-1534528741775-53994a69daeb?w=400',
    'https://images.unsplash.com/photo-1539571696357-5a69c17a67c6?w=400',
    'https://images.unsplash.com/photo-1507003211169-0a1dd7228f2d?w=400',
    'https://images.unsplash.com/photo-1494790108377-be9c29b29330?w=400',
  ];

  @override
  void initState() {
    super.initState();
    final user = Provider.of<CustomAuthService>(context, listen: false).currentUser;
    _nameController = TextEditingController(text: user?.displayName ?? '');
    _statusController = TextEditingController(text: user?.status ?? 'Hey there! I am using this app.');
    _photoController = TextEditingController(text: user?.photoUrl ?? '');
    _phoneController = TextEditingController(text: user?.phoneNumber ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _statusController.dispose();
    _photoController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _pickAndUploadImage(ImageSource source) async {
    try {
      // NOTE: We do NOT pass maxWidth/maxHeight/imageQuality so that animated GIFs
      // retain all their animation frames and format without being converted to JPEG!
      final XFile? pickedFile = await _picker.pickImage(
        source: source,
      );

      if (pickedFile == null) return;

      setState(() {
        _isUploading = true;
      });

      final authService = Provider.of<CustomAuthService>(context, listen: false);
      final uploadedUrl = await authService.uploadImage(pickedFile.path);

      if (!mounted) return;

      setState(() {
        _isUploading = false;
      });

      if (uploadedUrl != null) {
        setState(() {
          _photoController.text = uploadedUrl;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Fotoğraf yüklendi! Kaydetmek için sağ üstteki tike veya KAYDET butonuna basın.'),
            backgroundColor: AppColors.primaryLight,
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Fotoğraf yüklenemedi. Lütfen tekrar deneyin.'),
            backgroundColor: AppColors.callRed,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isUploading = false;
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

  void _saveProfile() async {
    if (_formKey.currentState!.validate()) {
      final authService = Provider.of<CustomAuthService>(context, listen: false);
      final error = await authService.updateProfile(
        displayName: _nameController.text.trim(),
        photoUrl: _photoController.text.trim(),
        status: _statusController.text.trim(),
        phoneNumber: _phoneController.text.trim(),
      );

      if (!mounted) return;

      if (error == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Profil başarıyla güncellendi!'),
            backgroundColor: AppColors.primaryLight,
            behavior: SnackBarBehavior.floating,
          ),
        );
        Navigator.pop(context);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error),
            backgroundColor: AppColors.callRed,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  void _showAvatarPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 16.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.surfaceLight,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Profil Fotoğrafı Seç',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: () {
                          Navigator.pop(ctx);
                          _pickAndUploadImage(ImageSource.gallery);
                        },
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceLight,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Column(
                            children: [
                              Icon(Icons.photo_library, color: AppColors.primaryLight, size: 32),
                              SizedBox(height: 8),
                              Text('Galeriden Seç', style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: InkWell(
                        onTap: () {
                          Navigator.pop(ctx);
                          _pickAndUploadImage(ImageSource.camera);
                        },
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceLight,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Column(
                            children: [
                              Icon(Icons.camera_alt, color: AppColors.primaryLight, size: 32),
                              SizedBox(height: 8),
                              Text('Fotoğraf Çek', style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                const Text(
                  'Veya Hazır Avatarlardan Seçin',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.textSecondary),
                ),
                const SizedBox(height: 12),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: _avatarPresets.length,
                  itemBuilder: (context, index) {
                    final url = _avatarPresets[index];
                    return InkWell(
                      onTap: () {
                        setState(() {
                          _photoController.text = url;
                        });
                        Navigator.pop(ctx);
                      },
                      child: AppAvatar(
                        imageUrl: url,
                        radius: 24,
                      ),
                    );
                  },
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final authService = Provider.of<CustomAuthService>(context);
    final user = authService.currentUser;

    final currentPhoto = _photoController.text.isNotEmpty
        ? _photoController.text
        : (user?.photoUrl ?? '');

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        title: const Text('Profili Düzenle', style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold)),
        elevation: 0,
        actions: [
          IconButton(
            icon: authService.isLoading
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: AppColors.primaryLight, strokeWidth: 2))
                : const Icon(Icons.check, color: AppColors.primaryLight),
            onPressed: authService.isLoading ? null : _saveProfile,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              // Avatar Preview & Change Button (Supports animated GIFs)
              Center(
                child: Stack(
                  children: [
                    AppAvatar(
                      radius: 56,
                      imageUrl: currentPhoto,
                      name: user?.displayName,
                      isLoading: _isUploading,
                    ),
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: GestureDetector(
                        onTap: _isUploading ? null : _showAvatarPicker,
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: const BoxDecoration(
                            color: AppColors.primaryLight,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.camera_alt, color: Colors.white, size: 20),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: _showAvatarPicker,
                icon: const Icon(Icons.photo_library, color: AppColors.primaryLight, size: 18),
                label: const Text('Fotoğraf Değiştir / Seç', style: TextStyle(color: AppColors.primaryLight)),
              ),
              const SizedBox(height: 24),

              // Username info (Read-only)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.alternate_email, color: AppColors.textSecondary),
                title: const Text('Kullanıcı Adı', style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                subtitle: Text('@${user?.username ?? ""}', style: const TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.bold)),
              ),
              const Divider(color: AppColors.surface),

              // Display Name Field
              TextFormField(
                controller: _nameController,
                style: const TextStyle(color: AppColors.textPrimary),
                decoration: const InputDecoration(
                  labelText: 'İsim (Görünen Ad)',
                  labelStyle: TextStyle(color: AppColors.primaryLight),
                  prefixIcon: Icon(Icons.person_outline, color: AppColors.primaryLight),
                  border: UnderlineInputBorder(),
                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.surfaceLight)),
                  focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.primaryLight, width: 2)),
                ),
                validator: (val) {
                  if (val == null || val.trim().isEmpty) {
                    return 'Lütfen bir isim girin';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 20),

              // Status / About Field
              TextFormField(
                controller: _statusController,
                style: const TextStyle(color: AppColors.textPrimary),
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Hakkımda / Durum',
                  labelStyle: TextStyle(color: AppColors.primaryLight),
                  prefixIcon: Icon(Icons.info_outline, color: AppColors.primaryLight),
                  border: UnderlineInputBorder(),
                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.surfaceLight)),
                  focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.primaryLight, width: 2)),
                ),
              ),
              const SizedBox(height: 20),

              // Phone Number Field
              TextFormField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                style: const TextStyle(color: AppColors.textPrimary),
                decoration: const InputDecoration(
                  labelText: 'Telefon Numarası (Rehber Eşleşmesi İçin)',
                  hintText: 'Örn: 05xxxxxxxxx',
                  hintStyle: TextStyle(color: AppColors.textSecondary),
                  labelStyle: TextStyle(color: AppColors.primaryLight),
                  prefixIcon: Icon(Icons.phone_outlined, color: AppColors.primaryLight),
                  border: UnderlineInputBorder(),
                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.surfaceLight)),
                  focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.primaryLight, width: 2)),
                ),
              ),
              const SizedBox(height: 20),

              const SizedBox(height: 36),

              // Save Button
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryLight,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: authService.isLoading ? null : _saveProfile,
                  child: authService.isLoading
                      ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Text('KAYDET', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
