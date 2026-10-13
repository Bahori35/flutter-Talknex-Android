import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../../constants/app_colors.dart';
import '../../models/user_model.dart';
import '../../models/group_model.dart';
import '../../services/custom_auth_service.dart';
import '../../services/custom_chat_service.dart';
import '../../services/socket_service.dart';
import '../../services/encryption_service.dart';
import 'group_info_screen.dart';
import '../chat/location_picker_screen.dart';
import '../chat/widgets/video_message_bubble.dart';
import '../chat/widgets/decrypted_image_widget.dart';

class GroupChatScreen extends StatefulWidget {
  final GroupModel group;
  final UserModel currentUser;
  final List<UserModel> contacts;

  const GroupChatScreen({
    super.key,
    required this.group,
    required this.currentUser,
    this.contacts = const [],
  });

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
      final senderIdStr = data['senderId']?.toString() ?? '';
      // Don't duplicate text/media if sent by current user, but DO process poll creation
      if (senderIdStr == widget.currentUser.uid && data['type'] != 'poll') return;

      if (gId == _group.id && mounted) {
        final map = Map<String, dynamic>.from(data);
        if (map['type'] != 'poll') {
          final rawContent = data['content']?.toString() ?? '';
          final decrypted = EndToEndEncryptionService.decryptText(
            rawContent,
            senderIdStr,
            'group_${_group.id}',
          );
          map['content'] = decrypted;
        }

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

    // Listen for group message edits
    _socketService.onGroupMessageEdited = (editedId, gId, newText) {
      if (int.tryParse(gId) == _group.id && mounted) {
        setState(() {
          _messages = _messages.map((m) {
            if (m.id == editedId) {
              final decrypted = EndToEndEncryptionService.decryptText(
                newText,
                m.senderId,
                'group_${_group.id}',
              );
              return m.copyWith(isEdited: true, content: decrypted);
            }
            return m;
          }).toList();
        });
      }
    };

    // Listen for live group poll updates
    _socketService.onGroupPollUpdated = (data) {
      final gId = data['groupId'] is int ? data['groupId'] : int.tryParse(data['groupId']?.toString() ?? '0') ?? 0;
      if (gId == _group.id && mounted) {
        final pData = data['poll'];
        if (pData != null && pData is Map<String, dynamic>) {
          final updatedPoll = GroupPollModel.fromJson(Map<String, dynamic>.from(pData));
          setState(() {
            _messages = _messages.map((m) {
              if (m.poll?.id == updatedPoll.id || m.id == updatedPoll.messageId.toString()) {
                return m.copyWith(poll: updatedPoll);
              }
              return m;
            }).toList();
          });
        }
      }
    };

    // Listen for live group deletion/closing by creator
    _socketService.onGroupDeleted = (gId, msg) {
      if (gId == _group.id.toString() && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            backgroundColor: AppColors.callRed,
            duration: const Duration(seconds: 3),
          ),
        );
        Navigator.pop(context, true);
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

    if (caption == null) {
      _messageController.clear();
    }
  }

  // Pick Photo or Video from Camera or Gallery
  Future<void> _pickAndSendMedia({required ImageSource source, required bool isVideo}) async {
    try {
      XFile? file;
      if (isVideo) {
        file = await _picker.pickVideo(
          source: source,
          maxDuration: const Duration(minutes: 3),
        );
      } else {
        file = await _picker.pickImage(
          source: source,
          maxWidth: 1920,
          maxHeight: 1920,
          imageQuality: 85,
        );
      }

      if (file == null) return;

      setState(() {
        _isUploadingMedia = true;
      });

      File uploadTargetFile = File(file.path);
      File? tempEncryptedFile;
      try {
        tempEncryptedFile = await EndToEndEncryptionService.encryptFile(
          uploadTargetFile,
          widget.currentUser.uid,
          'group_${_group.id}',
        );
        uploadTargetFile = tempEncryptedFile;
      } catch (e) {
        debugPrint('[GROUP MEDIA ENCRYPTION ERR] $e');
      }

      final authService = CustomAuthService();
      final mediaUrl = await authService.uploadImage(uploadTargetFile.path);

      // Clean up temporary encrypted upload file
      if (tempEncryptedFile != null && tempEncryptedFile.existsSync()) {
        try {
          await tempEncryptedFile.delete();
        } catch (_) {}
      }

      if (mediaUrl != null && mounted) {
        // Cache original decrypted local file for sender
        try {
          if (isVideo) {
            final appDocDir = await getApplicationDocumentsDirectory();
            final videoCacheDir = Directory(p.join(appDocDir.path, 'video_cache'));
            if (!videoCacheDir.existsSync()) videoCacheDir.createSync(recursive: true);
            final persistentCopy = File(p.join(videoCacheDir.path, '${mediaUrl.hashCode}.mp4'));
            if (!persistentCopy.existsSync()) {
              await File(file.path).copy(persistentCopy.path);
            }
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('vfile_${mediaUrl.hashCode}', persistentCopy.path);
          } else {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('ifile_${mediaUrl.hashCode}', file.path);
          }
        } catch (e) {
          debugPrint('[GROUP SENDER LOCAL CACHE ERR] $e');
        }

        _sendMessage(
          type: isVideo ? 'video' : 'image',
          mediaUrl: mediaUrl,
          caption: isVideo ? '🎥 Video' : '📷 Fotoğraf',
        );
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Medya yüklenirken bir hata oluştu.'),
            backgroundColor: AppColors.callRed,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      debugPrint('[MEDIA PICK ERROR] $e');
    } finally {
      if (mounted) {
        setState(() {
          _isUploadingMedia = false;
        });
      }
    }
  }

  // Pick and send Document (PDF, Word, Excel, ZIP, APK, etc.)
  Future<void> _pickAndSendDoc() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty || result.files.single.path == null) {
        return;
      }

      final file = result.files.single;
      final filePath = file.path!;
      final fileName = file.name;

      setState(() {
        _isUploadingMedia = true;
      });

      final authService = CustomAuthService();
      final fileUrl = await authService.uploadFile(filePath);

      if (fileUrl != null && mounted) {
        _sendMessage(
          type: 'doc',
          mediaUrl: fileUrl,
          caption: fileName,
        );
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Dosya yüklenirken bir hata oluştu.'),
            backgroundColor: AppColors.callRed,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      debugPrint('[DOC PICK ERROR] $e');
    } finally {
      if (mounted) {
        setState(() {
          _isUploadingMedia = false;
        });
      }
    }
  }

  // Open interactive Location Picker Map Screen
  Future<void> _openLocationPicker() async {
    setState(() {
      _isUploadingMedia = true;
    });

    LatLng? initialPos;
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (serviceEnabled) {
        LocationPermission permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) {
          permission = await Geolocator.requestPermission();
        }

        if (permission == LocationPermission.whileInUse || permission == LocationPermission.always) {
          final lastKnown = await Geolocator.getLastKnownPosition();
          if (lastKnown != null) {
            initialPos = LatLng(lastKnown.latitude, lastKnown.longitude);
          }

          final current = await Geolocator.getCurrentPosition(
            desiredAccuracy: LocationAccuracy.high,
            timeLimit: const Duration(seconds: 4),
          ).catchError((_) => lastKnown ?? Position(
            longitude: 28.9784,
            latitude: 41.0082,
            timestamp: DateTime.now(),
            accuracy: 0,
            altitude: 0,
            altitudeAccuracy: 0,
            heading: 0,
            headingAccuracy: 0,
            speed: 0,
            speedAccuracy: 0,
          ));
          initialPos = LatLng(current.latitude, current.longitude);
        }
      }
    } catch (e) {
      debugPrint('[PRE-GPS ERROR] $e');
    } finally {
      if (mounted) {
        setState(() {
          _isUploadingMedia = false;
        });
      }
    }

    if (!mounted) return;

    final result = await Navigator.push<LocationPickerResult>(
      context,
      MaterialPageRoute(
        builder: (_) => LocationPickerScreen(initialLocation: initialPos),
      ),
    );

    if (result != null && mounted) {
      final isLive = result.isLive;
      final mapsUrl = 'https://maps.google.com/?q=${result.latitude},${result.longitude}';
      
      String content;
      if (isLive) {
        content = '📍 Canlı Konum\n${result.address}';
      } else {
        content = '📌 ${result.title}\n${result.address}';
      }

      _sendMessage(
        type: 'location',
        mediaUrl: mapsUrl,
        caption: content,
      );
    }
  }

  // Open / Launch external document link or Map URL
  Future<void> _openDocument(String url) async {
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        await launchUrl(uri, mode: LaunchMode.platformDefault);
      }
    } catch (e) {
      debugPrint('[OPEN DOC ERROR] $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Bağlantı açılamadı.'),
            backgroundColor: AppColors.callRed,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  void _openFullScreenImage(String imageUrl, {String? senderId}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            iconTheme: const IconThemeData(color: Colors.white),
          ),
          body: Center(
            child: InteractiveViewer(
              child: DecryptedImageWidget(
                imageUrl: imageUrl,
                senderId: senderId ?? widget.currentUser.uid,
                receiverId: 'group_${_group.id}',
                fit: BoxFit.contain,
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showEditMessageDialog(GroupMessageModel message) {
    final editController = TextEditingController(text: message.content);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Mesajı Düzenle', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: editController,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Yeni mesajı girin...',
            hintStyle: TextStyle(color: Colors.white38),
            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.accent)),
            focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.accent)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('İptal', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary),
            onPressed: () {
              final newText = editController.text.trim();
              if (newText.isNotEmpty && newText != message.content) {
                final encrypted = EndToEndEncryptionService.encryptText(
                  newText,
                  widget.currentUser.uid,
                  'group_${_group.id}',
                );
                _socketService.editGroupMessage(
                  messageId: message.id,
                  groupId: _group.id,
                  newContent: encrypted,
                );
                setState(() {
                  _messages = _messages.map((m) {
                    if (m.id == message.id) {
                      return m.copyWith(isEdited: true, content: newText);
                    }
                    return m;
                  }).toList();
                });
              }
              Navigator.pop(ctx);
            },
            child: const Text('Kaydet', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
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
            if (isMe && message.type == 'text' && isWithin15Minutes)
              ListTile(
                leading: const Icon(Icons.edit_rounded, color: AppColors.accent),
                title: const Text('Mesajı Düzenle', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                subtitle: const Text('15 dakika içinde düzenlenebilir', style: TextStyle(color: Colors.white38, fontSize: 11)),
                onTap: () {
                  Navigator.pop(ctx);
                  _showEditMessageDialog(message);
                },
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
    final res = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GroupInfoScreen(
          group: _group,
          currentUser: widget.currentUser,
          contacts: widget.contacts,
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

    if (res == true || res == 'deleted') {
      if (mounted) {
        Navigator.pop(context, true);
      }
    }
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

  Widget _buildPollWidget(GroupMessageModel message) {
    final poll = message.poll!;
    final now = DateTime.now();
    final isExpired = poll.isExpired || now.isAfter(poll.expiresAt);
    final diff = poll.expiresAt.difference(now);
    final canChange = !isExpired && diff.inMinutes > 60;

    String remainingText = '';
    if (isExpired) {
      remainingText = 'Süresi Doldu • Kapandı';
    } else if (diff.inDays > 0) {
      remainingText = '${diff.inDays} gün ${diff.inHours % 24} saat kaldı';
    } else if (diff.inHours > 0) {
      remainingText = '${diff.inHours} saat ${diff.inMinutes % 60} dk kaldı';
    } else {
      remainingText = '${diff.inMinutes > 0 ? diff.inMinutes : 1} dakika kaldı';
    }

    final hasAnyVote = poll.options.any((o) => o.hasVoted);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.amber.withOpacity(0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.poll_rounded, color: Colors.amberAccent, size: 20),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  poll.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    height: 1.3,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Timer / Status Badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: isExpired
                  ? AppColors.callRed.withOpacity(0.18)
                  : (!canChange
                      ? Colors.orange.withOpacity(0.18)
                      : AppColors.onlineGreen.withOpacity(0.18)),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isExpired
                    ? AppColors.callRed.withOpacity(0.4)
                    : (!canChange
                        ? Colors.orange.withOpacity(0.4)
                        : AppColors.onlineGreen.withOpacity(0.4)),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isExpired
                      ? Icons.lock_clock_rounded
                      : (!canChange ? Icons.hourglass_bottom_rounded : Icons.timer_outlined),
                  size: 13,
                  color: isExpired
                      ? AppColors.callRed
                      : (!canChange ? Colors.orangeAccent : AppColors.onlineGreen),
                ),
                const SizedBox(width: 5),
                Text(
                  remainingText,
                  style: TextStyle(
                    color: isExpired
                        ? AppColors.callRed
                        : (!canChange ? Colors.orangeAccent : AppColors.onlineGreen),
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (!canChange && !isExpired) ...[
                  const SizedBox(width: 4),
                  const Text('• Oylar Kilitli', style: TextStyle(color: Colors.orangeAccent, fontSize: 11, fontWeight: FontWeight.bold)),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Options List
          ...poll.options.map((option) {
            final pct = option.percentage;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () {
                  if (isExpired) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Bu anketin süresi dolduğu için oy kullanılamaz.'),
                        backgroundColor: AppColors.callRed,
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                    return;
                  }

                  if (!canChange && hasAnyVote) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Anket bitimine 1 saatten az kaldığı için oyunuzu değiştiremezsiniz.'),
                        backgroundColor: Colors.orange,
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                    return;
                  }

                  _socketService.voteGroupPoll(
                    groupId: _group.id,
                    pollId: poll.id,
                    optionIndex: option.index,
                  );
                },
                child: Container(
                  height: 44,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceLight,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: option.hasVoted ? AppColors.accent : Colors.white12,
                      width: option.hasVoted ? 1.5 : 1,
                    ),
                  ),
                  child: Stack(
                    children: [
                      // Progress fill in background
                      FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: (pct / 100).clamp(0.0, 1.0),
                        child: Container(
                          color: option.hasVoted
                              ? AppColors.accent.withOpacity(0.3)
                              : Colors.white.withOpacity(0.12),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          children: [
                            Icon(
                              option.hasVoted
                                  ? Icons.check_circle_rounded
                                  : Icons.radio_button_unchecked,
                              color: option.hasVoted ? AppColors.accent : Colors.white38,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                option.text,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 13.5,
                                  fontWeight: option.hasVoted ? FontWeight.bold : FontWeight.w500,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Text(
                              '${pct.toStringAsFixed(0)}% (${option.voteCount})',
                              style: TextStyle(
                                color: option.hasVoted ? AppColors.accent : Colors.white60,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Toplam ${poll.totalVotes} kişi oy kullandı',
                style: const TextStyle(color: Colors.white54, fontSize: 11.5),
              ),
              const Text(
                'Çoklu seçim yapılabilir',
                style: TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ],
          ),
          if (!canChange && !isExpired)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '⚠️ Bitime 1 saatten az kaldığı için oylar kilitlenmiştir.',
                style: TextStyle(color: Colors.orange.shade300, fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLocationWidget(GroupMessageModel message) {
    final isLive = message.content.contains('Canlı Konum');

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        if (message.mediaUrl != null && message.mediaUrl!.isNotEmpty) {
          _openDocument(message.mediaUrl!);
        }
      },
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.25),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 125,
              width: double.infinity,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                gradient: LinearGradient(
                  colors: isLive
                      ? [const Color(0xFF0F2027), const Color(0xFF203A43), const Color(0xFF2C5364)]
                      : [const Color(0xFF1E3C72), const Color(0xFF2A5298)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned.fill(
                    child: Opacity(
                      opacity: 0.12,
                      child: GridView.builder(
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 6,
                        ),
                        itemBuilder: (_, __) => Container(
                          margin: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.white, width: 0.5),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: isLive ? AppColors.onlineGreen : const Color(0xFFFF5722),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: (isLive ? AppColors.onlineGreen : const Color(0xFFFF5722)).withOpacity(0.5),
                              blurRadius: 10,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: Icon(
                          isLive ? Icons.sensors_rounded : Icons.location_on_rounded,
                          color: Colors.white,
                          size: 26,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        isLive ? 'Canlı Konum' : 'Haritada Görüntüle',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  isLive ? Icons.near_me_rounded : Icons.pin_drop_rounded,
                  color: isLive ? AppColors.onlineGreen : const Color(0xFFFF5722),
                  size: 18,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    message.content.isNotEmpty ? message.content : 'Paylaşılan Konum',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    isLive ? 'Canlı' : 'Harita',
                    style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDocumentWidget(GroupMessageModel message) {
    final fileName = message.content.isNotEmpty ? message.content : 'Belge';
    final ext = fileName.contains('.') ? fileName.split('.').last.toUpperCase() : 'DOSYA';
    final docColor = _getDocumentColor(fileName);
    final docIcon = _getDocumentIcon(fileName);

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        if (message.mediaUrl != null && message.mediaUrl!.isNotEmpty) {
          _openDocument(message.mediaUrl!);
        }
      },
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.25),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: docColor.withOpacity(0.2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(docIcon, color: docColor, size: 24),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    fileName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$ext • İndir / Aç',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            CircleAvatar(
              radius: 15,
              backgroundColor: Colors.white.withOpacity(0.2),
              child: const Icon(
                Icons.arrow_downward_rounded,
                color: Colors.white,
                size: 16,
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _getDocumentIcon(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.pdf')) return Icons.picture_as_pdf;
    if (lower.endsWith('.doc') || lower.endsWith('.docx')) return Icons.description;
    if (lower.endsWith('.xls') || lower.endsWith('.xlsx') || lower.endsWith('.csv')) return Icons.table_chart;
    if (lower.endsWith('.zip') || lower.endsWith('.rar') || lower.endsWith('.7z')) return Icons.folder_zip;
    if (lower.endsWith('.apk')) return Icons.android;
    if (lower.endsWith('.mp3') || lower.endsWith('.wav') || lower.endsWith('.m4a') || lower.endsWith('.aac')) return Icons.audiotrack;
    return Icons.insert_drive_file;
  }

  Color _getDocumentColor(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.pdf')) return const Color(0xFFE53935);
    if (lower.endsWith('.doc') || lower.endsWith('.docx')) return const Color(0xFF1E88E5);
    if (lower.endsWith('.xls') || lower.endsWith('.xlsx') || lower.endsWith('.csv')) return const Color(0xFF43A047);
    if (lower.endsWith('.zip') || lower.endsWith('.rar') || lower.endsWith('.7z')) return const Color(0xFFFB8C00);
    if (lower.endsWith('.apk')) return const Color(0xFF00897B);
    return const Color(0xFF5E35B1);
  }

  Widget _buildGroupMessageBubble(GroupMessageModel message, bool isMe) {
    final timeStr = DateFormat('HH:mm').format(message.timestamp);
    final isLocation = message.type == 'location';
    final isDoc = message.type == 'doc';
    final isVideo = message.type == 'video' || (message.mediaUrl != null && message.mediaUrl!.endsWith('.mp4'));
    final isPoll = message.type == 'poll' && message.poll != null;
    final hasMedia = message.mediaUrl != null && message.mediaUrl!.isNotEmpty;

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () => _showMessageOptions(message),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: EdgeInsets.all(isPoll ? 2 : (hasMedia && !isDoc && !isLocation ? 4 : 10)),
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * (isPoll ? 0.85 : 0.78)),
          decoration: BoxDecoration(
            color: message.isDeleted
                ? AppColors.surfaceLight.withOpacity(0.4)
                : (isPoll ? Colors.transparent : (isMe ? AppColors.primary : AppColors.surface)),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(isMe ? 16 : 4),
              bottomRight: Radius.circular(isMe ? 4 : 16),
            ),
            border: Border.all(
              color: (isMe || isPoll) ? Colors.transparent : AppColors.cardBorder,
              width: 0.8,
            ),
          ),
          child: Column(
            crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              // Show sender name for other members
              if (!isMe && !message.isDeleted)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4, left: 4),
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
                if (isPoll) ...[
                  _buildPollWidget(message),
                ] else if (isLocation) ...[
                  _buildLocationWidget(message),
                ] else if (isDoc) ...[
                  _buildDocumentWidget(message),
                ] else if (hasMedia) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: isVideo
                        ? VideoMessageBubble(
                            videoUrl: message.mediaUrl!,
                            title: message.content.isNotEmpty && message.content != '🎥 Video'
                                ? message.content
                                : 'Video Mesajı',
                            senderId: message.senderId,
                            receiverId: 'group_${_group.id}',
                          )
                        : GestureDetector(
                            onTap: () => _openFullScreenImage(message.mediaUrl!, senderId: message.senderId),
                            child: DecryptedImageWidget(
                              imageUrl: message.mediaUrl!,
                              senderId: message.senderId,
                              receiverId: 'group_${_group.id}',
                              width: double.infinity,
                              height: 200,
                              fit: BoxFit.cover,
                            ),
                          ),
                  ),
                  if (message.content.isNotEmpty && message.content != '📷 Fotoğraf' && message.content != '🎥 Video')
                    Padding(
                      padding: const EdgeInsets.fromLTRB(6, 6, 6, 2),
                      child: Text(
                        message.content,
                        style: const TextStyle(color: Colors.white, fontSize: 14.5),
                      ),
                    ),
                ] else ...[
                  Text(
                    message.content,
                    style: const TextStyle(color: Colors.white, fontSize: 14.5),
                  ),
                ],
              ],

              const SizedBox(height: 4),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: hasMedia ? 4 : 0),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (message.isEdited && !message.isDeleted) ...[
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.edit_rounded,
                            size: 11,
                            color: isMe ? Colors.white70 : AppColors.accent,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            'düzenlendi • ',
                            style: TextStyle(
                              color: isMe ? Colors.white70 : AppColors.accent,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ],
                      ),
                    ],
                    Text(
                      timeStr,
                      style: const TextStyle(color: Colors.white54, fontSize: 10),
                    ),
                  ],
                ),
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
              icon: const Icon(Icons.attach_file_rounded, color: AppColors.textSecondary),
              onPressed: _showMediaPickerSheet,
            ),
            IconButton(
              icon: const Icon(Icons.camera_alt_rounded, color: AppColors.primaryLight),
              onPressed: () => _pickAndSendMedia(source: ImageSource.camera, isVideo: false),
            ),
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: AppColors.surfaceLight,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: AppColors.cardBorder),
                ),
                child: TextField(
                  controller: _messageController,
                  style: const TextStyle(color: AppColors.textPrimary, fontSize: 14.5),
                  decoration: const InputDecoration(
                    hintText: 'Mesaj yazın...',
                    hintStyle: TextStyle(color: AppColors.textSecondary, fontSize: 14),
                    border: InputBorder.none,
                  ),
                  maxLines: null,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _sendMessage(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => _sendMessage(),
              child: Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  gradient: AppColors.primaryGradient,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.primary.withOpacity(0.4),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: const Icon(Icons.send_rounded, color: Colors.white, size: 20),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openCreatePollDialog() {
    final titleController = TextEditingController();
    final optionControllers = [
      TextEditingController(),
      TextEditingController(),
    ];
    final durationController = TextEditingController(text: '24');
    String durationType = 'hours';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
                top: 16,
                left: 20,
                right: 20,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: const [
                        Icon(Icons.poll_rounded, color: Colors.amberAccent, size: 24),
                        SizedBox(width: 8),
                        Text(
                          'Yeni Anket Başlat',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Anket Sorusu / Başlığı',
                      style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: titleController,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      decoration: InputDecoration(
                        hintText: 'Örn: Toplantı hangi gün olsun?',
                        hintStyle: const TextStyle(color: Colors.white38),
                        filled: true,
                        fillColor: AppColors.surfaceLight,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Seçenekler (En az 2 seçenek)',
                      style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    ...List.generate(optionControllers.length, (index) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: optionControllers[index],
                                style: const TextStyle(color: Colors.white, fontSize: 14),
                                decoration: InputDecoration(
                                  hintText: '${index + 1}. Seçenek',
                                  hintStyle: const TextStyle(color: Colors.white38),
                                  filled: true,
                                  fillColor: AppColors.surfaceLight,
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    borderSide: BorderSide.none,
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                ),
                              ),
                            ),
                            if (optionControllers.length > 2)
                              IconButton(
                                icon: const Icon(Icons.remove_circle_outline, color: AppColors.callRed),
                                onPressed: () {
                                  setModalState(() {
                                    optionControllers.removeAt(index);
                                  });
                                },
                              ),
                          ],
                        ),
                      );
                    }),
                    TextButton.icon(
                      onPressed: () {
                        setModalState(() {
                          optionControllers.add(TextEditingController());
                        });
                      },
                      icon: const Icon(Icons.add_circle_outline_rounded, color: AppColors.accent),
                      label: const Text('Seçenek Ekle', style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Anket Süresi',
                      style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        SizedBox(
                          width: 80,
                          child: TextField(
                            controller: durationController,
                            keyboardType: TextInputType.number,
                            style: const TextStyle(color: Colors.white, fontSize: 14),
                            decoration: InputDecoration(
                              filled: true,
                              fillColor: AppColors.surfaceLight,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide.none,
                              ),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            decoration: BoxDecoration(
                              color: AppColors.surfaceLight,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: durationType,
                                dropdownColor: AppColors.surface,
                                style: const TextStyle(color: Colors.white, fontSize: 14),
                                icon: const Icon(Icons.arrow_drop_down, color: Colors.white70),
                                items: const [
                                  DropdownMenuItem(value: 'hours', child: Text('Saat')),
                                  DropdownMenuItem(value: 'days', child: Text('Gün')),
                                  DropdownMenuItem(value: 'months', child: Text('Ay')),
                                ],
                                onChanged: (val) {
                                  if (val != null) {
                                    setModalState(() {
                                      durationType = val;
                                    });
                                  }
                                },
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.amber.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.amber.withOpacity(0.3)),
                      ),
                      child: const Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.info_outline_rounded, color: Colors.amberAccent, size: 18),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Üyeler anket bitimine son 1 saat kalana kadar oylarını değiştirebilir. Süresi dolduğunda anket oy kullanımına kapanır.',
                              style: TextStyle(color: Colors.white70, fontSize: 11.5, height: 1.3),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.accent,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        onPressed: () {
                          final title = titleController.text.trim();
                          final options = optionControllers
                              .map((c) => c.text.trim())
                              .where((s) => s.isNotEmpty)
                              .toList();
                          final durVal = int.tryParse(durationController.text.trim()) ?? 24;

                          if (title.isEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Lütfen anket başlığı girin.')),
                            );
                            return;
                          }
                          if (options.length < 2) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('En az 2 seçenek yazmalısınız.')),
                            );
                            return;
                          }
                          if (durVal <= 0) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Geçerli bir süre girin.')),
                            );
                            return;
                          }

                          _socketService.createGroupPoll(
                            groupId: _group.id,
                            senderId: widget.currentUser.uid,
                            title: title,
                            options: options,
                            durationType: durationType,
                            durationValue: durVal,
                          );

                          Navigator.pop(ctx);
                        },
                        child: const Text(
                          'Anketi Başlat',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showMediaPickerSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildMediaOption(
                      icon: Icons.insert_drive_file,
                      label: 'Belge / Dosya',
                      color: const Color(0xFF5F66CD),
                      onTap: () {
                        Navigator.pop(ctx);
                        _pickAndSendDoc();
                      },
                    ),
                    _buildMediaOption(
                      icon: Icons.camera_alt,
                      label: 'Fotoğraf Çek',
                      color: Colors.pinkAccent,
                      onTap: () {
                        Navigator.pop(ctx);
                        _pickAndSendMedia(source: ImageSource.camera, isVideo: false);
                      },
                    ),
                    _buildMediaOption(
                      icon: Icons.videocam,
                      label: 'Video Çek',
                      color: Colors.deepPurpleAccent,
                      onTap: () {
                        Navigator.pop(ctx);
                        _pickAndSendMedia(source: ImageSource.camera, isVideo: true);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildMediaOption(
                      icon: Icons.photo_library,
                      label: 'Galeri Foto',
                      color: Colors.blueAccent,
                      onTap: () {
                        Navigator.pop(ctx);
                        _pickAndSendMedia(source: ImageSource.gallery, isVideo: false);
                      },
                    ),
                    _buildMediaOption(
                      icon: Icons.video_library,
                      label: 'Galeri Video',
                      color: Colors.green,
                      onTap: () {
                        Navigator.pop(ctx);
                        _pickAndSendMedia(source: ImageSource.gallery, isVideo: true);
                      },
                    ),
                    _buildMediaOption(
                      icon: Icons.location_on_rounded,
                      label: 'Konum',
                      color: const Color(0xFFFF5722),
                      onTap: () {
                        Navigator.pop(ctx);
                        _openLocationPicker();
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildMediaOption(
                      icon: Icons.poll_rounded,
                      label: 'Anket',
                      color: Colors.amberAccent,
                      onTap: () {
                        Navigator.pop(ctx);
                        if (_group.isAdmin) {
                          _openCreatePollDialog();
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Yalnızca grup yöneticileri anket başlatabilir.'),
                              backgroundColor: AppColors.callRed,
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        }
                      },
                    ),
                    const SizedBox(width: 80),
                    const SizedBox(width: 80),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildMediaOption({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 28,
            backgroundColor: color.withOpacity(0.18),
            child: Icon(icon, color: color, size: 28),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: const TextStyle(color: AppColors.textPrimary, fontSize: 12, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}
