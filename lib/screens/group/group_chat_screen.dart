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
import '../../widgets/emoji_gif_sticker_picker.dart';

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
  final _focusNode = FocusNode();
  final _scrollController = ScrollController();
  final _socketService = SocketService();
  final _chatService = CustomChatService();
  final _picker = ImagePicker();

  late GroupModel _group;
  List<GroupMessageModel> _messages = [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  bool _isUploadingMedia = false;
  bool _showEmojiPicker = false;

  void _toggleEmojiPicker() {
    if (_showEmojiPicker) {
      setState(() {
        _showEmojiPicker = false;
      });
      _focusNode.requestFocus();
    } else {
      FocusScope.of(context).unfocus();
      setState(() {
        _showEmojiPicker = true;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _group = widget.group;
    _scrollController.addListener(_onScroll);
    _setupSocketListeners();
    _loadMessages();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _messageController.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _setupSocketListeners() {
    // Listen for live group messages
    _socketService.onGroupMessageReceived = (data) {
      final gId = data['groupId'] is int ? data['groupId'] : int.tryParse(data['groupId']?.toString() ?? '0') ?? 0;
      final senderIdStr = data['senderId']?.toString() ?? '';
      // Don't duplicate text/media if sent by current user, but DO process poll and event creation
      if (senderIdStr == widget.currentUser.uid && data['type'] != 'poll' && data['type'] != 'event') return;

      if (gId == _group.id && mounted) {
        final map = Map<String, dynamic>.from(data);
        if (map['type'] != 'poll' && map['type'] != 'event') {
          final rawContent = data['content']?.toString() ?? '';
          final decrypted = EndToEndEncryptionService.decryptText(
            rawContent,
            senderIdStr,
            'group_${_group.id}',
          );
          map['content'] = decrypted;
        }

        try {
          final newMsg = GroupMessageModel.fromJson(map);
          setState(() {
            _messages.insert(0, newMsg);
          });
        } catch (e) {
          debugPrint('[GROUP MSG RECEIVE ERR]: $e');
        }
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
        if (pData != null && pData is Map) {
          try {
            final updatedPoll = GroupPollModel.fromJson(Map<String, dynamic>.from(pData));
            setState(() {
              _messages = _messages.map((m) {
                if (m.poll?.id == updatedPoll.id || m.id == updatedPoll.messageId.toString()) {
                  return m.copyWith(poll: updatedPoll);
                }
                return m;
              }).toList();
            });
          } catch (e) {
            debugPrint('[GROUP POLL UPDATE ERR]: $e');
          }
        }
      }
    };

    // Listen for live group event updates
    _socketService.onGroupEventUpdated = (data) {
      final gId = data['groupId'] is int ? data['groupId'] : int.tryParse(data['groupId']?.toString() ?? '0') ?? 0;
      if (gId == _group.id && mounted) {
        final eData = data['event'];
        if (eData != null && eData is Map) {
          try {
            final updatedEvent = GroupEventModel.fromJson(Map<String, dynamic>.from(eData));
            setState(() {
              _messages = _messages.map((m) {
                if (m.event?.id == updatedEvent.id || m.id == updatedEvent.messageId.toString()) {
                  return m.copyWith(event: updatedEvent);
                }
                return m;
              }).toList();
            });
          } catch (e) {
            debugPrint('[GROUP EVENT UPDATE ERR]: $e');
          }
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

  void _onScroll() {
    if (_scrollController.hasClients &&
        _scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 250 &&
        !_isLoadingMore &&
        _hasMore) {
      _loadMoreMessages();
    }
  }

  void _loadMoreMessages() async {
    if (_isLoadingMore || !_hasMore || _messages.isEmpty) return;
    setState(() {
      _isLoadingMore = true;
    });

    final oldestMsg = _messages.last;
    final beforeId = oldestMsg.id;

    final olderMessages = await _chatService.getGroupMessages(
      _group.id,
      widget.currentUser.uid,
      limit: 40,
      beforeId: beforeId,
    );

    if (mounted) {
      setState(() {
        _isLoadingMore = false;
        if (olderMessages.isEmpty || olderMessages.length < 40) {
          _hasMore = false;
        }
        _messages.addAll(olderMessages.reversed);
      });
    }
  }

  void _loadMessages() async {
    final msgs = await _chatService.getGroupMessages(_group.id, widget.currentUser.uid, limit: 40);
    if (mounted) {
      setState(() {
        _messages = msgs.reversed.toList();
        _isLoading = false;
        _hasMore = msgs.length >= 40;
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
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final viewBottomPadding = MediaQuery.of(context).viewPadding.bottom;
    final bottomInset = bottomPadding > viewBottomPadding ? bottomPadding : viewBottomPadding;

    return PopScope(
      canPop: !_showEmojiPicker,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _showEmojiPicker) {
          setState(() {
            _showEmojiPicker = false;
          });
        }
      },
      child: Scaffold(
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

          // Emoji / GIF / Sticker Picker Tray
          if (_showEmojiPicker)
            SizedBox(
              height: 310 + bottomInset,
              child: EmojiGifStickerPicker(
                onEmojiSelected: (emoji) {
                  final text = _messageController.text;
                  final selection = _messageController.selection;
                  final newText = (selection.start >= 0 && selection.end >= 0)
                      ? selection.textBefore(text) + emoji + selection.textAfter(text)
                      : text + emoji;
                  final newOffset = (selection.start >= 0)
                      ? selection.baseOffset + emoji.length
                      : newText.length;
                  _messageController.value = TextEditingValue(
                    text: newText,
                    selection: TextSelection.collapsed(offset: newOffset),
                  );
                },
                onBackspacePressed: () {
                  final text = _messageController.text;
                  if (text.isNotEmpty) {
                    final runes = text.runes.toList();
                    runes.removeLast();
                    _messageController.text = String.fromCharCodes(runes);
                  }
                },
                onGifSelected: (gifUrl) {
                  _sendMessage(type: 'gif', mediaUrl: gifUrl, caption: '👾 GIF');
                },
                onStickerSelected: (stickerUrl) {
                  _sendMessage(type: 'sticker', mediaUrl: stickerUrl, caption: '🏷️ Çıkartma');
                },
              ),
            ),
        ],
      ),
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

  String _formatTurkishDateTime(DateTime dt) {
    const months = [
      'Ocak', 'Şubat', 'Mart', 'Nisan', 'Mayıs', 'Haziran',
      'Temmuz', 'Ağustos', 'Eylül', 'Ekim', 'Kasım', 'Aralık'
    ];
    final day = dt.day;
    final month = (dt.month >= 1 && dt.month <= 12) ? months[dt.month - 1] : dt.month.toString();
    final year = dt.year;
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$day $month $year, $hour:$minute';
  }

  String _formatTimeOnly(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  Widget _buildEventWidget(GroupMessageModel message) {
    final event = message.event;
    if (event == null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.cardBorder),
        ),
        child: Row(
          children: [
            const Icon(Icons.event_available_rounded, color: Color(0xFFCE93D8), size: 24),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message.content.isNotEmpty ? message.content : 'Etkinlik',
                style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      );
    }

    try {
      final now = DateTime.now();
      final isPast = event.isPast || now.isAfter(event.endTime);
      final isStarted = now.isAfter(event.startTime) && !isPast;

      final timeDisplay = '${_formatTurkishDateTime(event.startTime)} - ${_formatTimeOnly(event.endTime)}';

      String reminderLabel = '';
      if (event.reminderUnit == 'minutes' || event.reminderUnit == 'dakika') {
        reminderLabel = '${event.reminderValue} dakika önce';
      } else if (event.reminderUnit == 'days' || event.reminderUnit == 'gün') {
        reminderLabel = '${event.reminderValue} gün önce';
      } else {
        reminderLabel = '${event.reminderValue} saat önce';
      }

      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isStarted ? Colors.tealAccent.withOpacity(0.4) : AppColors.cardBorder,
            width: isStarted ? 1.4 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: Event icon & Title
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFAB47BC).withOpacity(0.18),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.event_available_rounded, color: Color(0xFFCE93D8), size: 24),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        event.title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          height: 1.25,
                        ),
                      ),
                      if (event.description.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          event.description,
                          style: const TextStyle(color: Colors.white70, fontSize: 12.5),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // Status & Reminder Badge row
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
                  decoration: BoxDecoration(
                    color: isPast
                        ? AppColors.callRed.withOpacity(0.18)
                        : (isStarted ? Colors.teal.withOpacity(0.2) : Colors.purple.withOpacity(0.18)),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: isPast
                          ? AppColors.callRed.withOpacity(0.4)
                          : (isStarted ? Colors.tealAccent.withOpacity(0.5) : const Color(0xFFAB47BC).withOpacity(0.4)),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isPast
                            ? Icons.event_busy_rounded
                            : (isStarted ? Icons.play_arrow_rounded : Icons.schedule_rounded),
                        size: 13,
                        color: isPast
                            ? AppColors.callRed
                            : (isStarted ? Colors.tealAccent : const Color(0xFFCE93D8)),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        isPast ? 'Sona Erdi' : (isStarted ? 'Şu Anda Devam Ediyor' : 'Planlandı'),
                        style: TextStyle(
                          color: isPast
                              ? AppColors.callRed
                              : (isStarted ? Colors.tealAccent : const Color(0xFFCE93D8)),
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
                  decoration: BoxDecoration(
                    color: Colors.amber.withOpacity(0.14),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.amber.withOpacity(0.3)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.notifications_active_rounded, size: 12, color: Colors.amberAccent),
                      const SizedBox(width: 4),
                      Text(
                        'Bildirim: $reminderLabel',
                        style: const TextStyle(color: Colors.amberAccent, fontSize: 11, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
                if (event.allowGuests)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
                    decoration: BoxDecoration(
                      color: Colors.blue.withOpacity(0.14),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.blue.withOpacity(0.3)),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.people_alt_rounded, size: 12, color: Colors.lightBlueAccent),
                        SizedBox(width: 4),
                        Text(
                          'Konuk İzni Açık',
                          style: TextStyle(color: Colors.lightBlueAccent, fontSize: 11, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),

            // Date & Time Box
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.surfaceLight,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Icon(Icons.access_time_rounded, color: AppColors.accent, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      timeDisplay,
                      style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),

            // Location Box (Clickable to open map/navigation)
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () {
                String mapUrl;
                if (event.latitude != 0.0 && event.longitude != 0.0) {
                  mapUrl = 'https://maps.google.com/?q=${event.latitude},${event.longitude}';
                } else {
                  mapUrl = 'https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent(event.location)}';
                }
                _openDocument(mapUrl);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.surfaceLight,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFFF7043).withOpacity(0.35)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.location_on_rounded, color: Color(0xFFFF7043), size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            event.location,
                            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                          ),
                          const SizedBox(height: 2),
                          const Text(
                            'Haritada Yol Tarifi Al ↗',
                            style: TextStyle(color: Color(0xFFFF7043), fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.navigation_rounded, color: Color(0xFFFF7043), size: 16),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Attendance summary bar (clickable to view attendees list)
            InkWell(
              onTap: () => _showEventAttendeesSheet(event),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          Text(
                            '✓ ${event.goingCount} Katılıyor${event.totalGuests > 0 ? ' (+${event.totalGuests} misafir)' : ''}',
                            style: const TextStyle(color: AppColors.onlineGreen, fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                          Text(
                            '? ${event.maybeCount} Belki',
                            style: const TextStyle(color: Colors.amberAccent, fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                          Text(
                            '✗ ${event.declinedCount} Katılmıyor',
                            style: const TextStyle(color: Colors.white54, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right_rounded, color: Colors.white38, size: 18),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            // RSVP Action Buttons
            if (isPast)
              const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    'Bu etkinlik sona ermiştir.',
                    style: TextStyle(color: Colors.white38, fontSize: 12, fontStyle: FontStyle.italic),
                  ),
                ),
              )
            else ...[
              const Text(
                'Katılım Durumunuz:',
                style: TextStyle(color: Colors.white70, fontSize: 11.5, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  // Katılacağım
                  Expanded(
                    child: _buildRsvpButton(
                      label: event.myStatus == 'going' && event.myGuestCount > 0
                          ? 'Katılıyorum (+${event.myGuestCount})'
                          : 'Katılacağım',
                      icon: Icons.check_circle_rounded,
                      isSelected: event.myStatus == 'going',
                      activeColor: AppColors.onlineGreen,
                      onTap: () {
                        if (event.allowGuests) {
                          _showGuestPickerDialog(event);
                        } else {
                          _socketService.rsvpGroupEvent(
                            groupId: _group.id,
                            eventId: event.id,
                            status: 'going',
                            guestCount: 0,
                          );
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 6),
                  // Belki
                  Expanded(
                    child: _buildRsvpButton(
                      label: 'Belki',
                      icon: Icons.help_outline_rounded,
                      isSelected: event.myStatus == 'maybe',
                      activeColor: Colors.amberAccent,
                      onTap: () {
                        _socketService.rsvpGroupEvent(
                          groupId: _group.id,
                          eventId: event.id,
                          status: 'maybe',
                          guestCount: 0,
                        );
                      },
                    ),
                  ),
                  const SizedBox(width: 6),
                  // Katılmayacağım
                  Expanded(
                    child: _buildRsvpButton(
                      label: 'Katılmıyorum',
                      icon: Icons.cancel_outlined,
                      isSelected: event.myStatus == 'declined',
                      activeColor: AppColors.callRed,
                      onTap: () {
                        _socketService.rsvpGroupEvent(
                          groupId: _group.id,
                          eventId: event.id,
                          status: 'declined',
                          guestCount: 0,
                        );
                      },
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      );
    } catch (e) {
      debugPrint('[EVENT WIDGET BUILD ERR] $e');
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(message.content, style: const TextStyle(color: Colors.white)),
      );
    }
  }

  Widget _buildRsvpButton({
    required String label,
    required IconData icon,
    required bool isSelected,
    required Color activeColor,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        decoration: BoxDecoration(
          color: isSelected ? activeColor.withOpacity(0.22) : AppColors.surfaceLight,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? activeColor : Colors.white12,
            width: isSelected ? 1.4 : 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: isSelected ? activeColor : Colors.white60,
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? activeColor : Colors.white70,
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  void _showGuestPickerDialog(GroupEventModel event) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: const [
                    Icon(Icons.people_alt_rounded, color: Color(0xFFCE93D8), size: 22),
                    SizedBox(width: 8),
                    Text(
                      'Kaç Konuk / Misafir Getireceksiniz?',
                      style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Yanınızda katılacak misafir sayısını seçebilirsiniz.',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: List.generate(6, (count) {
                    final isSel = event.myStatus == 'going' && event.myGuestCount == count;
                    return InkWell(
                      onTap: () {
                        Navigator.pop(ctx);
                        _socketService.rsvpGroupEvent(
                          groupId: _group.id,
                          eventId: event.id,
                          status: 'going',
                          guestCount: count,
                        );
                      },
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(
                          color: isSel ? AppColors.onlineGreen.withOpacity(0.2) : AppColors.surfaceLight,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: isSel ? AppColors.onlineGreen : Colors.white12,
                          ),
                        ),
                        child: Text(
                          count == 0 ? 'Yalnızca Ben (0 Misafir)' : '+$count Misafir',
                          style: TextStyle(
                            color: isSel ? AppColors.onlineGreen : Colors.white,
                            fontSize: 13,
                            fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showEventAttendeesSheet(GroupEventModel event) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final going = event.attendees.where((a) => a.status == 'going').toList();
        final maybe = event.attendees.where((a) => a.status == 'maybe').toList();
        final declined = event.attendees.where((a) => a.status == 'declined').toList();

        return Container(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: Column(
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
              const SizedBox(height: 14),
              Text(
                'Etkinlik Katılımcıları (${event.attendees.length})',
                style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 14),
              Expanded(
                child: ListView(
                  children: [
                    if (going.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Text(
                          'KATILANLAR (${going.length}${event.totalGuests > 0 ? ' + ${event.totalGuests} Misafir' : ''})',
                          style: const TextStyle(color: AppColors.onlineGreen, fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                      ),
                      ...going.map((a) => _buildAttendeeTile(a, AppColors.onlineGreen)),
                      const SizedBox(height: 12),
                    ],
                    if (maybe.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Text(
                          'BELKİ (${maybe.length})',
                          style: const TextStyle(color: Colors.amberAccent, fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                      ),
                      ...maybe.map((a) => _buildAttendeeTile(a, Colors.amberAccent)),
                      const SizedBox(height: 12),
                    ],
                    if (declined.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Text(
                          'KATILMAYANLAR (${declined.length})',
                          style: const TextStyle(color: AppColors.callRed, fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                      ),
                      ...declined.map((a) => _buildAttendeeTile(a, AppColors.callRed)),
                    ],
                    if (event.attendees.isEmpty)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: 30),
                          child: Text(
                            'Henüz kimse yanıt vermedi.',
                            style: TextStyle(color: Colors.white38, fontSize: 13),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildAttendeeTile(GroupEventAttendeeModel attendee, Color badgeColor) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: badgeColor.withOpacity(0.2),
            backgroundImage: attendee.photoUrl.isNotEmpty ? CachedNetworkImageProvider(attendee.photoUrl) : null,
            child: attendee.photoUrl.isEmpty
                ? Text(
                    attendee.name.isNotEmpty ? attendee.name[0].toUpperCase() : '?',
                    style: TextStyle(color: badgeColor, fontWeight: FontWeight.bold, fontSize: 13),
                  )
                : null,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              attendee.name,
              style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w500),
            ),
          ),
          if (attendee.guestCount > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.2),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.blue.withOpacity(0.4)),
              ),
              child: Text(
                '+${attendee.guestCount} misafir',
                style: const TextStyle(color: Colors.lightBlueAccent, fontSize: 11, fontWeight: FontWeight.bold),
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

  Widget _buildGroupStickerWidget(GroupMessageModel message, bool isMe) {
    return Column(
      crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: CachedNetworkImage(
            imageUrl: message.mediaUrl!,
            width: 145,
            height: 145,
            fit: BoxFit.contain,
            placeholder: (ctx, url) => const SizedBox(
              width: 145,
              height: 145,
              child: Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent),
                ),
              ),
            ),
            errorWidget: (ctx, url, err) => const SizedBox(
              width: 145,
              height: 145,
              child: Icon(Icons.broken_image_rounded, color: Colors.white38),
            ),
          ),
        ),
        const SizedBox(height: 2),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.4),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            DateFormat('HH:mm').format(message.timestamp),
            style: const TextStyle(color: Colors.white70, fontSize: 10),
          ),
        ),
      ],
    );
  }

  Widget _buildGroupGifWidget(GroupMessageModel message, bool isMe) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            children: [
              CachedNetworkImage(
                imageUrl: message.mediaUrl!,
                width: 220,
                height: 170,
                fit: BoxFit.cover,
                placeholder: (ctx, url) => Container(
                  width: 220,
                  height: 170,
                  color: AppColors.surfaceLight,
                  child: const Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
                    ),
                  ),
                ),
                errorWidget: (ctx, url, err) => Container(
                  width: 220,
                  height: 170,
                  color: AppColors.surfaceLight,
                  child: const Icon(Icons.broken_image_rounded, color: Colors.white38),
                ),
              ),
              Positioned(
                bottom: 6,
                left: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.7),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'GIF',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildGroupMessageBubble(GroupMessageModel message, bool isMe) {
    final timeStr = DateFormat('HH:mm').format(message.timestamp);
    final isLocation = message.type == 'location';
    final isDoc = message.type == 'doc';
    final isSticker = message.type == 'sticker' && message.mediaUrl != null && message.mediaUrl!.isNotEmpty;
    final isGif = message.type == 'gif' && message.mediaUrl != null && message.mediaUrl!.isNotEmpty;
    final isPoll = message.type == 'poll';
    final isEvent = message.type == 'event';
    final isSpecialCard = isPoll || isEvent;
    final hasMedia = message.mediaUrl != null && message.mediaUrl!.isNotEmpty;
    final isVideo = message.type == 'video' ||
        (hasMedia && !isDoc && !isLocation && !isSticker && !isGif && (message.mediaUrl!.endsWith('.mp4') || message.content.contains('🎥 Video')));

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () => _showMessageOptions(message),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: EdgeInsets.all(isSticker ? 0 : (isSpecialCard ? 2 : (hasMedia && !isDoc && !isLocation ? 4 : 10))),
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * (isSpecialCard ? 0.88 : 0.78)),
          decoration: isSticker
              ? null
              : BoxDecoration(
                  color: message.isDeleted
                      ? AppColors.surfaceLight.withOpacity(0.4)
                      : (isSpecialCard ? Colors.transparent : (isMe ? AppColors.primary : AppColors.surface)),
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(16),
                    topRight: const Radius.circular(16),
                    bottomLeft: Radius.circular(isMe ? 16 : 4),
                    bottomRight: Radius.circular(isMe ? 4 : 16),
                  ),
                  border: Border.all(
                    color: (isMe || isSpecialCard) ? Colors.transparent : AppColors.cardBorder,
                    width: 0.8,
                  ),
                ),
          child: Column(
            crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              // Show sender name for other members
              if (!isMe && !message.isDeleted && !isSticker)
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
                if (isSticker) ...[
                  _buildGroupStickerWidget(message, isMe),
                ] else if (isGif) ...[
                  _buildGroupGifWidget(message, isMe),
                ] else if (isPoll) ...[
                  _buildPollWidget(message),
                ] else if (isEvent) ...[
                  _buildEventWidget(message),
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

              if (!isSticker) ...[
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
        top: false,
        bottom: !_showEmojiPicker,
        child: Row(
          children: [
            // WhatsApp-style Emoji, GIF, Sticker Tray Toggle
            IconButton(
              icon: Icon(
                _showEmojiPicker ? Icons.keyboard_rounded : Icons.sentiment_satisfied_alt_rounded,
                color: _showEmojiPicker ? AppColors.accent : AppColors.textSecondary,
                size: 24,
              ),
              onPressed: _toggleEmojiPicker,
            ),
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
                  focusNode: _focusNode,
                  onTap: () {
                    if (_showEmojiPicker) {
                      setState(() {
                        _showEmojiPicker = false;
                      });
                    }
                  },
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

  void _openCreateEventDialog() {
    final titleController = TextEditingController();
    final descController = TextEditingController();
    final locationController = TextEditingController();
    final reminderValController = TextEditingController(text: '1');
    String reminderUnit = 'hours';
    bool allowGuests = true;
    double selectedLat = 0.0;
    double selectedLng = 0.0;

    DateTime selectedStart = DateTime.now().add(const Duration(days: 1));
    selectedStart = DateTime(selectedStart.year, selectedStart.month, selectedStart.day, selectedStart.hour + 1, 0);
    DateTime selectedEnd = selectedStart.add(const Duration(hours: 3));

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
            String formatDT(DateTime dt) {
              return '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
            }

            Future<void> pickDateTime({required bool isStart}) async {
              final initial = isStart ? selectedStart : selectedEnd;
              final pickedDate = await showDatePicker(
                context: context,
                initialDate: initial,
                firstDate: DateTime.now().subtract(const Duration(days: 1)),
                lastDate: DateTime.now().add(const Duration(days: 365 * 2)),
                builder: (context, child) {
                  return Theme(
                    data: ThemeData.dark().copyWith(
                      colorScheme: const ColorScheme.dark(
                        primary: Color(0xFFAB47BC),
                        onPrimary: Colors.white,
                        surface: AppColors.surface,
                        onSurface: Colors.white,
                      ),
                    ),
                    child: child!,
                  );
                },
              );
              if (pickedDate == null) return;

              final pickedTime = await showTimePicker(
                context: context,
                initialTime: TimeOfDay(hour: initial.hour, minute: initial.minute),
                builder: (context, child) {
                  return Theme(
                    data: ThemeData.dark().copyWith(
                      colorScheme: const ColorScheme.dark(
                        primary: Color(0xFFAB47BC),
                        onPrimary: Colors.white,
                        surface: AppColors.surface,
                        onSurface: Colors.white,
                      ),
                    ),
                    child: child!,
                  );
                },
              );
              if (pickedTime == null) return;

              final newDT = DateTime(
                pickedDate.year,
                pickedDate.month,
                pickedDate.day,
                pickedTime.hour,
                pickedTime.minute,
              );

              setModalState(() {
                if (isStart) {
                  selectedStart = newDT;
                  if (selectedEnd.isBefore(selectedStart)) {
                    selectedEnd = selectedStart.add(const Duration(hours: 2));
                  }
                } else {
                  selectedEnd = newDT;
                }
              });
            }

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
                        Icon(Icons.event_available_rounded, color: Color(0xFFCE93D8), size: 24),
                        SizedBox(width: 8),
                        Text(
                          'Yeni Grup Etkinliği',
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
                      'Etkinlik Başlığı *',
                      style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: titleController,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      decoration: InputDecoration(
                        hintText: 'Örn: Şirket Yemeği, Piknik, Toplantı',
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
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Etkinlik Konumu *',
                          style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                        TextButton.icon(
                          onPressed: () async {
                            final result = await Navigator.push<LocationPickerResult>(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const LocationPickerScreen(),
                              ),
                            );
                            if (result != null) {
                              setModalState(() {
                                selectedLat = result.latitude;
                                selectedLng = result.longitude;
                                final fullLoc = (result.title.isNotEmpty && result.title != 'Konumunuz'
                                        ? '${result.title}, '
                                        : '') +
                                    result.address;
                                locationController.text = fullLoc.trim();
                              });
                            }
                          },
                          icon: const Icon(Icons.map_rounded, size: 16, color: Color(0xFFCE93D8)),
                          label: const Text(
                            'Haritada İşaretle',
                            style: TextStyle(color: Color(0xFFCE93D8), fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: locationController,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      decoration: InputDecoration(
                        hintText: 'Örn: Beşiktaş Sahil Kafe veya haritadan seçin',
                        hintStyle: const TextStyle(color: Colors.white38),
                        prefixIcon: const Icon(Icons.location_on_rounded, color: Color(0xFFFF7043), size: 20),
                        suffixIcon: (selectedLat != 0.0 || selectedLng != 0.0)
                            ? const Icon(Icons.check_circle_rounded, color: AppColors.onlineGreen, size: 20)
                            : null,
                        filled: true,
                        fillColor: AppColors.surfaceLight,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      ),
                    ),
                    if (selectedLat != 0.0 || selectedLng != 0.0) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          const Icon(Icons.my_location_rounded, size: 13, color: AppColors.onlineGreen),
                          const SizedBox(width: 4),
                          Text(
                            'Haritadan işaretlendi (${selectedLat.toStringAsFixed(4)}, ${selectedLng.toStringAsFixed(4)})',
                            style: const TextStyle(color: AppColors.onlineGreen, fontSize: 11, fontWeight: FontWeight.w500),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 14),
                    const Text(
                      'Açıklama (İsteğe Bağlı)',
                      style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: descController,
                      maxLines: 2,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      decoration: InputDecoration(
                        hintText: 'Etkinlikle ilgili detayları yazabilirsiniz...',
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
                    // Start & End Date pickers
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Başlangıç',
                                style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 6),
                              InkWell(
                                onTap: () => pickDateTime(isStart: true),
                                borderRadius: BorderRadius.circular(12),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                                  decoration: BoxDecoration(
                                    color: AppColors.surfaceLight,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.calendar_today_rounded, size: 16, color: Color(0xFFCE93D8)),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          formatDT(selectedStart),
                                          style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Bitiş',
                                style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 6),
                              InkWell(
                                onTap: () => pickDateTime(isStart: false),
                                borderRadius: BorderRadius.circular(12),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                                  decoration: BoxDecoration(
                                    color: AppColors.surfaceLight,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.event_busy_rounded, size: 16, color: Colors.orangeAccent),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          formatDT(selectedEnd),
                                          style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Reminder Setting
                    const Text(
                      'Etkinlik Bildirim Zamanı',
                      style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        SizedBox(
                          width: 80,
                          child: TextField(
                            controller: reminderValController,
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
                                value: reminderUnit,
                                dropdownColor: AppColors.surface,
                                style: const TextStyle(color: Colors.white, fontSize: 14),
                                icon: const Icon(Icons.arrow_drop_down, color: Colors.white70),
                                items: const [
                                  DropdownMenuItem(value: 'minutes', child: Text('Dakika Önce')),
                                  DropdownMenuItem(value: 'hours', child: Text('Saat Önce')),
                                  DropdownMenuItem(value: 'days', child: Text('Gün Önce')),
                                ],
                                onChanged: (val) {
                                  if (val != null) {
                                    setModalState(() {
                                      reminderUnit = val;
                                    });
                                  }
                                },
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
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
                          Icon(Icons.notifications_active_rounded, color: Colors.amberAccent, size: 18),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Etkinliğe "Katılacağım" diyen kullanıcılara, etkinlik başlamadan belirttiğiniz vakit önce otomatik hatırlatma bildirimi gönderilecektir.',
                              style: TextStyle(color: Colors.white70, fontSize: 11.5, height: 1.3),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),

                    // Allow Guests Switch
                    Container(
                      decoration: BoxDecoration(
                        color: AppColors.surfaceLight,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: SwitchListTile(
                        value: allowGuests,
                        activeColor: const Color(0xFFAB47BC),
                        title: const Text(
                          'Konuk / Misafir Getirme İzni',
                          style: TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w600),
                        ),
                        subtitle: const Text(
                          'Katılımcılar yanlarında gelecek kişi sayısını belirtebilir.',
                          style: TextStyle(color: Colors.white54, fontSize: 11.5),
                        ),
                        onChanged: (val) {
                          setModalState(() {
                            allowGuests = val;
                          });
                        },
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Submit Button
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFAB47BC),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        onPressed: () {
                          final title = titleController.text.trim();
                          final loc = locationController.text.trim();
                          final desc = descController.text.trim();
                          final rVal = int.tryParse(reminderValController.text.trim()) ?? 1;

                          if (title.isEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Lütfen etkinlik başlığı girin.')),
                            );
                            return;
                          }
                          if (loc.isEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Lütfen etkinlik konumu girin.')),
                            );
                            return;
                          }
                          if (selectedEnd.isBefore(selectedStart) || selectedEnd.isAtSameMomentAs(selectedStart)) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Bitiş zamanı başlangıç zamanından sonra olmalıdır.')),
                            );
                            return;
                          }

                          _socketService.createGroupEvent(
                            groupId: _group.id,
                            senderId: widget.currentUser.uid,
                            title: title,
                            description: desc,
                            location: loc,
                            latitude: selectedLat,
                            longitude: selectedLng,
                            startTime: selectedStart,
                            endTime: selectedEnd,
                            reminderValue: rVal,
                            reminderUnit: reminderUnit,
                            allowGuests: allowGuests,
                          );

                          Navigator.pop(ctx);
                        },
                        child: const Text(
                          'Etkinliği Oluştur ve Paylaş',
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
                    _buildMediaOption(
                      icon: Icons.event_available_rounded,
                      label: 'Etkinlik',
                      color: const Color(0xFFAB47BC),
                      onTap: () {
                        Navigator.pop(ctx);
                        if (_group.isAdmin) {
                          _openCreateEventDialog();
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Yalnızca grup yöneticileri etkinlik oluşturabilir.'),
                              backgroundColor: AppColors.callRed,
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        }
                      },
                    ),
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
