import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../constants/app_colors.dart';
import '../../models/user_model.dart';
import '../../models/group_model.dart';
import '../../services/custom_auth_service.dart';
import '../../services/custom_chat_service.dart';
import '../../widgets/app_avatar.dart';

class GroupInfoScreen extends StatefulWidget {
  final GroupModel group;
  final UserModel currentUser;
  final List<UserModel> contacts;
  final VoidCallback onGroupUpdated;

  const GroupInfoScreen({
    Key? key,
    required this.group,
    required this.currentUser,
    this.contacts = const [],
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

  bool get _isCreator {
    final myUid = int.tryParse(widget.currentUser.uid) ?? 0;
    return _group.createdBy == myUid;
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
              leading: AppAvatar(
                imageUrl: member.photoUrl,
                name: member.displayName,
                radius: 20,
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

  void _deleteAndCloseGroup() async {
    if (!_isCreator) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Yalnızca grubu kuran kişi grubu kapatabilir!'),
          backgroundColor: AppColors.callRed,
        ),
      );
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: AppColors.callRed, size: 28),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Grubu Kapat ve Sil',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 17),
              ),
            ),
          ],
        ),
        content: const Text(
          'Bu grubu tamamen kapatmak ve silmek istediğinize emin misiniz?\n\n'
          '• Gruptaki tüm mesajlar ve paylaşılan medyalar silinecektir.\n'
          '• Tüm üyelerin sohbet listesinden kaldırılacaktır.\n'
          '• Bu işlem geri alınamaz!',
          style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Vazgeç', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.callRed,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Grubu Kapat', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      final myUid = int.tryParse(widget.currentUser.uid) ?? 0;
      final res = await _chatService.deleteGroup(
        groupId: _group.id,
        userId: myUid,
      );

      if (res['success'] == true) {
        widget.onGroupUpdated();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Grup başarıyla kapatıldı ve silindi.'),
              backgroundColor: AppColors.callRed,
            ),
          );
          Navigator.pop(context, 'deleted');
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(res['error'] ?? 'Grup silinemedi'),
              backgroundColor: AppColors.callRed,
            ),
          );
        }
      }
    }
  }

  void _openAddMembersDialog() {
    if (!_isAdmin) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Yalnızca grup yöneticileri üye ekleyebilir!'),
          backgroundColor: AppColors.callRed,
        ),
      );
      return;
    }

    if (_members.length >= 200) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Grup üye limiti (en fazla 200 kişi) dolmuştur! Yeni üye eklenemez.'),
          backgroundColor: AppColors.callRed,
        ),
      );
      return;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return _AddMembersBottomSheet(
          group: _group,
          existingMembers: _members,
          currentUser: widget.currentUser,
          contacts: widget.contacts,
          onMembersAdded: () {
            _fetchDetails();
          },
        );
      },
    );
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
              icon: const Icon(Icons.person_add_rounded, color: AppColors.accent),
              tooltip: 'Üye Ekle',
              onPressed: _openAddMembersDialog,
            ),
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
                      AppAvatar(
                        radius: 54,
                        imageUrl: _group.photoUrl,
                        isGroup: true,
                        isLoading: _isUploadingPhoto,
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

                // Add Member Tile for Admins
                if (_isAdmin)
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.accent.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.accent.withOpacity(0.35)),
                    ),
                    child: ListTile(
                      onTap: _openAddMembersDialog,
                      leading: const CircleAvatar(
                        radius: 20,
                        backgroundColor: AppColors.accent,
                        child: Icon(Icons.person_add_rounded, color: Colors.black, size: 20),
                      ),
                      title: const Text(
                        'Katılımcı Ekle',
                        style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.bold, fontSize: 15),
                      ),
                      subtitle: Text(
                        '${_members.length} / 200 üye • Dokunarak yeni üye ekleyin',
                        style: const TextStyle(color: Colors.white60, fontSize: 12),
                      ),
                      trailing: const Icon(Icons.add_circle_outline_rounded, color: AppColors.accent),
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
                      leading: AppAvatar(
                        radius: 20,
                        imageUrl: member.photoUrl,
                        name: member.displayName,
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

                // Creator-only: Close / Delete Group Option
                if (_isCreator) ...[
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: ListTile(
                      tileColor: AppColors.callRed.withOpacity(0.12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(color: AppColors.callRed.withOpacity(0.4)),
                      ),
                      leading: const Icon(Icons.delete_forever_rounded, color: AppColors.callRed),
                      title: const Text(
                        'Grubu Kapat / Sil',
                        style: TextStyle(color: AppColors.callRed, fontWeight: FontWeight.bold),
                      ),
                      subtitle: const Text(
                        'Grup kurucusu olarak grubu tüm üyeler için tamamen kapatın ve silin',
                        style: TextStyle(color: Colors.white54, fontSize: 11.5),
                      ),
                      onTap: _deleteAndCloseGroup,
                    ),
                  ),
                ],
                const SizedBox(height: 40),
              ],
            ),
    );
  }
}

class _AddMembersBottomSheet extends StatefulWidget {
  final GroupModel group;
  final List<GroupMemberModel> existingMembers;
  final UserModel currentUser;
  final List<UserModel> contacts;
  final VoidCallback onMembersAdded;

  const _AddMembersBottomSheet({
    Key? key,
    required this.group,
    required this.existingMembers,
    required this.currentUser,
    required this.contacts,
    required this.onMembersAdded,
  }) : super(key: key);

  @override
  State<_AddMembersBottomSheet> createState() => _AddMembersBottomSheetState();
}

class _AddMembersBottomSheetState extends State<_AddMembersBottomSheet> {
  final _chatService = CustomChatService();
  final _searchController = TextEditingController();
  final Set<int> _selectedUserIds = {};

  List<UserModel> _availableUsers = [];
  bool _isLoading = true;
  bool _isAdding = false;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadCandidates();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _loadCandidates() async {
    final existingUserIds = widget.existingMembers.map((m) => m.userId.toString()).toSet();
    existingUserIds.add(widget.currentUser.uid);

    // 1. Fetch registered users from backend
    final registeredUsers = await _chatService.getUsers(widget.currentUser.uid);

    // 2. Combine with contacts passed
    final Map<String, UserModel> merged = {};
    for (final u in widget.contacts) {
      if (!existingUserIds.contains(u.uid)) {
        merged[u.uid] = u;
      }
    }
    for (final u in registeredUsers) {
      if (!existingUserIds.contains(u.uid)) {
        merged.putIfAbsent(u.uid, () => u);
      }
    }

    if (mounted) {
      setState(() {
        _availableUsers = merged.values.toList();
        _isLoading = false;
      });
    }
  }

  void _submitAdd() async {
    if (_selectedUserIds.isEmpty) return;

    final remainingCapacity = 200 - widget.existingMembers.length;
    if (_selectedUserIds.length > remainingCapacity) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('En fazla $remainingCapacity kişi daha ekleyebilirsiniz!'),
          backgroundColor: AppColors.callRed,
        ),
      );
      return;
    }

    setState(() => _isAdding = true);

    final adminUid = int.tryParse(widget.currentUser.uid) ?? 0;
    final res = await _chatService.addGroupMembers(
      groupId: widget.group.id,
      adminUserId: adminUid,
      userIds: _selectedUserIds.toList(),
    );

    if (mounted) {
      setState(() => _isAdding = false);
      Navigator.pop(context);

      widget.onMembersAdded();

      final addedCount = res['added'] ?? _selectedUserIds.length;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$addedCount kişi gruba başarıyla eklendi!'),
          backgroundColor: AppColors.accent,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final remainingCapacity = 200 - widget.existingMembers.length;

    var filtered = _availableUsers;
    if (_searchQuery.isNotEmpty) {
      filtered = filtered.where((u) {
        return u.displayName.toLowerCase().contains(_searchQuery.toLowerCase()) ||
            u.username.toLowerCase().contains(_searchQuery.toLowerCase()) ||
            u.phoneNumber.contains(_searchQuery);
      }).toList();
    }

    return Container(
      height: MediaQuery.of(context).size.height * 0.8,
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        children: [
          // Drag handle
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Katılımcı Ekle',
                        style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Mevcut: ${widget.existingMembers.length}/200 • Kalan kontenjan: $remainingCapacity',
                        style: const TextStyle(color: AppColors.accent, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.white70),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),

          // Search Box
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: TextField(
              controller: _searchController,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Kişi veya kullanıcı adı ara...',
                hintStyle: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
                prefixIcon: const Icon(Icons.search_rounded, color: AppColors.accent, size: 20),
                filled: true,
                fillColor: AppColors.surfaceLight,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
              ),
              onChanged: (val) {
                setState(() => _searchQuery = val.trim());
              },
            ),
          ),

          // Body
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator(color: AppColors.accent))
                : filtered.isEmpty
                    ? Center(
                        child: Text(
                          _searchQuery.isNotEmpty
                              ? 'Aramayla eşleşen kişi bulunamadı.'
                              : 'Eklenebilecek yeni kişi bulunamadı.\n(Tüm kişileriniz zaten bu grupta)',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
                        ),
                      )
                    : ListView.builder(
                        itemCount: filtered.length,
                        itemBuilder: (ctx, idx) {
                          final user = filtered[idx];
                          final uIdInt = int.tryParse(user.uid) ?? 0;
                          final isSelected = _selectedUserIds.contains(uIdInt);

                          return CheckboxListTile(
                            activeColor: AppColors.accent,
                            checkColor: Colors.black,
                            value: isSelected,
                            onChanged: (bool? checked) {
                              setState(() {
                                if (checked == true) {
                                  if (_selectedUserIds.length >= remainingCapacity) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text('Grup limiti dolu! En fazla $remainingCapacity kişi seçebilirsiniz.'),
                                        backgroundColor: AppColors.callRed,
                                      ),
                                    );
                                    return;
                                  }
                                  _selectedUserIds.add(uIdInt);
                                } else {
                                  _selectedUserIds.remove(uIdInt);
                                }
                              });
                            },
                            secondary: AppAvatar(
                              radius: 20,
                              imageUrl: user.photoUrl,
                              name: user.displayName,
                            ),
                            title: Text(
                              user.displayName,
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14),
                            ),
                            subtitle: Text(
                              user.phoneNumber.isNotEmpty ? user.phoneNumber : '@${user.username}',
                              style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
                            ),
                          );
                        },
                      ),
          ),

          // Bottom Button
          Container(
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(
              color: AppColors.surface,
              border: Border(top: BorderSide(color: AppColors.cardBorder)),
            ),
            child: SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  disabledBackgroundColor: Colors.white12,
                ),
                onPressed: _selectedUserIds.isEmpty || _isAdding ? null : _submitAdd,
                icon: _isAdding
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                    : const Icon(Icons.person_add_rounded, size: 20),
                label: Text(
                  _selectedUserIds.isEmpty
                      ? 'Kişi Seçin'
                      : 'Gruba Ekle (${_selectedUserIds.length} kişi)',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
