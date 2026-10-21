import 'package:flutter/material.dart';
import '../../../constants/app_colors.dart';
import '../../../services/translation_service.dart';

class ChatTranslationSheet extends StatefulWidget {
  final String chatId;
  final String chatTitle;

  const ChatTranslationSheet({
    super.key,
    required this.chatId,
    required this.chatTitle,
  });

  static Future<void> show(
    BuildContext context, {
    required String chatId,
    required String chatTitle,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => ChatTranslationSheet(chatId: chatId, chatTitle: chatTitle),
    );
  }

  @override
  State<ChatTranslationSheet> createState() => _ChatTranslationSheetState();
}

class _ChatTranslationSheetState extends State<ChatTranslationSheet> {
  late bool _isEnabled;
  late String _selectedLang;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _isEnabled = TranslationService.isChatAutoTranslateEnabled(widget.chatId);
    _selectedLang = TranslationService.getChatTargetLanguage(widget.chatId);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filteredLanguages = TranslationService.supportedLanguages.entries.where((entry) {
      if (_searchQuery.isEmpty) return true;
      final q = _searchQuery.toLowerCase();
      return entry.value.toLowerCase().contains(q) || entry.key.toLowerCase().contains(q);
    }).toList();

    return Container(
      height: MediaQuery.of(context).size.height * 0.72,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          // Drag handle
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 8),
            width: 42,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.accent.withOpacity(0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.g_translate_rounded, color: AppColors.accent, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Sohbeti Çevir',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        widget.chatTitle,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12.5,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.white54),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),

          const Divider(color: Colors.white12, height: 1),

          // Toggle Switch Banner
          Container(
            margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.surfaceLight,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: _isEnabled ? AppColors.accent.withOpacity(0.4) : Colors.white10,
              ),
            ),
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              activeColor: AppColors.accent,
              title: const Text(
                'Otomatik Çeviri',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                ),
              ),
              subtitle: Text(
                _isEnabled
                    ? 'Mesajlar ${TranslationService.getLanguageName(_selectedLang)} diline çevriliyor'
                    : 'Gelen mesajları otomatik olarak kendi dilinize çevirin',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              value: _isEnabled,
              onChanged: (val) async {
                setState(() => _isEnabled = val);
                await TranslationService.setChatAutoTranslate(
                  widget.chatId,
                  val,
                  targetLang: _selectedLang,
                );
              },
            ),
          ),

          // Search Bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: TextField(
              controller: _searchController,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Dil ara...',
                hintStyle: const TextStyle(color: Colors.white38, fontSize: 13.5),
                prefixIcon: const Icon(Icons.search_rounded, color: Colors.white38, size: 20),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded, color: Colors.white38, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
                filled: true,
                fillColor: AppColors.surfaceLight,
                contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (val) => setState(() => _searchQuery = val),
            ),
          ),

          const Padding(
            padding: EdgeInsets.fromLTRB(20, 10, 20, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'HEDEF DİL SEÇİN',
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                ),
              ),
            ),
          ),

          // Language List
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              itemCount: filteredLanguages.length,
              separatorBuilder: (_, __) => const Divider(color: Colors.white10, height: 1),
              itemBuilder: (ctx, index) {
                final entry = filteredLanguages[index];
                final code = entry.key;
                final name = entry.value;
                final isSelected = _selectedLang == code;

                return ListTile(
                  dense: true,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  title: Text(
                    name,
                    style: TextStyle(
                      color: isSelected ? AppColors.accent : Colors.white,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                      fontSize: 14.5,
                    ),
                  ),
                  subtitle: Text(
                    code.toUpperCase(),
                    style: TextStyle(
                      color: isSelected ? AppColors.accent.withOpacity(0.7) : Colors.white38,
                      fontSize: 11.5,
                    ),
                  ),
                  trailing: isSelected
                      ? const Icon(Icons.check_circle_rounded, color: AppColors.accent, size: 20)
                      : null,
                  onTap: () async {
                    setState(() {
                      _selectedLang = code;
                      _isEnabled = true; // Auto-enable when language tapped
                    });
                    await TranslationService.setChatAutoTranslate(
                      widget.chatId,
                      true,
                      targetLang: code,
                    );
                    if (context.mounted) {
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Sohbet $name diline çevriliyor'),
                          duration: const Duration(seconds: 2),
                          backgroundColor: AppColors.surfaceLight,
                        ),
                      );
                    }
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
