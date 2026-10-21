import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../../constants/app_colors.dart';
import '../../models/message_model.dart';
import '../../models/user_model.dart';
import '../../models/call_model.dart';
import '../../services/custom_auth_service.dart';
import '../../services/custom_chat_service.dart';
import '../../services/socket_service.dart';
import '../call/call_screen.dart';
import 'location_picker_screen.dart';
import 'live_location_screen.dart';
import '../../services/live_location_service.dart';
import 'video_editor_screen.dart';
import 'photo_editor_screen.dart';
import 'camera_screen.dart';
import 'widgets/video_message_bubble.dart';
import 'widgets/decrypted_image_widget.dart';
import 'widgets/audio_message_bubble.dart';
import 'widgets/contact_picker_sheet.dart';
import 'widgets/contact_message_bubble.dart';
import '../../services/voice_record_service.dart';
import '../../services/encryption_service.dart';
import '../../widgets/emoji_gif_sticker_picker.dart';
import '../../widgets/app_avatar.dart';
import '../../models/message_envelope.dart';
import '../../services/starred_messages_service.dart';
import 'widgets/forward_message_sheet.dart';
import 'starred_messages_screen.dart';
import '../../services/message_reactions_service.dart';
import '../../widgets/reaction_widgets.dart';

class ChatScreen extends StatefulWidget {
  final UserModel currentUser;
  final UserModel peerUser;

  const ChatScreen({
    super.key,
    required this.currentUser,
    required this.peerUser,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  final CustomChatService _chatService = CustomChatService();
  final SocketService _socketService = SocketService();
  final LiveLocationService _liveLocationService = LiveLocationService();
  final ImagePicker _picker = ImagePicker();
  List<MessageModel> _messages = [];
  MessageModel? _replyingToMessage;
  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  bool _isUploadingMedia = false;
  String _uploadingStatusText = 'Dosya yükleniyor...';
  late UserModel _peer;
  StreamSubscription<bool>? _liveSharingStatusSub;
  StreamSubscription<Map<String, dynamic>>? _peerLiveLocationSub;
  StreamSubscription<Map<String, dynamic>>? _peerLiveStoppedSub;
  bool get _isSharingLiveLocation => _liveLocationService.isSharingWith(widget.peerUser.uid);
  bool _showEmojiPicker = false;
  bool _hasText = false;
  bool _isRecordingVoice = false;
  int _voiceRecordSeconds = 0;
  Timer? _voiceRecordTimer;
  double _voiceAmplitude = 0.0;
  Timer? _voiceAmpTimer;

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
    _peer = widget.peerUser;
    _messageController.addListener(_onMessageTextChanged);
    _scrollController.addListener(_onScroll);
    _liveSharingStatusSub = _liveLocationService.onSharingStatusChanged.listen((_) {
      if (mounted) setState(() {});
    });
    _peerLiveLocationSub = _socketService.liveLocationStream.listen((data) {
      if (mounted && data['senderId']?.toString() == widget.peerUser.uid) {
        setState(() {});
      }
    });
    _peerLiveStoppedSub = _socketService.liveLocationStoppedStream.listen((data) {
      if (mounted && data['senderId']?.toString() == widget.peerUser.uid) {
        setState(() {});
      }
    });
    _loadMessages();

    // Mark all existing messages as read when opening chat
    _socketService.emitMessageRead(
      senderId: widget.peerUser.uid,
      receiverId: widget.currentUser.uid,
    );

    // Listen for live messages received from socket
    _socketService.onMessageReceived = (message) {
      if (message.senderId == widget.peerUser.uid) {
        if (mounted) {
          setState(() {
            _messages.insert(0, message.copyWith(isRead: true, isDelivered: true));
          });
          // Immediately send read receipt back since chat is actively open
          _socketService.emitMessageRead(
            senderId: widget.peerUser.uid,
            receiverId: widget.currentUser.uid,
            messageId: message.id,
          );
        }
      }
    };

    // Listen for message delivered receipt (Gray Double Tick)
    _socketService.onMessageDelivered = (data) {
      if (mounted) {
        final messageId = data['messageId']?.toString();
        setState(() {
          _messages = _messages.map((m) {
            if (messageId != null) {
              if (m.id == messageId) {
                return m.copyWith(isDelivered: true);
              }
            } else if (m.senderId == widget.currentUser.uid) {
              return m.copyWith(isDelivered: true);
            }
            return m;
          }).toList();
        });
      }
    };

    // Listen for message read receipt (Blue Double Tick)
    _socketService.onMessageRead = (data) {
      if (mounted) {
        final messageId = data['messageId']?.toString();
        setState(() {
          _messages = _messages.map((m) {
            if (messageId != null) {
              if (m.id == messageId) {
                return m.copyWith(isDelivered: true, isRead: true);
              }
            } else if (m.senderId == widget.currentUser.uid) {
              return m.copyWith(isDelivered: true, isRead: true);
            }
            return m;
          }).toList();
        });
      }
    };

    // Listen for live status change of peer
    _socketService.onUserStatusChange = (userId, isOnline) {
      if (userId == widget.peerUser.uid && mounted) {
        setState(() {
          _peer = _peer.copyWith(isOnline: isOnline);
        });
      }
    };

    // Listen for message deletion
    _socketService.onMessageDeleted = (deletedId, [mode = 'everyone']) {
      if (mounted) {
        setState(() {
          if (mode == 'me') {
            _messages = _messages.where((m) => m.id != deletedId).toList();
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

    // Listen for message editing
    _socketService.onMessageEdited = (editedId, newText) {
      if (mounted) {
        setState(() {
          _messages = _messages.map((m) {
            if (m.id == editedId) {
              return m.copyWith(isEdited: true, content: newText);
            }
            return m;
          }).toList();
        });
      }
    };

    // Listen for server confirmation of sent message to replace temporary ID with DB ID
    _socketService.onMessageSent = (tempId, realId) {
      _liveLocationService.updateActiveMessageId(tempId, realId);
      if (mounted) {
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
    final beforeId = int.tryParse(oldestMsg.id);

    final olderMessages = await _chatService.getMessages(
      widget.currentUser.uid,
      widget.peerUser.uid,
      limit: 40,
      beforeId: beforeId,
    );

    if (mounted) {
      setState(() {
        _isLoadingMore = false;
        if (olderMessages.isEmpty || olderMessages.length < 40) {
          _hasMore = false;
        }
        // Append older messages to end of reversed list
        _messages.addAll(olderMessages.reversed);
      });
    }
  }

  void _loadMessages() async {
    final messages = await _chatService.getMessages(widget.currentUser.uid, widget.peerUser.uid, limit: 40);
    if (mounted) {
      setState(() {
        _messages = messages.reversed.toList();
        _isLoading = false;
        _hasMore = messages.length >= 40;
      });
      // Mark as read
      _socketService.emitMessageRead(
        senderId: widget.peerUser.uid,
        receiverId: widget.currentUser.uid,
      );
    }
  }

  @override
  void dispose() {
    _messageController.removeListener(_onMessageTextChanged);
    _voiceRecordTimer?.cancel();
    _voiceAmpTimer?.cancel();
    if (_isRecordingVoice) {
      VoiceRecordService.cancelRecording();
    }
    _scrollController.removeListener(_onScroll);
    _liveSharingStatusSub?.cancel();
    _peerLiveLocationSub?.cancel();
    _peerLiveStoppedSub?.cancel();
    _messageController.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onMessageTextChanged() {
    final hasText = _messageController.text.trim().isNotEmpty;
    if (hasText != _hasText) {
      setState(() {
        _hasText = hasText;
      });
    }
  }

  String _formatVoiceTimer(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _startVoiceRecording() async {
    final granted = await VoiceRecordService.requestPermission();
    if (!granted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Ses kaydı için mikrofon izni gereklidir.'),
            backgroundColor: AppColors.callRed,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    final path = await VoiceRecordService.startRecording();
    if (path == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Ses kaydı başlatılamadı.'),
            backgroundColor: AppColors.callRed,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    setState(() {
      _isRecordingVoice = true;
      _voiceRecordSeconds = 0;
      _showEmojiPicker = false;
    });

    _voiceRecordTimer?.cancel();
    _voiceRecordTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _voiceRecordSeconds++;
        });
      }
    });

    _voiceAmpTimer?.cancel();
    _voiceAmpTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) async {
      final amp = await VoiceRecordService.getAmplitude();
      if (mounted) {
        setState(() {
          _voiceAmplitude = (amp / 32767.0).clamp(0.1, 1.0);
        });
      }
    });
  }

  Future<void> _cancelVoiceRecording() async {
    _voiceRecordTimer?.cancel();
    _voiceAmpTimer?.cancel();
    await VoiceRecordService.cancelRecording();
    if (mounted) {
      setState(() {
        _isRecordingVoice = false;
        _voiceRecordSeconds = 0;
      });
    }
  }

  Future<void> _stopAndSendVoiceRecording() async {
    _voiceRecordTimer?.cancel();
    _voiceAmpTimer?.cancel();
    final result = await VoiceRecordService.stopRecording();
    if (mounted) {
      setState(() {
        _isRecordingVoice = false;
      });
    }

    if (result == null) return;

    if (result.durationMs < 1000) {
      try {
        File(result.filePath).deleteSync();
      } catch (_) {}
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Ses kaydı çok kısa.'),
            duration: Duration(milliseconds: 1200),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    await _sendVoiceMessage(result.filePath, result.durationMs);
  }

  Future<void> _sendVoiceMessage(String localPath, int durationMs) async {
    setState(() {
      _isUploadingMedia = true;
      _uploadingStatusText = 'Ses mesajı gönderiliyor...';
    });

    try {
      File uploadTargetFile = File(localPath);
      File? tempEncryptedFile;

      try {
        tempEncryptedFile = await EndToEndEncryptionService.encryptFile(
          uploadTargetFile,
          widget.currentUser.uid,
          widget.peerUser.uid,
        );
        if (tempEncryptedFile.existsSync()) {
          uploadTargetFile = tempEncryptedFile;
        }
      } catch (encErr) {
        debugPrint('[VOICE ENCRYPT ERR] $encErr');
      }

      final authService = Provider.of<CustomAuthService>(context, listen: false);
      final mediaUrl = await authService.uploadFile(uploadTargetFile.path);

      try {
        if (tempEncryptedFile != null && tempEncryptedFile.existsSync()) {
          await tempEncryptedFile.delete();
        }
      } catch (_) {}

      if (mediaUrl != null && mounted) {
        final durationSec = (durationMs / 1000).round();
        final mins = (durationSec ~/ 60).toString().padLeft(2, '0');
        final secs = (durationSec % 60).toString().padLeft(2, '0');
        final durationLabel = '$mins:$secs';

        _sendMessage(
          customContent: '🎤 Ses Mesajı ($durationLabel)',
          type: MessageType.audio,
          mediaUrl: mediaUrl,
        );
      }
    } catch (e) {
      debugPrint('[SEND VOICE ERR] $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Ses mesajı gönderilemedi.'),
            backgroundColor: AppColors.callRed,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isUploadingMedia = false;
        });
      }
    }
  }

  void _startLiveLocationSharing({String? messageId}) async {
    await _liveLocationService.startSharing(
      senderId: widget.currentUser.uid,
      receiverId: widget.peerUser.uid,
      messageId: messageId,
    );
    if (mounted) {
      setState(() {});
    }
  }

  void _stopLiveLocationSharing({String? messageId}) async {
    await _liveLocationService.stopSharing(messageId: messageId);
    if (mounted) {
      setState(() {});
    }
  }

  String _getMessageSnippet(MessageModel msg) {
    switch (msg.type) {
      case MessageType.image:
        return msg.content.isNotEmpty && msg.content != '📷 Fotoğraf' ? msg.content : '📷 Fotoğraf';
      case MessageType.video:
        return msg.content.isNotEmpty && msg.content != '🎥 Video' ? msg.content : '🎥 Video';
      case MessageType.audio:
        return '🎤 Sesli Mesaj';
      case MessageType.doc:
        return '📄 ${msg.content.isNotEmpty ? msg.content : "Belge"}';
      case MessageType.location:
        return '📍 Konum';
      case MessageType.contact:
        return '👤 Kişi Kartı';
      case MessageType.gif:
        return '👾 GIF';
      case MessageType.sticker:
        return '🏷️ Çıkartma';
      default:
        return MessageEnvelope.unpack(msg.content).text;
    }
  }

  void _setReplyMessage(MessageModel message) {
    setState(() {
      _replyingToMessage = message;
    });
    _focusNode.requestFocus();
  }

  void _cancelReply() {
    setState(() {
      _replyingToMessage = null;
    });
  }

  void _openForwardSheet(MessageModel message) async {
    final sent = await ForwardMessageSheet.show(
      context,
      currentUser: widget.currentUser,
      content: MessageEnvelope.unpack(message.content).text,
      messageType: message.type.name,
      mediaUrl: message.mediaUrl,
    );
    if (sent == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Mesaj iletildi'),
          backgroundColor: AppColors.primary,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _copyMessage(MessageModel message) {
    String textToCopy = MessageEnvelope.unpack(message.content).text;
    if (textToCopy.isEmpty) {
      if (message.mediaUrl != null && message.mediaUrl!.isNotEmpty) {
        textToCopy = message.mediaUrl!;
      } else {
        textToCopy = message.content;
      }
    }
    if (textToCopy.trim().isNotEmpty) {
      Clipboard.setData(ClipboardData(text: textToCopy));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Mesaj panoya kopyalandı'),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Kopyalanacak metin bulunamadı'),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  void _toggleStar(MessageModel message) async {
    final isMe = message.senderId == widget.currentUser.uid;
    final senderName = isMe ? 'Siz' : widget.peerUser.displayName;

    final starredItem = StarredMessage(
      messageId: message.id,
      chatId: widget.peerUser.uid,
      chatTitle: widget.peerUser.displayName,
      senderId: message.senderId,
      senderName: senderName,
      content: MessageEnvelope.unpack(message.content).text,
      type: message.type.name,
      mediaUrl: message.mediaUrl,
      timestamp: message.timestamp,
      isGroup: false,
    );

    final isStarredNow = await StarredMessagesService.toggleStar(starredItem);

    if (mounted) {
      setState(() {
        final idx = _messages.indexWhere((m) => m.id == message.id);
        if (idx != -1) {
          _messages[idx] = _messages[idx].copyWith(isStarred: isStarredNow);
        }
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isStarredNow ? 'Yıldızlandı' : 'Yıldız kaldırıldı'),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  MessageModel? _sendMessage({String? customContent, MessageType type = MessageType.text, String? mediaUrl, bool isForwarded = false}) {
    final text = (customContent ?? _messageController.text).trim();
    if (text.isEmpty && mediaUrl == null) return null;

    ReplyMetadata? replyMeta;
    if (_replyingToMessage != null) {
      final isMe = _replyingToMessage!.senderId == widget.currentUser.uid;
      final senderName = isMe ? 'Siz' : widget.peerUser.displayName;
      final snippet = _getMessageSnippet(_replyingToMessage!);
      replyMeta = ReplyMetadata(
        id: _replyingToMessage!.id,
        sender: senderName,
        text: snippet,
        type: _replyingToMessage!.type.name,
      );
    }

    final packedContent = MessageEnvelope.pack(
      text: text,
      replyTo: replyMeta,
      isForwarded: isForwarded,
    );

    final newMessage = MessageModel(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      senderId: widget.currentUser.uid,
      receiverId: widget.peerUser.uid,
      content: text,
      type: type,
      mediaUrl: mediaUrl,
      timestamp: DateTime.now(),
      isRead: false,
      replyTo: replyMeta,
      isForwarded: isForwarded,
    );

    // Encrypt the packed message text for transmission & server storage
    final encryptedContent = EndToEndEncryptionService.encryptText(
      packedContent,
      widget.currentUser.uid,
      widget.peerUser.uid,
    );

    // 1. Emit encrypted message via Socket.io to peer & save in MariaDB
    _socketService.sendMessage(
      senderId: widget.currentUser.uid,
      receiverId: widget.peerUser.uid,
      content: encryptedContent,
      type: type.name,
      mediaUrl: mediaUrl,
      clientTempId: newMessage.id,
    );

    // 2. Add unencrypted plaintext message to sender's local list so UI is immediate and smooth
    setState(() {
      _messages.insert(0, newMessage);
      _replyingToMessage = null;
    });

    if (customContent == null) {
      _messageController.clear();
    }
    return newMessage;
  }

  bool _isVideoFile(String filePath) {
    final ext = p.extension(filePath).toLowerCase();
    return ext == '.mp4' ||
        ext == '.mov' ||
        ext == '.avi' ||
        ext == '.mkv' ||
        ext == '.webm' ||
        ext == '.3gp' ||
        ext == '.flv' ||
        ext == '.m4v';
  }

  // Common helper to encrypt, upload, cache and send a single media file
  Future<void> _uploadAndSendSingleMedia(
    File unencryptedLocalFile, {
    required bool isVideo,
    required String caption,
    bool showLoadingState = true,
  }) async {
    if (showLoadingState) {
      setState(() {
        _isUploadingMedia = true;
        _uploadingStatusText = isVideo ? 'Video yükleniyor...' : 'Fotoğraf yükleniyor...';
      });
    }

    try {
      File uploadTargetFile = unencryptedLocalFile;
      File? tempEncryptedFile;
      try {
        tempEncryptedFile = await EndToEndEncryptionService.encryptFile(
          uploadTargetFile,
          widget.currentUser.uid,
          widget.peerUser.uid,
        );
        uploadTargetFile = tempEncryptedFile;
      } catch (e) {
        debugPrint('[MEDIA ENCRYPTION ERR] $e');
      }

      if (!mounted) return;
      final authService = Provider.of<CustomAuthService>(context, listen: false);
      final mediaUrl = await authService.uploadImage(uploadTargetFile.path);

      // Clean up temporary encrypted upload file
      if (tempEncryptedFile != null && tempEncryptedFile.existsSync()) {
        try {
          await tempEncryptedFile.delete();
        } catch (_) {}
      }

      if (mediaUrl != null && mounted) {
        // Cache original decrypted local file for sender permanently
        try {
          if (isVideo) {
            final appDocDir = await getApplicationDocumentsDirectory();
            final videoCacheDir = Directory(p.join(appDocDir.path, 'video_cache'));
            if (!videoCacheDir.existsSync()) videoCacheDir.createSync(recursive: true);
            final persistentCopy = File(p.join(videoCacheDir.path, '${mediaUrl.hashCode}.mp4'));
            if (!persistentCopy.existsSync()) {
              await unencryptedLocalFile.copy(persistentCopy.path);
            }
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('vfile_${mediaUrl.hashCode}', persistentCopy.path);
          } else {
            final appDocDir = await getApplicationDocumentsDirectory();
            final imageCacheDir = Directory(p.join(appDocDir.path, 'image_cache'));
            if (!imageCacheDir.existsSync()) imageCacheDir.createSync(recursive: true);
            final persistentCopy = File(p.join(imageCacheDir.path, '${mediaUrl.hashCode}.jpg'));
            if (!persistentCopy.existsSync()) {
              await unencryptedLocalFile.copy(persistentCopy.path);
            }
            final fileBasename = p.basenameWithoutExtension(mediaUrl);
            if (fileBasename.isNotEmpty) {
              final namedCopy = File(p.join(imageCacheDir.path, '$fileBasename.jpg'));
              if (!namedCopy.existsSync()) {
                await unencryptedLocalFile.copy(namedCopy.path);
              }
            }
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('ifile_${mediaUrl.hashCode}', persistentCopy.path);
          }
        } catch (e) {
          debugPrint('[SENDER LOCAL CACHE ERR] $e');
        }
        _sendMessage(
          customContent: caption,
          type: isVideo ? MessageType.video : MessageType.image,
          mediaUrl: mediaUrl,
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
      debugPrint('[UPLOAD MEDIA ERR] $e');
    } finally {
      if (showLoadingState && mounted) {
        setState(() {
          _isUploadingMedia = false;
          _uploadingStatusText = 'Dosya yükleniyor...';
        });
      }
    }
  }



  // Unified Gallery Picker: Pick up to 30 Photos & Videos combined
  Future<void> _pickAndSendFromGallery() async {
    try {
      final List<XFile> mediaList = await _picker.pickMultipleMedia(limit: 30);
      if (mediaList.isEmpty) return;

      final selectedFiles = mediaList.take(30).map((x) => File(x.path)).toList();
      if (!mounted) return;

      final editorResult = await Navigator.push<PhotoEditorResult>(
        context,
        MaterialPageRoute(
          builder: (_) => PhotoEditorScreen.multiple(imageFiles: selectedFiles),
        ),
      );

      if (editorResult == null) return; // User cancelled

      final results = editorResult.allResults ?? [editorResult];
      final int totalCount = results.length;

      setState(() {
        _isUploadingMedia = true;
        _uploadingStatusText = totalCount > 1
            ? '1/$totalCount medya gönderiliyor...'
            : 'Medya gönderiliyor...';
      });

      for (int i = 0; i < results.length; i++) {
        if (!mounted) break;
        final res = results[i];
        final isVid = res.isVideo;
        final caption = res.caption.isNotEmpty
            ? res.caption
            : (isVid ? '🎥 Video' : '📷 Fotoğraf');

        setState(() {
          _uploadingStatusText = totalCount > 1
              ? '${i + 1}/$totalCount medya gönderiliyor...'
              : 'Medya gönderiliyor...';
        });

        await _uploadAndSendSingleMedia(
          res.file,
          isVideo: isVid,
          caption: caption,
          showLoadingState: false,
        );
      }
    } catch (e) {
      debugPrint('[GALLERY PICK ERROR] $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Galeriden medya seçilirken bir hata oluştu.'),
            backgroundColor: AppColors.callRed,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isUploadingMedia = false;
          _uploadingStatusText = 'Dosya yükleniyor...';
        });
      }
    }
  }

  // Dedicated Video Editor & Sender (Opens VideoEditorScreen for trimming, music, mixer)
  Future<void> _pickAndEditVideo() async {
    try {
      final XFile? file = await _picker.pickVideo(
        source: ImageSource.gallery,
        maxDuration: const Duration(minutes: 10),
      );
      if (file == null) return;

      if (!mounted) return;

      final videoResult = await Navigator.push<VideoEditorResult>(
        context,
        MaterialPageRoute(
          builder: (_) => VideoEditorScreen(initialVideoFile: File(file.path)),
        ),
      );

      if (videoResult == null) return; // User cancelled editing

      final caption = videoResult.caption.isNotEmpty ? videoResult.caption : '🎥 Video';
      await _uploadAndSendSingleMedia(
        videoResult.file,
        isVideo: true,
        caption: caption,
      );
    } catch (e) {
      debugPrint('[VIDEO EDIT PICK ERROR] $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Video düzenlenirken bir hata oluştu.'),
            backgroundColor: AppColors.callRed,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  // Pick and send Document (PDF, Word, Excel, ZIP, APK, etc.)
  Future<void> _pickAndSendDocument() async {
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

      final authService = Provider.of<CustomAuthService>(context, listen: false);
      final fileUrl = await authService.uploadFile(filePath);

      if (fileUrl != null && mounted) {
        _sendMessage(
          customContent: fileName,
          type: MessageType.doc,
          mediaUrl: fileUrl,
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

  // Open / Download external document link
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
            content: Text('Dosya açılamadı veya indirilemedi.'),
            backgroundColor: AppColors.callRed,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  IconData _getDocumentIcon(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.pdf')) return Icons.picture_as_pdf;
    if (lower.endsWith('.doc') || lower.endsWith('.docx')) return Icons.description;
    if (lower.endsWith('.xls') || lower.endsWith('.xlsx') || lower.endsWith('.csv')) return Icons.table_chart;
    if (lower.endsWith('.zip') || lower.endsWith('.rar') || lower.endsWith('.7z') || lower.endsWith('.tar') || lower.endsWith('.gz')) return Icons.folder_zip;
    if (lower.endsWith('.apk')) return Icons.android;
    if (lower.endsWith('.txt')) return Icons.article;
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

  // Open WhatsApp-like interactive Location Picker Map Screen
  Future<void> _openLocationPicker() async {
    // Show a quick loading state while acquiring GPS
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
          // First try last known position for instant zero-delay coordinate
          final lastKnown = await Geolocator.getLastKnownPosition();
          if (lastKnown != null) {
            initialPos = LatLng(lastKnown.latitude, lastKnown.longitude);
          }

          // Then get high accuracy current position
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

      final sentMsg = _sendMessage(
        customContent: content,
        type: MessageType.location,
        mediaUrl: mapsUrl,
      );

      if (isLive) {
        _startLiveLocationSharing(messageId: sentMsg?.id);
      }
    }
  }

  // Direct In-App Camera Screen: Photo and Video switcher directly inside the live viewfinder
  Future<void> _openCameraScreen() async {
    final result = await Navigator.push<CameraCaptureResult>(
      context,
      MaterialPageRoute(
        builder: (_) => const CameraScreen(),
      ),
    );

    if (result == null || !mounted) return;

    final caption = result.caption.isNotEmpty
        ? result.caption
        : (result.isVideo ? '🎥 Video' : '📷 Fotoğraf');

    await _uploadAndSendSingleMedia(
      result.file,
      isVideo: result.isVideo,
      caption: caption,
    );
  }

  Future<void> _openContactPicker() async {
    final contactData = await ContactPickerSheet.show(context);
    if (contactData != null && mounted) {
      final jsonStr = jsonEncode(contactData.toJson());
      _sendMessage(
        customContent: jsonStr,
        type: MessageType.contact,
      );
    }
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
                      icon: Icons.photo_library_rounded,
                      label: 'Galeri',
                      color: Colors.blueAccent,
                      onTap: () {
                        Navigator.pop(ctx);
                        _pickAndSendFromGallery();
                      },
                    ),
                    _buildMediaOption(
                      icon: Icons.camera_alt_rounded,
                      label: 'Kamera',
                      color: Colors.pinkAccent,
                      onTap: () {
                        Navigator.pop(ctx);
                        _openCameraScreen();
                      },
                    ),
                    _buildMediaOption(
                      icon: Icons.movie_filter_rounded,
                      label: 'Video Düzenle',
                      color: const Color(0xFF9C27B0),
                      onTap: () {
                        Navigator.pop(ctx);
                        _pickAndEditVideo();
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildMediaOption(
                      icon: Icons.insert_drive_file_rounded,
                      label: 'Belge / Dosya',
                      color: const Color(0xFF5F66CD),
                      onTap: () {
                        Navigator.pop(ctx);
                        _pickAndSendDocument();
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
                    _buildMediaOption(
                      icon: Icons.person_rounded,
                      label: 'Kişi',
                      color: const Color(0xFF00BFA5),
                      onTap: () {
                        Navigator.pop(ctx);
                        _openContactPicker();
                      },
                    ),
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

  void _showMessageActionDialog(MessageModel message, bool isMe) {
    if (message.isDeleted) return; // Already deleted

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final currentReaction = MessageReactionsService.getUserReaction(message.id, widget.currentUser.uid);

        return SafeArea(
          child: Wrap(
            children: [
              Container(
                margin: const EdgeInsets.symmetric(vertical: 10),
                alignment: Alignment.center,
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              // WhatsApp style emoji reaction bar
              Center(
                child: EmojiReactionPickerBar(
                  currentReaction: currentReaction,
                  onReactionSelected: (emoji) async {
                    Navigator.pop(ctx);
                    final newEmoji = await MessageReactionsService.toggleReaction(
                      messageId: message.id,
                      userId: widget.currentUser.uid,
                      userName: widget.currentUser.displayName,
                      emoji: emoji,
                    );
                    _socketService.sendReaction(
                      messageId: message.id,
                      senderId: widget.currentUser.uid,
                      senderName: widget.currentUser.displayName,
                      receiverId: widget.peerUser.uid,
                      emoji: newEmoji ?? '',
                    );
                  },
                  onPlusPressed: () {
                    Navigator.pop(ctx);
                    _openCustomEmojiPickerForMessage(message.id);
                  },
                ),
              ),
              const Divider(color: Colors.white12, height: 16),
              // 1. Cevapla (Reply)
              ListTile(
                leading: const Icon(Icons.reply_rounded, color: AppColors.primaryLight),
                title: const Text('Cevapla', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                onTap: () {
                  Navigator.pop(ctx);
                  _setReplyMessage(message);
                },
              ),
              // 2. Kopyala (Copy)
              ListTile(
                leading: const Icon(Icons.copy_rounded, color: Colors.white70),
                title: const Text('Kopyala', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                onTap: () {
                  Navigator.pop(ctx);
                  _copyMessage(message);
                },
              ),
              // 3. İlet (Forward)
              ListTile(
                leading: const Icon(Icons.shortcut_rounded, color: AppColors.accent),
                title: const Text('İlet', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                onTap: () {
                  Navigator.pop(ctx);
                  _openForwardSheet(message);
                },
              ),
              // 3. Yıldız Ekle / Kaldır (Star / Unstar)
              Builder(
                builder: (context) {
                  final isStarred = message.isStarred || StarredMessagesService.isStarred(message.id);
                  return ListTile(
                    leading: Icon(
                      isStarred ? Icons.star_rounded : Icons.star_outline_rounded,
                      color: Colors.amber,
                    ),
                    title: Text(
                      isStarred ? 'Yıldızı Kaldır' : 'Yıldız Ekle',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      _toggleStar(message);
                    },
                  );
                },
              ),
              if (isMe && message.type == MessageType.text)
                Builder(
                  builder: (context) {
                    final isWithin15Minutes = DateTime.now().difference(message.timestamp).inMinutes < 15;
                    if (!isWithin15Minutes) return const SizedBox.shrink();

                    return ListTile(
                      leading: const Icon(Icons.edit_rounded, color: AppColors.accent),
                      title: const Text('Mesajı Düzenle', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                      subtitle: const Text('15 dakika içinde düzenlenebilir', style: TextStyle(color: Colors.white38, fontSize: 11)),
                      onTap: () {
                        Navigator.pop(ctx);
                        _showEditMessageDialog(message);
                      },
                    );
                  },
                ),
              Builder(
                builder: (context) {
                  final isWithin15Minutes = DateTime.now().difference(message.timestamp).inMinutes < 15;
                  final canDeleteForEveryone = isMe && isWithin15Minutes;

                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ListTile(
                        leading: const Icon(Icons.delete_outline_rounded, color: AppColors.callRed),
                        title: Text(
                          canDeleteForEveryone ? 'Mesajı Sil...' : 'Benden Sil',
                          style: const TextStyle(color: AppColors.callRed, fontWeight: FontWeight.w600),
                        ),
                        subtitle: canDeleteForEveryone
                            ? const Text('Herkesten veya sadece benden sil', style: TextStyle(color: Colors.white38, fontSize: 11))
                            : const Text('15 dakika dolduğu için sadece sizden silinir', style: TextStyle(color: Colors.white38, fontSize: 11)),
                        onTap: () {
                          Navigator.pop(ctx);
                          _confirmDeleteMessage(message, canDeleteForEveryone: canDeleteForEveryone);
                        },
                      ),
                    ],
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.close_rounded, color: Colors.white54),
                title: const Text('İptal', style: TextStyle(color: Colors.white54)),
                onTap: () => Navigator.pop(ctx),
              ),
            ],
          ),
        );
      },
    );
  }

  void _openCustomEmojiPickerForMessage(String messageId) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SizedBox(
          height: 320,
          child: EmojiGifStickerPicker(
            onEmojiSelected: (emoji) async {
              Navigator.pop(ctx);
              final newEmoji = await MessageReactionsService.toggleReaction(
                messageId: messageId,
                userId: widget.currentUser.uid,
                userName: widget.currentUser.displayName,
                emoji: emoji,
              );
              _socketService.sendReaction(
                messageId: messageId,
                senderId: widget.currentUser.uid,
                senderName: widget.currentUser.displayName,
                receiverId: widget.peerUser.uid,
                emoji: newEmoji ?? '',
              );
            },
            onBackspacePressed: () {},
            onGifSelected: (_) {},
            onStickerSelected: (_) {},
          ),
        );
      },
    );
  }

  void _confirmDeleteMessage(MessageModel message, {required bool canDeleteForEveryone}) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Mesajı Sil', style: TextStyle(color: Colors.white)),
        content: Text(
          canDeleteForEveryone
              ? 'Bu mesajı herkesten mi yoksa sadece kendinizden mi silmek istersiniz?\n(15 dakika sonra sadece kendinizden silebilirsiniz)'
              : '15 dakika dolduğu için bu mesaj sadece sizden silinecektir. Karşı taraf mesajı görmeye devam eder.',
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Vazgeç', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.surfaceLight),
            onPressed: () {
              Navigator.pop(ctx);
              // Delete for me
              _socketService.deleteMessage(
                messageId: message.id,
                senderId: widget.currentUser.uid,
                receiverId: widget.peerUser.uid,
                mode: 'me',
              );
              setState(() {
                _messages = _messages.where((m) => m.id != message.id).toList();
              });
            },
            child: const Text('Benden Sil', style: TextStyle(color: Colors.white)),
          ),
          if (canDeleteForEveryone)
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.callRed),
              onPressed: () {
                Navigator.pop(ctx);
                // Delete for everyone
                _socketService.deleteMessage(
                  messageId: message.id,
                  senderId: widget.currentUser.uid,
                  receiverId: widget.peerUser.uid,
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
              child: const Text('Herkesten Sil', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
        ],
      ),
    );
  }

  void _showEditMessageDialog(MessageModel message) {
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
            hintText: 'Yeni mesaj...',
            hintStyle: TextStyle(color: Colors.white38),
            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.accent)),
            focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.accent, width: 2)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('İptal', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent),
            onPressed: () {
              final newText = editController.text.trim();
              if (newText.isEmpty || newText == message.content) {
                Navigator.pop(ctx);
                return;
              }
              Navigator.pop(ctx);

              // Encrypt updated content for transmission
              final encNew = EndToEndEncryptionService.encryptText(
                newText,
                widget.currentUser.uid,
                widget.peerUser.uid,
              );

              // Emit live edit via socket
              _socketService.editMessage(
                messageId: message.id,
                senderId: widget.currentUser.uid,
                receiverId: widget.peerUser.uid,
                newContent: encNew,
              );

              // Update local list
              setState(() {
                _messages = _messages.map((m) {
                  if (m.id == message.id) {
                    return m.copyWith(isEdited: true, content: newText);
                  }
                  return m;
                }).toList();
              });
            },
            child: const Text('Kaydet', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _openFullScreenImage(String imageUrl, {String? senderId, String? receiverId}) {
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
                receiverId: receiverId ?? widget.peerUser.uid,
                fit: BoxFit.contain,
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _startCall(CallType callType) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CallScreen(
          currentUser: widget.currentUser,
          peerUser: widget.peerUser,
          callType: callType,
          isCaller: true,
        ),
      ),
    );
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
      backgroundColor: AppColors.chatBackground,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        leadingWidth: 40,
        titleSpacing: 0,
        elevation: 0,
        title: Row(
          children: [
            Stack(
              children: [
                AppAvatar(
                  radius: 20,
                  imageUrl: _peer.photoUrl,
                  name: _peer.displayName,
                ),
                if (_peer.isOnline)
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: AppColors.onlineGreen,
                        shape: BoxShape.circle,
                        border: Border.all(color: AppColors.surface, width: 2),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _peer.displayName,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    _peer.isOnline ? 'Çevrimiçi' : 'Çevrimdışı',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: _peer.isOnline ? AppColors.onlineGreen : AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: AppColors.accent.withOpacity(0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.videocam_rounded, color: AppColors.accent, size: 20),
            ),
            tooltip: 'Görüntülü Arama',
            onPressed: () => _startCall(CallType.video),
          ),
          IconButton(
            icon: Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: AppColors.primary.withOpacity(0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.call_rounded, color: AppColors.primaryLight, size: 18),
            ),
            tooltip: 'Sesli Arama',
            onPressed: () => _startCall(CallType.audio),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded, color: Colors.white70),
            color: AppColors.surfaceLight,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            onSelected: (val) {
              if (val == 'starred') {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => StarredMessagesScreen(
                      chatId: widget.peerUser.uid,
                      chatTitle: widget.peerUser.displayName,
                    ),
                  ),
                );
              }
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(
                value: 'starred',
                child: Row(
                  children: [
                    Icon(Icons.star_rounded, color: Colors.amber, size: 20),
                    SizedBox(width: 10),
                    Text('Yıldızlı Mesajlar', style: TextStyle(color: Colors.white, fontSize: 14)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          // Live location sharing banner (WhatsApp style)
          if (_liveLocationService.isSharingWith(widget.peerUser.uid))
            Material(
              color: AppColors.surface,
              child: InkWell(
                onTap: () {
                  final activeMsgId = _liveLocationService.activeMessageId;
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => LiveLocationScreen(
                        initialPosition: _liveLocationService.lastPosition ?? const LatLng(39.925533, 32.866287),
                        peerUser: widget.peerUser,
                        currentUser: widget.currentUser,
                        isMyLiveLocation: true,
                        isLiveActive: true,
                        messageId: activeMsgId,
                        onStopSharing: () => _stopLiveLocationSharing(messageId: activeMsgId),
                      ),
                    ),
                  );
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: AppColors.onlineGreen.withOpacity(0.35), width: 1),
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: AppColors.onlineGreen.withOpacity(0.15),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.sensors_rounded, color: AppColors.onlineGreen, size: 18),
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'Canlı konumunuzu paylaşıyorsunuz',
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: () => _stopLiveLocationSharing(messageId: _liveLocationService.activeMessageId),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                          decoration: BoxDecoration(
                            color: AppColors.callRed.withOpacity(0.18),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: AppColors.callRed.withOpacity(0.4)),
                          ),
                          child: const Text(
                            'Durdur',
                            style: TextStyle(
                              color: AppColors.callRed,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Peer live location sharing banner (WhatsApp style)
          if (!_liveLocationService.isSharingWith(widget.peerUser.uid) && _socketService.lastLiveLocations.containsKey(widget.peerUser.uid))
            Material(
              color: AppColors.surface,
              child: InkWell(
                onTap: () {
                  final peerLive = _socketService.lastLiveLocations[widget.peerUser.uid];
                  final lat = (peerLive?['latitude'] as num?)?.toDouble() ?? 39.925533;
                  final lon = (peerLive?['longitude'] as num?)?.toDouble() ?? 32.866287;
                  final peerMsgId = peerLive?['messageId']?.toString();
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => LiveLocationScreen(
                        initialPosition: LatLng(lat, lon),
                        peerUser: widget.peerUser,
                        currentUser: widget.currentUser,
                        isMyLiveLocation: false,
                        isLiveActive: true,
                        messageId: peerMsgId,
                      ),
                    ),
                  );
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: AppColors.onlineGreen.withOpacity(0.35), width: 1),
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: AppColors.onlineGreen.withOpacity(0.15),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.near_me_rounded, color: AppColors.onlineGreen, size: 18),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '${widget.peerUser.displayName} canlı konumunu paylaşıyor',
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                        decoration: BoxDecoration(
                          color: AppColors.onlineGreen.withOpacity(0.18),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppColors.onlineGreen.withOpacity(0.4)),
                        ),
                        child: const Text(
                          'Görüntüle',
                          style: TextStyle(
                            color: AppColors.onlineGreen,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Uploading banner
          if (_isUploadingMedia)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.primary.withOpacity(0.3)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent),
                  ),
                  const SizedBox(width: 10),
                  Text(_uploadingStatusText, style: const TextStyle(color: AppColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w500)),
                ],
              ),
            ),

          // Message List
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator(color: AppColors.primaryLight))
                : _messages.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              width: 70,
                              height: 70,
                              decoration: BoxDecoration(
                                color: AppColors.surface,
                                shape: BoxShape.circle,
                                border: Border.all(color: AppColors.cardBorder),
                              ),
                              child: const Icon(Icons.waving_hand_rounded, size: 34, color: AppColors.accent),
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              'Sohbete Başlayın 👋',
                              style: TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'Mesajlarınız uçtan uca güvenlidir.',
                              style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        reverse: true,
                        controller: _scrollController,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        itemCount: _messages.length,
                        itemBuilder: (context, index) {
                          final message = _messages[index];
                          final isMe = message.senderId == widget.currentUser.uid;
                          return _buildMessageBubble(message, isMe);
                        },
                      ),
          ),

          // Message Input Field
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
                  _sendMessage(type: MessageType.gif, mediaUrl: gifUrl, customContent: '👾 GIF');
                },
                onStickerSelected: (stickerUrl) {
                  _sendMessage(type: MessageType.sticker, mediaUrl: stickerUrl, customContent: '🏷️ Çıkartma');
                },
              ),
            ),
        ],
      ),
    ),
    );
  }

  Widget _buildDocumentWidget(MessageModel message) {
    final fileName = message.content.isNotEmpty ? message.content : 'Belge / Doküman';
    final docIcon = _getDocumentIcon(fileName);
    final docColor = _getDocumentColor(fileName);
    final ext = fileName.contains('.') ? fileName.split('.').last.toUpperCase() : 'DOC';

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        if (message.mediaUrl != null && message.mediaUrl!.isNotEmpty) {
          _openDocument(message.mediaUrl!);
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.2),
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

  Widget _buildLocationWidget(MessageModel message) {
    final isMe = message.senderId == widget.currentUser.uid;
    final isLiveType = message.content.contains('Canlı Konum');
    final isStopped = _liveLocationService.isMessageStopped(message.id);

    // Live is active ONLY if:
    // 1) It is a live location message
    // 2) It has NOT been stopped
    // 3) For sender (isMe): LiveLocationService is actively sharing with this peer
    //    AND (activeMessageId matches message.id OR this is the newest unstopped live location message in this conversation)
    // 4) For recipient (!isMe): Peer is actively broadcasting via socket AND peer messageId matches this message
    bool isLiveActive = false;
    if (isLiveType && !isStopped) {
      if (isMe) {
        if (_liveLocationService.isSharingWith(widget.peerUser.uid)) {
          if (_liveLocationService.activeMessageId == message.id) {
            isLiveActive = true;
          } else {
            // Find newest live location message sent by me that isn't stopped
            final latestMyLive = _messages.firstWhere(
              (m) => m.senderId == widget.currentUser.uid &&
                     m.content.contains('Canlı Konum') &&
                     !_liveLocationService.isMessageStopped(m.id),
              orElse: () => message,
            );
            if (latestMyLive.id == message.id) {
              isLiveActive = true;
              _liveLocationService.setActiveMessageId(message.id);
            }
          }
        }
      } else {
        final peerLive = _socketService.lastLiveLocations[widget.peerUser.uid];
        final peerMsgId = peerLive?['messageId']?.toString();
        isLiveActive = peerLive != null && (peerMsgId == null || peerMsgId == message.id);
      }
    }

    // Parse coordinates if available from mediaUrl (https://maps.google.com/?q=lat,lon)
    LatLng locationPos = const LatLng(39.925533, 32.866287);
    if (message.mediaUrl != null && message.mediaUrl!.contains('?q=')) {
      try {
        final qParam = message.mediaUrl!.split('?q=').last;
        final parts = qParam.split(',');
        if (parts.length >= 2) {
          final lat = double.parse(parts[0].trim());
          final lon = double.parse(parts[1].trim());
          locationPos = LatLng(lat, lon);
        }
      } catch (e) {
        debugPrint('[PARSE COORDS ERR] $e');
      }
    }

    // If actively streaming, use the latest real-time GPS coordinates
    if (isLiveActive) {
      if (isMe) {
        if (_liveLocationService.lastPosition != null) {
          locationPos = _liveLocationService.lastPosition!;
        }
      } else {
        final cachedLive = _socketService.lastLiveLocations[widget.peerUser.uid];
        if (cachedLive != null) {
          final cLat = (cachedLive['latitude'] as num?)?.toDouble();
          final cLon = (cachedLive['longitude'] as num?)?.toDouble();
          if (cLat != null && cLon != null) {
            locationPos = LatLng(cLat, cLon);
          }
        }
      }
    }

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        if (isLiveType) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => LiveLocationScreen(
                initialPosition: locationPos,
                peerUser: widget.peerUser,
                currentUser: widget.currentUser,
                isMyLiveLocation: isMe,
                isLiveActive: isLiveActive,
                messageId: message.id,
                onStopSharing: () => _stopLiveLocationSharing(messageId: message.id),
              ),
            ),
          );
        } else {
          if (message.mediaUrl != null && message.mediaUrl!.isNotEmpty) {
            _openDocument(message.mediaUrl!);
          }
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
                  colors: isLiveActive
                      ? [const Color(0xFF0F2027), const Color(0xFF203A43), const Color(0xFF2C5364)]
                      : isLiveType
                          ? [const Color(0xFF1E242B), const Color(0xFF232A32)]
                          : [const Color(0xFF1E3C72), const Color(0xFF2A5298)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Grid Pattern Effect
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

                  // Live pulsing rings (ONLY for active live location)
                  if (isLiveActive)
                    Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: AppColors.onlineGreen.withOpacity(0.4),
                          width: 2,
                        ),
                      ),
                    ),

                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: isLiveActive
                              ? AppColors.onlineGreen
                              : isLiveType
                                  ? Colors.white.withOpacity(0.12)
                                  : const Color(0xFFFF5722),
                          shape: BoxShape.circle,
                          boxShadow: isLiveActive
                              ? [
                                  BoxShadow(
                                    color: AppColors.onlineGreen.withOpacity(0.5),
                                    blurRadius: 10,
                                    spreadRadius: 2,
                                  ),
                                ]
                              : null,
                        ),
                        child: Icon(
                          isLiveActive
                              ? Icons.sensors_rounded
                              : isLiveType
                                  ? Icons.location_off_rounded
                                  : Icons.location_on_rounded,
                          color: Colors.white,
                          size: 26,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        isLiveActive
                            ? 'Canlı Takip Et'
                            : isLiveType
                                ? 'Konumu Görüntüle'
                                : 'Haritada Görüntüle',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ],
                  ),

                  // Top right badge
                  if (isLiveActive)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: AppColors.onlineGreen,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.fiber_manual_record, color: Colors.white, size: 8),
                            SizedBox(width: 4),
                            Text(
                              'CANLI',
                              style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                    )
                  else if (isLiveType)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.4),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.white24, width: 0.8),
                        ),
                        child: const Text(
                          'SONA ERDİ',
                          style: TextStyle(color: Colors.white60, fontSize: 10, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  isLiveActive
                      ? Icons.near_me_rounded
                      : isLiveType
                          ? Icons.location_off_rounded
                          : Icons.pin_drop_rounded,
                  color: isLiveActive
                      ? AppColors.onlineGreen
                      : isLiveType
                          ? Colors.white54
                          : const Color(0xFFFF5722),
                  size: 18,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    isLiveType && !isLiveActive
                        ? 'Canlı konum paylaşımı sona erdi'
                        : (message.content.isNotEmpty ? message.content : 'Paylaşılan Konum'),
                    style: TextStyle(
                      color: isLiveType && !isLiveActive ? Colors.white60 : Colors.white,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: isLiveActive
                        ? AppColors.onlineGreen.withOpacity(0.2)
                        : Colors.white.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    isLiveActive ? 'Canlı' : (isLiveType ? 'Sona Erdi' : 'Harita'),
                    style: TextStyle(
                      color: isLiveActive ? AppColors.onlineGreen : (isLiveType ? Colors.white60 : Colors.white),
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            if (isLiveActive && isMe) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () => _stopLiveLocationSharing(messageId: message.id),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.callRed.withOpacity(0.2),
                    foregroundColor: AppColors.callRed,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                      side: BorderSide(color: AppColors.callRed.withOpacity(0.4)),
                    ),
                  ),
                  icon: const Icon(Icons.stop_circle_outlined, size: 16),
                  label: const Text(
                    'Paylaşımı Durdur',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStickerMessageWidget(MessageModel message, bool isMe) {
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
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                DateFormat('HH:mm').format(message.timestamp),
                style: const TextStyle(color: Colors.white70, fontSize: 10),
              ),
              if (isMe && !message.isDeleted) ...[
                const SizedBox(width: 4),
                Icon(
                  (message.isRead || message.isDelivered) ? Icons.done_all_rounded : Icons.done_rounded,
                  size: 13,
                  color: message.isRead ? AppColors.accent : Colors.white70,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildGifMessageWidget(MessageModel message, bool isMe) {
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

  Widget _buildMessageBubble(MessageModel message, bool isMe) {
    final bool isLocation = message.type == MessageType.location;
    final bool isDoc = message.type == MessageType.doc;
    final bool isContact = message.type == MessageType.contact;
    final bool isSticker = message.type == MessageType.sticker && message.mediaUrl != null && message.mediaUrl!.isNotEmpty;
    final bool isGif = message.type == MessageType.gif && message.mediaUrl != null && message.mediaUrl!.isNotEmpty;
    final bool hasMedia = message.mediaUrl != null && message.mediaUrl!.isNotEmpty;
    final bool isVideo = message.type == MessageType.video ||
        (hasMedia && !isDoc && !isLocation && !isContact && !isSticker && !isGif && (message.mediaUrl!.endsWith('.mp4') || message.content.contains('🎥 Video')));
    final bool isAudio = message.type == MessageType.audio ||
        (hasMedia && !isVideo && !isDoc && !isLocation && !isContact && !isSticker && !isGif && (message.mediaUrl!.endsWith('.m4a') || message.mediaUrl!.endsWith('.aac') || message.mediaUrl!.endsWith('.mp3')));

    final bool isDeleted = message.isDeleted;
    final bool isEdited = message.isEdited;

    final unpacked = MessageEnvelope.unpack(message.content);
    final displayContent = unpacked.text;
    final effectiveReply = message.replyTo ?? unpacked.replyTo;
    final effectiveForwarded = message.isForwarded || unpacked.isForwarded;

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Dismissible(
        key: Key('reply_${message.id}'),
        direction: DismissDirection.startToEnd,
        confirmDismiss: (_) async {
          _setReplyMessage(message);
          return false;
        },
        background: Container(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.only(left: 16),
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.accent.withOpacity(0.2),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.reply_rounded, color: AppColors.accent, size: 20),
          ),
        ),
        child: GestureDetector(
          onLongPress: () => _showMessageActionDialog(message, isMe),
          child: ValueListenableBuilder<int>(
            valueListenable: MessageReactionsService.reactionNotifier,
            builder: (context, _, __) {
              final hasReactions = MessageReactionsService.getReactions(message.id).isNotEmpty;

              return Padding(
                padding: EdgeInsets.only(bottom: hasReactions ? 10.0 : 0.0),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      margin: const EdgeInsets.symmetric(vertical: 3.5),
                      padding: EdgeInsets.all(isSticker ? 0 : (isContact ? 4 : (hasMedia && !isDoc && !isLocation ? 4 : 10))),
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(context).size.width * 0.78,
                      ),
            decoration: isSticker
                ? null
                : BoxDecoration(
                    gradient: isMe ? (isDeleted ? null : AppColors.bubbleGradient) : null,
                    color: isDeleted 
                        ? (isMe ? Colors.white10 : Colors.white12) 
                        : (isMe ? null : AppColors.peerMessageBubble),
                    border: Border.all(
                      color: isDeleted ? Colors.white24 : (isMe ? Colors.transparent : AppColors.cardBorder),
                    ),
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(16),
                      topRight: const Radius.circular(16),
                      bottomLeft: Radius.circular(isMe ? 16 : 3),
                      bottomRight: Radius.circular(isMe ? 3 : 16),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.1),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (isDeleted) ...[
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.block_rounded, color: Colors.white54, size: 16),
                      const SizedBox(width: 6),
                      Text(
                        'Bu mesaj silindi',
                        style: TextStyle(
                          color: Colors.white60,
                          fontSize: 13.5,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                  ),
                ] else ...[
                  if (effectiveForwarded) _buildForwardedHeader(),
                  if (effectiveReply != null) _buildQuotedBox(effectiveReply, isMe),
                  if (isSticker) ...[
                    _buildStickerMessageWidget(message, isMe),
                  ] else if (isGif) ...[
                    _buildGifMessageWidget(message, isMe),
                  ] else if (isLocation) ...[
                    _buildLocationWidget(message),
                  ] else if (isContact) ...[
                    ContactMessageBubble(
                      message: message,
                      isMe: isMe,
                      currentUser: widget.currentUser,
                    ),
                  ] else if (isDoc) ...[
                    _buildDocumentWidget(message),
                  ] else if (isAudio) ...[
                    AudioMessageBubble(
                      audioUrl: message.mediaUrl!,
                      senderId: message.senderId,
                      receiverId: widget.peerUser.uid,
                      isMe: isMe,
                    ),
                  ] else if (hasMedia) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: isVideo
                          ? VideoMessageBubble(
                              videoUrl: message.mediaUrl!,
                              title: displayContent.isNotEmpty && displayContent != '🎥 Video'
                                  ? displayContent
                                  : 'Video Mesajı',
                              senderId: message.senderId,
                              receiverId: message.receiverId,
                            )
                          : GestureDetector(
                              onTap: () => _openFullScreenImage(message.mediaUrl!, senderId: message.senderId, receiverId: message.receiverId),
                              child: DecryptedImageWidget(
                                imageUrl: message.mediaUrl!,
                                senderId: message.senderId,
                                receiverId: message.receiverId,
                                width: double.infinity,
                                height: 200,
                                fit: BoxFit.cover,
                              ),
                            ),
                    ),
                    if (displayContent.isNotEmpty && displayContent != '📷 Fotoğraf' && displayContent != '🎥 Video')
                      Padding(
                        padding: const EdgeInsets.fromLTRB(6, 6, 6, 2),
                        child: Text(
                          displayContent,
                          style: const TextStyle(color: Colors.white, fontSize: 14.5),
                        ),
                      ),
                  ] else ...[
                    Text(
                      displayContent,
                      style: TextStyle(
                        color: isMe ? Colors.white : AppColors.textPrimary,
                        fontSize: 14.5,
                        height: 1.35,
                      ),
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
                        if (isEdited && !isDeleted) ...[
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
                          DateFormat('HH:mm').format(message.timestamp),
                          style: TextStyle(
                            color: isMe ? Colors.white70 : AppColors.textSecondary,
                            fontSize: 11,
                          ),
                        ),
                        if (message.isStarred || StarredMessagesService.isStarred(message.id)) ...[
                          const SizedBox(width: 3),
                          const Icon(
                            Icons.star_rounded,
                            size: 13,
                            color: Colors.amberAccent,
                          ),
                        ],
                        if (isMe && !isDeleted) ...[
                          const SizedBox(width: 4),
                          Icon(
                            (message.isRead || message.isDelivered) ? Icons.done_all_rounded : Icons.done_rounded,
                            size: 15,
                            color: message.isRead ? AppColors.accent : Colors.white70,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (hasReactions)
            Positioned(
              bottom: -6,
              right: isMe ? 12 : null,
              left: isMe ? null : 12,
              child: MessageReactionBadge(
                messageId: message.id,
                isMe: isMe,
              ),
            ),
        ],
      ),
    );
  },
),
),
),
);
}

  Widget _buildForwardedHeader() {
    return const Padding(
      padding: EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.shortcut_rounded, size: 13, color: Colors.white60),
          SizedBox(width: 4),
          Text(
            'İletildi',
            style: TextStyle(
              color: Colors.white60,
              fontSize: 11,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuotedBox(ReplyMetadata reply, bool isMe) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.22),
        borderRadius: BorderRadius.circular(8),
        border: Border(
          left: BorderSide(
            color: isMe ? AppColors.accent : const Color(0xFF00BFA5),
            width: 3.5,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            reply.sender,
            style: TextStyle(
              color: isMe ? AppColors.accent : const Color(0xFF00BFA5),
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            reply.text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReplyPreviewBanner() {
    if (_replyingToMessage == null) return const SizedBox.shrink();

    final isMe = _replyingToMessage!.senderId == widget.currentUser.uid;
    final senderName = isMe ? 'Siz' : widget.peerUser.displayName;
    final snippet = _getMessageSnippet(_replyingToMessage!);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceLight,
        border: Border(
          left: const BorderSide(color: AppColors.accent, width: 4),
          top: BorderSide(color: Colors.white.withOpacity(0.06)),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.reply_rounded, color: AppColors.accent, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  senderName,
                  style: const TextStyle(
                    color: AppColors.accent,
                    fontWeight: FontWeight.bold,
                    fontSize: 12.5,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  snippet,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, color: Colors.white60, size: 18),
            splashRadius: 18,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: _cancelReply,
          ),
        ],
      ),
    );
  }

  Widget _buildMessageInput() {
    if (_isRecordingVoice) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        color: AppColors.surface,
        child: SafeArea(
          top: false,
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded, color: AppColors.callRed, size: 24),
                tooltip: 'Kaydı İptal Et',
                onPressed: _cancelVoiceRecording,
              ),
              const SizedBox(width: 4),
              Container(
                width: 10,
                height: 10,
                decoration: const BoxDecoration(
                  color: AppColors.callRed,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.callRed,
                      blurRadius: 6,
                      spreadRadius: 1,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _formatVoiceTimer(_voiceRecordSeconds),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Row(
                  children: [
                    ...List.generate(5, (idx) {
                      final barH = (12.0 + (idx % 2 == 0 ? _voiceAmplitude * 16 : (1.0 - _voiceAmplitude) * 12)).clamp(6.0, 24.0);
                      return Container(
                        width: 3,
                        height: barH,
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        decoration: BoxDecoration(
                          color: AppColors.accent.withValues(alpha: 0.8),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      );
                    }),
                    const SizedBox(width: 8),
                    const Flexible(
                      child: Text(
                        'Kaydediliyor...',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white60,
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _stopAndSendVoiceRecording,
                child: Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    gradient: AppColors.primaryGradient,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.accent.withValues(alpha: 0.4),
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

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildReplyPreviewBanner(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          color: AppColors.surface,
          child: SafeArea(
            top: false,
            bottom: !_showEmojiPicker,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.surfaceLight,
                      borderRadius: BorderRadius.circular(25),
                      border: Border.all(color: AppColors.cardBorder),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        // WhatsApp-style Emoji, GIF, Sticker Tray Toggle
                        IconButton(
                          icon: Icon(
                            _showEmojiPicker ? Icons.keyboard_rounded : Icons.sentiment_satisfied_alt_rounded,
                            color: _showEmojiPicker ? AppColors.accent : AppColors.textSecondary,
                            size: 24,
                          ),
                          splashRadius: 20,
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                          constraints: const BoxConstraints(),
                          onPressed: _toggleEmojiPicker,
                        ),
                        Expanded(
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
                            style: const TextStyle(color: AppColors.textPrimary, fontSize: 15),
                            decoration: const InputDecoration(
                              hintText: 'Mesaj yazın...',
                              hintStyle: TextStyle(color: AppColors.textSecondary, fontSize: 14.5),
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 10),
                              isDense: true,
                            ),
                            maxLines: 5,
                            minLines: 1,
                            textInputAction: TextInputAction.newline,
                            onSubmitted: (_) => _sendMessage(),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.attach_file_rounded, color: AppColors.textSecondary, size: 22),
                          splashRadius: 20,
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                          constraints: const BoxConstraints(),
                          onPressed: _showMediaPickerSheet,
                        ),
                        IconButton(
                          icon: const Icon(Icons.camera_alt_rounded, color: AppColors.primaryLight, size: 22),
                          splashRadius: 20,
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                          constraints: const BoxConstraints(),
                          onPressed: _openCameraScreen,
                        ),
                        const SizedBox(width: 4),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  transitionBuilder: (child, anim) => ScaleTransition(scale: anim, child: child),
                  child: _hasText
                      ? GestureDetector(
                          key: const ValueKey('send_btn'),
                          onTap: () => _sendMessage(),
                          child: Container(
                            width: 46,
                            height: 46,
                            decoration: BoxDecoration(
                              gradient: AppColors.primaryGradient,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: AppColors.primary.withValues(alpha: 0.4),
                                  blurRadius: 10,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            child: const Icon(Icons.send_rounded, color: Colors.white, size: 20),
                          ),
                        )
                      : GestureDetector(
                          key: const ValueKey('mic_btn'),
                          onTap: _startVoiceRecording,
                          child: Container(
                            width: 46,
                            height: 46,
                            decoration: BoxDecoration(
                              gradient: AppColors.primaryGradient,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: AppColors.accent.withValues(alpha: 0.4),
                                  blurRadius: 10,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            child: const Icon(Icons.mic_rounded, color: Colors.white, size: 22),
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
