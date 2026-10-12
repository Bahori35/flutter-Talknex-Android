import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import '../../constants/app_colors.dart';
import '../../models/user_model.dart';
import '../../models/group_model.dart';
import '../../services/custom_auth_service.dart';
import '../../services/custom_chat_service.dart';
import '../../services/socket_service.dart';
import '../../services/encryption_service.dart';
import 'group_info_screen.dart';

class GroupChatScreen extends StatefulWidget {
  final GroupModel group;
  final UserModel currentUser;

  const GroupChatScreen({
    Key? key,
    required this.group,
    required this.currentUser,
  }) : super(key: key);

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final _socketService = SocketService();
  final _chatService = CustomChatService();
  final _picker = ImagePicker();

  late GroupModel _group;
  List<GroupMessageModel> _messages = [];
  bool _isLoading = true;
  bool _isUploadingMedia = false;

  @override
  void initState() {
    super.initState();
    _group = widget.group;
    _setupSocketListeners();
    _loadMessages();
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _setupSocketListeners() {
    // Listen for live group messages
    _socketService.onGroupMessageReceived = (data) {
      final gId = data['groupId'] is int ? data['groupId'] : int.tryParse(data['groupId']?.toString() ?? '0') ?? 0;
      if (gId == _group.id && mounted) {
        final rawContent = data['content']?.toString() ?? '';
        final decrypted = EndToEndEncryptionService.decryptText(
          rawContent,
          data['senderId']?.toString() ?? '',
          'group_${_group.id}',
        );
        final map = Map<String, dynamic>.from(data);
        map['content'] = decrypted;

        final newMsg = GroupMessageModel.fromJson(map);
        setState(() {
          _messages.insert(0, newMsg);
        });
      }
    };

    // Listen for live group message deletions
    _socketService.onGroupMessageDeleted = (deletedId, gId, [mode = 'everyone']) {
      final gIdInt = int.tryParse(gId) ?? 0;
      if (gIdInt == _group.id && mounted) {
        setState(() {
          if (mode == 'me') {
            _messages.removeWhere((m) => m.id == deletedId);
          } else {
            _messages = _messages.map((m) {
              if (m.id == deletedId) {
                return m.copyWith(isDeleted: true, content: 'Bu mesaj silindi');
              }
              return m;
            }).toList();
          }
        });
      }
    };

    // Replace temp ID with real DB ID
    _socketService.onGroupMessageSent = (tempId, realId, gId) {
      if (int.tryParse(gId) == _group.id && mounted) {
        setState(() {
          _messages = _messages.map((m) {
            if (m.id == tempId) {
              return m.copyWith(id: realId);
            }
            return m;
          }).toList();
        });
      }
    };
  }

  void _loadMessages() async {
    final msgs = await _chatService.getGroupMessages(_group.id, widget.currentUser.uid);
    if (mounted) {
      setState(() {
        _messages = msgs.reversed.toList();
        _isLoading = false;
      });
    }
  }

  void _sendMessage({String type = 'text', String? mediaUrl, String? caption}) {
    final text = caption ?? _messageController.text.trim();
    if (text.isEmpty && mediaUrl == null) return;

    final tempId = 'temp_${DateTime.now().millisecondsSinceEpoch}';
    final encrypted = EndToEndEncryptionService.encryptText(
      text,
      widget.currentUser.uid,
      'group_${_group.id}',
    );

    _socketService.sendGroupMessage(
      groupId: _group.id,
      senderId: widget.currentUser.uid,
      content: encrypted,
      type: type,
      mediaUrl: mediaUrl,
      clientTempId: tempId,
    );

    // Optimistically add to UI
    final optimisticMsg = GroupMessageModel(
      id: tempId,
      groupId: _group.id,
      senderId: widget.currentUser.uid,
      senderName: widget.currentUser.displayName,
      senderPhoto: widget.currentUser.photoUrl,
      content: text,
      type: type,
      mediaUrl: mediaUrl,
      timestamp: DateTime.now(),
    );

    setState(() {
      _messages.insert(0, optimisticMsg);
    });

    _messageController.clear();
  }

  Future<void> _pickAndSendImage() async {
    try {
      final XFile? file = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1200,
        maxHeight: 1200,
        imageQuality: 85,
      );
      if (file == null) return;

      setState(() => _isUploadingMedia = true);
      final authService = CustomAuthService();
      final uploadedUrl = await authService.uploadImage(file.path);
      setState(() => _isUploadingMedia = false);

      if (uploadedUrl != null) {
        _sendMessage(type: 'image', mediaUrl: uploadedUrl, caption: '📷 Fotoğraf');
      }
    } catch (e) {
      setState(() => _isUploadingMedia = false);
    }
  }

  Future<void> _pickAndSendVideo() async {
    try {
      final XFile? file = await _picker.pickVideo(source: ImageSource.gallery);
      if (file == null) return;

      setState(() => _isUploadingMedia = true);
      final authService = CustomAuthService();
      final uploadedUrl = await authService.uploadImage(file.path);
      setState(() => _isUploadingMedia = false);

      if (uploadedUrl != null) {
        _sendMessage(type: 'video', mediaUrl: uploadedUrl, caption: '🎥 Video');
      }
    } catch (e) {
      setState(() => _isUploadingMedia = false);
    }
  }

  Future<void> _pickAndSendDoc() async {
    try {
      final result = await FilePicker.platform.pickFiles();
      if (result == null || result.files.single.path == null) return;

      final file = File(result.files.single.path!);
      final fileName = result.files.single.name;

      setState(() => _isUploadingMedia = true);
      final authService = CustomAuthService();
      final uploadedUrl = await authService.uploadImage(file.path);
      setState(() => _isUploadingMedia = false);

      if (uploadedUrl != null) {
        _sendMessage(type: 'doc', mediaUrl: uploadedUrl, caption: fileName);
      }
    } catch (e) {
      setState(() => _isUploadingMedia = false);
    }
  }

  void _showMessageOptions(GroupMessageModel message) {
    if (message.isDeleted) return;

    final isMe = message.senderId == widget.currentUser.uid;
    final isAdmin = _group.isAdmin;
    final isWithin15Minutes = DateTime.now().difference(message.timestamp).inMinutes < 15;

    // Admin can delete anyone's message anytime! Sender can delete own message within 15 minutes!
    final canDeleteForEveryone = isAdmin || (isMe && isWithin15Minutes);

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            Container(
              margin: const EdgeInsets.symmetric(vertical: 10),
              alignment: Alignment.center,
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded, color: AppColors.callRed),
              title: Text(
                canDeleteForEveryone
                    ? (isAdmin && !isMe ? 'Yönetici Olarak Mesajı Sil' : 'Mesajı Sil...')
                    : 'Benden Sil',
                style: const TextStyle(color: AppColors.callRed, fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                canDeleteForEveryone
                    ? (isAdmin && !isMe ? 'Grup yöneticisi yetkinizle bu mesajı gruptan silebilirsiniz' : 'Herkesten veya sadece benden sil')
                    : '15 dakika dolduğu için sadece sizden silinir',
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _confirmDeleteMessage(message, canDeleteForEveryone: canDeleteForEveryone, isAdminAction: isAdmin && !isMe);
              },
            ),
            ListTile(
              leading: const Icon(Icons.close_rounded, color: Colors.white54),
              title: const Text('İptal', style: TextStyle(color: Colors.white54)),
              onTap: () => Navigator.pop(ctx),
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDeleteMessage(GroupMessageModel message, {required bool canDeleteForEveryone, bool isAdminAction = false}) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Mesajı Sil', style: TextStyle(color: Colors.white)),
        content: Text(
          isAdminAction
              ? 'Yönetici olarak bu üyenin mesajını tüm gruptan kaldırmak istiyor musunuz?'
              : (canDeleteForEveryone
                  ? 'Bu mesajı tüm gruptan mı yoksa sadece kendinizden mi silmek istersiniz?'
                  : 'Bu mesaj sadece sizden silinecektir.'),
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Vazgeç', style: TextStyle(color: Colors.white60)),
          ),
          if (!isAdminAction)
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.surfaceLight),
              onPressed: () {
                Navigator.pop(ctx);
                _socketService.deleteGroupMessage(
                  messageId: message.id,
                  groupId: _group.id,
                  mode: 'me',
                );
                setState(() {
                  _messages.removeWhere((m) => m.id == message.id);
                });
              },
              child: const Text('Benden Sil', style: TextStyle(color: Colors.white)),
            ),
          if (canDeleteForEveryone)
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.callRed),
              onPressed: () {
                Navigator.pop(ctx);
                _socketService.deleteGroupMessage(
                  messageId: message.id,
                  groupId: _group.id,
                  mode: 'everyone',
                );
                setState(() {
                  _messages = _messages.map((m) {
                    if (m.id == message.id) {
                      return m.copyWith(isDeleted: true, content: 'Bu mesaj silindi');
                    }
                    return m;
                  }).toList();
                });
              },
              child: Text(isAdminAction ? 'Gruptan Kaldır' : 'Herkesten Sil', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
        ],
      ),
    );
  }

  void _openGroupInfo() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GroupInfoScreen(
          group: _group,
          currentUser: widget.currentUser,
          onGroupUpdated: () async {
            final refreshed = await _chatService.getGroupDetails(_group.id);
            if (refreshed != null && mounted) {
              setState(() {
                _group = _group.copyWith(
                  name: refreshed['name'] ?? _group.name,
                  photoUrl: refreshed['photoUrl'] ?? _group.photoUrl,
                  description: refreshed['description'] ?? _group.description,
                  memberCount: refreshed['memberCount'] ?? _group.memberCount,
                );
              });
            }
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 1,
        titleSpacing: 0,
        title: InkWell(
          onTap: _openGroupInfo,
          child: Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: AppColors.surfaceLight,
                backgroundImage: _group.photoUrl.isNotEmpty
                    ? CachedNetworkImageProvider(_group.photoUrl)
                    : null,
                child: _group.photoUrl.isEmpty
                    ? const Icon(Icons.group_rounded, color: AppColors.textSecondary)
                    : null,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _group.name,
                      style: const TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '${_group.memberCount} katılımcı • Bilgi için dokunun',
                      style: const TextStyle(color: AppColors.accent, fontSize: 11),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline_rounded, color: AppColors.textPrimary),
            onPressed: _openGroupInfo,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_isUploadingMedia)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent)),
                  SizedBox(width: 10),
                  Text('Medya yükleniyor...', style: TextStyle(color: AppColors.textPrimary, fontSize: 13)),
                ],
              ),
            ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator(color: AppColors.primaryLight))
                : _messages.isEmpty
                    ? const Center(
                        child: Text(
                          'Grupta henüz mesaj yok.\nİlk mesajı yazarak sohbeti başlatın!',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
                        ),
                      )
                    : ListView.builder(
                        reverse: true,
                        controller: _scrollController,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        itemCount: _messages.length,
                        itemBuilder: (context, index) {
                          final msg = _messages[index];
                          final isMe = msg.senderId == widget.currentUser.uid;
                          return _buildGroupMessageBubble(msg, isMe);
                        },
                      ),
          ),
          _buildMessageInput(),
        ],
      ),
    );
  }

  Widget _buildGroupMessageBubble(GroupMessageModel message, bool isMe) {
    final timeStr = DateFormat('HH:mm').format(message.timestamp);

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () => _showMessageOptions(message),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
          decoration: BoxDecoration(
            color: message.isDeleted
                ? AppColors.surfaceLight.withOpacity(0.4)
                : (isMe ? AppColors.primary : AppColors.surface),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(isMe ? 16 : 4),
              bottomRight: Radius.circular(isMe ? 4 : 16),
            ),
            border: Border.all(
              color: isMe ? Colors.transparent : AppColors.cardBorder,
              width: 0.8,
            ),
          ),
          child: Column(
            crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              // Show sender name for other members
              if (!isMe && !message.isDeleted)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    message.senderName,
                    style: const TextStyle(
                      color: AppColors.accent,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),

              // Deleted message text
              if (message.isDeleted)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.block, size: 14, color: Colors.white54),
                    const SizedBox(width: 6),
                    Text(
                      message.content,
                      style: const TextStyle(color: Colors.white54, fontStyle: FontStyle.italic, fontSize: 13),
                    ),
                  ],
                )
              else ...[
                // Image message
                if (message.type == 'image' && message.mediaUrl != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: CachedNetworkImage(
                      imageUrl: message.mediaUrl!,
                      width: 220,
                      height: 180,
                      fit: BoxFit.cover,
                      placeholder: (_, __) => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                      errorWidget: (_, __, ___) => const Icon(Icons.broken_image, size: 40),
                    ),
                  ),

                // Video message
                if (message.type == 'video' && message.mediaUrl != null)
                  Container(
                    width: 220,
                    height: 130,
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Center(
                      child: Icon(Icons.play_circle_fill_rounded, color: Colors.white, size: 48),
                    ),
                  ),

                if (message.type == 'doc')
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.description, color: Colors.white, size: 24),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          message.content,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),

                if (message.type == 'text')
                  Text(
                    message.content,
                    style: const TextStyle(color: Colors.white, fontSize: 14.5),
                  ),
              ],

              const SizedBox(height: 4),
              Text(
                timeStr,
                style: const TextStyle(color: Colors.white54, fontSize: 10),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMessageInput() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      color: AppColors.surface,
      child: SafeArea(
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.add_photo_alternate_rounded, color: AppColors.primaryLight),
              onPressed: _showMediaPickerBottomSheet,
            ),
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: AppColors.surfaceLight,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: TextField(
                  controller: _messageController,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: const InputDecoration(
                    hintText: 'Mesaj yazın...',
                    hintStyle: TextStyle(color: Colors.white54),
                    border: InputBorder.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            CircleAvatar(
              backgroundColor: AppColors.primaryLight,
              radius: 22,
              child: IconButton(
                icon: const Icon(Icons.send_rounded, color: Colors.white, size: 20),
                onPressed: () => _sendMessage(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showMediaPickerBottomSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.image, color: Colors.green),
              title: const Text('Fotoğraf Gönder', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(ctx);
                _pickAndSendImage();
              },
            ),
            ListTile(
              leading: const Icon(Icons.video_collection, color: Colors.blue),
              title: const Text('Video Gönder', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(ctx);
                _pickAndSendVideo();
              },
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file, color: Colors.orange),
              title: const Text('Belge / Dosya Gönder', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(ctx);
                _pickAndSendDoc();
              },
            ),
          ],
        ),
      ),
    );
  }
}
