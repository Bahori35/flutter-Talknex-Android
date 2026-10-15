import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../../constants/app_colors.dart';

/// The result returned when photo editing is completed
class PhotoEditorResult {
  final File file;
  final String caption;

  PhotoEditorResult({
    required this.file,
    required this.caption,
  });
}

enum OverlayType { text, emoji, location }

class OverlayItem {
  final String id;
  final OverlayType type;
  String text;
  Color color;
  Color backgroundColor;
  Offset position;
  double fontSize;

  OverlayItem({
    required this.id,
    required this.type,
    required this.text,
    this.color = Colors.white,
    this.backgroundColor = Colors.black54,
    required this.position,
    this.fontSize = 22.0,
  });
}

class FilterOption {
  final String name;
  final List<double>? matrix;

  const FilterOption(this.name, this.matrix);
}

class PhotoEditorScreen extends StatefulWidget {
  final File imageFile;

  const PhotoEditorScreen({
    super.key,
    required this.imageFile,
  });

  @override
  State<PhotoEditorScreen> createState() => _PhotoEditorScreenState();
}

class _PhotoEditorScreenState extends State<PhotoEditorScreen> {
  final GlobalKey _repaintKey = GlobalKey();
  final TextEditingController _captionController = TextEditingController();

  final List<FilterOption> _filters = const [
    FilterOption('Orijinal', null),
    FilterOption('Canlı', [
      1.25, 0,    0,    0, 0,
      0,    1.25, 0,    0, 0,
      0,    0,    1.25, 0, 0,
      0,    0,    0,    1, 0,
    ]),
    FilterOption('Sıcak', [
      1.18, 0,    0,    0, 10,
      0,    1.08, 0,    0, 5,
      0,    0,    0.85, 0, -10,
      0,    0,    0,    1, 0,
    ]),
    FilterOption('Soğuk', [
      0.85, 0,    0,    0, -10,
      0,    1.0,  0,    0, 0,
      0,    0,    1.25, 0, 15,
      0,    0,    0,    1, 0,
    ]),
    FilterOption('S&B', [
      0.2126, 0.7152, 0.0722, 0, 0,
      0.2126, 0.7152, 0.0722, 0, 0,
      0.2126, 0.7152, 0.0722, 0, 0,
      0,      0,      0,      1, 0,
    ]),
    FilterOption('Sepia', [
      0.393, 0.769, 0.189, 0, 0,
      0.349, 0.686, 0.168, 0, 0,
      0.272, 0.534, 0.131, 0, 0,
      0,     0,     0,     1, 0,
    ]),
    FilterOption('Dramatik', [
      1.4, 0,   0,   0, -25,
      0,   1.4, 0,   0, -25,
      0,   0,   1.4, 0, -25,
      0,   0,   0,   1, 0,
    ]),
    FilterOption('Sinematik', [
      1.12, 0,   0,    0, 8,
      0,    1.0, 0,    0, 0,
      0,    0,   1.20, 0, 12,
      0,    0,   0,    1, 0,
    ]),
    FilterOption('Nostalji', [
      0.9, 0,   0,   0, 35,
      0,   0.9, 0,   0, 35,
      0,   0,   0.9, 0, 35,
      0,   0,   0,   1, 0,
    ]),
  ];

  int _selectedFilterIndex = 0;
  int _rotationQuarter = 0; // 0, 1, 2, 3 (each * 90 degrees)
  bool _isFlipped = false;
  double? _targetAspectRatio; // null = free/original, 1.0 = 1:1, 4/3, 16/9

  final List<OverlayItem> _overlays = [];
  String? _selectedOverlayId;

  bool _isExporting = false;
  bool _showFilterTray = false;
  bool _showCropTray = false;

  @override
  void dispose() {
    _captionController.dispose();
    super.dispose();
  }

  // --- ACTIONS ---

  void _rotateImage() {
    setState(() {
      _rotationQuarter = (_rotationQuarter + 1) % 4;
    });
  }

  void _flipImage() {
    setState(() {
      _isFlipped = !_isFlipped;
    });
  }

  void _undoLastOverlay() {
    if (_overlays.isNotEmpty) {
      setState(() {
        _overlays.removeLast();
        _selectedOverlayId = null;
      });
    }
  }

  // Add / Edit Text Overlay
  void _openTextDialog({OverlayItem? existing}) {
    final textCtrl = TextEditingController(text: existing?.text ?? '');
    Color selectedColor = existing?.color ?? Colors.white;
    Color selectedBg = existing?.backgroundColor ?? Colors.black54;

    final colors = [
      Colors.white,
      Colors.black,
      const Color(0xFF00E676), // WhatsApp Green
      const Color(0xFF00B0FF), // Blue
      const Color(0xFFFFD600), // Yellow
      const Color(0xFFFF5252), // Red
      const Color(0xFFFF4081), // Pink
      const Color(0xFFE040FB), // Purple
      const Color(0xFFFF9100), // Orange
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Container(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
                top: 20,
                left: 16,
                right: 16,
              ),
              decoration: const BoxDecoration(
                color: Color(0xFF1F2C34),
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        existing != null ? 'Yazıyı Düzenle' : 'Yazı Ekle',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      IconButton(
                        icon: const Icon(Icons.check_circle_rounded, color: AppColors.accent, size: 28),
                        onPressed: () {
                          final text = textCtrl.text.trim();
                          if (text.isNotEmpty) {
                            setState(() {
                              if (existing != null) {
                                existing.text = text;
                                existing.color = selectedColor;
                                existing.backgroundColor = selectedBg;
                              } else {
                                _overlays.add(OverlayItem(
                                  id: DateTime.now().millisecondsSinceEpoch.toString(),
                                  type: OverlayType.text,
                                  text: text,
                                  color: selectedColor,
                                  backgroundColor: selectedBg,
                                  position: const Offset(50, 100),
                                  fontSize: 22.0,
                                ));
                              }
                            });
                          }
                          Navigator.pop(ctx);
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: selectedBg,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: TextField(
                      controller: textCtrl,
                      autofocus: true,
                      style: TextStyle(
                        color: selectedColor,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                      decoration: const InputDecoration(
                        hintText: 'Metin yazın...',
                        hintStyle: TextStyle(color: Colors.white54),
                        border: InputBorder.none,
                      ),
                      maxLines: 3,
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Background toggle
                  Row(
                    children: [
                      const Text('Arka Plan:', style: TextStyle(color: Colors.white70, fontSize: 13)),
                      const SizedBox(width: 12),
                      ActionChip(
                        label: const Text('Şeffaf'),
                        backgroundColor: selectedBg == Colors.transparent ? AppColors.accent : AppColors.surfaceLight,
                        labelStyle: TextStyle(color: selectedBg == Colors.transparent ? Colors.black : Colors.white),
                        onPressed: () => setSheetState(() => selectedBg = Colors.transparent),
                      ),
                      const SizedBox(width: 8),
                      ActionChip(
                        label: const Text('Koyu'),
                        backgroundColor: selectedBg == Colors.black54 ? AppColors.accent : AppColors.surfaceLight,
                        labelStyle: TextStyle(color: selectedBg == Colors.black54 ? Colors.black : Colors.white),
                        onPressed: () => setSheetState(() => selectedBg = Colors.black54),
                      ),
                      const SizedBox(width: 8),
                      ActionChip(
                        label: const Text('Açık'),
                        backgroundColor: selectedBg == Colors.white70 ? AppColors.accent : AppColors.surfaceLight,
                        labelStyle: TextStyle(color: selectedBg == Colors.white70 ? Colors.black : Colors.white),
                        onPressed: () => setSheetState(() => selectedBg = Colors.white70),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  // Color choices
                  SizedBox(
                    height: 38,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: colors.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 10),
                      itemBuilder: (context, idx) {
                        final c = colors[idx];
                        final isSel = selectedColor == c;
                        return GestureDetector(
                          onTap: () => setSheetState(() => selectedColor = c),
                          child: Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              color: c,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: isSel ? Colors.white : Colors.white24,
                                width: isSel ? 2.5 : 1,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // Add Emoji / Sticker
  void _openEmojiSheet() {
    final emojiCategories = {
      'İfadeler': ['😍', '😂', '🔥', '❤️', '😎', '🥳', '🤩', '👏', '🙌', '💯', '✨', '🥰', '😭', '🤯', '🤫', '👀'],
      'Kutlama': ['🎉', '🎂', '🍾', '🎈', '🎁', '🏆', '🥇', '👑', '⭐', '🌟', '💥', '🍹', '🍕', '🍔', '🍦', '🍩'],
      'Doğa': ['🌸', '☀️', '🌴', '☕', '🐱', '🐶', '🦁', '🍀', '🌈', '⚡', '🌙', '🌊', '🍁', '🍓', '🥑', '🏖️'],
      'Semboller': ['📍', '🚀', '💬', '📢', '💡', '🎵', '🚗', '✈️', '🎮', '⚽', '💎', '🎯', '🔔', '🏷️', '✅', '❤️‍🔥'],
    };

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1F2C34),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return DefaultTabController(
          length: emojiCategories.length,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
              ),
              TabBar(
                isScrollable: true,
                indicatorColor: AppColors.accent,
                labelColor: AppColors.accent,
                unselectedLabelColor: Colors.white60,
                tabs: emojiCategories.keys.map((title) => Tab(text: title)).toList(),
              ),
              SizedBox(
                height: 250,
                child: TabBarView(
                  children: emojiCategories.values.map((emojis) {
                    return GridView.builder(
                      padding: const EdgeInsets.all(16),
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 6,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                      ),
                      itemCount: emojis.length,
                      itemBuilder: (context, idx) {
                        final emoji = emojis[idx];
                        return GestureDetector(
                          onTap: () {
                            Navigator.pop(ctx);
                            setState(() {
                              _overlays.add(OverlayItem(
                                id: DateTime.now().millisecondsSinceEpoch.toString(),
                                type: OverlayType.emoji,
                                text: emoji,
                                position: const Offset(120, 150),
                                fontSize: 48.0,
                              ));
                            });
                          },
                          child: Center(
                            child: Text(emoji, style: const TextStyle(fontSize: 32)),
                          ),
                        );
                      },
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // Add Location Badge
  Future<void> _openLocationDialog() async {
    final locCtrl = TextEditingController();
    bool isFetching = false;

    await showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDlgState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1F2C34),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Row(
                children: [
                  Icon(Icons.location_on_rounded, color: AppColors.callRed),
                  SizedBox(width: 8),
                  Text('Konum Çıkartması', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: locCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'Örn: Kadıköy, İstanbul',
                      hintStyle: const TextStyle(color: Colors.white38),
                      filled: true,
                      fillColor: Colors.black26,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                      prefixIcon: const Icon(Icons.place, color: AppColors.accent),
                    ),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.surfaceLight,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: isFetching
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.my_location, color: AppColors.primaryLight, size: 18),
                    label: const Text('Mevcut Konumumu Kullan'),
                    onPressed: isFetching
                        ? null
                        : () async {
                            setDlgState(() => isFetching = true);
                            try {
                              bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
                              if (!serviceEnabled) {
                                setDlgState(() => isFetching = false);
                                return;
                              }
                              LocationPermission permission = await Geolocator.checkPermission();
                              if (permission == LocationPermission.denied) {
                                permission = await Geolocator.requestPermission();
                              }
                              if (permission == LocationPermission.whileInUse || permission == LocationPermission.always) {
                                final pos = await Geolocator.getCurrentPosition(
                                  desiredAccuracy: LocationAccuracy.medium,
                                  timeLimit: const Duration(seconds: 5),
                                );
                                locCtrl.text = '📍 Konum: (${pos.latitude.toStringAsFixed(3)}, ${pos.longitude.toStringAsFixed(3)})';
                              }
                            } catch (_) {
                              locCtrl.text = '📍 Mevcut Konumum';
                            }
                            setDlgState(() => isFetching = false);
                          },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('İptal', style: TextStyle(color: Colors.white60)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: Colors.black,
                  ),
                  onPressed: () {
                    final text = locCtrl.text.trim();
                    if (text.isNotEmpty) {
                      setState(() {
                        _overlays.add(OverlayItem(
                          id: DateTime.now().millisecondsSinceEpoch.toString(),
                          type: OverlayType.location,
                          text: text.startsWith('📍') ? text : '📍 $text',
                          position: const Offset(60, 200),
                          fontSize: 16.0,
                        ));
                      });
                    }
                    Navigator.pop(ctx);
                  },
                  child: const Text('Ekle', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // Export final edited photo
  Future<void> _exportAndSend() async {
    if (_isExporting) return;
    setState(() => _isExporting = true);

    try {
      // Unselect any selected overlay to hide bounding boxes during render
      setState(() => _selectedOverlayId = null);
      await Future.delayed(const Duration(milliseconds: 60));

      final boundary = _repaintKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) {
        setState(() => _isExporting = false);
        return;
      }

      final image = await boundary.toImage(pixelRatio: 2.2);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        setState(() => _isExporting = false);
        return;
      }

      final bytes = byteData.buffer.asUint8List();
      final tempDir = await getTemporaryDirectory();
      final outPath = p.join(tempDir.path, 'edited_${DateTime.now().millisecondsSinceEpoch}.jpg');
      final exportedFile = File(outPath);
      await exportedFile.writeAsBytes(bytes);

      if (!mounted) return;
      Navigator.pop(
        context,
        PhotoEditorResult(
          file: exportedFile,
          caption: _captionController.text.trim(),
        ),
      );
    } catch (e) {
      debugPrint('[PHOTO EXPORT ERR] $e');
      if (mounted) setState(() => _isExporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedFilter = _filters[_selectedFilterIndex];

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // TOP BAR
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              color: Colors.black.withOpacity(0.5),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: Colors.white, size: 26),
                    onPressed: () => Navigator.pop(context),
                  ),
                  const Spacer(),
                  // Crop & Rotate
                  IconButton(
                    icon: Icon(
                      Icons.crop_rotate_rounded,
                      color: _showCropTray ? AppColors.accent : Colors.white,
                      size: 24,
                    ),
                    tooltip: 'Döndür & Kırp',
                    onPressed: () {
                      setState(() {
                        _showCropTray = !_showCropTray;
                        if (_showCropTray) _showFilterTray = false;
                      });
                    },
                  ),
                  // Emoji
                  IconButton(
                    icon: const Icon(Icons.sentiment_satisfied_alt_rounded, color: Colors.white, size: 24),
                    tooltip: 'Emoji / Çıkartma Ekle',
                    onPressed: _openEmojiSheet,
                  ),
                  // Text
                  IconButton(
                    icon: const Icon(Icons.title_rounded, color: Colors.white, size: 24),
                    tooltip: 'Yazı Ekle',
                    onPressed: () => _openTextDialog(),
                  ),
                  // Location
                  IconButton(
                    icon: const Icon(Icons.location_on_rounded, color: Colors.white, size: 24),
                    tooltip: 'Konum Ekle',
                    onPressed: _openLocationDialog,
                  ),
                  // Filters Toggle
                  IconButton(
                    icon: Icon(
                      Icons.auto_awesome_rounded,
                      color: _showFilterTray ? AppColors.accent : Colors.white,
                      size: 24,
                    ),
                    tooltip: 'Filtreler',
                    onPressed: () {
                      setState(() {
                        _showFilterTray = !_showFilterTray;
                        if (_showFilterTray) _showCropTray = false;
                      });
                    },
                  ),
                  // Undo Overlay
                  if (_overlays.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.undo_rounded, color: Colors.white, size: 24),
                      tooltip: 'Geri Al',
                      onPressed: _undoLastOverlay,
                    ),
                ],
              ),
            ),

            // CROP & ROTATE TRAY (if open)
            if (_showCropTray)
              Container(
                color: const Color(0xFF1A2228),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    TextButton.icon(
                      style: TextButton.styleFrom(foregroundColor: Colors.white),
                      icon: const Icon(Icons.rotate_right_rounded, color: AppColors.accent),
                      label: const Text('90° Döndür'),
                      onPressed: _rotateImage,
                    ),
                    TextButton.icon(
                      style: TextButton.styleFrom(foregroundColor: Colors.white),
                      icon: const Icon(Icons.flip_rounded, color: AppColors.accent),
                      label: const Text('Aynala'),
                      onPressed: _flipImage,
                    ),
                    PopupMenuButton<double?>(
                      tooltip: 'En/Boy Oranı',
                      icon: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.aspect_ratio_rounded, color: AppColors.accent, size: 18),
                          SizedBox(width: 4),
                          Text('Oran', style: TextStyle(color: Colors.white, fontSize: 13)),
                        ],
                      ),
                      color: const Color(0xFF263238),
                      onSelected: (val) => setState(() => _targetAspectRatio = val),
                      itemBuilder: (ctx) => [
                        const PopupMenuItem(value: null, child: Text('Orijinal / Serbest', style: TextStyle(color: Colors.white))),
                        const PopupMenuItem(value: 1.0, child: Text('1:1 Kare', style: TextStyle(color: Colors.white))),
                        const PopupMenuItem(value: 4 / 3, child: Text('4:3 Standart', style: TextStyle(color: Colors.white))),
                        const PopupMenuItem(value: 16 / 9, child: Text('16:9 Geniş', style: TextStyle(color: Colors.white))),
                      ],
                    ),
                  ],
                ),
              ),

            // CENTER CANVAS (Image + Filter + Rotation + Overlays)
            Expanded(
              child: Center(
                child: FittedBox(
                  fit: BoxFit.contain,
                  child: RepaintBoundary(
                    key: _repaintKey,
                    child: Container(
                      color: Colors.black,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          // Base Image with Rotation, Flip and Filter
                          ClipRect(
                            child: Transform(
                              alignment: Alignment.center,
                              transform: Matrix4.identity()
                                ..rotateZ(_rotationQuarter * (math.pi / 2))
                                ..scale(_isFlipped ? -1.0 : 1.0, 1.0),
                              child: _targetAspectRatio != null
                                  ? AspectRatio(
                                      aspectRatio: _targetAspectRatio!,
                                      child: _buildFilteredImage(selectedFilter),
                                    )
                                  : _buildFilteredImage(selectedFilter),
                            ),
                          ),

                          // Overlays (Draggable text, emojis, location)
                          ..._overlays.map((item) => _buildOverlayWidget(item)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // FILTER CAROUSEL (if open)
            if (_showFilterTray)
              Container(
                height: 96,
                color: const Color(0xFF141D22),
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  itemCount: _filters.length,
                  itemBuilder: (context, idx) {
                    final f = _filters[idx];
                    final isSel = idx == _selectedFilterIndex;
                    return GestureDetector(
                      onTap: () => setState(() => _selectedFilterIndex = idx),
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 6),
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: isSel ? AppColors.accent.withOpacity(0.2) : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: isSel ? AppColors.accent : Colors.transparent,
                            width: 2,
                          ),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: SizedBox(
                                width: 50,
                                height: 50,
                                child: f.matrix != null
                                    ? ColorFiltered(
                                        colorFilter: ColorFilter.matrix(f.matrix!),
                                        child: Image.file(widget.imageFile, fit: BoxFit.cover),
                                      )
                                    : Image.file(widget.imageFile, fit: BoxFit.cover),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              f.name,
                              style: TextStyle(
                                color: isSel ? AppColors.accent : Colors.white70,
                                fontSize: 11,
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

            // BOTTOM BAR (WhatsApp style caption input & send button)
            Container(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
              color: Colors.black.withOpacity(0.7),
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1F2C34),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.edit_note_rounded, color: AppColors.accent, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _captionController,
                              style: const TextStyle(color: Colors.white, fontSize: 14),
                              decoration: const InputDecoration(
                                hintText: 'Bir başlık ekleyin...',
                                hintStyle: TextStyle(color: Colors.white54, fontSize: 14),
                                border: InputBorder.none,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  // Send / Done FAB
                  GestureDetector(
                    onTap: _isExporting ? null : _exportAndSend,
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: const BoxDecoration(
                        gradient: AppColors.primaryGradient,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.accent,
                            blurRadius: 8,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Center(
                        child: _isExporting
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.send_rounded, color: Colors.white, size: 22),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilteredImage(FilterOption filter) {
    final imageWidget = Image.file(
      widget.imageFile,
      fit: BoxFit.contain,
    );

    if (filter.matrix != null) {
      return ColorFiltered(
        colorFilter: ColorFilter.matrix(filter.matrix!),
        child: imageWidget,
      );
    }
    return imageWidget;
  }

  Widget _buildOverlayWidget(OverlayItem item) {
    final isSelected = _selectedOverlayId == item.id;

    Widget content;
    if (item.type == OverlayType.emoji) {
      content = Text(
        item.text,
        style: TextStyle(fontSize: item.fontSize),
      );
    } else if (item.type == OverlayType.location) {
      content = Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Colors.black.withOpacity(0.75), const Color(0xFF1F2C34).withOpacity(0.85)],
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.callRed.withOpacity(0.8), width: 1.5),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 6, offset: const Offset(0, 2)),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.location_on_rounded, color: AppColors.callRed, size: 18),
            const SizedBox(width: 4),
            Text(
              item.text.replaceAll('📍', '').trim(),
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: item.fontSize,
              ),
            ),
          ],
        ),
      );
    } else {
      // Text Overlay
      content = Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: item.backgroundColor,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          item.text,
          style: TextStyle(
            color: item.color,
            fontSize: item.fontSize,
            fontWeight: FontWeight.bold,
          ),
        ),
      );
    }

    return Positioned(
      left: item.position.dx,
      top: item.position.dy,
      child: GestureDetector(
        onPanUpdate: (details) {
          setState(() {
            item.position += details.delta;
            _selectedOverlayId = item.id;
          });
        },
        onTap: () {
          setState(() {
            _selectedOverlayId = (_selectedOverlayId == item.id) ? null : item.id;
          });
          if (item.type == OverlayType.text) {
            _openTextDialog(existing: item);
          }
        },
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              decoration: isSelected
                  ? BoxDecoration(
                      border: Border.all(color: AppColors.accent, width: 1.5),
                      borderRadius: BorderRadius.circular(8),
                    )
                  : null,
              child: content,
            ),
            if (isSelected)
              Positioned(
                top: -10,
                right: -10,
                child: GestureDetector(
                  onTap: () {
                    setState(() {
                      _overlays.removeWhere((o) => o.id == item.id);
                      _selectedOverlayId = null;
                    });
                  },
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: const BoxDecoration(
                      color: AppColors.callRed,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.close, color: Colors.white, size: 14),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
