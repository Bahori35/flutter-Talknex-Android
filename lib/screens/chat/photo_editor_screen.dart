import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../../constants/app_colors.dart';
import 'location_picker_screen.dart';

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
  double scale;
  double rotation;

  OverlayItem({
    required this.id,
    required this.type,
    required this.text,
    this.color = Colors.white,
    this.backgroundColor = Colors.black54,
    required this.position,
    this.fontSize = 22.0,
    this.scale = 1.0,
    this.rotation = 0.0,
  });
}

class FilterOption {
  final String name;
  final List<double>? matrix;

  const FilterOption(this.name, this.matrix);
}

enum _CropHandle { none, center, topLeft, topRight, bottomLeft, bottomRight }

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

  late File _currentImageFile;
  ui.Image? _loadedUiImage;

  // Crop mode state
  bool _isCropMode = false;
  bool _isCropping = false;
  Rect _cropRectNorm = const Rect.fromLTWH(0, 0, 1, 1);
  int _cropRotationQuarter = 0;
  bool _cropIsFlipped = false;
  double? _selectedAspectPreset; // null = free, 1.0 = 1:1, 4/3, 16/9, 3/4, 9/16
  _CropHandle _activeCropHandle = _CropHandle.none;

  // Filters
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
  bool _showFilterTray = false;

  // Overlays
  final List<OverlayItem> _overlays = [];
  String? _selectedOverlayId;
  double _activeOverlayBaseScale = 1.0;
  double _activeOverlayBaseRotation = 0.0;

  bool _isExporting = false;

  @override
  void initState() {
    super.initState();
    _currentImageFile = widget.imageFile;
    _loadUiImage();
  }

  Future<void> _loadUiImage() async {
    try {
      final bytes = await _currentImageFile.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      if (mounted) {
        setState(() {
          _loadedUiImage = frame.image;
        });
      }
    } catch (e) {
      debugPrint('[LOAD UI IMAGE ERR] $e');
    }
  }

  @override
  void dispose() {
    _captionController.dispose();
    super.dispose();
  }

  OverlayItem? get _selectedOverlay {
    if (_selectedOverlayId == null) return null;
    try {
      return _overlays.firstWhere((o) => o.id == _selectedOverlayId);
    } catch (_) {
      return null;
    }
  }

  // --- CROP & ROTATE LOGIC ---

  void _enterCropMode() {
    setState(() {
      _isCropMode = true;
      _showFilterTray = false;
      _selectedOverlayId = null;
      _cropRectNorm = const Rect.fromLTWH(0, 0, 1, 1);
      _cropRotationQuarter = 0;
      _cropIsFlipped = false;
      _selectedAspectPreset = null;
    });
  }

  void _rotateCrop() {
    setState(() {
      _cropRotationQuarter = (_cropRotationQuarter + 1) % 4;
      _cropRectNorm = const Rect.fromLTWH(0, 0, 1, 1);
      _selectedAspectPreset = null;
    });
  }

  void _flipCrop() {
    setState(() {
      _cropIsFlipped = !_cropIsFlipped;
    });
  }

  void _resetCrop() {
    setState(() {
      _cropRectNorm = const Rect.fromLTWH(0, 0, 1, 1);
      _cropRotationQuarter = 0;
      _cropIsFlipped = false;
      _selectedAspectPreset = null;
    });
  }

  void _setAspectPreset(double? targetAspect) {
    setState(() {
      _selectedAspectPreset = targetAspect;
      if (targetAspect == null) {
        _cropRectNorm = const Rect.fromLTWH(0, 0, 1, 1);
        return;
      }

      final bool isRotated = (_cropRotationQuarter % 2 != 0);
      final double origW = _loadedUiImage?.width.toDouble() ?? 1000;
      final double origH = _loadedUiImage?.height.toDouble() ?? 1000;
      final double curW = isRotated ? origH : origW;
      final double curH = isRotated ? origW : origH;
      final double curAspect = curW / curH;

      double normW, normH;
      if (curAspect > targetAspect) {
        normH = 1.0;
        normW = (targetAspect / curAspect).clamp(0.1, 1.0);
      } else {
        normW = 1.0;
        normH = (curAspect / targetAspect).clamp(0.1, 1.0);
      }

      final double normLeft = ((1.0 - normW) / 2.0).clamp(0.0, 1.0);
      final double normTop = ((1.0 - normH) / 2.0).clamp(0.0, 1.0);
      _cropRectNorm = Rect.fromLTWH(normLeft, normTop, normW, normH);
    });
  }

  Future<void> _applyCrop() async {
    if (_isCropping) return;
    setState(() => _isCropping = true);

    try {
      final cropped = await _executeCrop(
        inputFile: _currentImageFile,
        cropRectNorm: _cropRectNorm,
        rotationQuarter: _cropRotationQuarter,
        isFlipped: _cropIsFlipped,
      );

      _currentImageFile = cropped;
      await _loadUiImage();

      if (mounted) {
        setState(() {
          _isCropMode = false;
          _cropRotationQuarter = 0;
          _cropIsFlipped = false;
          _cropRectNorm = const Rect.fromLTWH(0, 0, 1, 1);
          _selectedAspectPreset = null;
        });
      }
    } catch (e) {
      debugPrint('[CROP EXECUTE ERR] $e');
    } finally {
      if (mounted) setState(() => _isCropping = false);
    }
  }

  Future<File> _executeCrop({
    required File inputFile,
    required Rect cropRectNorm,
    required int rotationQuarter,
    required bool isFlipped,
  }) async {
    final bytes = await inputFile.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final ui.Image srcImage = frame.image;

    final double origW = srcImage.width.toDouble();
    final double origH = srcImage.height.toDouble();

    // Source rect in image pixel space
    final double sx = (cropRectNorm.left * origW).clamp(0.0, origW - 1);
    final double sy = (cropRectNorm.top * origH).clamp(0.0, origH - 1);
    final double sw = (cropRectNorm.width * origW).clamp(1.0, origW - sx);
    final double sh = (cropRectNorm.height * origH).clamp(1.0, origH - sy);

    final bool isRotated = (rotationQuarter % 2 != 0);
    final int outW = (isRotated ? sh : sw).round();
    final int outH = (isRotated ? sw : sh).round();

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    canvas.save();
    canvas.translate(outW / 2.0, outH / 2.0);
    if (rotationQuarter != 0) {
      canvas.rotate(rotationQuarter * (math.pi / 2));
    }
    if (isFlipped) {
      canvas.scale(-1.0, 1.0);
    }
    canvas.translate(-sw / 2.0, -sh / 2.0);

    canvas.drawImageRect(
      srcImage,
      Rect.fromLTWH(sx, sy, sw, sh),
      Rect.fromLTWH(0, 0, sw, sh),
      Paint()..filterQuality = FilterQuality.high,
    );
    canvas.restore();

    final croppedUiImage = await recorder.endRecording().toImage(outW, outH);
    final byteData = await croppedUiImage.toByteData(format: ui.ImageByteFormat.png);
    final tempDir = await getTemporaryDirectory();
    final outPath = p.join(tempDir.path, 'crop_${DateTime.now().millisecondsSinceEpoch}.png');
    final croppedFile = File(outPath);
    await croppedFile.writeAsBytes(byteData!.buffer.asUint8List());

    return croppedFile;
  }

  // --- OVERLAYS (TEXT, EMOJI, LOCATION) ---

  void _undoLastOverlay() {
    if (_overlays.isNotEmpty) {
      setState(() {
        _overlays.removeLast();
        _selectedOverlayId = null;
      });
    }
  }

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
                                final newItem = OverlayItem(
                                  id: DateTime.now().millisecondsSinceEpoch.toString(),
                                  type: OverlayType.text,
                                  text: text,
                                  color: selectedColor,
                                  backgroundColor: selectedBg,
                                  position: const Offset(60, 120),
                                  fontSize: 22.0,
                                );
                                _overlays.add(newItem);
                                _selectedOverlayId = newItem.id;
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
                              final newItem = OverlayItem(
                                id: DateTime.now().millisecondsSinceEpoch.toString(),
                                type: OverlayType.emoji,
                                text: emoji,
                                position: const Offset(120, 160),
                                fontSize: 48.0,
                              );
                              _overlays.add(newItem);
                              _selectedOverlayId = newItem.id;
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

  Future<void> _openLocationDialog() async {
    final locCtrl = TextEditingController();

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Container(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
                top: 16,
                left: 16,
                right: 16,
              ),
              decoration: const BoxDecoration(
                color: Color(0xFF1F2C34),
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Drag indicator
                  Center(
                    child: Container(
                      width: 38,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Title row
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: AppColors.callRed.withOpacity(0.15),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.location_on_rounded, color: AppColors.callRed, size: 22),
                      ),
                      const SizedBox(width: 10),
                      const Text(
                        'Konum Çıkartması Ekle',
                        style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.close_rounded, color: Colors.white60, size: 22),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // Button: MAP PICKER ("Haritada İşaretle / Seç")
                  InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () async {
                      final LocationPickerResult? picked = await Navigator.push<LocationPickerResult>(
                        ctx,
                        MaterialPageRoute(builder: (_) => const LocationPickerScreen()),
                      );
                      if (picked != null) {
                        String name = picked.address;
                        if (name.isEmpty || name.startsWith('Enlem:')) {
                          name = picked.title;
                        }
                        if (name.isEmpty || name == 'İşaretlenen Nokta' || name.startsWith('Enlem:')) {
                          name = 'Seçilen Konum';
                        }
                        setSheetState(() {
                          locCtrl.text = name;
                        });
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF00A884), Color(0xFF008069)],
                        ),
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF00A884).withOpacity(0.35),
                            blurRadius: 8,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.map_rounded, color: Colors.white, size: 24),
                          SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Haritadan Konum İşaretle',
                                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14.5),
                                ),
                                SizedBox(height: 2),
                                Text(
                                  'Harita üzerinde istediğiniz yeri seçin',
                                  style: TextStyle(color: Colors.white70, fontSize: 11.5),
                                ),
                              ],
                            ),
                          ),
                          Icon(Icons.chevron_right_rounded, color: Colors.white70, size: 22),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 14),

                  // Divider
                  Row(
                    children: [
                      const Expanded(child: Divider(color: Colors.white12)),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Text(
                          'veya konumu yazın',
                          style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 12),
                        ),
                      ),
                      const Expanded(child: Divider(color: Colors.white12)),
                    ],
                  ),

                  const SizedBox(height: 12),

                  // Text input for place name
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.black26,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: TextField(
                      controller: locCtrl,
                      style: const TextStyle(color: Colors.white, fontSize: 15),
                      decoration: InputDecoration(
                        hintText: 'Örn: Kadıköy, İstanbul veya Kordon...',
                        hintStyle: const TextStyle(color: Colors.white38, fontSize: 13.5),
                        border: InputBorder.none,
                        prefixIcon: const Icon(Icons.edit_location_alt_rounded, color: AppColors.accent, size: 20),
                        suffixIcon: locCtrl.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear_rounded, color: Colors.white54, size: 18),
                                onPressed: () => setSheetState(() => locCtrl.clear()),
                              )
                            : null,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      ),
                      onChanged: (_) => setSheetState(() {}),
                    ),
                  ),

                  const SizedBox(height: 10),

                  // Quick suggestions
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      'Kadıköy',
                      'Beşiktaş',
                      'Taksim',
                      'İzmir Kordon',
                      'Ankara Kızılay',
                      'Antalya Kaleiçi',
                      'Bodrum',
                    ].map((place) {
                      return ActionChip(
                        label: Text(place),
                        backgroundColor: const Color(0xFF263238),
                        labelStyle: const TextStyle(color: Colors.white70, fontSize: 11.5),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        side: BorderSide.none,
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                        onPressed: () {
                          setSheetState(() {
                            locCtrl.text = place;
                          });
                        },
                      );
                    }).toList(),
                  ),

                  const SizedBox(height: 16),

                  // Add Badge Button
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    onPressed: () {
                      final text = locCtrl.text.trim();
                      if (text.isNotEmpty) {
                        setState(() {
                          final newItem = OverlayItem(
                            id: DateTime.now().millisecondsSinceEpoch.toString(),
                            type: OverlayType.location,
                            text: text.startsWith('📍') ? text : '📍 $text',
                            position: const Offset(60, 200),
                            fontSize: 16.0,
                          );
                          _overlays.add(newItem);
                          _selectedOverlayId = newItem.id;
                        });
                        Navigator.pop(ctx);
                      }
                    },
                    child: const Text('Konum Rozetini Ekle', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // --- EXPORT FINAL EDITED PHOTO ---

  Future<void> _exportAndSend() async {
    if (_isExporting) return;
    setState(() {
      _isExporting = true;
      _selectedOverlayId = null; // hide bounding boxes
    });

    try {
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

  // --- BUILD METHODS ---

  @override
  Widget build(BuildContext context) {
    if (_isCropMode) {
      return _buildCropModeScreen();
    }
    return _buildMainEditorScreen();
  }

  // --- CROP MODE SCREEN ---
  Widget _buildCropModeScreen() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // Top Bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              color: Colors.black87,
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: Colors.white, size: 26),
                    onPressed: () => setState(() => _isCropMode = false),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'Kırp ve Döndür',
                    style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _resetCrop,
                    child: const Text('Sıfırla', style: TextStyle(color: Colors.white70, fontSize: 14)),
                  ),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                    ),
                    icon: _isCropping
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                        : const Icon(Icons.check_rounded, color: Colors.black, size: 18),
                    label: const Text('Bitti', style: TextStyle(fontWeight: FontWeight.bold)),
                    onPressed: _isCropping ? null : _applyCrop,
                  ),
                ],
              ),
            ),

            // Crop Canvas
            Expanded(
              child: _loadedUiImage == null
                  ? const Center(child: CircularProgressIndicator(color: AppColors.accent))
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        final bool isRotated = (_cropRotationQuarter % 2 != 0);
                        final double origW = _loadedUiImage!.width.toDouble();
                        final double origH = _loadedUiImage!.height.toDouble();
                        final double curW = isRotated ? origH : origW;
                        final double curH = isRotated ? origW : origH;

                        final double maxW = constraints.maxWidth - 24;
                        final double maxH = constraints.maxHeight - 24;
                        final double fitScale = math.min(maxW / curW, maxH / curH);
                        final double displayW = curW * fitScale;
                        final double displayH = curH * fitScale;

                        final double offsetX = (constraints.maxWidth - displayW) / 2;
                        final double offsetY = (constraints.maxHeight - displayH) / 2;
                        final Rect imageRect = Rect.fromLTWH(offsetX, offsetY, displayW, displayH);

                        final Rect screenCropRect = Rect.fromLTWH(
                          offsetX + _cropRectNorm.left * displayW,
                          offsetY + _cropRectNorm.top * displayH,
                          _cropRectNorm.width * displayW,
                          _cropRectNorm.height * displayH,
                        );

                        return GestureDetector(
                          onPanStart: (details) {
                            final pos = details.localPosition;
                            const handleRadius = 26.0;

                            if ((pos - screenCropRect.topLeft).distance <= handleRadius) {
                              _activeCropHandle = _CropHandle.topLeft;
                            } else if ((pos - screenCropRect.topRight).distance <= handleRadius) {
                              _activeCropHandle = _CropHandle.topRight;
                            } else if ((pos - screenCropRect.bottomLeft).distance <= handleRadius) {
                              _activeCropHandle = _CropHandle.bottomLeft;
                            } else if ((pos - screenCropRect.bottomRight).distance <= handleRadius) {
                              _activeCropHandle = _CropHandle.bottomRight;
                            } else if (screenCropRect.contains(pos)) {
                              _activeCropHandle = _CropHandle.center;
                            } else {
                              _activeCropHandle = _CropHandle.none;
                            }
                          },
                          onPanUpdate: (details) {
                            if (_activeCropHandle == _CropHandle.none) return;

                            final dNx = details.delta.dx / displayW;
                            final dNy = details.delta.dy / displayH;

                            setState(() {
                              if (_activeCropHandle == _CropHandle.center) {
                                final newLeft = (_cropRectNorm.left + dNx).clamp(0.0, 1.0 - _cropRectNorm.width);
                                final newTop = (_cropRectNorm.top + dNy).clamp(0.0, 1.0 - _cropRectNorm.height);
                                _cropRectNorm = Rect.fromLTWH(newLeft, newTop, _cropRectNorm.width, _cropRectNorm.height);
                              } else if (_activeCropHandle == _CropHandle.topLeft) {
                                final newLeft = (_cropRectNorm.left + dNx).clamp(0.0, _cropRectNorm.right - 0.1);
                                final newTop = (_cropRectNorm.top + dNy).clamp(0.0, _cropRectNorm.bottom - 0.1);
                                _cropRectNorm = Rect.fromLTWH(newLeft, newTop, _cropRectNorm.right - newLeft, _cropRectNorm.bottom - newTop);
                              } else if (_activeCropHandle == _CropHandle.topRight) {
                                final newRight = (_cropRectNorm.right + dNx).clamp(_cropRectNorm.left + 0.1, 1.0);
                                final newTop = (_cropRectNorm.top + dNy).clamp(0.0, _cropRectNorm.bottom - 0.1);
                                _cropRectNorm = Rect.fromLTWH(_cropRectNorm.left, newTop, newRight - _cropRectNorm.left, _cropRectNorm.bottom - newTop);
                              } else if (_activeCropHandle == _CropHandle.bottomLeft) {
                                final newLeft = (_cropRectNorm.left + dNx).clamp(0.0, _cropRectNorm.right - 0.1);
                                final newBottom = (_cropRectNorm.bottom + dNy).clamp(_cropRectNorm.top + 0.1, 1.0);
                                _cropRectNorm = Rect.fromLTWH(newLeft, _cropRectNorm.top, _cropRectNorm.right - newLeft, newBottom - _cropRectNorm.top);
                              } else if (_activeCropHandle == _CropHandle.bottomRight) {
                                final newRight = (_cropRectNorm.right + dNx).clamp(_cropRectNorm.left + 0.1, 1.0);
                                final newBottom = (_cropRectNorm.bottom + dNy).clamp(_cropRectNorm.top + 0.1, 1.0);
                                _cropRectNorm = Rect.fromLTWH(_cropRectNorm.left, _cropRectNorm.top, newRight - _cropRectNorm.left, newBottom - _cropRectNorm.top);
                              }
                            });
                          },
                          onPanEnd: (_) => _activeCropHandle = _CropHandle.none,
                          child: Stack(
                            children: [
                              // Transformed Preview Image
                              Positioned(
                                left: offsetX,
                                top: offsetY,
                                width: displayW,
                                height: displayH,
                                child: Transform(
                                  alignment: Alignment.center,
                                  transform: Matrix4.identity()
                                    ..rotateZ(_cropRotationQuarter * (math.pi / 2))
                                    ..scale(_cropIsFlipped ? -1.0 : 1.0, 1.0),
                                  child: Image.file(_currentImageFile, fit: BoxFit.fill),
                                ),
                              ),

                              // Crop Overlay (Grid, Dimmed area, Brackets)
                              Positioned.fill(
                                child: CustomPaint(
                                  painter: CropOverlayPainter(
                                    imageRect: imageRect,
                                    cropRect: screenCropRect,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),

            // Bottom Crop Controls
            Container(
              color: const Color(0xFF141D22),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Rotate & Flip buttons
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TextButton.icon(
                        style: TextButton.styleFrom(foregroundColor: Colors.white),
                        icon: const Icon(Icons.rotate_right_rounded, color: AppColors.accent, size: 20),
                        label: const Text('90° Döndür'),
                        onPressed: _rotateCrop,
                      ),
                      const SizedBox(width: 24),
                      TextButton.icon(
                        style: TextButton.styleFrom(foregroundColor: Colors.white),
                        icon: const Icon(Icons.flip_rounded, color: AppColors.accent, size: 20),
                        label: const Text('Aynala'),
                        onPressed: _flipCrop,
                      ),
                    ],
                  ),
                  const Divider(color: Colors.white12, height: 10),
                  // Aspect Ratio Presets
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        _buildAspectChip('Serbest', null),
                        _buildAspectChip('1:1 Kare', 1.0),
                        _buildAspectChip('4:3', 4.0 / 3.0),
                        _buildAspectChip('16:9', 16.0 / 9.0),
                        _buildAspectChip('3:4', 3.0 / 4.0),
                        _buildAspectChip('9:16 Dikey', 9.0 / 16.0),
                      ],
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

  Widget _buildAspectChip(String label, double? ratio) {
    final bool isSel = (_selectedAspectPreset == ratio);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        label: Text(label),
        selected: isSel,
        selectedColor: AppColors.accent,
        backgroundColor: const Color(0xFF1F2C34),
        labelStyle: TextStyle(
          color: isSel ? Colors.black : Colors.white,
          fontSize: 12,
          fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
        ),
        onSelected: (_) => _setAspectPreset(ratio),
      ),
    );
  }

  // --- MAIN EDITOR SCREEN ---
  Widget _buildMainEditorScreen() {
    final selectedFilter = _filters[_selectedFilterIndex];
    final selectedItem = _selectedOverlay;

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
                    icon: const Icon(Icons.crop_rotate_rounded, color: Colors.white, size: 24),
                    tooltip: 'Kırp & Döndür',
                    onPressed: _enterCropMode,
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
                        _selectedOverlayId = null;
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

            // CENTER CANVAS (Image + Filter + Overlays)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () {
                  if (_selectedOverlayId != null) {
                    setState(() => _selectedOverlayId = null);
                  }
                },
                child: Center(
                  child: RepaintBoundary(
                    key: _repaintKey,
                    child: Stack(
                      alignment: Alignment.center,
                      clipBehavior: Clip.none,
                      children: [
                        // The Cropped Filtered Base Image
                        _buildFilteredImage(selectedFilter),

                        // Overlays (Draggable & scalable text, emojis, location)
                        ..._overlays.map((item) => _buildOverlayWidget(item)),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // FLOATING SIZE SLIDER (When an overlay is selected)
            if (selectedItem != null)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF1F2C34).withOpacity(0.95),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppColors.accent.withOpacity(0.5), width: 1.2),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 8, offset: const Offset(0, 3)),
                  ],
                ),
                child: Row(
                  children: [
                    const Icon(Icons.aspect_ratio_rounded, color: AppColors.accent, size: 18),
                    const SizedBox(width: 6),
                    const Text('Boyut:', style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)),
                    IconButton(
                      icon: const Icon(Icons.remove_circle_outline_rounded, color: Colors.white, size: 20),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: () {
                        setState(() {
                          selectedItem.scale = (selectedItem.scale - 0.15).clamp(0.4, 4.0);
                        });
                      },
                    ),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          thumbColor: AppColors.accent,
                          activeTrackColor: AppColors.accent,
                          inactiveTrackColor: Colors.white24,
                          trackHeight: 3,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                        ),
                        child: Slider(
                          value: selectedItem.scale,
                          min: 0.4,
                          max: 3.5,
                          onChanged: (val) {
                            setState(() {
                              selectedItem.scale = val;
                            });
                          },
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.add_circle_outline_rounded, color: Colors.white, size: 20),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: () {
                        setState(() {
                          selectedItem.scale = (selectedItem.scale + 0.15).clamp(0.4, 4.0);
                        });
                      },
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${(selectedItem.scale * 100).round()}%',
                      style: const TextStyle(color: AppColors.accent, fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => setState(() => _selectedOverlayId = null),
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: const BoxDecoration(
                          color: AppColors.surfaceLight,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.check, color: Colors.white, size: 16),
                      ),
                    ),
                  ],
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
                                        child: Image.file(_currentImageFile, fit: BoxFit.cover),
                                      )
                                    : Image.file(_currentImageFile, fit: BoxFit.cover),
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
      _currentImageFile,
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

    // Apply scale and rotation
    final transformedContent = Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()
        ..scale(item.scale, item.scale)
        ..rotateZ(item.rotation),
      child: content,
    );

    return Positioned(
      left: item.position.dx,
      top: item.position.dy,
      child: GestureDetector(
        onScaleStart: (details) {
          _activeOverlayBaseScale = item.scale;
          _activeOverlayBaseRotation = item.rotation;
          setState(() {
            _selectedOverlayId = item.id;
          });
        },
        onScaleUpdate: (details) {
          setState(() {
            _selectedOverlayId = item.id;
            // 1. Drag position
            item.position += details.focalPointDelta;

            // 2. Pinch-to-zoom (scaling)
            if (details.scale != 1.0) {
              item.scale = (_activeOverlayBaseScale * details.scale).clamp(0.4, 4.0);
            }

            // 3. Rotation
            if (details.rotation != 0.0) {
              item.rotation = _activeOverlayBaseRotation + details.rotation;
            }
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
              child: transformedContent,
            ),
            // Delete button (Top Right)
            if (isSelected)
              Positioned(
                top: -12,
                right: -12,
                child: GestureDetector(
                  onTap: () {
                    setState(() {
                      _overlays.removeWhere((o) => o.id == item.id);
                      _selectedOverlayId = null;
                    });
                  },
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(
                      color: AppColors.callRed,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.close, color: Colors.white, size: 14),
                  ),
                ),
              ),
            // Resize handle (Bottom Right)
            if (isSelected)
              Positioned(
                bottom: -12,
                right: -12,
                child: GestureDetector(
                  onPanUpdate: (details) {
                    setState(() {
                      final delta = (details.delta.dx + details.delta.dy) * 0.015;
                      item.scale = (item.scale + delta).clamp(0.4, 4.0);
                    });
                  },
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(
                      color: AppColors.accent,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.open_in_full_rounded, color: Colors.black, size: 14),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Custom painter for the interactive Crop Mode overlay
class CropOverlayPainter extends CustomPainter {
  final Rect imageRect;
  final Rect cropRect;

  CropOverlayPainter({
    required this.imageRect,
    required this.cropRect,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Dark mask outside crop rect (only within imageRect)
    final maskPaint = Paint()
      ..color = Colors.black.withOpacity(0.65)
      ..style = PaintingStyle.fill;

    final path = Path()
      ..addRect(imageRect)
      ..addRect(cropRect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(path, maskPaint);

    // 2. White border for crop rect
    final borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRect(cropRect, borderPaint);

    // 3. 3x3 Grid lines (Rule of thirds)
    final gridPaint = Paint()
      ..color = Colors.white.withOpacity(0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;

    final double w = cropRect.width;
    final double h = cropRect.height;

    // Vertical lines
    canvas.drawLine(
      Offset(cropRect.left + w / 3, cropRect.top),
      Offset(cropRect.left + w / 3, cropRect.bottom),
      gridPaint,
    );
    canvas.drawLine(
      Offset(cropRect.left + 2 * w / 3, cropRect.top),
      Offset(cropRect.left + 2 * w / 3, cropRect.bottom),
      gridPaint,
    );

    // Horizontal lines
    canvas.drawLine(
      Offset(cropRect.left, cropRect.top + h / 3),
      Offset(cropRect.right, cropRect.top + h / 3),
      gridPaint,
    );
    canvas.drawLine(
      Offset(cropRect.left, cropRect.top + 2 * h / 3),
      Offset(cropRect.right, cropRect.top + 2 * h / 3),
      gridPaint,
    );

    // 4. Corner brackets (WhatsApp style bold corners)
    final cornerPaint = Paint()
      ..color = AppColors.accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;

    const double cornerLen = 22.0;

    // Top-Left
    canvas.drawLine(Offset(cropRect.left, cropRect.top), Offset(cropRect.left + cornerLen, cropRect.top), cornerPaint);
    canvas.drawLine(Offset(cropRect.left, cropRect.top), Offset(cropRect.left, cropRect.top + cornerLen), cornerPaint);

    // Top-Right
    canvas.drawLine(Offset(cropRect.right, cropRect.top), Offset(cropRect.right - cornerLen, cropRect.top), cornerPaint);
    canvas.drawLine(Offset(cropRect.right, cropRect.top), Offset(cropRect.right, cropRect.top + cornerLen), cornerPaint);

    // Bottom-Left
    canvas.drawLine(Offset(cropRect.left, cropRect.bottom), Offset(cropRect.left + cornerLen, cropRect.bottom), cornerPaint);
    canvas.drawLine(Offset(cropRect.left, cropRect.bottom), Offset(cropRect.left, cropRect.bottom - cornerLen), cornerPaint);

    // Bottom-Right
    canvas.drawLine(Offset(cropRect.right, cropRect.bottom), Offset(cropRect.right - cornerLen, cropRect.bottom), cornerPaint);
    canvas.drawLine(Offset(cropRect.right, cropRect.bottom), Offset(cropRect.right, cropRect.bottom - cornerLen), cornerPaint);
  }

  @override
  bool shouldRepaint(covariant CropOverlayPainter oldDelegate) {
    return oldDelegate.cropRect != cropRect || oldDelegate.imageRect != imageRect;
  }
}
