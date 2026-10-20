import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../constants/app_colors.dart';
import '../../models/user_model.dart';
import '../../services/custom_auth_service.dart';
import '../../services/custom_chat_service.dart';
import '../../services/emergency_service.dart';
import '../../widgets/app_avatar.dart';

class EmergencyScreen extends StatefulWidget {
  const EmergencyScreen({super.key});

  @override
  State<EmergencyScreen> createState() => _EmergencyScreenState();
}

class _EmergencyScreenState extends State<EmergencyScreen> with SingleTickerProviderStateMixin {
  final EmergencyService _emergencyService = EmergencyService();
  final CustomChatService _chatService = CustomChatService();
  late TextEditingController _messageController;
  late AnimationController _pulseController;
  bool _isSavingMessage = false;

  final List<String> _presetTemplates = [
    '🚨 Başım dertte ve yardıma ihtiyacım var! Canlı konumuma bakın!',
    '⚠️ Acil bir durumdayım, lütfen hemen bana ulaşın ve konumuma gelin!',
    '🚗 Trafik kazası geçirdim! Acil yardıma ihtiyacım var, konumum aşağıdadır!',
    '👣 Beni birileri takip ediyor, güvende değilim! Canlı konumumu takip edin!',
  ];

  @override
  void initState() {
    super.initState();
    _messageController = TextEditingController(text: _emergencyService.customMessage);
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _messageController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  void _saveMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Acil durum mesajı boş bırakılamaz.'),
          backgroundColor: AppColors.callRed,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() {
      _isSavingMessage = true;
    });

    await _emergencyService.setCustomMessage(text);

    setState(() {
      _isSavingMessage = false;
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Özel acil durum mesajınız kaydedildi!'),
          backgroundColor: AppColors.onlineGreen,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _showAddContactModal() async {
    final authService = Provider.of<CustomAuthService>(context, listen: false);
    final currentUser = authService.currentUser;
    if (currentUser == null) return;

    if (_emergencyService.contacts.length >= 10) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('En fazla 10 acil durum kişisi ekleyebilirsiniz.'),
          backgroundColor: AppColors.callRed,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return _AddEmergencyContactModal(
          currentUserId: currentUser.uid,
          onContactSelected: (user) async {
            final added = await _emergencyService.addContact(user);
            if (ctx.mounted) Navigator.pop(ctx);
            if (mounted) {
              if (added) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('${user.displayName} acil durum kişilerine eklendi.'),
                    backgroundColor: AppColors.onlineGreen,
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Bu kişi zaten ekli veya sınır aşıldı.'),
                    backgroundColor: AppColors.callRed,
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            }
          },
        );
      },
    );
  }

  void _confirmAndTriggerSOS() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: AppColors.callRed, size: 28),
            SizedBox(width: 10),
            Text('Acil Durum Uyarısı Testi', style: TextStyle(color: Colors.white, fontSize: 18)),
          ],
        ),
        content: Text(
          'Tanımladığınız ${_emergencyService.contacts.length} kişiye anlık canlı konumunuz ve özel mesajınız gizlice gönderilecek. Bu işlemi başlatmak istiyor musunuz?',
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('İptal', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final authService = Provider.of<CustomAuthService>(context, listen: false);
              final currentUserId = authService.currentUser?.uid;
              final success = await _emergencyService.triggerEmergencyAlert(currentUserId: currentUserId);
              if (mounted) {
                if (success) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        '🚨 SOS Uyarısı ve Canlı Konum ${_emergencyService.contacts.length} kişiye başarıyla iletildi!',
                      ),
                      backgroundColor: AppColors.onlineGreen,
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('SOS gönderilemedi. Lütfen kişi eklediğinizden ve GPS izni verdiğinizden emin olun.'),
                      backgroundColor: AppColors.callRed,
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.callRed,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Şimdi Gönder', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _emergencyService,
      builder: (context, _) {
        final isEnabled = _emergencyService.isEnabled;
        final contacts = _emergencyService.contacts;

        return Scaffold(
          backgroundColor: AppColors.background,
          appBar: AppBar(
            backgroundColor: AppColors.surface,
            elevation: 0,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20),
              onPressed: () => Navigator.pop(context),
            ),
            title: const Text(
              'Acil Durum (SOS)',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
            ),
          ),
          body: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 1. SOS Status Card
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: isEnabled
                          ? [const Color(0xFF3E1116), const Color(0xFF1F0E13)]
                          : [AppColors.surface, AppColors.surfaceLight],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: isEnabled ? AppColors.callRed.withOpacity(0.5) : AppColors.cardBorder,
                      width: 1.2,
                    ),
                    boxShadow: isEnabled
                        ? [
                            BoxShadow(
                              color: AppColors.callRed.withOpacity(0.2),
                              blurRadius: 16,
                              offset: const Offset(0, 4),
                            ),
                          ]
                        : null,
                  ),
                  child: Row(
                    children: [
                      ScaleTransition(
                        scale: Tween(begin: 0.95, end: 1.05).animate(_pulseController),
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: isEnabled ? AppColors.callRed.withOpacity(0.2) : Colors.white12,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: isEnabled ? AppColors.callRed : Colors.white24,
                              width: 1.5,
                            ),
                          ),
                          child: Icon(
                            Icons.shield_rounded,
                            color: isEnabled ? AppColors.callRed : Colors.white54,
                            size: 30,
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              isEnabled ? 'Acil Durum Koruması Aktif' : 'Acil Durum Koruması Kapalı',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              isEnabled
                                  ? 'Tuşa 3 sn basılı tutulduğunda anında yardım çağrısı gider.'
                                  : 'Otomatik yardım uyarısı devre dışı bırakıldı.',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.7),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Switch(
                        value: isEnabled,
                        activeColor: AppColors.callRed,
                        onChanged: (val) => _emergencyService.setEnabled(val),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 22),

                // 2. Hardware Trigger Key Selector
                _buildSectionHeader('Tetikleyici Telefon Tuşu', Icons.touch_app_rounded),
                const SizedBox(height: 10),
                Container(
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.cardBorder),
                  ),
                  child: Column(
                    children: [
                      RadioListTile<String>(
                        value: 'volume_up',
                        groupValue: _emergencyService.triggerKey,
                        activeColor: AppColors.callRed,
                        title: const Text(
                          'Ses Açma Tuşu (3 Saniye Basılı Tut)',
                          style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                        ),
                        subtitle: const Text(
                          'Önerilen: Cebinizdeyken kolayca hissedilir ve tetiklenir.',
                          style: TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                        onChanged: isEnabled ? (val) => _emergencyService.setTriggerKey(val!) : null,
                      ),
                      Divider(color: Colors.white.withOpacity(0.06), height: 1),
                      RadioListTile<String>(
                        value: 'volume_down',
                        groupValue: _emergencyService.triggerKey,
                        activeColor: AppColors.callRed,
                        title: const Text(
                          'Ses Kısma Tuşu (3 Saniye Basılı Tut)',
                          style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                        ),
                        subtitle: const Text(
                          'Alternatif tuş seçeneği.',
                          style: TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                        onChanged: isEnabled ? (val) => _emergencyService.setTriggerKey(val!) : null,
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 22),

                // 3. Custom Emergency Message
                _buildSectionHeader('Özel Acil Durum Mesajı', Icons.message_rounded),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.cardBorder),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: _messageController,
                        maxLines: 3,
                        style: const TextStyle(color: Colors.white, fontSize: 13.5),
                        decoration: InputDecoration(
                          hintText: 'Acil durumda otomatik gönderilecek mesajınızı yazın...',
                          hintStyle: const TextStyle(color: Colors.white38),
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      const SizedBox(height: 10),
                      // Preset suggestions
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: _presetTemplates.map((template) {
                            return Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ActionChip(
                                label: Text(
                                  template.length > 28 ? '${template.substring(0, 28)}...' : template,
                                  style: const TextStyle(fontSize: 11, color: Colors.white70),
                                ),
                                backgroundColor: Colors.white.withOpacity(0.07),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                onPressed: () {
                                  _messageController.text = template;
                                },
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerRight,
                        child: ElevatedButton.icon(
                          onPressed: _isSavingMessage ? null : _saveMessage,
                          icon: _isSavingMessage
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                )
                              : const Icon(Icons.check_rounded, size: 16),
                          label: const Text('Mesajı Kaydet', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 22),

                // 4. Emergency Contacts (Up to 10)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _buildSectionHeader('Acil Durum Kişileri (${contacts.length}/10)', Icons.people_alt_rounded),
                    if (contacts.length < 10)
                      TextButton.icon(
                        onPressed: _showAddContactModal,
                        icon: const Icon(Icons.person_add_rounded, color: AppColors.accent, size: 18),
                        label: const Text(
                          '+ Kişi Ekle',
                          style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),

                if (contacts.isEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppColors.cardBorder),
                    ),
                    child: Column(
                      children: [
                        Icon(Icons.contact_phone_outlined, size: 44, color: Colors.white.withOpacity(0.3)),
                        const SizedBox(height: 10),
                        const Text(
                          'Henüz acil durum kişisi eklenmedi',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Tehlike anında canlı konumunuzun ve mesajınızın gideceği en güvendiğiniz 10 kişiyi seçin.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                        const SizedBox(height: 14),
                        ElevatedButton.icon(
                          onPressed: _showAddContactModal,
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Kişi Ekle', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.accent,
                            foregroundColor: Colors.black,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: contacts.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (ctx, index) {
                      final contact = contacts[index];
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: AppColors.cardBorder),
                        ),
                        child: Row(
                          children: [
                            AppAvatar(
                              radius: 20,
                              imageUrl: contact.photoUrl,
                              name: contact.displayName,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    contact.displayName,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                    ),
                                  ),
                                  Text(
                                    '@${contact.username}',
                                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline_rounded, color: AppColors.callRed, size: 22),
                              tooltip: 'Listeden Çıkar',
                              onPressed: () => _emergencyService.removeContact(contact.uid),
                            ),
                          ],
                        ),
                      );
                    },
                  ),

                const SizedBox(height: 28),

                // 5. Test SOS Button
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton.icon(
                    onPressed: contacts.isEmpty ? null : _confirmAndTriggerSOS,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.callRed,
                      foregroundColor: Colors.white,
                      elevation: 4,
                      shadowColor: AppColors.callRed.withOpacity(0.5),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    icon: const Icon(Icons.warning_rounded, size: 22),
                    label: const Text(
                      'Acil Durum Uyarısını Test Et (SOS)',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                // 6. Discreet Explanatory Note
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.04),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline_rounded, color: Colors.white54, size: 18),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Sessiz & Gizli Koruma: Atadığınız tuşa 3 saniye basıldığında ekranda dikkat çekici ışık veya siren sesi çıkmaz. Yalnızca cebinizde hissedeceğiniz 3 kısa titreşimle uyarının iletildiği doğrulanır.',
                          style: TextStyle(color: Colors.white60, fontSize: 11.5, height: 1.4),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSectionHeader(String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, color: AppColors.accent, size: 18),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14.5,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}

class _AddEmergencyContactModal extends StatefulWidget {
  final String currentUserId;
  final ValueChanged<UserModel> onContactSelected;

  const _AddEmergencyContactModal({
    required this.currentUserId,
    required this.onContactSelected,
  });

  @override
  State<_AddEmergencyContactModal> createState() => _AddEmergencyContactModalState();
}

class _AddEmergencyContactModalState extends State<_AddEmergencyContactModal> {
  final CustomChatService _chatService = CustomChatService();
  final TextEditingController _searchCtrl = TextEditingController();
  List<UserModel> _allUsers = [];
  List<UserModel> _filteredUsers = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadUsers();
    _searchCtrl.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _loadUsers() async {
    final users = await _chatService.getUsers(widget.currentUserId);
    if (mounted) {
      setState(() {
        _allUsers = users;
        _filteredUsers = users;
        _isLoading = false;
      });
    }
  }

  void _onSearchChanged() {
    final query = _searchCtrl.text.toLowerCase().trim();
    setState(() {
      if (query.isEmpty) {
        _filteredUsers = _allUsers;
      } else {
        _filteredUsers = _allUsers.where((u) {
          return u.displayName.toLowerCase().contains(query) ||
                 u.username.toLowerCase().contains(query);
        }).toList();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.75,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Acil Durum Kişisi Seç',
            style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _searchCtrl,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            decoration: InputDecoration(
              hintText: 'Kişi ara (isim veya @kullanıcıadı)...',
              hintStyle: const TextStyle(color: Colors.white38),
              prefixIcon: const Icon(Icons.search, color: Colors.white54, size: 20),
              filled: true,
              fillColor: AppColors.surfaceLight,
              contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 16),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator(color: AppColors.accent))
                : _filteredUsers.isEmpty
                    ? Center(
                        child: Text(
                          _searchCtrl.text.isEmpty ? 'Kayıtlı kişi bulunamadı.' : 'Aramanızla eşleşen kişi yok.',
                          style: const TextStyle(color: Colors.white54),
                        ),
                      )
                    : ListView.separated(
                        itemCount: _filteredUsers.length,
                        separatorBuilder: (_, __) => Divider(color: Colors.white.withOpacity(0.06), height: 1),
                        itemBuilder: (ctx, idx) {
                          final user = _filteredUsers[idx];
                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                            leading: AppAvatar(
                              radius: 20,
                              imageUrl: user.photoUrl,
                              name: user.displayName,
                            ),
                            title: Text(
                              user.displayName,
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                            ),
                            subtitle: Text(
                              '@${user.username}',
                              style: const TextStyle(color: Colors.white54, fontSize: 12),
                            ),
                            trailing: const Icon(Icons.add_circle_outline_rounded, color: AppColors.accent, size: 24),
                            onTap: () => widget.onContactSelected(user),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
