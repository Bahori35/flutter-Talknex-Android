import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import '../../../constants/app_colors.dart';
import '../../../models/user_model.dart';
import '../../../models/group_model.dart';
import '../../../models/message_envelope.dart';
import '../../../services/custom_chat_service.dart';
import '../../../services/socket_service.dart';
import '../../../services/encryption_service.dart';
import '../../../widgets/app_avatar.dart';
import '../../../utils/media_url_helper.dart';

class ForwardTarget {
  final String id;
  final String name;
  final String photoUrl;
  final bool isGroup;
  final String subtitle;
  final String phone;

  ForwardTarget({
    required this.id,
    required this.name,
    String photoUrl = '',
    required this.isGroup,
    this.subtitle = '',
    this.phone = '',
  }) : photoUrl = formatMediaUrl(photoUrl);
}

class ForwardMessageSheet extends StatefulWidget {
  final UserModel currentUser;
  final String content;
  final String messageType;
  final String? mediaUrl;
  final List<UserModel>? contacts;

  const ForwardMessageSheet({
    super.key,
    required this.currentUser,
    required this.content,
    String messageType = 'text',
    String? type,
    this.mediaUrl,
    this.contacts,
  }) : messageType = type ?? messageType;

  static Future<bool?> show(
    BuildContext context, {
    required UserModel currentUser,
    required String content,
    String messageType = 'text',
    String? type,
    String? mediaUrl,
    List<UserModel>? contacts,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => ForwardMessageSheet(
        currentUser: currentUser,
        content: content,
        messageType: messageType,
        mediaUrl: mediaUrl,
        contacts: contacts,
      ),
    );
  }

  @override
  State<ForwardMessageSheet> createState() => _ForwardMessageSheetState();
}

class _ForwardMessageSheetState extends State<ForwardMessageSheet> {
  final TextEditingController _searchController = TextEditingController();
  final CustomChatService _chatService = CustomChatService();
  final SocketService _socketService = SocketService();

  List<ForwardTarget> _allTargets = [];
  List<ForwardTarget> _filteredTargets = [];
  final Set<String> _selectedTargetIds = {};
  bool _isLoading = true;
  bool _isSending = false;

  @override
  void initState() {
    super.initState();
    _loadTargets();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  static String _normalizePhone(String phone) {
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    if (digits.length >= 10) {
      return digits.substring(digits.length - 10);
    }
    return digits;
  }

  Future<void> _loadTargets() async {
    try {
      final Map<String, String> phoneToNameMap = {};
      final Map<String, String> uidToNameMap = {};

      // 1. If caller passed existing synced contacts (e.g. from GroupChatScreen / HomeScreen)
      if (widget.contacts != null) {
        for (final c in widget.contacts!) {
          if (c.displayName.trim().isNotEmpty) {
            uidToNameMap[c.uid] = c.displayName.trim();
          }
          final norm = _normalizePhone(c.phoneNumber);
          if (norm.isNotEmpty && c.displayName.trim().isNotEmpty) {
            phoneToNameMap[norm] = c.displayName.trim();
          }
        }
      }

      // 2. Query device address book (phone contacts)
      try {
        final bool permission = await FlutterContacts.requestPermission(readonly: true);
        if (permission) {
          final deviceContacts = await FlutterContacts.getContacts(withProperties: true, withPhoto: false);
          for (final dc in deviceContacts) {
            final cName = dc.displayName.trim();
            if (cName.isNotEmpty) {
              for (final phone in dc.phones) {
                final norm = _normalizePhone(phone.number);
                if (norm.isNotEmpty) {
                  phoneToNameMap[norm] = cName;
                }
              }
            }
          }
        }
      } catch (ce) {
        debugPrint('[FORWARD CONTACTS PERMISSION ERR] $ce');
      }

      // 3. Fetch groups and registered users
      final groups = await _chatService.getMyGroups(widget.currentUser.uid);
      final users = await _chatService.getUsers(widget.currentUser.uid);

      final List<ForwardTarget> targets = [];

      // Add groups
      for (final g in groups) {
        targets.add(ForwardTarget(
          id: 'group_${g.id}',
          name: g.name,
          photoUrl: g.photoUrl,
          isGroup: true,
          subtitle: '${g.memberCount} üye • Grup',
        ));
      }

      // Add users
      for (final u in users) {
        if (u.uid != widget.currentUser.uid) {
          String resolvedName = u.displayName.trim();
          final norm = _normalizePhone(u.phoneNumber);

          if (uidToNameMap.containsKey(u.uid)) {
            resolvedName = uidToNameMap[u.uid]!;
          } else if (norm.isNotEmpty && phoneToNameMap.containsKey(norm)) {
            resolvedName = phoneToNameMap[norm]!;
          } else if (resolvedName.isEmpty) {
            resolvedName = u.username.isNotEmpty ? u.username : 'Talknex Kullanıcısı';
          }

          targets.add(ForwardTarget(
            id: u.uid,
            name: resolvedName,
            photoUrl: u.photoUrl,
            isGroup: false,
            subtitle: u.status.isNotEmpty
                ? u.status
                : (u.phoneNumber.isNotEmpty ? u.phoneNumber : 'Birebir Sohbet'),
            phone: u.phoneNumber,
          ));
        }
      }

      // Sort: Groups first, then users alphabetically by resolved name
      targets.sort((a, b) {
        if (a.isGroup != b.isGroup) {
          return a.isGroup ? -1 : 1;
        }
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

      if (mounted) {
        setState(() {
          _allTargets = targets;
          _filteredTargets = targets;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('[FORWARD LOAD ERR] $e');
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _onSearchChanged() {
    final q = _searchController.text.trim().toLowerCase();
    setState(() {
      if (q.isEmpty) {
        _filteredTargets = _allTargets;
      } else {
        _filteredTargets = _allTargets.where((t) {
          return t.name.toLowerCase().contains(q) ||
              t.subtitle.toLowerCase().contains(q) ||
              t.phone.replaceAll(RegExp(r'\D'), '').contains(q);
        }).toList();
      }
    });
  }

  void _toggleSelection(ForwardTarget target) {
    setState(() {
      if (_selectedTargetIds.contains(target.id)) {
        _selectedTargetIds.remove(target.id);
      } else {
        if (_selectedTargetIds.length >= 5) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('En fazla 5 sohbete aynı anda iletebilirsiniz.'),
              duration: Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
            ),
          );
          return;
        }
        _selectedTargetIds.add(target.id);
      }
    });
  }

  Future<void> _sendForwardedMessages() async {
    if (_selectedTargetIds.isEmpty || _isSending) return;

    setState(() => _isSending = true);

    try {
      final packedContent = MessageEnvelope.pack(
        text: widget.content,
        isForwarded: true,
      );

      for (final targetId in _selectedTargetIds) {
        final target = _allTargets.firstWhere(
          (t) => t.id == targetId,
          orElse: () => ForwardTarget(id: targetId, name: '', isGroup: false),
        );

        if (target.isGroup) {
          final gIdInt = int.tryParse(target.id.replaceFirst('group_', '')) ?? 0;
          if (gIdInt > 0) {
            final encrypted = EndToEndEncryptionService.encryptText(
              packedContent,
              widget.currentUser.uid,
              'group_$gIdInt',
            );
            _socketService.sendGroupMessage(
              groupId: gIdInt,
              senderId: widget.currentUser.uid,
              content: encrypted,
              type: widget.messageType,
              mediaUrl: widget.mediaUrl,
            );
          }
        } else {
          final encrypted = EndToEndEncryptionService.encryptText(
            packedContent,
            widget.currentUser.uid,
            target.id,
          );
          _socketService.sendMessage(
            senderId: widget.currentUser.uid,
            receiverId: target.id,
            content: encrypted,
            type: widget.messageType,
            mediaUrl: widget.mediaUrl,
          );
        }
      }

      if (mounted) {
        Navigator.pop(context, true);
      }
    } catch (e) {
      debugPrint('[FORWARD SEND ERR] $e');
      if (mounted) {
        setState(() => _isSending = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Mesaj iletilirken bir hata oluştu.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Column(
          children: [
            // Handle bar
            const SizedBox(height: 12),
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),

            // Header title
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.accent.withOpacity(0.18),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.shortcut_rounded, color: AppColors.accent, size: 20),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Mesajı İlet',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          'İletmek istediğiniz kişi veya grupları seçin (en fazla 5)',
                          style: TextStyle(color: Colors.white54, fontSize: 11.5),
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

            const SizedBox(height: 12),

            // Search bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Container(
                height: 42,
                decoration: BoxDecoration(
                  color: AppColors.surfaceLight,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.cardBorder),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  children: [
                    const Icon(Icons.search_rounded, color: AppColors.primaryLight, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        style: const TextStyle(color: Colors.white, fontSize: 14),
                        decoration: const InputDecoration(
                          hintText: 'Kişi veya grup ara...',
                          hintStyle: TextStyle(color: Colors.white38, fontSize: 13.5),
                          border: InputBorder.none,
                          isDense: true,
                        ),
                      ),
                    ),
                    if (_searchController.text.isNotEmpty)
                      GestureDetector(
                        onTap: () => _searchController.clear(),
                        child: const Icon(Icons.clear_rounded, color: Colors.white54, size: 18),
                      ),
                  ],
                ),
              ),
            ),

            // Horizontal selected chips preview bar (WhatsApp style)
            if (_selectedTargetIds.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                height: 74,
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _selectedTargetIds.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 12),
                  itemBuilder: (context, idx) {
                    final targetId = _selectedTargetIds.elementAt(idx);
                    final target = _allTargets.firstWhere(
                      (t) => t.id == targetId,
                      orElse: () => ForwardTarget(id: targetId, name: '', isGroup: false),
                    );
                    return GestureDetector(
                      onTap: () => _toggleSelection(target),
                      child: SizedBox(
                        width: 54,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Stack(
                              clipBehavior: Clip.none,
                              children: [
                                AppAvatar(
                                  radius: 20,
                                  imageUrl: target.photoUrl,
                                  name: target.name,
                                  isGroup: target.isGroup,
                                ),
                                Positioned(
                                  top: -2,
                                  right: -2,
                                  child: Container(
                                    padding: const EdgeInsets.all(2),
                                    decoration: BoxDecoration(
                                      color: Colors.grey.shade800,
                                      shape: BoxShape.circle,
                                      border: Border.all(color: AppColors.surface, width: 1.5),
                                    ),
                                    child: const Icon(Icons.close, size: 10, color: Colors.white),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              target.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white70, fontSize: 10.5),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              Divider(color: Colors.white.withOpacity(0.06), height: 1),
            ],

            const SizedBox(height: 8),

            // Targets list
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator(color: AppColors.accent))
                  : _filteredTargets.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.search_off_rounded, color: Colors.white.withOpacity(0.3), size: 48),
                              const SizedBox(height: 10),
                              const Text('Eşleşen sohbet bulunamadı.', style: TextStyle(color: Colors.white54, fontSize: 13.5)),
                            ],
                          ),
                        )
                      : ListView.separated(
                          controller: scrollController,
                          physics: const BouncingScrollPhysics(),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          itemCount: _filteredTargets.length,
                          separatorBuilder: (_, __) => Divider(color: Colors.white.withOpacity(0.04), height: 1),
                          itemBuilder: (ctx, index) {
                            final target = _filteredTargets[index];
                            final isSelected = _selectedTargetIds.contains(target.id);

                            return ListTile(
                              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              leading: Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  AppAvatar(
                                    radius: 22,
                                    imageUrl: target.photoUrl,
                                    name: target.name,
                                    isGroup: target.isGroup,
                                  ),
                                  if (target.isGroup)
                                    Positioned(
                                      bottom: -2,
                                      right: -2,
                                      child: Container(
                                        padding: const EdgeInsets.all(2.5),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF673AB7),
                                          shape: BoxShape.circle,
                                          border: Border.all(color: AppColors.surface, width: 1.5),
                                        ),
                                        child: const Icon(Icons.group, color: Colors.white, size: 10),
                                      ),
                                    ),
                                ],
                              ),
                              title: Text(
                                target.name,
                                style: const TextStyle(color: Colors.white, fontSize: 14.5, fontWeight: FontWeight.w600),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                target.subtitle.isNotEmpty
                                    ? target.subtitle
                                    : (target.isGroup ? 'Grup Sohbeti' : 'Birebir Sohbet'),
                                style: const TextStyle(color: Colors.white54, fontSize: 12),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: Container(
                                width: 24,
                                height: 24,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: isSelected ? AppColors.accent : Colors.transparent,
                                  border: Border.all(
                                    color: isSelected ? AppColors.accent : Colors.white30,
                                    width: 2,
                                  ),
                                ),
                                child: isSelected
                                    ? const Icon(Icons.check, size: 16, color: Colors.black)
                                    : null,
                              ),
                              onTap: () => _toggleSelection(target),
                            );
                          },
                        ),
            ),

            // Bottom action bar
            if (_selectedTargetIds.isNotEmpty)
              Container(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                decoration: BoxDecoration(
                  color: AppColors.surfaceLight,
                  border: Border(top: BorderSide(color: Colors.white.withOpacity(0.08))),
                ),
                child: SafeArea(
                  top: false,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${_selectedTargetIds.length} sohbet seçildi',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14),
                        ),
                      ),
                      ElevatedButton.icon(
                        onPressed: _isSending ? null : _sendForwardedMessages,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.accent,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                        icon: _isSending
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                              )
                            : const Icon(Icons.send_rounded, size: 18),
                        label: Text(
                          _isSending ? 'İletiliyor...' : 'İlet',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
