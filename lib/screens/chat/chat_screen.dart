import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
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
import 'video_editor_screen.dart';
import 'photo_editor_screen.dart';
import 'widgets/video_message_bubble.dart';
import 'widgets/decrypted_image_widget.dart';
import '../../services/encryption_service.dart';
import '../../widgets/emoji_gif_sticker_picker.dart';
import '../../widgets/app_avatar.dart';

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
  final ImagePicker _picker = ImagePicker();
  List<MessageModel> _messages = [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  bool _isUploadingMedia = false;
  String _uploadingStatusText = 'Dosya yükleniyor...';
  late UserModel _peer;
  StreamSubscription<Position>? _liveLocationSubscription;
  bool _isSharingLiveLocation = false;
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
    _peer = widget.peerUser;
    _scrollController.addListener(_onScroll);
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
    _scrollController.removeListener(_onScroll);
    _liveLocationSubscription?.cancel();
    _messageController.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _startLiveLocationSharing({String? messageId}) async {
    _liveLocationSubscription?.cancel();
    setState(() {
      _isSharingLiveLocation = true;
    });

    try {
      _liveLocationSubscription = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 3,
        ),
      ).listen((Position position) {
        if (_isSharingLiveLocation) {
          _socketService.emitLiveLocationUpdate(
            senderId: widget.currentUser.uid,
            receiverId: widget.peerUser.uid,
            latitude: position.latitude,
            longitude: position.longitude,
            heading: position.heading,
            speed: position.speed,
            messageId: messageId,
          );
        }
      });
    } catch (e) {
      debugPrint('[LIVE BROADCAST ERROR] $e');
    }
  }

  void _stopLiveLocationSharing({String? messageId}) {
    _liveLocationSubscription?.cancel();
    _liveLocationSubscription = null;
    setState(() {
      _isSharingLiveLocation = false;
    });
    _socketService.emitStopLiveLocation(
      senderId: widget.currentUser.uid,
      receiverId: widget.peerUser.uid,
      messageId: messageId,
    );
  }

  void _sendMessage({String? customContent, MessageType type = MessageType.text, String? mediaUrl}) {
    final text = (customContent ?? _messageController.text).trim();
    if (text.isEmpty && mediaUrl == null) return;

    final newMessage = MessageModel(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      senderId: widget.currentUser.uid,
      receiverId: widget.peerUser.uid,
      content: text,
      type: type,
      mediaUrl: mediaUrl,
      timestamp: DateTime.now(),
      isRead: false,
    );

    // Encrypt the message text for transmission & server storage
    final encryptedContent = EndToEndEncryptionService.encryptText(
      text,
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
    });

    if (customContent == null) {
      _messageController.clear();
    }
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

  // Pick Photo or Video from Camera (Normal video does NOT open editor)
  Future<void> _pickAndSendMedia({required ImageSource source, required bool isVideo}) async {
    try {
      XFile? file;
      if (isVideo) {
        file = await _picker.pickVideo(
          source: source,
          maxDuration: const Duration(minutes: 5),
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

      File unencryptedLocalFile = File(file.path);
      String caption = isVideo ? '🎥 Video' : '📷 Fotoğraf';

      // Photo Editor if media is an image
      if (!isVideo) {
        final editorResult = await Navigator.push<PhotoEditorResult>(
          context,
          MaterialPageRoute(
            builder: (_) => PhotoEditorScreen(imageFile: File(file!.path)),
          ),
        );
        if (editorResult == null) return; // User cancelled editing
        unencryptedLocalFile = editorResult.file;
        if (editorResult.caption.isNotEmpty) {
          caption = editorResult.caption;
        }
      }
      // Note: Normal video is sent directly without forcing video editor!

      await _uploadAndSendSingleMedia(
        unencryptedLocalFile,
        isVideo: isVideo,
        caption: caption,
      );
    } catch (e) {
      debugPrint('[MEDIA PICK ERROR] $e');
    }
  }

  // Unified Gallery Picker: Pick up to 30 Photos & Videos combined
  Future<void> _pickAndSendFromGallery() async {
    try {
      final List<XFile> mediaList = await _picker.pickMultipleMedia(limit: 30);
      if (mediaList.isEmpty) return;

      final selectedItems = mediaList.take(30).toList();
      final int totalCount = selectedItems.length;

      setState(() {
        _isUploadingMedia = true;
        _uploadingStatusText = totalCount > 1
            ? '1/$totalCount medya gönderiliyor...'
            : 'Medya gönderiliyor...';
      });

      for (int i = 0; i < selectedItems.length; i++) {
        if (!mounted) break;
        final xfile = selectedItems[i];
        final file = File(xfile.path);
        final isVideo = _isVideoFile(xfile.path);
        final caption = isVideo ? '🎥 Video' : '📷 Fotoğraf';

        setState(() {
          _uploadingStatusText = totalCount > 1
              ? '${i + 1}/$totalCount medya gönderiliyor...'
              : 'Medya gönderiliyor...';
        });

        await _uploadAndSendSingleMedia(
          file,
          isVideo: isVideo,
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

      _sendMessage(
        customContent: content,
        type: MessageType.location,
        mediaUrl: mapsUrl,
      );

      if (isLive) {
        _startLiveLocationSharing();
      }
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
                      icon: Icons.movie_filter_rounded,
                      label: 'Video Düzenle',
                      color: const Color(0xFF9C27B0),
                      onTap: () {
                        Navigator.pop(ctx);
                        _pickAndEditVideo();
                      },
                    ),
                    _buildMediaOption(
                      icon: Icons.insert_drive_file_rounded,
                      label: 'Belge / Dosya',
                      color: const Color(0xFF5F66CD),
                      onTap: () {
                        Navigator.pop(ctx);
                        _pickAndSendDocument();
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildMediaOption(
                      icon: Icons.camera_alt_rounded,
                      label: 'Fotoğraf Çek',
                      color: Colors.pinkAccent,
                      onTap: () {
                        Navigator.pop(ctx);
                        _pickAndSendMedia(source: ImageSource.camera, isVideo: false);
                      },
                    ),
                    _buildMediaOption(
                      icon: Icons.videocam_rounded,
                      label: 'Video Çek',
                      color: Colors.deepPurpleAccent,
                      onTap: () {
                        Navigator.pop(ctx);
                        _pickAndSendMedia(source: ImageSource.camera, isVideo: true);
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
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
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
    final isLive = message.content.contains('Canlı Konum');
    final isMe = message.senderId == widget.currentUser.uid;

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

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        if (isLive) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => LiveLocationScreen(
                initialPosition: locationPos,
                peerUser: widget.peerUser,
                currentUser: widget.currentUser,
                isMyLiveLocation: isMe,
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

                  // Live pulsing rings
                  if (isLive)
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
                        isLive ? 'Canlı Takip Et' : 'Haritada Görüntüle',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ],
                  ),

                  // Top right live badge
                  if (isLive)
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
    final bool isSticker = message.type == MessageType.sticker && message.mediaUrl != null && message.mediaUrl!.isNotEmpty;
    final bool isGif = message.type == MessageType.gif && message.mediaUrl != null && message.mediaUrl!.isNotEmpty;
    final bool hasMedia = message.mediaUrl != null && message.mediaUrl!.isNotEmpty;
    final bool isVideo = message.type == MessageType.video ||
        (hasMedia && !isDoc && !isLocation && !isSticker && !isGif && (message.mediaUrl!.endsWith('.mp4') || message.content.contains('🎥 Video')));

    final bool isDeleted = message.isDeleted;
    final bool isEdited = message.isEdited;

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () => _showMessageActionDialog(message, isMe),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3.5),
          padding: EdgeInsets.all(isSticker ? 0 : (hasMedia && !isDoc && !isLocation ? 4 : 10)),
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
                if (isSticker) ...[
                  _buildStickerMessageWidget(message, isMe),
                ] else if (isGif) ...[
                  _buildGifMessageWidget(message, isMe),
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
}
