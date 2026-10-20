import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../constants/app_colors.dart';
import '../../../models/message_model.dart';
import '../../../models/user_model.dart';
import '../../../services/custom_chat_service.dart';
import '../chat_screen.dart';

class ContactMessageBubble extends StatelessWidget {
  final MessageModel? message;
  final String? content;
  final bool isMe;
  final UserModel? currentUser;

  const ContactMessageBubble({
    super.key,
    this.message,
    this.content,
    required this.isMe,
    this.currentUser,
  });

  Map<String, dynamic> _parseContactData() {
    final raw = content ?? message?.content ?? '';
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {}

    // Fallback: simple text parsing
    final lines = raw.split('\n');
    String name = 'Paylaşılan Kişi';
    String phone = '';
    for (final line in lines) {
      if (line.toLowerCase().startsWith('kişi:') || line.toLowerCase().startsWith('isim:')) {
        name = line.substring(line.indexOf(':') + 1).trim();
      } else if (line.toLowerCase().startsWith('tel:') || line.toLowerCase().startsWith('telefon:')) {
        phone = line.substring(line.indexOf(':') + 1).trim();
      } else if (phone.isEmpty && RegExp(r'^[+0-9\s-]+$').hasMatch(line.trim())) {
        phone = line.trim();
      }
    }
    return {
      'name': name.isNotEmpty ? name : 'Paylaşılan Kişi',
      'phone': phone,
    };
  }

  void _callNumber(BuildContext context, String phone) async {
    final cleanPhone = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    if (cleanPhone.isEmpty) return;

    final uri = Uri.parse('tel:$cleanPhone');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Arama başlatılamadı.')),
        );
      }
    }
  }

  void _sendMessage(BuildContext context, String phone, String name) async {
    final cleanPhone = phone.replaceAll(RegExp(r'[^0-9+]'), '');

    // Check if user exists on Talknex
    if (currentUser != null) {
      try {
        final chatService = CustomChatService();
        final matched = await chatService.syncContacts(
          userId: int.tryParse(currentUser!.uid) ?? 0,
          contacts: [{'phone': cleanPhone, 'name': name}],
        );

        if (matched.isNotEmpty && context.mounted) {
          final peer = matched.first;
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ChatScreen(
                currentUser: currentUser!,
                peerUser: peer,
              ),
            ),
          );
          return;
        }
      } catch (_) {}
    }

    // Fallback to SMS if not registered on Talknex
    final smsUri = Uri.parse('sms:$cleanPhone');
    if (await canLaunchUrl(smsUri)) {
      await launchUrl(smsUri, mode: LaunchMode.externalApplication);
    }
  }

  void _addToContacts(BuildContext context, String name, String phone) async {
    try {
      final cleanPhone = phone.trim();
      final cleanName = name.trim();

      final newContact = Contact(
        name: Name(first: cleanName),
        phones: [Phone(cleanPhone)],
      );

      final result = await FlutterContacts.openExternalInsert(newContact);
      if (result != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$cleanName rehbere eklendi!'),
            backgroundColor: AppColors.onlineGreen,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      debugPrint('[ADD TO CONTACTS ERR] $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Rehbere ekleme ekranı açılamadı.'),
            backgroundColor: AppColors.callRed,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final contactData = _parseContactData();
    final name = contactData['name']?.toString() ?? 'Kişi';
    final phone = contactData['phone']?.toString() ?? '';
    final initial = name.isNotEmpty ? name.substring(0, 1).toUpperCase() : '?';

    return Container(
      width: 250,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header info
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        const Color(0xFF00BFA5),
                        const Color(0xFF00897B),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      initial,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 20,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        phone.isNotEmpty ? phone : 'Numara belirtilmedi',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          Divider(color: Colors.white.withOpacity(0.1), height: 1),

          // Actions Row (Ara, Mesaj, Rehbere Ekle)
          IntrinsicHeight(
            child: Row(
              children: [
                // Ara
                Expanded(
                  child: InkWell(
                    borderRadius: const BorderRadius.only(bottomLeft: Radius.circular(14)),
                    onTap: phone.isNotEmpty ? () => _callNumber(context, phone) : null,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.phone_rounded, color: AppColors.accent, size: 16),
                          SizedBox(width: 6),
                          Text(
                            'Ara',
                            style: TextStyle(color: AppColors.accent, fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                VerticalDivider(color: Colors.white.withOpacity(0.1), width: 1),

                // Mesaj
                Expanded(
                  child: InkWell(
                    onTap: phone.isNotEmpty ? () => _sendMessage(context, phone, name) : null,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.chat_bubble_outline_rounded, color: AppColors.primaryLight, size: 16),
                          SizedBox(width: 6),
                          Text(
                            'Mesaj',
                            style: TextStyle(color: AppColors.primaryLight, fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                VerticalDivider(color: Colors.white.withOpacity(0.1), width: 1),

                // Rehbere Kaydet
                Expanded(
                  child: InkWell(
                    borderRadius: const BorderRadius.only(bottomRight: Radius.circular(14)),
                    onTap: phone.isNotEmpty ? () => _addToContacts(context, name, phone) : null,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.person_add_alt_1_rounded, color: Color(0xFF00BFA5), size: 16),
                          SizedBox(width: 6),
                          Text(
                            'Kaydet',
                            style: TextStyle(color: Color(0xFF00BFA5), fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
