import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../../constants/app_colors.dart';
import '../../services/starred_messages_service.dart';

class StarredMessagesScreen extends StatelessWidget {
  final String? chatId;
  final String? chatTitle;

  const StarredMessagesScreen({
    super.key,
    this.chatId,
    this.chatTitle,
  });

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDate = DateTime(dt.year, dt.month, dt.day);

    if (messageDate == today) {
      return 'Bugün ${DateFormat('HH:mm').format(dt)}';
    } else if (messageDate == today.subtract(const Duration(days: 1))) {
      return 'Dün ${DateFormat('HH:mm').format(dt)}';
    } else {
      return DateFormat('dd.MM.yyyy HH:mm').format(dt);
    }
  }

  Widget _buildTypePreview(StarredMessage item) {
    switch (item.type) {
      case 'image':
        return Row(
          children: [
            const Icon(Icons.photo_rounded, size: 18, color: Colors.blueAccent),
            const SizedBox(width: 8),
            Text(
              item.content.isNotEmpty && item.content != '📷 Fotoğraf' ? item.content : 'Fotoğraf',
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ],
        );
      case 'video':
        return Row(
          children: [
            const Icon(Icons.videocam_rounded, size: 18, color: Colors.pinkAccent),
            const SizedBox(width: 8),
            Text(
              item.content.isNotEmpty && item.content != '🎥 Video' ? item.content : 'Video',
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ],
        );
      case 'audio':
        return const Row(
          children: [
            Icon(Icons.mic_rounded, size: 18, color: AppColors.accent),
            SizedBox(width: 8),
            Text('Sesli Mesaj', style: TextStyle(color: Colors.white, fontSize: 14)),
          ],
        );
      case 'contact':
        return Row(
          children: [
            const Icon(Icons.person_rounded, size: 18, color: Color(0xFF00BFA5)),
            const SizedBox(width: 8),
            Text(
              item.content.isNotEmpty ? 'Kişi Kartı' : 'Kişi',
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ],
        );
      case 'location':
        return const Row(
          children: [
            Icon(Icons.location_on_rounded, size: 18, color: Color(0xFFFF5722)),
            SizedBox(width: 8),
            Text('Konum Mesajı', style: TextStyle(color: Colors.white, fontSize: 14)),
          ],
        );
      case 'doc':
        return Row(
          children: [
            const Icon(Icons.insert_drive_file_rounded, size: 18, color: Color(0xFF5F66CD)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                item.content.isNotEmpty ? item.content : 'Belge / Doküman',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
          ],
        );
      default:
        return Text(
          item.content,
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.35),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = chatTitle != null ? '$chatTitle - Yıldızlı' : 'Yıldızlı Mesajlar';

    return Scaffold(
      backgroundColor: AppColors.chatBackground,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        title: Text(
          title,
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 17, fontWeight: FontWeight.bold),
        ),
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: StarredMessagesService.starNotifier,
        builder: (context, _, __) {
          final items = StarredMessagesService.getStarredMessages(chatId: chatId);

          if (items.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: Colors.amber.withOpacity(0.12),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.star_rounded,
                        color: Colors.amber,
                        size: 56,
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'Yıldızlı Mesaj Yok',
                      style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Önemli mesajları daha sonra kolayca bulmak için üzerine basılı tutup "Yıldız Ekle" seçeneğini kullanabilirsiniz.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white54, fontSize: 13.5, height: 1.4),
                    ),
                  ],
                ),
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (ctx, index) {
              final item = items[index];

              return Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.cardBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Top header: Chat title & Timestamp
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 12,
                          backgroundColor: item.isGroup
                              ? const Color(0xFF673AB7).withOpacity(0.3)
                              : AppColors.primary.withOpacity(0.2),
                          child: Icon(
                            item.isGroup ? Icons.group : Icons.person,
                            size: 14,
                            color: item.isGroup ? const Color(0xFFB388FF) : AppColors.primaryLight,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            item.chatTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontWeight: FontWeight.w600,
                              fontSize: 12.5,
                            ),
                          ),
                        ),
                        Text(
                          _formatDate(item.timestamp),
                          style: const TextStyle(color: Colors.white38, fontSize: 11),
                        ),
                        const SizedBox(width: 6),
                        GestureDetector(
                          onTap: () {
                            final text = item.content.isNotEmpty ? item.content : (item.mediaUrl ?? '');
                            if (text.isNotEmpty) {
                              Clipboard.setData(ClipboardData(text: text));
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Mesaj panoya kopyalandı'),
                                  behavior: SnackBarBehavior.floating,
                                  duration: Duration(seconds: 2),
                                ),
                              );
                            }
                          },
                          child: const Icon(
                            Icons.copy_rounded,
                            color: Colors.white54,
                            size: 18,
                          ),
                        ),
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: () {
                            StarredMessagesService.removeStar(item.messageId);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: const Text('Yıldız kaldırıldı'),
                                behavior: SnackBarBehavior.floating,
                                duration: const Duration(seconds: 2),
                                action: SnackBarAction(
                                  label: 'Geri Al',
                                  textColor: Colors.amber,
                                  onPressed: () => StarredMessagesService.toggleStar(item),
                                ),
                              ),
                            );
                          },
                          child: const Icon(
                            Icons.star_rounded,
                            color: Colors.amber,
                            size: 20,
                          ),
                        ),
                      ],
                    ),

                    const Divider(color: Colors.white10, height: 16),

                    // Sender name
                    Text(
                      item.senderName,
                      style: const TextStyle(
                        color: AppColors.accent,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 4),

                    // Message content preview
                    _buildTypePreview(item),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
