import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../constants/app_colors.dart';
import '../../models/user_model.dart';
import '../../models/group_model.dart';
import '../../services/custom_auth_service.dart';
import '../../services/custom_chat_service.dart';

class GroupInfoScreen extends StatefulWidget {
  final GroupModel group;
  final UserModel currentUser;
  final VoidCallback onGroupUpdated;

  const GroupInfoScreen({
    Key? key,
    required this.group,
    required this.currentUser,
    required this.onGroupUpdated,
  }) : super(key: key);

  @override
  State<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends State<GroupInfoScreen> {
  final _chatService = CustomChatService();
  final _picker = ImagePicker();

  late GroupModel _group;
  List<GroupMemberModel> _members = [];
  bool _isLoading = true;
  bool _isUploadingPhoto = false;

  @override
  void initState() {
    super.initState();
    _group = widget.group;
    _fetchDetails();
  }

  bool get _isAdmin {
    final myUid = int.tryParse(widget.currentUser.uid) ?? 0;
    return _members.any((m) => m.userId == myUid && m.isAdmin);
  }

  void _fetchDetails() async {
    final data = await _chatService.getGroupDetails(_group.id);
    if (mounted && data != null) {
      final List<dynamic> memberList = data['members'] ?? [];
      setState(() {
        _group = _group.copyWith(
          name: data['name'] ?? _group.name,
          photoUrl: data['photoUrl'] ?? _group.photoUrl,
          description: data['description'] ?? _group.description,
          memberCount: data['memberCount'] ?? _group.memberCount,
        );
        _members = memberList.map((m) => GroupMemberModel.fromJson(m)).toList();
        _isLoading = false;
      });
      widget.onGroupUpdated();
    } else if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _changeGroupPhoto() async {
    if (!_isAdmin) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Grup fotoğrafını yalnızca yöneticiler değiştirebilir!'), backgroundColor: AppColors.callRed),
      );
      return;
    }

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

      if (uploadedUrl != null) {
        final success = await _chatService.updateGroupInfo(
          groupId: _group.id,
          userId: int.tryParse(widget.currentUser.uid) ?? 0,
          photoUrl: uploadedUrl,
        );
        if (success && mounted) {
          setState(() {
            _group = _group.copyWith(photoUrl: uploadedUrl);
            _isUploadingPhoto = false;
          });
          widget.onGroupUpdated();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Grup fotoğrafı güncellendi!'), backgroundColor: AppColors.primaryLight),
          );
        }
      } else {
        setState(() => _isUploadingPhoto = false);
      }
    } catch (e) {
      if (mounted) setState(() => _isUploadingPhoto = false);
    }
  }

  void _editGroupNameAndDesc() {
    if (!_isAdmin) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Grup bilgilerini yalnızca yöneticiler düzenleyebilir!'), backgroundColor: AppColors.callRed),
      );
      return;
    }

    final nameController = TextEditingController(text: _group.name);
    final descController = TextEditingController(text: _group.description);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Grup Bilgilerini Düzenle', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Grup Adı',
                labelStyle: TextStyle(color: AppColors.primaryLight),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: descController,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Açıklama',
                labelStyle: TextStyle(color: AppColors.primaryLight),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('İptal', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.primaryLight),
            onPressed: () async {
              final newName = nameController.text.trim();
              if (newName.isEmpty) return;
              Navigator.pop(ctx);

              final success = await _chatService.updateGroupInfo(
                groupId: _group.id,
                userId: int.tryParse(widget.currentUser.uid) ?? 0,
                name: newName,
                description: descController.text.trim(),
              );

              if (success && mounted) {
                setState(() {
                  _group = _group.copyWith(
                    name: newName,
                    description: descController.text.trim(),
                  );
                });
                widget.onGroupUpdated();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Grup bilgileri güncellendi!'), backgroundColor: AppColors.primaryLight),
                );
              }
            },
            child: const Text('Kaydet', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _showMemberOptions(GroupMemberModel member) {
    final myUid = int.tryParse(widget.currentUser.uid) ?? 0;
    final isMe = member.userId == myUid;

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: CircleAvatar(
                backgroundImage: member.photoUrl.isNotEmpty ? CachedNetworkImageProvider(member.photoUrl) : null,
                child: member.photoUrl.isEmpty ? const Icon(Icons.person) : null,
              ),
              title: Text(member.displayName, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              subtitle: Text(
                member.isAdmin ? '👑 Grup Yöneticisi' : 'Üye',
                style: TextStyle(color: member.isAdmin ? AppColors.accent : Colors.white60),
              ),
            ),
            const Divider(color: AppColors.cardBorder),

            // Promote / Demote admin (Only admin can change, cannot change self)
            if (_isAdmin && !isMe)
              ListTile(
                leading: Icon(
                  member.isAdmin ? Icons.person_remove_rounded : Icons.admin_panel_settings_rounded,
                  color: member.isAdmin ? Colors.orangeAccent : AppColors.accent,
                ),
                title: Text(
                  member.isAdmin ? 'Yöneticilikten Çıkar (Üye Yap)' : 'Grup Yöneticisi Yap (Admin)',
                  style: const TextStyle(color: Colors.white),
                ),
                onTap: () async {
                  Navigator.pop(ctx);
                  final newRole = member.isAdmin ? 'member' : 'admin';
                  final ok = await _chatService.updateMemberRole(
                    groupId: _group.id,
                    adminUserId: myUid,
                    targetUserId: member.userId,
                    newRole: newRole,
                  );
                  if (ok) {
                    _fetchDetails();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('${member.displayName} ${newRole == 'admin' ? 'yönetici yapıldı' : 'üye yapıldı'}!'),
                        backgroundColor: AppColors.primaryLight,
                      ),
                    );
                  }
                },
              ),

            // Remove member (Only admin can remove others)
            if (_isAdmin && !isMe)
              ListTile(
                leading: const Icon(Icons.person_remove, color: AppColors.callRed),
                title: const Text('Gruptan Çıkar', style: TextStyle(color: AppColors.callRed)),
                onTap: () async {
                  Navigator.pop(ctx);
                  final ok = await _chatService.removeGroupMember(
                    groupId: _group.id,
                    targetUserId: member.userId,
                    requesterId: myUid,
                  );
                  if (ok) {
                    _fetchDetails();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('${member.displayName} gruptan çıkarıldı.'), backgroundColor: AppColors.callRed),
                    );
                  }
                },
              ),

            ListTile(
              leading: const Icon(Icons.close, color: Colors.white54),
              title: const Text('Kapat', style: TextStyle(color: Colors.white54)),
              onTap: () => Navigator.pop(ctx),
            ),
          ],
        ),
      ),
    );
  }

  void _leaveGroup() async {
    final myUid = int.tryParse(widget.currentUser.uid) ?? 0;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Gruptan Ayrıl', style: TextStyle(color: Colors.white)),
        content: const Text('Bu gruptan ayrılmak istediğinizden emin misiniz?', style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('İptal', style: TextStyle(color: Colors.white60))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.callRed),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Ayrıl', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _chatService.removeGroupMember(
        groupId: _group.id,
        targetUserId: myUid,
        requesterId: myUid,
      );
      widget.onGroupUpdated();
      if (mounted) {
        Navigator.pop(context); // close info
        Navigator.pop(context); // close chat screen
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        title: const Text('Grup Bilgisi', style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold)),
        actions: [
          if (_isAdmin)
            IconButton(
              icon: const Icon(Icons.edit_rounded, color: AppColors.primaryLight),
              tooltip: 'Grup Bilgilerini Düzenle',
              onPressed: _editGroupNameAndDesc,
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: AppColors.primaryLight))
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: 20),
              children: [
                // Group Avatar & Photo Edit
                Center(
                  child: Stack(
                    children: [
                      CircleAvatar(
                        radius: 54,
                        backgroundColor: AppColors.surfaceLight,
                        backgroundImage: _group.photoUrl.isNotEmpty
                            ? CachedNetworkImageProvider(_group.photoUrl)
                            : null,
                        child: _isUploadingPhoto
                            ? const CircularProgressIndicator(color: AppColors.primaryLight)
                            : (_group.photoUrl.isEmpty
                                ? const Icon(Icons.group_rounded, size: 54, color: AppColors.textSecondary)
                                : null),
                      ),
                      if (_isAdmin)
                        Positioned(
                          bottom: 0,
                          right: 0,
                          child: GestureDetector(
                            onTap: _isUploadingPhoto ? null : _changeGroupPhoto,
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: const BoxDecoration(
                                color: AppColors.primaryLight,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.camera_alt, color: Colors.white, size: 18),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // Group Name
                Center(
                  child: Text(
                    _group.name,
                    style: const TextStyle(color: AppColors.textPrimary, fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(height: 4),

                // Member Count and Limit Info
                Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceLight,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${_members.length} / 200 Katılımcı (Üye Limiti)',
                      style: const TextStyle(color: AppColors.accent, fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // Description
                if (_group.description.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Center(
                      child: Text(
                        _group.description,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: AppColors.textSecondary, fontSize: 14),
                      ),
                    ),
                  ),
                const SizedBox(height: 24),

                const Divider(color: AppColors.cardBorder),

                // Members Header
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Katılımcılar (${_members.length})',
                        style: const TextStyle(color: AppColors.textPrimary, fontSize: 15, fontWeight: FontWeight.bold),
                      ),
                      if (_isAdmin)
                        const Text(
                          'Yönetici Yetkisi Var 👑',
                          style: TextStyle(color: AppColors.accent, fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                    ],
                  ),
                ),

                // Member list
                ..._members.map((member) {
                  final isMe = member.userId.toString() == widget.currentUser.uid;
                  return Container(
                    margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.cardBorder),
                    ),
                    child: ListTile(
                      onTap: () => _showMemberOptions(member),
                      leading: CircleAvatar(
                        radius: 20,
                        backgroundColor: AppColors.surfaceLight,
                        backgroundImage: member.photoUrl.isNotEmpty ? CachedNetworkImageProvider(member.photoUrl) : null,
                        child: member.photoUrl.isEmpty ? const Icon(Icons.person, color: AppColors.textSecondary) : null,
                      ),
                      title: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${member.displayName} ${isMe ? "(Sen)" : ""}',
                              style: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w600),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (member.isAdmin)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: AppColors.accent.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: AppColors.accent.withOpacity(0.4)),
                              ),
                              child: const Text(
                                'Yönetici',
                                style: TextStyle(color: AppColors.accent, fontSize: 11, fontWeight: FontWeight.bold),
                              ),
                            ),
                        ],
                      ),
                      subtitle: Text(
                        member.phoneNumber.isNotEmpty ? member.phoneNumber : '@${member.username}',
                        style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
                      ),
                      trailing: const Icon(Icons.more_horiz, color: AppColors.textSecondary),
                    ),
                  );
                }),

                const SizedBox(height: 24),
                // Leave Group Option
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: ListTile(
                    tileColor: AppColors.surface,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    leading: const Icon(Icons.exit_to_app_rounded, color: AppColors.callRed),
                    title: const Text('Gruptan Ayrıl', style: TextStyle(color: AppColors.callRed, fontWeight: FontWeight.bold)),
                    onTap: _leaveGroup,
                  ),
                ),
                const SizedBox(height: 40),
              ],
            ),
    );
  }
}
