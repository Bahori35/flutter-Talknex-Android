import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../constants/app_colors.dart';

enum PickerTab { emoji, gif, sticker }

class EmojiGifStickerPicker extends StatefulWidget {
  final Function(String emoji) onEmojiSelected;
  final VoidCallback onBackspacePressed;
  final Function(String gifUrl) onGifSelected;
  final Function(String stickerUrl) onStickerSelected;

  const EmojiGifStickerPicker({
    super.key,
    required this.onEmojiSelected,
    required this.onBackspacePressed,
    required this.onGifSelected,
    required this.onStickerSelected,
  });

  @override
  State<EmojiGifStickerPicker> createState() => _EmojiGifStickerPickerState();
}

class _EmojiGifStickerPickerState extends State<EmojiGifStickerPicker> {
  PickerTab _currentTab = PickerTab.emoji;
  int _selectedEmojiCategory = 0;
  int _selectedGifCategory = 0;
  int _selectedStickerPack = 0;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  // EMOJI DATA CATEGORIES
  static final List<Map<String, dynamic>> _emojiCategories = [
    {
      'name': 'Yüzler & İfadeler',
      'icon': '😀',
      'emojis': [
        '😀', '😃', '😄', '😁', '😆', '😅', '🤣', '😂', '🙂', '🙃',
        '😉', '😊', '😇', '🥰', '😍', '🤩', '😘', '😗', '😚', '😙',
        '😋', '😛', '😜', '🤪', '😝', '🤑', '🤗', '🤭', '🤫', '🤔',
        '🤐', '🤨', '😐', '😑', '😶', '😏', '😒', '🙄', '😬', '🤥',
        '😌', '😔', '😪', '🤤', '😴', '😷', '🤒', '🤕', '🤢', '🤮',
        '🤧', '🥵', '🥶', '🥴', '😵', '🤯', '🤠', '🥳', '😎', '🤓',
        '🧐', '😕', '😟', '🙁', '😮', '😯', '😲', '😳', '🥺', '😦',
        '😧', '😨', '😰', '😥', '😢', '😭', '😱', '😖', '😣', '😞',
        '😓', '😩', '😫', '🥱', '😤', '😡', '😠', '🤬', '😈', '👿',
        '💀', '☠️', '💩', '🤡', '👻', '👽', '👾', '🤖'
      ]
    },
    {
      'name': 'İnsanlar & Jestler',
      'icon': '👋',
      'emojis': [
        '👋', '🤚', '🖐️', '✋', '🖖', '👌', '🤌', '🤏', '✌️', '🤞',
        '🫰', '🤟', '🤘', '🤙', '👈', '👉', '👆', '🖕', '👇', '☝️',
        '👍', '👎', '✊', '👊', '🤛', '🤜', '👏', '🙌', '👐', '🤲',
        '🤝', '🙏', '✍️', '💅', '🤳', '💪', '🦵', '🦶', '👂', '👃',
        '🧠', '👀', '👁️', '👅', '👄', '💋', '🫂', '👶', '👧', '👦',
        '👩', '👨', '👵', '👴', '👮', '🕵️', '👷', '💂', '🦸', '🦹'
      ]
    },
    {
      'name': 'Aşk & Kalpler',
      'icon': '❤️',
      'emojis': [
        '❤️', '🧡', '💛', '💚', '💙', '💜', '🤎', '🖤', '🤍', '💔',
        '❤️‍🔥', '❤️‍🩹', '❣️', '💕', '💞', '💓', '💗', '💖', '💘', '💝',
        '💟', '💌', '💐', '🌹', '🥀', '🌺', '🌸', '🌷', '💍', '💎'
      ]
    },
    {
      'name': 'Hayvanlar & Doğa',
      'icon': '🐱',
      'emojis': [
        '🐶', '🐱', '🐭', '🐹', '🐰', '🦊', '🐻', '🐼', '🐨', '🐯',
        '🦁', '🐮', '🐷', '🐸', '🐵', '🐔', '🐧', '🐦', '🐤', '🦆',
        '🦅', '🦉', '🦇', '🐺', '🐗', '🐴', '🦄', '🐝', '🐛', '🦋',
        '🐌', '🐞', '🐜', '🐢', '🐍', '🦎', '🐙', '🦑', '🦐', '🦀',
        '🐠', '🐟', '🐬', '🐳', '🦈', '🐊', '🐅', '🐆', '🦓', '🐘'
      ]
    },
    {
      'name': 'Yiyecek & İçecek',
      'icon': '🍕',
      'emojis': [
        '🍏', '🍎', '🍐', '🍊', '🍋', '🍌', '🍉', '🍇', '🍓', '🍒',
        '🍑', '🥭', '🍍', '🥥', '🥝', '🍅', '🥑', '🍔', '🍟', '🍕',
        '🌭', '🥪', '🌮', '🌯', '🥗', '🍝', '🍜', '🍲', '🍣', '🍱',
        '🥟', '🍤', '🍙', '🍚', '🍦', '🍧', '🍨', '🍩', '🍪', '🎂',
        '🍰', '🧁', '🍫', '🍬', '🍭', '🍿', '☕', '🫖', '🍵', '🥤'
      ]
    },
    {
      'name': 'Spor & Aktiviteler',
      'icon': '⚽',
      'emojis': [
        '⚽', '🏀', '🏈', '⚾', '🥎', '🎾', '🏐', '🏉', '🎱', '🏓',
        '🏸', '🏒', '🥊', '🥋', '🎯', '⛳', '⛸️', '🎣', '🤿', '🎽',
        '🛹', '🛼', '🎿', '🏂', '🏋️', '🧗', '🧘', '🏄', '🏊', '🚴',
        '🏆', '🥇', '🥈', '🥉', '🏅', '🎮', '🕹️', '🎲', '🧩', '🎨'
      ]
    },
    {
      'name': 'Nesneler & Semboller',
      'icon': '💡',
      'emojis': [
        '🚗', '🚕', '🚙', '🚌', '🏎️', '🚓', '🚑', '🚒', '🛵', '🚲',
        '🚀', '🛸', '🚁', '🚢', '⛵', '🏖️', '🌋', '🏰', '📱', '💻',
        '🖥️', '📷', '🎥', '📺', '⏰', '💡', '💸', '💵', '💰', '💳',
        '🎁', '🎈', '🎊', '🎉', '🔥', '💥', '✨', '🌟', '💫', '⚡',
        '🌈', '☀️', '🌧️', '❄️', '🌙', '💯', '⚠️', '⛔', '💬', '🔔'
      ]
    },
  ];

  // GIF DATA CATEGORIES (Reliable public CDN GIF links)
  static final List<Map<String, dynamic>> _gifCategories = [
    {
      'name': 'Trendler',
      'tag': 'trending',
      'gifs': [
        {
          'title': 'Dans Eden Kedi',
          'url': 'https://media.giphy.com/media/JIX9t2j0ZTN9S/giphy.gif',
        },
        {
          'title': 'Kutlama Minyonlar',
          'url': 'https://media.giphy.com/media/chzz1FQgqhytWRWbp3/giphy.gif',
        },
        {
          'title': 'SpongeBob Sevinç',
          'url': 'https://media.giphy.com/media/nDSlfqf0gn5g4/giphy.gif',
        },
        {
          'title': 'Patlamış Mısır Keyfi',
          'url': 'https://media.giphy.com/media/t3dLl0TGHCxTG/giphy.gif',
        },
        {
          'title': 'Bebek Dansı',
          'url': 'https://media.giphy.com/media/blSTtZehjAZ8I/giphy.gif',
        },
        {
          'title': 'Kadeh Kaldırma',
          'url': 'https://media.giphy.com/media/GCLlQnV7dXZ2E/giphy.gif',
        },
      ]
    },
    {
      'name': 'Komik',
      'tag': 'funny',
      'gifs': [
        {
          'title': 'Gülmekten Kırılan Kedi',
          'url': 'https://media.giphy.com/media/10JhviFuU2gWD6/giphy.gif',
        },
        {
          'title': 'Yüzünü Kapatma',
          'url': 'https://media.giphy.com/media/3oEjI67Egb8G9jNFsI/giphy.gif',
        },
        {
          'title': 'Şüpheli Bakış',
          'url': 'https://media.giphy.com/media/H5C8CevNMbpBqNqFjl/giphy.gif',
        },
        {
          'title': 'Kafa Karışıklığı',
          'url': 'https://media.giphy.com/media/DHqth0hVQoIzS/giphy.gif',
        },
        {
          'title': 'Gülme Krizi',
          'url': 'https://media.giphy.com/media/BY8ORoRpnGDXeBNwxg/giphy.gif',
        },
        {
          'title': 'Köpek Şaşkınlığı',
          'url': 'https://media.giphy.com/media/4Zo41lhzKt6iZ8xff9/giphy.gif',
        },
      ]
    },
    {
      'name': 'Aşk & Sevgi',
      'tag': 'love',
      'gifs': [
        {
          'title': 'Kalp Patlaması',
          'url': 'https://media.giphy.com/media/26BRv0ThflsHCqDrG/giphy.gif',
        },
        {
          'title': 'Sıcak Sarılma',
          'url': 'https://media.giphy.com/media/od5H3PmEG5EVq/giphy.gif',
        },
        {
          'title': 'Öpücük Gönderme',
          'url': 'https://media.giphy.com/media/l4pTdcifPZLpDjL1e/giphy.gif',
        },
        {
          'title': 'Sevimli Sarılma',
          'url': 'https://media.giphy.com/media/3bqtLDeiDtwhq/giphy.gif',
        },
        {
          'title': 'Kalp Gözler',
          'url': 'https://media.giphy.com/media/uw0KqTWZSm8gg/giphy.gif',
        },
        {
          'title': 'Seni Seviyorum',
          'url': 'https://media.giphy.com/media/M90mJvfWfd5mbUuULX/giphy.gif',
        },
      ]
    },
    {
      'name': 'Kutlama',
      'tag': 'party',
      'gifs': [
        {
          'title': 'Konfeti Yağmuru',
          'url': 'https://media.giphy.com/media/artj92V8o75VPL7AeQ/giphy.gif',
        },
        {
          'title': 'Havai Fişek',
          'url': 'https://media.giphy.com/media/peAFQfg7Ol6IE/giphy.gif',
        },
        {
          'title': 'Çılgın Parti',
          'url': 'https://media.giphy.com/media/l0MYt5jPR6QX5pnqM/giphy.gif',
        },
        {
          'title': 'Şampanya Kutlaması',
          'url': 'https://media.giphy.com/media/3KC2jD2Q38OSMQnpMN/giphy.gif',
        },
        {
          'title': 'Çak Bir Beşlik',
          'url': 'https://media.giphy.com/media/l0ErFafpUCQTQFMSk/giphy.gif',
        },
        {
          'title': 'Doğum Günü Pastası',
          'url': 'https://media.giphy.com/media/l4KibWpBGWchSqCRy/giphy.gif',
        },
      ]
    },
    {
      'name': 'Onay & Alkış',
      'tag': 'clap',
      'gifs': [
        {
          'title': 'Alkışlar',
          'url': 'https://media.giphy.com/media/nbvFVPiEiJH6JOGIok/giphy.gif',
        },
        {
          'title': 'Başparmak Yukarı',
          'url': 'https://media.giphy.com/media/111ebonMs90YLu/giphy.gif',
        },
        {
          'title': 'Harika İş',
          'url': 'https://media.giphy.com/media/l3q2XhfQ8oCkm1GhO/giphy.gif',
        },
        {
          'title': 'Kesinlikle Evet',
          'url': 'https://media.giphy.com/media/3o7abKhOpu0NwenH3O/giphy.gif',
        },
        {
          'title': 'Akıl Uçurucu',
          'url': 'https://media.giphy.com/media/xT0xeJpnrWC4XWblEk/giphy.gif',
        },
        {
          'title': 'Kusursuz',
          'url': 'https://media.giphy.com/media/3o7aCWJavAgtBzLWrS/giphy.gif',
        },
      ]
    },
    {
      'name': 'Duygusal',
      'tag': 'sad',
      'gifs': [
        {
          'title': 'Gözyaşı',
          'url': 'https://media.giphy.com/media/L95W4wv8nnb9K/giphy.gif',
        },
        {
          'title': 'Ağlayan Kedi',
          'url': 'https://media.giphy.com/media/d2lcHJTG5Tscg/giphy.gif',
        },
        {
          'title': 'Yağmurda Üzüntü',
          'url': 'https://media.giphy.com/media/7SF5scGB2AFrgsXP63/giphy.gif',
        },
        {
          'title': 'Yalnızlık',
          'url': 'https://media.giphy.com/media/ISOckXUybVfQ4/giphy.gif',
        },
      ]
    },
  ];

  // STICKER PACKS (WhatsApp-style transparent sticker assets)
  static final List<Map<String, dynamic>> _stickerPacks = [
    {
      'name': 'Sevimli Kediler',
      'icon': '🐱',
      'stickers': [
        'https://cdn-icons-png.flaticon.com/512/616/616430.png',
        'https://cdn-icons-png.flaticon.com/512/616/616408.png',
        'https://cdn-icons-png.flaticon.com/512/616/616412.png',
        'https://cdn-icons-png.flaticon.com/512/616/616410.png',
        'https://cdn-icons-png.flaticon.com/512/616/616411.png',
        'https://cdn-icons-png.flaticon.com/512/616/616432.png',
        'https://cdn-icons-png.flaticon.com/512/616/616434.png',
        'https://cdn-icons-png.flaticon.com/512/616/616440.png',
      ]
    },
    {
      'name': 'Sadık Dostlar',
      'icon': '🐶',
      'stickers': [
        'https://cdn-icons-png.flaticon.com/512/616/616408.png',
        'https://cdn-icons-png.flaticon.com/512/616/616414.png',
        'https://cdn-icons-png.flaticon.com/512/616/616418.png',
        'https://cdn-icons-png.flaticon.com/512/616/616422.png',
        'https://cdn-icons-png.flaticon.com/512/616/616428.png',
        'https://cdn-icons-png.flaticon.com/512/616/616435.png',
        'https://cdn-icons-png.flaticon.com/512/616/616439.png',
        'https://cdn-icons-png.flaticon.com/512/616/616441.png',
      ]
    },
    {
      'name': '3D İfadeler',
      'icon': '😎',
      'stickers': [
        'https://cdn-icons-png.flaticon.com/512/927/927567.png',
        'https://cdn-icons-png.flaticon.com/512/927/927568.png',
        'https://cdn-icons-png.flaticon.com/512/927/927570.png',
        'https://cdn-icons-png.flaticon.com/512/927/927572.png',
        'https://cdn-icons-png.flaticon.com/512/927/927574.png',
        'https://cdn-icons-png.flaticon.com/512/927/927576.png',
        'https://cdn-icons-png.flaticon.com/512/927/927578.png',
        'https://cdn-icons-png.flaticon.com/512/927/927580.png',
      ]
    },
    {
      'name': 'Aşk & Kalp',
      'icon': '💖',
      'stickers': [
        'https://cdn-icons-png.flaticon.com/512/2107/2107832.png',
        'https://cdn-icons-png.flaticon.com/512/2107/2107834.png',
        'https://cdn-icons-png.flaticon.com/512/2107/2107836.png',
        'https://cdn-icons-png.flaticon.com/512/2107/2107838.png',
        'https://cdn-icons-png.flaticon.com/512/2107/2107840.png',
        'https://cdn-icons-png.flaticon.com/512/2107/2107842.png',
        'https://cdn-icons-png.flaticon.com/512/2107/2107844.png',
        'https://cdn-icons-png.flaticon.com/512/2107/2107846.png',
      ]
    },
    {
      'name': 'Meme & Tepkiler',
      'icon': '🔥',
      'stickers': [
        'https://cdn-icons-png.flaticon.com/512/742/742751.png',
        'https://cdn-icons-png.flaticon.com/512/742/742752.png',
        'https://cdn-icons-png.flaticon.com/512/742/742755.png',
        'https://cdn-icons-png.flaticon.com/512/742/742760.png',
        'https://cdn-icons-png.flaticon.com/512/742/742765.png',
        'https://cdn-icons-png.flaticon.com/512/742/742770.png',
        'https://cdn-icons-png.flaticon.com/512/742/742774.png',
        'https://cdn-icons-png.flaticon.com/512/742/742780.png',
      ]
    },
  ];

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(
          top: BorderSide(color: AppColors.cardBorder, width: 0.8),
        ),
      ),
      child: Column(
        children: [
          // Content Area (Emoji / GIF / Sticker)
          Expanded(
            child: _buildCurrentTabView(),
          ),

          // Bottom WhatsApp-style Navigation Switcher Bar
          _buildBottomTabBar(),
        ],
      ),
    );
  }

  // --- TAB CONTENT VIEW ---
  Widget _buildCurrentTabView() {
    switch (_currentTab) {
      case PickerTab.emoji:
        return _buildEmojiTab();
      case PickerTab.gif:
        return _buildGifTab();
      case PickerTab.sticker:
        return _buildStickerTab();
    }
  }

  // 1. EMOJI TAB
  Widget _buildEmojiTab() {
    final currentCategory = _emojiCategories[_selectedEmojiCategory];
    final List<String> emojis = List<String>.from(currentCategory['emojis']);

    return Column(
      children: [
        // Category Icons Selector Header
        Container(
          height: 40,
          color: AppColors.surfaceLight.withOpacity(0.4),
          child: Row(
            children: [
              Expanded(
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: _emojiCategories.length,
                  itemBuilder: (context, index) {
                    final isSelected = index == _selectedEmojiCategory;
                    return InkWell(
                      onTap: () {
                        setState(() {
                          _selectedEmojiCategory = index;
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color: isSelected ? AppColors.accent : Colors.transparent,
                              width: 2.5,
                            ),
                          ),
                        ),
                        child: Text(
                          _emojiCategories[index]['icon'] as String,
                          style: TextStyle(
                            fontSize: 18,
                            color: isSelected ? Colors.white : Colors.white60,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              // Backspace Button
              InkWell(
                onTap: widget.onBackspacePressed,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: Icon(Icons.backspace_outlined, color: Colors.white70, size: 20),
                ),
              ),
            ],
          ),
        ),

        // Emoji Grid
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 8,
              mainAxisSpacing: 6,
              crossAxisSpacing: 6,
            ),
            itemCount: emojis.length,
            itemBuilder: (context, index) {
              final emoji = emojis[index];
              return InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => widget.onEmojiSelected(emoji),
                child: Center(
                  child: Text(
                    emoji,
                    style: const TextStyle(fontSize: 24),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // 2. GIF TAB
  Widget _buildGifTab() {
    final currentCat = _gifCategories[_selectedGifCategory];
    List<Map<String, String>> gifs = List<Map<String, String>>.from(currentCat['gifs']);

    if (_searchQuery.trim().isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      final allGifs = _gifCategories.expand((c) => List<Map<String, String>>.from(c['gifs'])).toList();
      gifs = allGifs.where((g) => (g['title'] ?? '').toLowerCase().contains(q)).toList();
    }

    return Column(
      children: [
        // GIF Search Bar & Categories
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
          child: Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: AppColors.surfaceLight,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: AppColors.cardBorder),
            ),
            child: Row(
              children: [
                const Icon(Icons.search_rounded, color: Colors.white54, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: const InputDecoration(
                      hintText: 'GIF Ara...',
                      hintStyle: TextStyle(color: Colors.white38, fontSize: 13),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                    onChanged: (val) {
                      setState(() {
                        _searchQuery = val;
                      });
                    },
                  ),
                ),
                if (_searchQuery.isNotEmpty)
                  GestureDetector(
                    onTap: () {
                      _searchController.clear();
                      setState(() {
                        _searchQuery = '';
                      });
                    },
                    child: const Icon(Icons.close_rounded, color: Colors.white54, size: 16),
                  ),
              ],
            ),
          ),
        ),

        // GIF Category Pills
        SizedBox(
          height: 36,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            itemCount: _gifCategories.length,
            itemBuilder: (context, index) {
              final isSel = index == _selectedGifCategory && _searchQuery.isEmpty;
              return Padding(
                padding: const EdgeInsets.only(right: 6, top: 4, bottom: 4),
                child: ChoiceChip(
                  label: Text(_gifCategories[index]['name'] as String),
                  selected: isSel,
                  selectedColor: AppColors.primary,
                  backgroundColor: AppColors.surfaceLight,
                  labelStyle: TextStyle(
                    color: isSel ? Colors.white : Colors.white70,
                    fontSize: 11.5,
                    fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  onSelected: (val) {
                    setState(() {
                      _selectedGifCategory = index;
                      _searchController.clear();
                      _searchQuery = '';
                    });
                  },
                ),
              );
            },
          ),
        ),

        // GIF Grid
        Expanded(
          child: gifs.isEmpty
              ? const Center(
                  child: Text('Sonuç bulunamadı.', style: TextStyle(color: Colors.white38, fontSize: 13)),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 1.35,
                  ),
                  itemCount: gifs.length,
                  itemBuilder: (context, index) {
                    final item = gifs[index];
                    final gifUrl = item['url']!;
                    return InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => widget.onGifSelected(gifUrl),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            CachedNetworkImage(
                              imageUrl: gifUrl,
                              fit: BoxFit.cover,
                              placeholder: (ctx, url) => Container(
                                color: AppColors.surfaceLight,
                                child: const Center(
                                  child: SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
                                  ),
                                ),
                              ),
                              errorWidget: (ctx, url, err) => Container(
                                color: AppColors.surfaceLight,
                                child: const Icon(Icons.broken_image_rounded, color: Colors.white38),
                              ),
                            ),
                            // Mini GIF pill tag
                            Positioned(
                              bottom: 6,
                              left: 6,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.65),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Text(
                                  'GIF',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // 3. STICKER TAB
  Widget _buildStickerTab() {
    final currentPack = _stickerPacks[_selectedStickerPack];
    final List<String> stickers = List<String>.from(currentPack['stickers']);

    return Column(
      children: [
        // Sticker Pack Header Tabs
        Container(
          height: 42,
          color: AppColors.surfaceLight.withOpacity(0.4),
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: _stickerPacks.length,
            itemBuilder: (context, index) {
              final isSel = index == _selectedStickerPack;
              return InkWell(
                onTap: () {
                  setState(() {
                    _selectedStickerPack = index;
                  });
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: isSel ? AppColors.accent : Colors.transparent,
                        width: 2.5,
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      Text(
                        _stickerPacks[index]['icon'] as String,
                        style: const TextStyle(fontSize: 16),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _stickerPacks[index]['name'] as String,
                        style: TextStyle(
                          color: isSel ? Colors.white : Colors.white60,
                          fontSize: 12,
                          fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),

        // Sticker Grid
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
            ),
            itemCount: stickers.length,
            itemBuilder: (context, index) {
              final stickerUrl = stickers[index];
              return InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => widget.onStickerSelected(stickerUrl),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: CachedNetworkImage(
                    imageUrl: stickerUrl,
                    fit: BoxFit.contain,
                    placeholder: (ctx, url) => Container(
                      alignment: Alignment.center,
                      child: const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent),
                      ),
                    ),
                    errorWidget: (ctx, url, err) => const Icon(
                      Icons.broken_image_rounded,
                      color: Colors.white24,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // --- BOTTOM WHATSAPP-STYLE TAB SWITCHER ---
  Widget _buildBottomTabBar() {
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final viewBottomPadding = MediaQuery.of(context).viewPadding.bottom;
    final bottomInset = bottomPadding > viewBottomPadding ? bottomPadding : viewBottomPadding;

    return Container(
      padding: EdgeInsets.only(bottom: bottomInset),
      decoration: const BoxDecoration(
        color: AppColors.surfaceLight,
        border: Border(
          top: BorderSide(color: AppColors.cardBorder, width: 0.8),
        ),
      ),
      child: SizedBox(
        height: 48,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _buildBottomTabButton(
              tab: PickerTab.emoji,
              icon: Icons.sentiment_satisfied_alt_rounded,
              label: 'EMOJİ',
            ),
            _buildBottomTabButton(
              tab: PickerTab.gif,
              icon: Icons.gif_box_rounded,
              label: 'GIF',
            ),
            _buildBottomTabButton(
              tab: PickerTab.sticker,
              icon: Icons.sticky_note_2_rounded,
              label: 'ÇIKARTMA',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomTabButton({
    required PickerTab tab,
    required IconData icon,
    required String label,
  }) {
    final isSelected = _currentTab == tab;
    return InkWell(
      onTap: () {
        setState(() {
          _currentTab = tab;
        });
      },
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 20,
              color: isSelected ? AppColors.accent : Colors.white54,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? AppColors.accent : Colors.white54,
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                letterSpacing: 0.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
