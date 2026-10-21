import 'package:flutter/material.dart';
import '../constants/app_colors.dart';
import '../services/message_reactions_service.dart';
import 'app_avatar.dart';

/// Floating WhatsApp-style reaction bar displaying the 6 standard emojis + custom '+' picker
class EmojiReactionPickerBar extends StatelessWidget {
  final String? currentReaction;
  final ValueChanged<String> onReactionSelected;
  final VoidCallback onPlusPressed;

  const EmojiReactionPickerBar({
    super.key,
    required this.currentReaction,
    required this.onReactionSelected,
    required this.onPlusPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(32),
        border: Border.all(color: Colors.white.withOpacity(0.12), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.35),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ...MessageReactionsService.quickReactions.map((emoji) {
            final isSelected = currentReaction == emoji;
            return _buildEmojiButton(emoji, isSelected);
          }),
          const SizedBox(width: 4),
          // Custom '+' button for all emojis
          GestureDetector(
            onTap: onPlusPressed,
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withOpacity(0.08),
              ),
              child: const Icon(
                Icons.add_rounded,
                color: Colors.white70,
                size: 20,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmojiButton(String emoji, bool isSelected) {
    return GestureDetector(
      onTap: () => onReactionSelected(emoji),
      child: Container(
        width: 40,
        height: 40,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isSelected ? AppColors.accent.withOpacity(0.25) : Colors.transparent,
          border: isSelected ? Border.all(color: AppColors.accent, width: 1.5) : null,
        ),
        alignment: Alignment.center,
        child: Text(
          emoji,
          style: TextStyle(
            fontSize: isSelected ? 24 : 22,
          ),
        ),
      ),
    );
  }
}

/// Message reaction pill displayed at the bottom corner of a message bubble
class MessageReactionBadge extends StatelessWidget {
  final String messageId;
  final bool isMe;
  final VoidCallback? onTap;

  const MessageReactionBadge({
    super.key,
    required this.messageId,
    required this.isMe,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: MessageReactionsService.reactionNotifier,
      builder: (context, _, __) {
        final emojiCounts = MessageReactionsService.getEmojiCounts(messageId);
        if (emojiCounts.isEmpty) {
          return const SizedBox.shrink();
        }

        final totalCount = emojiCounts.fold<int>(0, (sum, item) => sum + item.count);
        // Show up to 3 most popular emojis
        final displayEmojis = emojiCounts.take(3).map((e) => e.emoji).join(' ');

        return GestureDetector(
          onTap: onTap ?? () => showReactionsDetailSheet(context, messageId),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.surfaceLight,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Colors.white.withOpacity(0.15),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.3),
                  blurRadius: 4,
                  offset: const Offset(0, 1.5),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  displayEmojis,
                  style: const TextStyle(fontSize: 12),
                ),
                if (totalCount > 1) ...[
                  const SizedBox(width: 4),
                  Text(
                    '$totalCount',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Bottom sheet showing who reacted with which emoji, matching WhatsApp style
void showReactionsDetailSheet(BuildContext context, String messageId) {
  showModalBottomSheet(
    context: context,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) {
      return _ReactionsDetailSheet(messageId: messageId);
    },
  );
}

class _ReactionsDetailSheet extends StatefulWidget {
  final String messageId;

  const _ReactionsDetailSheet({required this.messageId});

  @override
  State<_ReactionsDetailSheet> createState() => _ReactionsDetailSheetState();
}

class _ReactionsDetailSheetState extends State<_ReactionsDetailSheet> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late List<({String emoji, int count})> _emojiCounts;
  late List<MessageReaction> _allReactions;

  @override
  void initState() {
    super.initState();
    _loadData();
    _tabController = TabController(length: _emojiCounts.length + 1, vsync: this);
  }

  void _loadData() {
    _allReactions = MessageReactionsService.getReactions(widget.messageId);
    _emojiCounts = MessageReactionsService.getEmojiCounts(widget.messageId);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_allReactions.isEmpty) {
      return const SizedBox(
        height: 120,
        child: Center(
          child: Text('Tepki bulunamadı.', style: TextStyle(color: Colors.white54)),
        ),
      );
    }

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Tab bar: "Tümü" + each unique emoji
          TabBar(
            controller: _tabController,
            isScrollable: true,
            indicatorColor: AppColors.accent,
            indicatorWeight: 3,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white54,
            tabs: [
              Tab(text: 'Tümü (${_allReactions.length})'),
              ..._emojiCounts.map((ec) => Tab(text: '${ec.emoji} ${ec.count}')),
            ],
          ),
          const Divider(color: Colors.white12, height: 1),
          // Content
          SizedBox(
            height: 260,
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildReactionList(_allReactions),
                ..._emojiCounts.map((ec) {
                  final filtered = _allReactions.where((r) => r.emoji == ec.emoji).toList();
                  return _buildReactionList(filtered);
                }),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReactionList(List<MessageReaction> list) {
    return ListView.builder(
      itemCount: list.length,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemBuilder: (context, idx) {
        final r = list[idx];
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: AppAvatar(
            radius: 20,
            imageUrl: '',
            name: r.userName,
          ),
          title: Text(
            r.userName,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14),
          ),
          trailing: Text(
            r.emoji,
            style: const TextStyle(fontSize: 22),
          ),
        );
      },
    );
  }
}
