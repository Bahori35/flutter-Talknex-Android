import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:intl/intl.dart';

import '../../constants/app_colors.dart';
import '../../models/user_model.dart';
import '../../models/call_model.dart';
import '../../models/story_model.dart';
import '../../services/custom_auth_service.dart';
import '../../services/custom_chat_service.dart';
import '../../services/socket_service.dart';
import '../../services/notification_service.dart';
import '../../models/group_model.dart';
import '../chat/chat_screen.dart';
import '../call/call_screen.dart';
import '../profile/profile_screen.dart';
import '../story/story_view_screen.dart';
import '../story/add_story_screen.dart';
import '../group/create_group_screen.dart';
import '../group/group_chat_screen.dart';
import '../../services/encryption_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final CustomChatService _chatService = CustomChatService();
  final SocketService _socketService = SocketService();
  final NotificationService _notificationService = NotificationService();
  final TextEditingController _searchController = TextEditingController();
  bool _isSearching = false;
  String _searchQuery = '';
  List<UserModel> _users = [];
  bool _isLoadingUsers = true;

  // Phone Contacts Match
  List<UserModel> _phoneContacts = [];
  bool _isSyncingContacts = false;
  bool _hasContactPermission = false;

  // Story state
  List<UserStoryGroup> _storyGroups = [];
  bool _isLoadingStories = true;

  // Call Logs state
  List<CallModel> _callLogs = [];
  bool _isLoadingCalls = true;

  // Groups state
  List<GroupModel> _groups = [];
  bool _isLoadingGroups = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _tabController.addListener(() {
      if (mounted) setState(() {});
    });
    _notificationService.init();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final authService = Provider.of<CustomAuthService>(context, listen: false);
      final currentUser = authService.currentUser;
      if (currentUser != null) {
        // Connect Socket.io client
        _socketService.initSocket(currentUser.uid);

        // Register FCM Push Notifications
        _initFirebaseMessaging(authService);

        // Listen for live messages received while in HomeScreen
        _socketService.onMessageReceived = (message) {
          String senderDisplayName = message.senderName ?? 'Yeni Mesaj';
          try {
            final senderObj = _phoneContacts.firstWhere((u) => u.uid == message.senderId);
            senderDisplayName = senderObj.displayName;
          } catch (_) {}

          // Reload contacts to bring latest chat to top
          _loadUsers();

          _notificationService.showMessageNotification(
            id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
            senderName: senderDisplayName,
            messageContent: message.content,
          );
        };

        // Listen for live group messages received while in HomeScreen
        _socketService.onGroupMessageReceived = (data) {
          _loadGroups();
        };

        // Listen for group deletion/closing
        _socketService.onGroupDeleted = (groupId, message) {
          _loadGroups();
        };

        // Listen for incoming calls
        _socketService.onIncomingCall = (callData) {
          _notificationService.startRingtone();
          _showIncomingCallDialog(callData, currentUser);
        };

        // Listen for real-time user online/offline status changes
        _socketService.onUserStatusChange = (userId, isOnline) {
          if (mounted) {
            setState(() {
              final phoneIdx = _phoneContacts.indexWhere((u) => u.uid == userId);
              if (phoneIdx != -1) {
                _phoneContacts[phoneIdx] = _phoneContacts[phoneIdx].copyWith(isOnline: isOnline);
              }
            });
          }
        };

        _loadUsers();
        _loadStories();
        _loadCallLogs();
        _loadGroups();

        // Check if there is an incoming call waiting for us (e.g. app was launched from notification)
        _checkPendingIncomingCall(currentUser);
      }
    });
  }

  void _loadGroups() async {
    try {
      final authService = Provider.of<CustomAuthService>(context, listen: false);
      final currentUser = authService.currentUser;
      if (currentUser != null) {
        final groups = await _chatService.getMyGroups(currentUser.uid);
        if (mounted) {
          setState(() {
            _groups = groups;
            _isLoadingGroups = false;
          });
        }
      }
    } catch (e) {
      debugPrint('[HOME] Groups load error: $e');
      if (mounted) {
        setState(() => _isLoadingGroups = false);
      }
    }
  }

  void _loadCallLogs() async {
    try {
      final authService = Provider.of<CustomAuthService>(context, listen: false);
      final currentUser = authService.currentUser;
      if (currentUser != null) {
        final logs = await _chatService.getCallLogs(currentUser.uid);
        if (mounted) {
          setState(() {
            _callLogs = logs;
            _isLoadingCalls = false;
          });
        }
      }
    } catch (e) {
      debugPrint('[HOME] Call logs load error: $e');
      if (mounted) {
        setState(() {
          _isLoadingCalls = false;
        });
      }
    }
  }

  void _loadStories() async {
    final authService = Provider.of<CustomAuthService>(context, listen: false);
    final currentUser = authService.currentUser;
    if (currentUser != null) {
      final stories = await _chatService.getStories(currentUser.uid);
      if (mounted) {
        setState(() {
          _storyGroups = stories;
          _isLoadingStories = false;
        });
      }
    }
  }

  void _checkPendingIncomingCall(UserModel currentUser) async {
    try {
      final response = await http.get(
        Uri.parse('${CustomAuthService.baseUrl.replaceAll('/api', '')}/api/calls/pending/${currentUser.uid}'),
      ).timeout(const Duration(seconds: 3));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['hasPendingCall'] == true && data['callData'] != null) {
          debugPrint('[CALL] Bekleyen gelen arama bulundu, dialog aciliyor!');
          _notificationService.startRingtone();
          _showIncomingCallDialog(Map<String, dynamic>.from(data['callData']), currentUser);
        }
      }
    } catch (e) {
      debugPrint('[CALL] Pending call check error: $e');
    }
  }

  void _initFirebaseMessaging(CustomAuthService authService) async {
    try {
      FirebaseMessaging messaging = FirebaseMessaging.instance;

      // Request notification permissions
      NotificationSettings settings = await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );

      debugPrint('[FCM] Bildirim izin durumu: ${settings.authorizationStatus}');

      String? token = await messaging.getToken();
      if (token != null) {
        debugPrint('[FCM] Cihaz Token alindi: $token');
        await authService.syncFcmToken(token);
      }

      messaging.onTokenRefresh.listen((newToken) {
        debugPrint('[FCM] Token yenilendi: $newToken');
        authService.syncFcmToken(newToken);
      });
    } catch (e) {
      debugPrint('[FCM] Error initializing messaging: $e');
    }
  }




  void _showIncomingCallDialog(Map<String, dynamic> callData, UserModel currentUser) {
    final callerData = callData['caller'] as Map<String, dynamic>;
    final callTypeStr = callData['callType'] ?? 'video';
    final offer = Map<String, dynamic>.from(callData['offer']);

    final callerUid = callerData['uid'].toString();
    String callerDisplayName = callerData['displayName'] ?? callerData['username'] ?? 'User';
    try {
      final matchedContact = _phoneContacts.firstWhere((u) => u.uid == callerUid);
      callerDisplayName = matchedContact.displayName;
    } catch (_) {}

    final callerUser = UserModel(
      uid: callerUid,
      username: callerData['username'] ?? 'User',
      email: '',
      displayName: callerDisplayName,
      photoUrl: callerData['photoUrl'] ?? '',
    );

    final int callNotificationId = 9999;
    _notificationService.showIncomingCallNotification(
      id: callNotificationId,
      callerName: callerUser.displayName,
      callType: callTypeStr == 'video' ? 'Görüntülü' : 'Sesli',
    );

    bool isDialogClosed = false;
    BuildContext? dialogContext;

    // If caller cancels before we answer, dismiss the dialog immediately!
    _socketService.onCallEnded = () {
      if (!isDialogClosed) {
        isDialogClosed = true;
        _notificationService.cancelCallNotification(callNotificationId);
        _notificationService.stopRingtone();
        if (dialogContext != null && Navigator.canPop(dialogContext!)) {
          Navigator.pop(dialogContext!);
        }
      }
    };

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        dialogContext = ctx;
        return Dialog(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircleAvatar(
                  radius: 40,
                  backgroundImage: CachedNetworkImageProvider(callerUser.photoUrl),
                ),
                const SizedBox(height: 16),
                Text(
                  callerUser.displayName,
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                ),
                const SizedBox(height: 8),
                Text(
                  callTypeStr == 'video' ? 'Gelen Görüntülü Arama...' : 'Gelen Sesli Arama...',
                  style: const TextStyle(color: AppColors.primaryLight, fontSize: 14),
                ),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.call_end, color: AppColors.callRed, size: 36),
                      onPressed: () {
                        isDialogClosed = true;
                        _notificationService.cancelCallNotification(callNotificationId);
                        _notificationService.stopRingtone();
                        _socketService.emitEndCall(callerUser.uid);
                        Navigator.pop(ctx);
                      },
                    ),
                    IconButton(
                      icon: Icon(
                        callTypeStr == 'video' ? Icons.videocam : Icons.call,
                        color: AppColors.callGreen,
                        size: 36,
                      ),
                      onPressed: () {
                        isDialogClosed = true;
                        _notificationService.cancelCallNotification(callNotificationId);
                        _notificationService.stopRingtone();
                        Navigator.pop(ctx);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => CallScreen(
                              currentUser: currentUser,
                              peerUser: callerUser,
                              callType: callTypeStr == 'video' ? CallType.video : CallType.audio,
                              isCaller: false,
                              incomingOffer: offer,
                            ),
                          ),
                        );
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

  void _loadUsers() async {
    final authService = Provider.of<CustomAuthService>(context, listen: false);
    final currentUser = authService.currentUser;
    if (currentUser != null) {
      await _syncDeviceContacts(silent: true);
      if (mounted) {
        setState(() {
          _isLoadingUsers = false;
        });
      }
    }
  }

  Future<void> _syncDeviceContacts({bool silent = false}) async {
    final authService = Provider.of<CustomAuthService>(context, listen: false);
    final currentUser = authService.currentUser;
    if (currentUser == null) return;

    if (!silent) {
      setState(() {
        _isSyncingContacts = true;
      });
    }

    try {
      bool permission = await FlutterContacts.requestPermission(readonly: true);
      if (mounted) {
        setState(() {
          _hasContactPermission = permission;
        });
      }

      List<Map<String, String>> contactList = [];
      if (permission) {
        List<Contact> contacts = await FlutterContacts.getContacts(withProperties: true, withPhoto: false);
        for (var contact in contacts) {
          for (var phone in contact.phones) {
            final num = phone.number.trim();
            if (num.isNotEmpty) {
              contactList.add({
                'phone': num,
                'name': contact.displayName.trim().isNotEmpty ? contact.displayName.trim() : '',
              });
            }
          }
        }
      }

      final myUid = int.tryParse(currentUser.uid) ?? 0;
      final matched = await _chatService.syncContacts(
        userId: myUid,
        contacts: contactList,
      );

      if (mounted) {
        setState(() {
          _phoneContacts = matched;
          _isSyncingContacts = false;
        });
        if (!silent) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${matched.length} kişi bulundu!'),
              backgroundColor: AppColors.primaryLight,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('[CONTACTS] Sync error: $e');
      if (mounted) {
        setState(() {
          _isSyncingContacts = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _startAudioOrVideoCall(UserModel peerUser, CallType callType) async {
    final authService = Provider.of<CustomAuthService>(context, listen: false);
    final currentUser = authService.currentUser;
    if (currentUser == null) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CallScreen(
          currentUser: currentUser,
          peerUser: peerUser,
          callType: callType,
          isCaller: true,
        ),
      ),
    );

    _loadCallLogs();
  }

  @override
  Widget build(BuildContext context) {
    final authService = Provider.of<CustomAuthService>(context);
    final currentUser = authService.currentUser;

    if (currentUser == null) {
      return const Scaffold(
        backgroundColor: AppColors.background,
        body: Center(
          child: CircularProgressIndicator(color: AppColors.primaryLight),
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        titleSpacing: 16,
        title: _isSearching
            ? Container(
                height: 42,
                decoration: BoxDecoration(
                  color: AppColors.surfaceLight,
                  borderRadius: BorderRadius.circular(24),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: TextField(
                  controller: _searchController,
                  autofocus: true,
                  style: const TextStyle(color: AppColors.textPrimary, fontSize: 14),
                  decoration: const InputDecoration(
                    hintText: 'Sohbet veya kişi ara...',
                    hintStyle: TextStyle(color: AppColors.textSecondary, fontSize: 14),
                    border: InputBorder.none,
                    icon: Icon(Icons.search, color: AppColors.primaryLight, size: 20),
                  ),
                  onChanged: (val) {
                    setState(() {
                      _searchQuery = val.trim();
                    });
                  },
                ),
              )
            : Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.primary.withOpacity(0.35),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.asset(
                        'assets/images/logo.png',
                        width: 38,
                        height: 38,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) => Container(
                          decoration: BoxDecoration(
                            gradient: AppColors.primaryGradient,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.shield_outlined, color: Colors.white, size: 22),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Talknex',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w800,
                          fontSize: 20,
                          letterSpacing: 0.3,
                        ),
                      ),
                      Text(
                        'Güvenli & Hızlı İletişim',
                        style: TextStyle(
                          color: AppColors.accent,
                          fontWeight: FontWeight.w500,
                          fontSize: 10,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
        actions: [
          IconButton(
            icon: Icon(
              _isSearching ? Icons.close : Icons.search,
              color: AppColors.textPrimary,
            ),
            onPressed: () {
              setState(() {
                _isSearching = !_isSearching;
                _searchQuery = '';
                _searchController.clear();
              });
            },
          ),
          IconButton(
            icon: const Icon(Icons.sync_rounded, color: AppColors.textPrimary),
            tooltip: 'Rehberi Eşitle',
            onPressed: () {
              setState(() {
                _isLoadingUsers = true;
              });
              _loadUsers();
            },
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: AppColors.textPrimary),
            color: AppColors.surfaceLight,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            onSelected: (val) {
              if (val == 'profile') {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ProfileScreen()),
                );
              } else if (val == 'new_group') {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => CreateGroupScreen(
                      currentUser: currentUser,
                      contacts: _phoneContacts,
                    ),
                  ),
                ).then((created) {
                  if (created == true) {
                    _loadGroups();
                  }
                });
              } else if (val == 'logout') {
                authService.signOut();
              }
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(
                value: 'new_group',
                child: Row(
                  children: [
                    Icon(Icons.group_add_rounded, color: AppColors.accent, size: 20),
                    SizedBox(width: 12),
                    Text(
                      'Yeni Grup Kur',
                      style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'profile',
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 14,
                      backgroundImage: CachedNetworkImageProvider(currentUser.photoUrl),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            currentUser.displayName,
                            style: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold, fontSize: 13),
                            overflow: TextOverflow.ellipsis,
                          ),
                          const Text(
                            'Profili Düzenle',
                            style: TextStyle(color: AppColors.primaryLight, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'logout',
                child: Row(
                  children: [
                    Icon(Icons.logout_rounded, color: AppColors.callRed, size: 20),
                    SizedBox(width: 12),
                    Text(
                      'Çıkış Yap',
                      style: TextStyle(color: AppColors.callRed, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: AppColors.surfaceLight.withOpacity(0.5),
              borderRadius: BorderRadius.circular(25),
              border: Border.all(color: AppColors.cardBorder),
            ),
            child: TabBar(
              controller: _tabController,
              indicator: BoxDecoration(
                gradient: AppColors.primaryGradient,
                borderRadius: BorderRadius.circular(22),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.primary.withOpacity(0.35),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              indicatorSize: TabBarIndicatorSize.tab,
              dividerColor: Colors.transparent,
              labelColor: Colors.white,
              unselectedLabelColor: AppColors.textSecondary,
              labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
              unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
              tabs: const [
                Tab(text: 'Sohbet'),
                Tab(text: 'Hikaye'),
                Tab(text: 'Rehber'),
                Tab(text: 'Aramalar'),
              ],
            ),
          ),
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildChatsTab(currentUser),
          _buildStoriesTab(currentUser),
          _buildUsersTab(currentUser),
          _buildCallsTab(currentUser),
        ],
      ),
      floatingActionButton: _buildFab(currentUser),
    );
  }

  Widget? _buildFab(UserModel currentUser) {
    if (_tabController.index == 0) {
      return FloatingActionButton(
        backgroundColor: Colors.transparent,
        elevation: 4,
        onPressed: () {
          _tabController.animateTo(2); // Go to contacts
        },
        child: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            gradient: AppColors.primaryGradient,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: AppColors.primary.withOpacity(0.4),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: const Icon(Icons.chat_rounded, color: Colors.white),
        ),
      );
    } else if (_tabController.index == 1) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.small(
            backgroundColor: AppColors.surfaceLight,
            onPressed: () => _navigateToAddStory(currentUser),
            child: const Icon(Icons.edit_rounded, color: AppColors.textPrimary),
          ),
          const SizedBox(height: 12),
          FloatingActionButton(
            backgroundColor: Colors.transparent,
            elevation: 4,
            onPressed: () => _navigateToAddStory(currentUser),
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                gradient: AppColors.primaryGradient,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: AppColors.primary.withOpacity(0.4),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: const Icon(Icons.camera_alt_rounded, color: Colors.white),
            ),
          ),
        ],
      );
    }
    return null;
  }

  void _navigateToAddStory(UserModel currentUser) async {
    final res = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AddStoryScreen(currentUser: currentUser),
      ),
    );
    if (res == true) {
      _loadStories();
    }
  }

  void _openStoryViewer(int groupIndex, UserModel currentUser) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StoryViewScreen(
          storyGroups: _storyGroups,
          initialGroupIndex: groupIndex,
          currentUser: currentUser,
          onStoryDeletedOrUpdated: _loadStories,
        ),
      ),
    ).then((_) {
      _loadStories();
    });
  }

  // Stories (Durum) Tab
  Widget _buildStoriesTab(UserModel currentUser) {
    if (_isLoadingStories) {
      return const Center(child: CircularProgressIndicator(color: AppColors.primaryLight));
    }

    final myUid = currentUser.uid;
    UserStoryGroup? myStoryGroup;
    List<UserStoryGroup> recentUpdates = [];
    List<UserStoryGroup> viewedUpdates = [];

    for (final group in _storyGroups) {
      if (group.userId.toString() == myUid) {
        myStoryGroup = group;
      } else {
        if (group.allViewed) {
          viewedUpdates.add(group);
        } else {
          recentUpdates.add(group);
        }
      }
    }

    return RefreshIndicator(
      color: AppColors.primaryLight,
      onRefresh: () async {
        _loadStories();
      },
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          // My Status Tile
          ListTile(
            onTap: () {
              if (myStoryGroup != null && myStoryGroup.stories.isNotEmpty) {
                final myIdx = _storyGroups.indexWhere((g) => g.userId.toString() == myUid);
                _openStoryViewer(myIdx != -1 ? myIdx : 0, currentUser);
              } else {
                _navigateToAddStory(currentUser);
              }
            },
            leading: Stack(
              children: [
                Container(
                  padding: const EdgeInsets.all(2.5),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: (myStoryGroup != null && myStoryGroup.stories.isNotEmpty)
                        ? Border.all(color: AppColors.primaryLight, width: 2.5)
                        : null,
                  ),
                  child: CircleAvatar(
                    radius: 24,
                    backgroundColor: AppColors.surfaceLight,
                    backgroundImage: currentUser.photoUrl.isNotEmpty
                        ? CachedNetworkImageProvider(currentUser.photoUrl)
                        : null,
                    child: currentUser.photoUrl.isEmpty
                        ? const Icon(Icons.person, color: AppColors.textSecondary)
                        : null,
                  ),
                ),
                if (myStoryGroup == null || myStoryGroup.stories.isEmpty)
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: const BoxDecoration(
                        color: AppColors.primaryLight,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.add, color: Colors.white, size: 16),
                    ),
                  ),
              ],
            ),
            title: const Text('Durumum', style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold, fontSize: 16)),
            subtitle: Text(
              (myStoryGroup != null && myStoryGroup.stories.isNotEmpty)
                  ? '${myStoryGroup.stories.length} hikaye • Görmek için dokunun'
                  : 'Durum güncellemesi eklemek için dokunun',
              style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
            trailing: IconButton(
              icon: const Icon(Icons.camera_alt, color: AppColors.primaryLight),
              onPressed: () => _navigateToAddStory(currentUser),
            ),
          ),

          if (recentUpdates.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
              child: Row(
                children: [
                  const Icon(Icons.auto_awesome, color: AppColors.accent, size: 16),
                  const SizedBox(width: 6),
                  Text(
                    'Son Güncellemeler (${recentUpdates.length})',
                    style: const TextStyle(color: AppColors.textSecondary, fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                ],
              ),
            ),
            ...recentUpdates.map((group) {
              final idx = _storyGroups.indexOf(group);
              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.cardBorder),
                ),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                  onTap: () => _openStoryViewer(idx, currentUser),
                  leading: Container(
                    padding: const EdgeInsets.all(2.5),
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: AppColors.storyRingGradient,
                    ),
                    child: CircleAvatar(
                      radius: 23,
                      backgroundColor: AppColors.surfaceLight,
                      backgroundImage: group.userPhotoUrl.isNotEmpty
                          ? CachedNetworkImageProvider(group.userPhotoUrl)
                          : null,
                      child: group.userPhotoUrl.isEmpty
                          ? const Icon(Icons.person, color: AppColors.textSecondary)
                          : null,
                    ),
                  ),
                  title: Text(
                    group.displayName,
                    style: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold, fontSize: 15),
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${group.stories.length} yeni hikaye',
                    style: const TextStyle(color: AppColors.accent, fontSize: 12, fontWeight: FontWeight.w500),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.textSecondary, size: 20),
                ),
              );
            }),
          ],

          if (viewedUpdates.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(18, 16, 18, 8),
              child: Text(
                'Görülen Güncellemeler',
                style: TextStyle(color: AppColors.textSecondary, fontWeight: FontWeight.bold, fontSize: 13),
              ),
            ),
            ...viewedUpdates.map((group) {
              final idx = _storyGroups.indexOf(group);
              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.surface.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.cardBorder),
                ),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                  onTap: () => _openStoryViewer(idx, currentUser),
                  leading: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.textMuted, width: 2),
                    ),
                    child: CircleAvatar(
                      radius: 23,
                      backgroundColor: AppColors.surfaceLight,
                      backgroundImage: group.userPhotoUrl.isNotEmpty
                          ? CachedNetworkImageProvider(group.userPhotoUrl)
                          : null,
                      child: group.userPhotoUrl.isEmpty
                          ? const Icon(Icons.person, color: AppColors.textSecondary)
                          : null,
                    ),
                  ),
                  title: Text(
                    group.displayName,
                    style: const TextStyle(color: AppColors.textSecondary, fontWeight: FontWeight.w600, fontSize: 15),
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: const Text('Görüldü', style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
                  trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.textMuted, size: 20),
                ),
              );
            }),
          ],

          if (recentUpdates.isEmpty && viewedUpdates.isEmpty && (myStoryGroup == null || myStoryGroup.stories.isEmpty)) ...[
            const SizedBox(height: 60),
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  children: [
                    Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        shape: BoxShape.circle,
                        border: Border.all(color: AppColors.cardBorder),
                      ),
                      child: const Icon(Icons.history_toggle_off_rounded, size: 40, color: AppColors.textMuted),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Henüz Hikaye Paylaşılmadı',
                      style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Kişilerinizle anlarınızı paylaşmak için yukarıdaki karttan ilk hikayenizi ekleyin!',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.textSecondary, fontSize: 13, height: 1.4),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // Chats Tab
  Widget _buildChatsTab(UserModel currentUser) {
    if (_isLoadingUsers) {
      return const Center(child: CircularProgressIndicator(color: AppColors.primaryLight));
    }

    var filteredUsers = _phoneContacts;
    if (_searchQuery.isNotEmpty) {
      filteredUsers = filteredUsers
          .where((u) =>
              u.displayName.toLowerCase().contains(_searchQuery.toLowerCase()) ||
              u.username.toLowerCase().contains(_searchQuery.toLowerCase()) ||
              u.phoneNumber.contains(_searchQuery))
          .toList();
    }

    final allowedStoryGroups = _storyGroups.where((g) {
      return g.userId.toString() == currentUser.uid ||
          _phoneContacts.any((c) => c.uid == g.userId.toString());
    }).map((g) {
      if (g.userId.toString() != currentUser.uid) {
        try {
          final matched = _phoneContacts.firstWhere((c) => c.uid == g.userId.toString());
          return UserStoryGroup(
            userId: g.userId,
            username: g.username,
            displayName: matched.displayName,
            userPhotoUrl: g.userPhotoUrl,
            stories: g.stories,
            allViewed: g.allViewed,
            latestTimestamp: g.latestTimestamp,
          );
        } catch (_) {}
      }
      return g;
    }).toList();

    return Column(
      children: [
        // Top Horizontal Active Story Bar
        if (allowedStoryGroups.isNotEmpty)
          Container(
            height: 100,
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppColors.cardBorder, width: 1)),
            ),
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              children: [
                // My Story Bubble
                GestureDetector(
                  onTap: () {
                    final myUid = currentUser.uid;
                    final myIdx = allowedStoryGroups.indexWhere((g) => g.userId.toString() == myUid);
                    if (myIdx != -1) {
                      _openStoryViewer(myIdx, currentUser);
                    } else {
                      _navigateToAddStory(currentUser);
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Stack(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(2.5),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: allowedStoryGroups.any((g) => g.userId.toString() == currentUser.uid)
                                    ? AppColors.storyRingGradient
                                    : null,
                              ),
                              child: CircleAvatar(
                                radius: 25,
                                backgroundColor: AppColors.surfaceLight,
                                backgroundImage: currentUser.photoUrl.isNotEmpty
                                    ? CachedNetworkImageProvider(currentUser.photoUrl)
                                    : null,
                                child: currentUser.photoUrl.isEmpty
                                    ? const Icon(Icons.person, color: AppColors.textSecondary)
                                    : null,
                              ),
                            ),
                            if (!allowedStoryGroups.any((g) => g.userId.toString() == currentUser.uid))
                              Positioned(
                                bottom: 0,
                                right: 0,
                                child: Container(
                                  padding: const EdgeInsets.all(2),
                                  decoration: BoxDecoration(
                                    gradient: AppColors.primaryGradient,
                                    shape: BoxShape.circle,
                                    border: Border.all(color: AppColors.background, width: 2),
                                  ),
                                  child: const Icon(Icons.add, color: Colors.white, size: 14),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 5),
                        const Text(
                          'Hikayen',
                          style: TextStyle(color: AppColors.textPrimary, fontSize: 11, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                ),

                // Other Users Stories
                ...allowedStoryGroups.where((g) => g.userId.toString() != currentUser.uid).map((group) {
                  final groupIdx = allowedStoryGroups.indexOf(group);
                  return GestureDetector(
                    onTap: () => _openStoryViewer(groupIdx, currentUser),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(2.5),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: group.allViewed ? null : AppColors.storyRingGradient,
                              border: group.allViewed ? Border.all(color: AppColors.textMuted, width: 2) : null,
                            ),
                            child: CircleAvatar(
                              radius: 25,
                              backgroundColor: AppColors.surfaceLight,
                              backgroundImage: group.userPhotoUrl.isNotEmpty
                                  ? CachedNetworkImageProvider(group.userPhotoUrl)
                                  : null,
                              child: group.userPhotoUrl.isEmpty
                                  ? const Icon(Icons.person, color: AppColors.textSecondary)
                                  : null,
                            ),
                          ),
                          const SizedBox(height: 5),
                          SizedBox(
                            width: 64,
                            child: Text(
                              group.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: AppColors.textPrimary, fontSize: 11, fontWeight: FontWeight.w500),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),

        // Unified Chat & Group List (Sorted by latest message timestamp)
        Expanded(
          child: Builder(
            builder: (context) {
              // Combine direct contacts and groups into unified conversation items
              final List<Map<String, dynamic>> allConversations = [];

              for (final group in _groups) {
                if (_searchQuery.isEmpty || group.name.toLowerCase().contains(_searchQuery.toLowerCase())) {
                  allConversations.add({
                    'type': 'group',
                    'group': group,
                    'time': group.lastTime ?? DateTime.fromMillisecondsSinceEpoch(0),
                  });
                }
              }

              for (final user in filteredUsers) {
                allConversations.add({
                  'type': 'user',
                  'user': user,
                  'time': user.lastTime ?? DateTime.fromMillisecondsSinceEpoch(0),
                });
              }

              // Sort descending: most recent message/time first
              allConversations.sort((a, b) {
                final DateTime timeA = a['time'] as DateTime;
                final DateTime timeB = b['time'] as DateTime;
                return timeB.compareTo(timeA);
              });

              if (allConversations.isEmpty) {
                return RefreshIndicator(
                  color: AppColors.primaryLight,
                  onRefresh: () async {
                    _loadUsers();
                    _loadGroups();
                  },
                  child: ListView(
                    padding: const EdgeInsets.all(24.0),
                    children: [
                      const SizedBox(height: 60),
                      Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              width: 80,
                              height: 80,
                              decoration: BoxDecoration(
                                color: AppColors.surface,
                                shape: BoxShape.circle,
                                border: Border.all(color: AppColors.cardBorder),
                              ),
                              child: const Icon(Icons.chat_bubble_outline_rounded, size: 40, color: AppColors.textMuted),
                            ),
                            const SizedBox(height: 16),
                            const Text(
                              'Sohbet Bulunamadı',
                              style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold, fontSize: 16),
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'Rehberinizdeki kayıtlı kişilerle veya yeni grup kurarak sohbete başlayabilirsiniz.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: AppColors.textSecondary, fontSize: 13, height: 1.4),
                            ),
                            const SizedBox(height: 16),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppColors.primary,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                  ),
                                  onPressed: () => _syncDeviceContacts(silent: false),
                                  icon: const Icon(Icons.sync_rounded, size: 18),
                                  label: const Text('Rehberi Yenile'),
                                ),
                                const SizedBox(width: 12),
                                ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppColors.accent,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                  ),
                                  onPressed: () {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => CreateGroupScreen(
                                          currentUser: currentUser,
                                          contacts: _phoneContacts,
                                        ),
                                      ),
                                    ).then((created) {
                                      if (created == true) _loadGroups();
                                    });
                                  },
                                  icon: const Icon(Icons.group_add_rounded, size: 18),
                                  label: const Text('Grup Kur'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }

              return RefreshIndicator(
                color: AppColors.primaryLight,
                onRefresh: () async {
                  _loadUsers();
                  _loadGroups();
                },
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: allConversations.length,
                  itemBuilder: (context, index) {
                    final item = allConversations[index];

                    if (item['type'] == 'group') {
                      final GroupModel group = item['group'] as GroupModel;
                      final timeStr = group.lastTime != null
                          ? DateFormat('HH:mm').format(group.lastTime!)
                          : '';

                      return Container(
                        margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: AppColors.primaryLight.withOpacity(0.2)),
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                          leading: Stack(
                            children: [
                              CircleAvatar(
                                radius: 26,
                                backgroundColor: AppColors.surfaceLight,
                                backgroundImage: group.photoUrl.isNotEmpty
                                    ? CachedNetworkImageProvider(group.photoUrl)
                                    : null,
                                child: group.photoUrl.isEmpty
                                    ? const Icon(Icons.group_rounded, color: AppColors.accent, size: 28)
                                    : null,
                              ),
                              Positioned(
                                bottom: 0,
                                right: 0,
                                child: Container(
                                  padding: const EdgeInsets.all(3),
                                  decoration: const BoxDecoration(
                                    color: AppColors.accent,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(Icons.groups, size: 10, color: Colors.black),
                                ),
                              ),
                            ],
                          ),
                          title: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  group.name,
                                  style: const TextStyle(
                                    color: AppColors.textPrimary,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 15,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (timeStr.isNotEmpty)
                                Text(
                                  timeStr,
                                  style: const TextStyle(color: AppColors.textSecondary, fontSize: 11),
                                ),
                            ],
                          ),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 2.0),
                            child: Row(
                              children: [
                                if (group.isAdmin) ...[
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                    margin: const EdgeInsets.only(right: 6),
                                    decoration: BoxDecoration(
                                      color: AppColors.accent.withOpacity(0.18),
                                      borderRadius: BorderRadius.circular(5),
                                    ),
                                    child: const Text(
                                      'Yönetici',
                                      style: TextStyle(color: AppColors.accent, fontSize: 9.5, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                ],
                                Expanded(
                                  child: Builder(
                                    builder: (context) {
                                      String displayMsg = group.lastMessage;
                                      if (displayMsg.isNotEmpty) {
                                        final senderKey = group.lastSenderId.isNotEmpty ? group.lastSenderId : currentUser.uid;
                                        displayMsg = EndToEndEncryptionService.decryptText(
                                          displayMsg,
                                          senderKey,
                                          'group_${group.id}',
                                        );
                                      }
                                      return Text(
                                        displayMsg.isNotEmpty
                                            ? displayMsg
                                            : '${group.memberCount} üye • Grup sohbeti',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: displayMsg.isNotEmpty ? AppColors.textPrimary : AppColors.textSecondary,
                                          fontSize: 12.5,
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ),
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => GroupChatScreen(
                                  group: group,
                                  currentUser: currentUser,
                                  contacts: _phoneContacts,
                                ),
                              ),
                            ).then((_) => _loadGroups());
                          },
                        ),
                      );
                    } else {
                      final UserModel user = item['user'] as UserModel;
                      final timeStr = user.lastTime != null && user.lastMessage.isNotEmpty
                          ? DateFormat('HH:mm').format(user.lastTime!)
                          : '';

                      return Container(
                        margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: AppColors.cardBorder),
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                          leading: Stack(
                            children: [
                              CircleAvatar(
                                radius: 26,
                                backgroundColor: AppColors.surfaceLight,
                                backgroundImage: CachedNetworkImageProvider(user.photoUrl),
                              ),
                              if (user.isOnline)
                                Positioned(
                                  bottom: 0,
                                  right: 0,
                                  child: Container(
                                    width: 14,
                                    height: 14,
                                    decoration: BoxDecoration(
                                      color: AppColors.onlineGreen,
                                      shape: BoxShape.circle,
                                      border: Border.all(color: AppColors.surface, width: 2),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          title: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  user.displayName,
                                  style: const TextStyle(
                                    color: AppColors.textPrimary,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 15,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (timeStr.isNotEmpty)
                                Text(
                                  timeStr,
                                  style: const TextStyle(color: AppColors.textSecondary, fontSize: 11),
                                ),
                            ],
                          ),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 2.0),
                            child: Builder(
                              builder: (context) {
                                String displayMsg = user.lastMessage;
                                if (displayMsg.isNotEmpty) {
                                  displayMsg = EndToEndEncryptionService.decryptText(
                                    displayMsg,
                                    currentUser.uid,
                                    user.uid,
                                  );
                                }
                                return Text(
                                  displayMsg.isNotEmpty ? displayMsg : user.status,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: displayMsg.isNotEmpty ? AppColors.textPrimary : AppColors.textSecondary,
                                    fontSize: 12.5,
                                  ),
                                );
                              },
                            ),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: Container(
                                  padding: const EdgeInsets.all(7),
                                  decoration: BoxDecoration(
                                    color: AppColors.primary.withOpacity(0.12),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(Icons.call_rounded, color: AppColors.primaryLight, size: 18),
                                ),
                                onPressed: () => _startAudioOrVideoCall(user, CallType.audio),
                              ),
                              IconButton(
                                icon: Container(
                                  padding: const EdgeInsets.all(7),
                                  decoration: BoxDecoration(
                                    color: AppColors.accent.withOpacity(0.12),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(Icons.videocam_rounded, color: AppColors.accent, size: 18),
                                ),
                                onPressed: () => _startAudioOrVideoCall(user, CallType.video),
                              ),
                            ],
                          ),
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ChatScreen(peerUser: user, currentUser: currentUser),
                              ),
                            ).then((_) => _loadUsers());
                          },
                        ),
                      );
                    }
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // Users / Contacts Tab
  Widget _buildUsersTab(UserModel currentUser) {
    if (_isLoadingUsers) {
      return const Center(child: CircularProgressIndicator(color: AppColors.primaryLight));
    }

    var filteredPhoneContacts = _phoneContacts;

    if (_searchQuery.isNotEmpty) {
      filteredPhoneContacts = filteredPhoneContacts
          .where((u) =>
              u.displayName.toLowerCase().contains(_searchQuery.toLowerCase()) ||
              u.username.toLowerCase().contains(_searchQuery.toLowerCase()) ||
              u.phoneNumber.contains(_searchQuery))
          .toList();
    }

    return RefreshIndicator(
      color: AppColors.primaryLight,
      onRefresh: () async {
        await _syncDeviceContacts(silent: false);
      },
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          // Header Sync Tile
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [AppColors.primary.withOpacity(0.15), AppColors.accent.withOpacity(0.08)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.primary.withOpacity(0.3)),
            ),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              onTap: _isSyncingContacts ? null : () => _syncDeviceContacts(silent: false),
              leading: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  gradient: AppColors.primaryGradient,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: _isSyncingContacts
                    ? const Center(
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                        ),
                      )
                    : const Icon(Icons.sync_rounded, color: Colors.white, size: 24),
              ),
              title: const Text(
                'Rehberi Yenile & Eşitle',
                style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold, fontSize: 15),
              ),
              subtitle: Text(
                _phoneContacts.isNotEmpty
                    ? '${_phoneContacts.length} kişi Talknex kullanıyor'
                    : 'Rehberinizdeki kişileri otomatik bulun',
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
              ),
              trailing: const Icon(Icons.arrow_forward_ios_rounded, color: AppColors.primaryLight, size: 16),
            ),
          ),

          if (filteredPhoneContacts.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
              child: Text(
                'Rehberinizdeki Kişiler (${filteredPhoneContacts.length})',
                style: const TextStyle(color: AppColors.accent, fontWeight: FontWeight.bold, fontSize: 13),
              ),
            ),
            ...filteredPhoneContacts.map((user) {
              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.cardBorder),
                ),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                  leading: Stack(
                    children: [
                      CircleAvatar(
                        radius: 24,
                        backgroundColor: AppColors.surfaceLight,
                        backgroundImage: CachedNetworkImageProvider(user.photoUrl),
                      ),
                      if (user.isOnline)
                        Positioned(
                          bottom: 0,
                          right: 0,
                          child: Container(
                            width: 14,
                            height: 14,
                            decoration: BoxDecoration(
                              color: AppColors.onlineGreen,
                              shape: BoxShape.circle,
                              border: Border.all(color: AppColors.surface, width: 2),
                            ),
                          ),
                        ),
                    ],
                  ),
                  title: Text(
                    user.displayName,
                    style: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w700, fontSize: 15),
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    user.isOnline ? "Çevrimiçi" : "Çevrimdışı",
                    style: TextStyle(
                      color: user.isOnline ? AppColors.onlineGreen : AppColors.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: Container(
                          padding: const EdgeInsets.all(7),
                          decoration: BoxDecoration(
                            color: AppColors.primary.withOpacity(0.12),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.call_rounded, color: AppColors.primaryLight, size: 18),
                        ),
                        onPressed: () => _startAudioOrVideoCall(user, CallType.audio),
                      ),
                      IconButton(
                        icon: Container(
                          padding: const EdgeInsets.all(7),
                          decoration: BoxDecoration(
                            color: AppColors.accent.withOpacity(0.12),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.chat_bubble_rounded, color: AppColors.accent, size: 18),
                        ),
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ChatScreen(peerUser: user, currentUser: currentUser),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              );
            }),
          ] else ...[
            const SizedBox(height: 40),
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  children: [
                    Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        shape: BoxShape.circle,
                        border: Border.all(color: AppColors.cardBorder),
                      ),
                      child: const Icon(Icons.perm_contact_calendar_outlined, size: 40, color: AppColors.textMuted),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Kayıtlı Kişi Bulunamadı',
                      style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Rehberinizdeki kişilerin Talknex hesabı olduğunda burada otomatik olarak görünecektir.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.textSecondary, fontSize: 13, height: 1.4),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // Calls Tab
  Widget _buildCallsTab(UserModel currentUser) {
    if (_isLoadingCalls) {
      return const Center(child: CircularProgressIndicator(color: AppColors.primaryLight));
    }

    return RefreshIndicator(
      color: AppColors.primaryLight,
      onRefresh: () async {
        _loadCallLogs();
      },
      child: _callLogs.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        shape: BoxShape.circle,
                        border: Border.all(color: AppColors.cardBorder),
                      ),
                      child: const Icon(Icons.phone_missed_rounded, size: 40, color: AppColors.textMuted),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Henüz Arama Kaydı Yok',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.textPrimary, fontSize: 17, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Kişilerinizle yaptığınız tüm sesli ve görüntülü görüşmeler burada güvenle listelenir.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.textSecondary, fontSize: 13, height: 1.4),
                    ),
                  ],
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _callLogs.length,
              itemBuilder: (context, index) {
                final log = _callLogs[index];
                final isOutgoing = log.callerId == currentUser.uid;

                final otherUserId = isOutgoing ? log.receiverId : log.callerId;
                String otherUserName = isOutgoing ? log.receiverName : log.callerName;
                String otherUserPic = isOutgoing ? log.receiverPic : log.callerPic;

                try {
                  final matched = _phoneContacts.firstWhere((c) => c.uid == otherUserId);
                  otherUserName = matched.displayName;
                  otherUserPic = matched.photoUrl;
                } catch (_) {}

                final bool isMissed = log.callStatus == CallStatus.missed || (log.durationSeconds == 0 && !isOutgoing);
                final bool isVideo = log.callType == CallType.video;

                IconData callDirectionIcon;
                Color callDirectionColor;

                if (isOutgoing) {
                  callDirectionIcon = Icons.call_made_rounded;
                  callDirectionColor = AppColors.primaryLight;
                } else if (isMissed) {
                  callDirectionIcon = Icons.call_missed_rounded;
                  callDirectionColor = AppColors.callRed;
                } else {
                  callDirectionIcon = Icons.call_received_rounded;
                  callDirectionColor = AppColors.callGreen;
                }

                String _formatCallTime(DateTime dt) {
                  final now = DateTime.now();
                  final isToday = dt.year == now.year && dt.month == now.month && dt.day == now.day;
                  final yesterday = now.subtract(const Duration(days: 1));
                  final isYesterday = dt.year == yesterday.year && dt.month == yesterday.month && dt.day == yesterday.day;
                  
                  final timeStr = DateFormat('HH:mm').format(dt);
                  if (isToday) {
                    return 'Bugün, $timeStr';
                  } else if (isYesterday) {
                    return 'Dün, $timeStr';
                  }
                  
                  const turkishMonths = [
                    '', 'Oca', 'Şub', 'Mar', 'Nis', 'May', 'Haz',
                    'Tem', 'Ağu', 'Eyl', 'Eki', 'Kas', 'Ara'
                  ];
                  final monthName = (dt.month >= 1 && dt.month <= 12) ? turkishMonths[dt.month] : '';
                  return '${dt.day} $monthName, $timeStr';
                }

                return Container(
                  margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.cardBorder),
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    leading: CircleAvatar(
                      radius: 24,
                      backgroundColor: AppColors.surfaceLight,
                      backgroundImage: otherUserPic.isNotEmpty ? CachedNetworkImageProvider(otherUserPic) : null,
                      child: otherUserPic.isEmpty ? const Icon(Icons.person, color: AppColors.textSecondary) : null,
                    ),
                    title: Text(
                      otherUserName,
                      style: TextStyle(
                        color: isMissed ? AppColors.callRed : AppColors.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 3.0),
                      child: Row(
                        children: [
                          Icon(callDirectionIcon, color: callDirectionColor, size: 15),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              _formatCallTime(log.timestamp),
                              style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (log.durationSeconds > 0) ...[
                            const Text(' • ', style: TextStyle(color: AppColors.textSecondary)),
                            Text(
                              log.formattedDuration,
                              style: const TextStyle(color: AppColors.primaryLight, fontSize: 12, fontWeight: FontWeight.w600),
                            ),
                          ] else if (isMissed) ...[
                            const Text(' • ', style: TextStyle(color: AppColors.textSecondary)),
                            const Text(
                              'Cevapsız',
                              style: TextStyle(color: AppColors.callRed, fontSize: 12, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ],
                      ),
                    ),
                    trailing: IconButton(
                      icon: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: (isVideo ? AppColors.accent : AppColors.primary).withOpacity(0.12),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          isVideo ? Icons.videocam_rounded : Icons.call_rounded,
                          color: isVideo ? AppColors.accent : AppColors.primaryLight,
                          size: 20,
                        ),
                      ),
                      onPressed: () {
                        final targetUser = UserModel(
                          uid: otherUserId,
                          username: otherUserName,
                          email: '',
                          displayName: otherUserName,
                          photoUrl: otherUserPic,
                        );
                        _startAudioOrVideoCall(targetUser, log.callType);
                      },
                    ),
                  ),
                );
              },
            ),
    );
  }
}
