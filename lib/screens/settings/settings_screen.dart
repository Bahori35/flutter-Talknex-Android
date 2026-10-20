import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../constants/app_colors.dart';
import '../../services/custom_auth_service.dart';
import '../../services/emergency_service.dart';
import '../../widgets/app_avatar.dart';
import '../profile/profile_screen.dart';
import 'emergency_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final authService = Provider.of<CustomAuthService>(context);
    final currentUser = authService.currentUser;
    final emergencyService = EmergencyService();

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
          'Ayarlar',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
        ),
      ),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          children: [
            // Profile Card
            if (currentUser != null)
              InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const ProfileScreen()),
                  );
                },
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppColors.cardBorder),
                  ),
                  child: Row(
                    children: [
                      AppAvatar(
                        radius: 28,
                        imageUrl: currentUser.photoUrl,
                        name: currentUser.displayName,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              currentUser.displayName,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '@${currentUser.username}',
                              style: const TextStyle(color: AppColors.accent, fontSize: 13),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              currentUser.status,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white54, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.arrow_forward_ios_rounded, color: Colors.white38, size: 16),
                    ],
                  ),
                ),
              ),

            const SizedBox(height: 20),

            // Highlighted: Emergency SOS Setting Tile
            AnimatedBuilder(
              animation: emergencyService,
              builder: (ctx, _) {
                final isEnabled = emergencyService.isEnabled;
                final count = emergencyService.contactCount;

                return InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const EmergencyScreen()),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          const Color(0xFF3B1217).withOpacity(0.9),
                          const Color(0xFF1E0E12).withOpacity(0.9),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: AppColors.callRed.withOpacity(0.4), width: 1.2),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.callRed.withOpacity(0.15),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: AppColors.callRed.withOpacity(0.2),
                            shape: BoxShape.circle,
                            border: Border.all(color: AppColors.callRed.withOpacity(0.5)),
                          ),
                          child: const Icon(Icons.shield_rounded, color: AppColors.callRed, size: 24),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Text(
                                    'Acil Durum (SOS)',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 15,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: isEnabled ? AppColors.callRed : Colors.white24,
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      isEnabled ? '$count Kişi' : 'Kapalı',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 3),
                              const Text(
                                'Tuşa 3 sn basılı tutunca gizli konum ve yardım mesajı atar.',
                                style: TextStyle(color: Colors.white60, fontSize: 11.5),
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.arrow_forward_ios_rounded, color: AppColors.callRed, size: 16),
                      ],
                    ),
                  ),
                );
              },
            ),

            const SizedBox(height: 20),

            // Other Settings Group
            Container(
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: AppColors.cardBorder),
              ),
              child: Column(
                children: [
                  _buildSettingTile(
                    icon: Icons.lock_outline_rounded,
                    iconColor: AppColors.onlineGreen,
                    title: 'Gizlilik ve Güvenlik',
                    subtitle: 'Uçtan Uca Şifreleme (E2EE), Son Görülme',
                    onTap: () {
                      _showInfoDialog(
                        context,
                        'Gizlilik & Uçtan Uca Şifreleme',
                        'Talknex üzerindeki tüm mesajlar ve aramalar AES-256-GCM ve WebRTC P2P protokolü ile şifrelenir. Mesajlarınız sunucu dahil hiç kimse tarafından okunamaz.',
                      );
                    },
                  ),
                  _buildDivider(),
                  _buildSettingTile(
                    icon: Icons.notifications_none_rounded,
                    iconColor: const Color(0xFFFF9800),
                    title: 'Bildirimler ve Sesler',
                    subtitle: 'Mesaj ve çağrı zil sesleri, öncelik ayarları',
                    onTap: () {
                      _showInfoDialog(
                        context,
                        'Bildirim Ayarları',
                        'Firebase Cloud Messaging (FCM) ve sistem bildirimleri aktiftir. Bildirim izinlerini telefonunuzun Ayarlar > Uygulamalar > Talknex menüsünden de yönetebilirsiniz.',
                      );
                    },
                  ),
                  _buildDivider(),
                  _buildSettingTile(
                    icon: Icons.location_on_outlined,
                    iconColor: AppColors.accent,
                    title: 'Canlı Konum ve Harita',
                    subtitle: 'Arka plan GPS takibi ve otomatik merkezleme',
                    onTap: () {
                      _showInfoDialog(
                        context,
                        'Canlı Konum Servisi',
                        'Talknex Android Foreground Service teknolojisi kullanarak siz uygulamayı kapatsanız veya araç sürseniz bile canlı konumunuzu kesintisiz paylaşır.',
                      );
                    },
                  ),
                  _buildDivider(),
                  _buildSettingTile(
                    icon: Icons.info_outline_rounded,
                    iconColor: AppColors.primaryLight,
                    title: 'Hakkında ve Lisans',
                    subtitle: 'Talknex v1.0.0 (Build 39255827711)',
                    onTap: () {
                      _showInfoDialog(
                        context,
                        'Talknex Hakkında',
                        'Talknex, Flutter ve yüksek performanslı Go/MariaDB altyapısıyla geliştirilmiş yeni nesil güvenli iletişim platformudur.\n\nSürüm: 1.0.0\nMotor: Go Socket.io + WebRTC\nGüvenlik: AES-256-GCM E2EE',
                      );
                    },
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // Logout Tile
            Container(
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: AppColors.cardBorder),
              ),
              child: _buildSettingTile(
                icon: Icons.logout_rounded,
                iconColor: AppColors.callRed,
                title: 'Çıkış Yap',
                subtitle: 'Hesabınızdan güvenle çıkış yapın',
                textColor: AppColors.callRed,
                onTap: () => authService.signOut(),
              ),
            ),

            const SizedBox(height: 30),
            Text(
              'Talknex Messenger • Güvenli ve Uçtan Uca Şifreli',
              style: TextStyle(color: Colors.white.withOpacity(0.35), fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    Color textColor = Colors.white,
  }) {
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: iconColor.withOpacity(0.12),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: iconColor, size: 20),
      ),
      title: Text(
        title,
        style: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 14),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(color: Colors.white.withOpacity(0.55), fontSize: 12),
      ),
      trailing: const Icon(Icons.arrow_forward_ios_rounded, color: Colors.white24, size: 14),
    );
  }

  Widget _buildDivider() {
    return Divider(color: Colors.white.withOpacity(0.06), height: 1, indent: 56);
  }

  void _showInfoDialog(BuildContext context, String title, String content) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(title, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
        content: Text(content, style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.4)),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Anladım'),
          ),
        ],
      ),
    );
  }
}
