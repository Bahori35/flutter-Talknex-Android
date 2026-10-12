import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../constants/app_colors.dart';
import '../../models/user_model.dart';
import '../../services/custom_auth_service.dart';
import '../../services/custom_chat_service.dart';

class CreateGroupScreen extends StatefulWidget {
  final UserModel currentUser;
  final List<UserModel> contacts;

  const CreateGroupScreen({
    Key? key,
    required this.currentUser,
    required this.contacts,
  }) : super(key: key);

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _descController = TextEditingController();
  final _chatService = CustomChatService();
  final _picker = ImagePicker();

  String _photoUrl = '';
  final Set<int> _selectedUserIds = {};
  bool _isCreating = false;
  bool _isUploadingPhoto = false;

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    super.dispose();
  }

  Future<void> _pickGroupPhoto() async {
    try {
      final XFile? file = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 85,
      );
      if (file == null) return;

      setState(() => _isUploadingPhoto = true);
      final authService = Provider.of<CustomAuthService>(context, listen: false);
      final uploadedUrl = await authService.uploadImage(file.path);

      if (mounted) {
        setState(() {
          _isUploadingPhoto = false;
          if (uploadedUrl != null) {
            _photoUrl = uploadedUrl;
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isUploadingPhoto = false);
      }
    }
  }

  void _createGroup() async {
    if (!_formKey.currentState!.validate()) return;

    final groupName = _nameController.text.trim();
    if (groupName.isEmpty) return;

    // Max 200 member check (including creator)
    if (_selectedUserIds.length + 1 > 200) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Bir grupta en fazla 200 kişi bulunabilir!'),
          backgroundColor: AppColors.callRed,
        ),
      );
      return;
    }

    setState(() => _isCreating = true);

    final currentUserIdInt = int.tryParse(widget.currentUser.uid) ?? 0;
    final res = await _chatService.createGroup(
      name: groupName,
      createdBy: currentUserIdInt,
      memberIds: _selectedUserIds.toList(),
      photoUrl: _photoUrl,
      description: _descController.text.trim(),
    );

    if (!mounted) return;
    setState(() => _isCreating = false);

    if (res != null && res['status'] == 'success') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Grup başarıyla oluşturuldu!'),
          backgroundColor: AppColors.primaryLight,
        ),
      );
      Navigator.pop(context, true);
    } else {
      final msg = res?['error'] ?? 'Grup oluşturulamadı';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg.toString()),
          backgroundColor: AppColors.callRed,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Exclude current user from contact list
    final availableContacts = widget.contacts
        .where((u) => u.uid != widget.currentUser.uid)
        .toList();

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        title: const Text(
          'Yeni Grup Kur',
          style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            icon: _isCreating
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(color: AppColors.primaryLight, strokeWidth: 2),
                  )
                : const Icon(Icons.check, color: AppColors.primaryLight),
            onPressed: _isCreating ? null : _createGroup,
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Group Avatar & Name Input
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                GestureDetector(
                  onTap: _isUploadingPhoto ? null : _pickGroupPhoto,
                  child: Stack(
                    children: [
                      CircleAvatar(
                        radius: 36,
                        backgroundColor: AppColors.surfaceLight,
                        backgroundImage: _photoUrl.isNotEmpty
                            ? CachedNetworkImageProvider(_photoUrl)
                            : null,
                        child: _isUploadingPhoto
                            ? const CircularProgressIndicator(color: AppColors.primaryLight)
                            : (_photoUrl.isEmpty
                                ? const Icon(Icons.group_rounded, size: 36, color: AppColors.textSecondary)
                                : null),
                      ),
                      Positioned(
                        bottom: 0,
                        right: 0,
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: const BoxDecoration(
                            color: AppColors.primaryLight,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.camera_alt, color: Colors.white, size: 16),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    children: [
                      TextFormField(
                        controller: _nameController,
                        style: const TextStyle(color: AppColors.textPrimary),
                        decoration: const InputDecoration(
                          labelText: 'Grup İsmi *',
                          labelStyle: TextStyle(color: AppColors.primaryLight),
                          hintText: 'Örn: Arkadaşlar Grubu',
                          hintStyle: TextStyle(color: AppColors.textSecondary),
                          border: UnderlineInputBorder(),
                          enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.surfaceLight)),
                          focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.primaryLight, width: 2)),
                        ),
                        validator: (val) {
                          if (val == null || val.trim().isEmpty) {
                            return 'Lütfen bir grup adı girin';
                          }
                          return null;
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Description field
            TextFormField(
              controller: _descController,
              maxLines: 2,
              style: const TextStyle(color: AppColors.textPrimary),
              decoration: const InputDecoration(
                labelText: 'Grup Açıklaması (İsteğe bağlı)',
                labelStyle: TextStyle(color: AppColors.primaryLight),
                border: UnderlineInputBorder(),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.surfaceLight)),
                focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.primaryLight, width: 2)),
              ),
            ),
            const SizedBox(height: 24),

            // Member Selection Header with Limit Warning
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Üye Seç',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.primaryLight.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${_selectedUserIds.length + 1} / 200 Kişi (Limit)',
                    style: const TextStyle(
                      color: AppColors.primaryLight,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Grup kurucusu olarak siz otomatik yönetici (admin) olacaksınız.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 12),

            // Contacts List to Select
            if (availableContacts.isEmpty)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(32.0),
                  child: Text(
                    'Rehberinizde eklenebilecek kayıtlı kişi bulunamadı.',
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                ),
              )
            else
              ...availableContacts.map((contact) {
                final uidInt = int.tryParse(contact.uid) ?? 0;
                final isSelected = _selectedUserIds.contains(uidInt);

                return Container(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isSelected ? AppColors.primaryLight : AppColors.cardBorder,
                      width: isSelected ? 1.5 : 1,
                    ),
                  ),
                  child: CheckboxListTile(
                    activeColor: AppColors.primaryLight,
                    checkColor: Colors.white,
                    value: isSelected,
                    onChanged: (bool? checked) {
                      if (checked == true) {
                        if (_selectedUserIds.length + 1 >= 200) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('En fazla 200 kişi eklenebilir!'),
                              backgroundColor: AppColors.callRed,
                            ),
                          );
                          return;
                        }
                        setState(() {
                          _selectedUserIds.add(uidInt);
                        });
                      } else {
                        setState(() {
                          _selectedUserIds.remove(uidInt);
                        });
                      }
                    },
                    secondary: CircleAvatar(
                      radius: 20,
                      backgroundColor: AppColors.surfaceLight,
                      backgroundImage: contact.photoUrl.isNotEmpty
                          ? CachedNetworkImageProvider(contact.photoUrl)
                          : null,
                      child: contact.photoUrl.isEmpty
                          ? const Icon(Icons.person, color: AppColors.textSecondary)
                          : null,
                    ),
                    title: Text(
                      contact.displayName,
                      style: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      contact.phoneNumber.isNotEmpty ? contact.phoneNumber : '@${contact.username}',
                      style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
                    ),
                  ),
                );
              }),
            const SizedBox(height: 40),

            // Create Group Button
            SizedBox(
              height: 48,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primaryLight,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: _isCreating ? null : _createGroup,
                icon: const Icon(Icons.group_add_rounded, color: Colors.white),
                label: _isCreating
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                      )
                    : const Text(
                        'GRUBU OLUŞTUR',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                      ),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}
