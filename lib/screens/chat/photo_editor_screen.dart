import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';
import '../../constants/app_colors.dart';
import 'location_picker_screen.dart';

/// The result returned when photo editing is completed
class PhotoEditorResult {
  final File file;
  final String caption;
  final bool isVideo;
  final List<PhotoEditorResult>? allResults;

  PhotoEditorResult({
    required this.file,
    required this.caption,
    this.isVideo = false,
    this.allResults,
  });
}

class DrawnStroke {
  final List<Offset> points;
  final Color color;
  final double strokeWidth;

  DrawnStroke({
    required this.points,
    required this.color,
    required this.strokeWidth,
  });
}

class PhotoItemState {
  final String id;
  File originalFile;
  File currentImageFile;
  ui.Image? loadedUiImage;
  String caption;
  int selectedFilterIndex;
  List<OverlayItem> overlays;
  List<DrawnStroke> drawnStrokes;
  Rect cropRectNorm;
  int cropRotationQuarter;
  bool cropIsFlipped;
  double? selectedAspectPreset;
  bool isVideo;
  VideoPlayerController? videoController;
  bool isVideoInitialized;

  PhotoItemState({
    required this.id,
    required this.originalFile,
    required this.currentImageFile,
    this.loadedUiImage,
    this.caption = '',
    this.selectedFilterIndex = 0,
    List<OverlayItem>? overlays,
    List<DrawnStroke>? drawnStrokes,
    this.cropRectNorm = const Rect.fromLTWH(0, 0, 1, 1),
    this.cropRotationQuarter = 0,
    this.cropIsFlipped = false,
    this.selectedAspectPreset,
    this.isVideo = false,
    this.videoController,
    this.isVideoInitialized = false,
  })  : overlays = overlays ?? [],
        drawnStrokes = drawnStrokes ?? [];
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
  final File? imageFile;
  final List<File>? imageFiles;

  const PhotoEditorScreen({
    super.key,
    required File imageFile,
  })  : imageFile = imageFile,
        imageFiles = null;

  const PhotoEditorScreen.multiple({
    super.key,
    required List<File> imageFiles,
  })  : imageFiles = imageFiles,
        imageFile = null;

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

  // Multi-item WhatsApp-style management
  final List<PhotoItemState> _items = [];
  int _currentIndex = 0;
  final ScrollController _thumbScrollController = ScrollController();

  // Overlays for active photo
  final List<OverlayItem> _overlays = [];
  String? _selectedOverlayId;
  double _activeOverlayBaseScale = 1.0;
  double _activeOverlayBaseRotation = 0.0;

  // Drawing / Pen mode state
  bool _isDrawingMode = false;
  bool _isHighlighter = false;
  final List<DrawnStroke> _drawnStrokes = [];
  DrawnStroke? _currentStroke;
  Color _selectedDrawColor = const Color(0xFF00E676);
  double _selectedStrokeWidth = 6.0;

  final List<Color> _drawColors = const [
    Color(0xFF00E676), // WhatsApp Green
    Colors.white,
    Colors.black,
    Color(0xFFFF3B30), // Red
    Color(0xFF00B0FF), // Blue
    Color(0xFFFFD600), // Yellow
    Color(0xFFFF4081), // Pink
    Color(0xFFFF9100), // Orange
    Color(0xFFE040FB), // Purple
    Color(0xFF00E5FF), // Cyan
  ];

  void _enterDrawingMode() {
    setState(() {
      _isDrawingMode = true;
      _showFilterTray = false;
      _selectedOverlayId = null;
    });
  }

  void _exitDrawingMode() {
    setState(() {
      _isDrawingMode = false;
      _syncCurrentItemDrawnStrokes();
    });
  }

  void _undoLastStroke() {
    if (_drawnStrokes.isNotEmpty) {
      setState(() {
        _drawnStrokes.removeLast();
        _syncCurrentItemDrawnStrokes();
      });
    }
  }

  void _clearAllStrokes() {
    if (_drawnStrokes.isNotEmpty) {
      setState(() {
        _drawnStrokes.clear();
        _syncCurrentItemDrawnStrokes();
      });
    }
  }

  void _syncCurrentItemDrawnStrokes() {
    if (_items.isNotEmpty && _currentIndex < _items.length) {
      _items[_currentIndex].drawnStrokes = List.from(_drawnStrokes);
    }
  }

  bool _isExporting = false;

  @override
  void initState() {
    super.initState();
    final List<File> initialFiles = widget.imageFiles ?? (widget.imageFile != null ? [widget.imageFile!] : []);
    for (int i = 0; i < initialFiles.length; i++) {
      final f = initialFiles[i];
      final isVid = _checkIsVideo(f.path);
      final item = PhotoItemState(
        id: '${DateTime.now().millisecondsSinceEpoch}_$i',
        originalFile: f,
        currentImageFile: f,
        isVideo: isVid,
      );
      _items.add(item);
      if (isVid) {
        _initVideoControllerForItem(item);
      }
    }

    if (_items.isNotEmpty) {
      _currentImageFile = _items.first.currentImageFile;
      _loadStateFromItem(_items[_currentIndex]);
    } else {
      _currentImageFile = File('');
    }
  }

  Future<void> _initVideoControllerForItem(PhotoItemState item) async {
    if (!item.isVideo || item.videoController != null) return;
    try {
      final controller = VideoPlayerController.file(item.originalFile);
      item.videoController = controller;
      await controller.initialize();
      controller.setLooping(true);
      if (controller.value.duration.inMilliseconds > 200) {
        await controller.seekTo(const Duration(milliseconds: 200));
      }
      item.isVideoInitialized = true;
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('[VIDEO CONTROLLER INIT ERR] $e');
    }
  }

  void _disposeItemVideo(PhotoItemState item) {
    try {
      item.videoController?.pause();
      item.videoController?.dispose();
      item.videoController = null;
      item.isVideoInitialized = false;
    } catch (_) {}
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (duration.inHours > 0) {
      return '${duration.inHours}:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  bool _checkIsVideo(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.mp4') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.avi') ||
        lower.endsWith('.mkv') ||
        lower.endsWith('.3gp') ||
        lower.endsWith('.webm');
  }

  void _syncCurrentItemOverlays() {
    if (_items.isNotEmpty && _currentIndex < _items.length) {
      _items[_currentIndex].overlays = List.from(_overlays);
    }
  }

  void _saveStateToCurrentItem() {
    if (_currentIndex < 0 || _currentIndex >= _items.length) return;
    final item = _items[_currentIndex];
    item.caption = _captionController.text;
    item.selectedFilterIndex = _selectedFilterIndex;
    item.currentImageFile = _currentImageFile;
    item.loadedUiImage = _loadedUiImage;
    item.overlays = List.from(_overlays);
    item.drawnStrokes = List.from(_drawnStrokes);
    item.cropRectNorm = _cropRectNorm;
    item.cropRotationQuarter = _cropRotationQuarter;
    item.cropIsFlipped = _cropIsFlipped;
    item.selectedAspectPreset = _selectedAspectPreset;
  }

  void _loadStateFromItem(PhotoItemState item) {
    _captionController.text = item.caption;
    _selectedFilterIndex = item.selectedFilterIndex;
    _currentImageFile = item.currentImageFile;
    _loadedUiImage = item.loadedUiImage;
    _overlays.clear();
    _overlays.addAll(item.overlays);
    _drawnStrokes.clear();
    _drawnStrokes.addAll(item.drawnStrokes);
    _isDrawingMode = false;
    _isHighlighter = false;
    _selectedOverlayId = null;
    _cropRectNorm = item.cropRectNorm;
    _cropRotationQuarter = item.cropRotationQuarter;
    _cropIsFlipped = item.cropIsFlipped;
    _selectedAspectPreset = item.selectedAspectPreset;
    _isCropMode = false;
    _showFilterTray = false;

    if (!item.isVideo && _loadedUiImage == null) {
      _loadUiImage();
    }
  }

  void _switchPhoto(int newIndex) {
    if (newIndex < 0 || newIndex >= _items.length || newIndex == _currentIndex) return;
    // Pause currently playing video if switching away
    if (_items[_currentIndex].isVideo) {
      _items[_currentIndex].videoController?.pause();
    }
    _saveStateToCurrentItem();
    setState(() {
      _currentIndex = newIndex;
      _loadStateFromItem(_items[_currentIndex]);
    });
    _scrollToThumbnail(newIndex);
  }

  void _scrollToThumbnail(int index) {
    if (!_thumbScrollController.hasClients) return;
    final targetOffset = (index * 64.0) - 100.0;
    _thumbScrollController.animateTo(
      targetOffset.clamp(0.0, _thumbScrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  void _selectThumbnail(int index) {
    if (index == _currentIndex) return;
    _switchPhoto(index);
  }

  void _deleteCurrentItem() {
    if (_items.length <= 1) {
      Navigator.pop(context);
      return;
    }
    final removed = _items.removeAt(_currentIndex);
    _disposeItemVideo(removed);
    setState(() {
      if (_currentIndex >= _items.length) {
        _currentIndex = _items.length - 1;
      }
      _loadStateFromItem(_items[_currentIndex]);
    });
  }

  void _deleteItemAtIndex(int index) {
    if (_items.length <= 1) {
      Navigator.pop(context);
      return;
    }
    final removed = _items.removeAt(index);
    _disposeItemVideo(removed);
    setState(() {
      if (_currentIndex >= _items.length) {
        _currentIndex = _items.length - 1;
        _loadStateFromItem(_items[_currentIndex]);
      } else if (_currentIndex == index) {
        _loadStateFromItem(_items[_currentIndex]);
      }
    });
  }

  Future<void> _addMoreMedia() async {
    final remainingLimit = 30 - _items.length;
    if (remainingLimit <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('En fazla 30 medya ekleyebilirsiniz.'),
          backgroundColor: AppColors.callRed,
        ),
      );
      return;
    }

    try {
      final picker = ImagePicker();
      final List<XFile> additionalList = await picker.pickMultipleMedia(limit: remainingLimit);
      if (additionalList.isEmpty) return;

      final newItems = additionalList.map((x) {
        final f = File(x.path);
        final isVid = _checkIsVideo(x.path);
        return PhotoItemState(
          id: '${DateTime.now().millisecondsSinceEpoch}_${math.Random().nextInt(10000)}',
          originalFile: f,
          currentImageFile: f,
          isVideo: isVid,
        );
      }).toList();

      for (final item in newItems) {
        _items.add(item);
        if (item.isVideo) {
          _initVideoControllerForItem(item);
        }
      }

      setState(() {});
    } catch (e) {
      debugPrint('[ADD MORE MEDIA ERR] $e');
    }
  }

  Future<void> _loadUiImage() async {
    try {
      final bytes = await _currentImageFile.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      if (mounted) {
        setState(() {
          _loadedUiImage = frame.image;
          if (_items.isNotEmpty && _currentIndex < _items.length) {
            _items[_currentIndex].loadedUiImage = frame.image;
          }
        });
      }
    } catch (e) {
      debugPrint('[LOAD UI IMAGE ERR] $e');
    }
  }

  @override
  void dispose() {
    for (final item in _items) {
      _disposeItemVideo(item);
    }
    _captionController.dispose();
    _thumbScrollController.dispose();
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
      if (_items.isNotEmpty && _currentIndex < _items.length) {
        _items[_currentIndex].currentImageFile = cropped;
      }
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
    _saveStateToCurrentItem();

    setState(() {
      _isExporting = true;
      _selectedOverlayId = null; // hide bounding boxes
      _showFilterTray = false;
    });

    try {
      final List<PhotoEditorResult> results = [];
      final int total = _items.length;

      for (int i = 0; i < total; i++) {
        if (!mounted) return;
        final item = _items[i];

        if (item.isVideo) {
          results.add(PhotoEditorResult(
            file: item.originalFile,
            caption: item.caption,
            isVideo: true,
          ));
          continue;
        }

        final bool hasEdits = item.overlays.isNotEmpty ||
            item.drawnStrokes.isNotEmpty ||
            item.selectedFilterIndex != 0 ||
            item.currentImageFile.path != item.originalFile.path;

        if (!hasEdits) {
          results.add(PhotoEditorResult(
            file: item.originalFile,
            caption: item.caption,
            isVideo: false,
          ));
        } else {
          // Switch to this item and render via RepaintBoundary
          if (_currentIndex != i) {
            setState(() {
              _currentIndex = i;
              _loadStateFromItem(item);
            });
            await Future.delayed(const Duration(milliseconds: 60));
          } else {
            await Future.delayed(const Duration(milliseconds: 30));
          }

          final boundary = _repaintKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
          if (boundary != null) {
            final image = await boundary.toImage(pixelRatio: 2.2);
            final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
            if (byteData != null) {
              final bytes = byteData.buffer.asUint8List();
              final tempDir = await getTemporaryDirectory();
              final outPath = p.join(tempDir.path, 'edited_${DateTime.now().millisecondsSinceEpoch}_$i.jpg');
              final exportedFile = File(outPath);
              await exportedFile.writeAsBytes(bytes);
              results.add(PhotoEditorResult(
                file: exportedFile,
                caption: item.caption,
                isVideo: false,
              ));
              continue;
            }
          }

          results.add(PhotoEditorResult(
            file: item.currentImageFile,
            caption: item.caption,
            isVideo: false,
          ));
        }
      }

      if (!mounted) return;

      if (results.isEmpty) {
        setState(() => _isExporting = false);
        return;
      }

      Navigator.pop(
        context,
        PhotoEditorResult(
          file: results.first.file,
          caption: results.first.caption,
          isVideo: results.first.isVideo,
          allResults: results,
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

  Widget _buildStrokeWidthChip(String label, double width, {bool isHighlighter = false}) {
    final bool isSel = (_selectedStrokeWidth == width && _isHighlighter == isHighlighter);
    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedStrokeWidth = width;
          _isHighlighter = isHighlighter;
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: isSel ? AppColors.accent.withOpacity(0.25) : const Color(0xFF1F2C34),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSel ? AppColors.accent : Colors.white24,
            width: isSel ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: isHighlighter ? 12 : math.max(width * 0.7, 4.0),
              height: isHighlighter ? 6 : math.max(width * 0.7, 4.0),
              decoration: BoxDecoration(
                color: isSel ? AppColors.accent : Colors.white70,
                borderRadius: BorderRadius.circular(isHighlighter ? 2 : 10),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: isSel ? AppColors.accent : Colors.white,
                fontSize: 11.5,
                fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- MAIN EDITOR SCREEN ---
  Widget _buildMainEditorScreen() {
    final selectedFilter = _filters[_selectedFilterIndex];
    final selectedItem = _selectedOverlay;
    final bool isCurrentVideo = _items.isNotEmpty &&
        _currentIndex < _items.length &&
        _items[_currentIndex].isVideo;

    return PopScope(
      canPop: !_isDrawingMode,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _isDrawingMode) {
          _exitDrawingMode();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Stack(
            children: [
              Column(
                children: [
                  // TOP BAR
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    color: Colors.black.withOpacity(0.5),
                    child: _isDrawingMode
                        ? Row(
                            children: [
                              IconButton(
                                icon: const Icon(Icons.arrow_back_rounded, color: Colors.white, size: 26),
                                tooltip: 'Geri',
                                onPressed: _exitDrawingMode,
                              ),
                              const SizedBox(width: 4),
                              const Text(
                                'Kalem & Çizim',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const Spacer(),
                              IconButton(
                                icon: const Icon(Icons.undo_rounded, size: 24),
                                color: _drawnStrokes.isNotEmpty ? Colors.white : Colors.white38,
                                tooltip: 'Son Çizgiyi Geri Al',
                                onPressed: _drawnStrokes.isNotEmpty ? _undoLastStroke : null,
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_sweep_rounded, size: 24),
                                color: _drawnStrokes.isNotEmpty ? Colors.white : Colors.white38,
                                tooltip: 'Tümünü Temizle',
                                onPressed: _drawnStrokes.isNotEmpty ? _clearAllStrokes : null,
                              ),
                              const SizedBox(width: 6),
                              ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.accent,
                                  foregroundColor: Colors.black,
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                                  minimumSize: Size.zero,
                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                ),
                                icon: const Icon(Icons.check_rounded, color: Colors.black, size: 18),
                                label: const Text(
                                  'Bitti',
                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                ),
                                onPressed: _exitDrawingMode,
                              ),
                            ],
                          )
                        : Row(
                            children: [
                              IconButton(
                                icon: const Icon(Icons.close_rounded, color: Colors.white, size: 26),
                                onPressed: () => Navigator.pop(context),
                              ),
                              if (_items.length > 1) ...[
                                const SizedBox(width: 4),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.15),
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: Text(
                                    '${_currentIndex + 1} / ${_items.length}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline_rounded, color: Colors.white70, size: 22),
                                  tooltip: 'Bu medyayı sil',
                                  onPressed: _deleteCurrentItem,
                                ),
                              ],
                              const Spacer(),
                              if (!isCurrentVideo) ...[
                                // Crop & Rotate
                                IconButton(
                                  icon: const Icon(Icons.crop_rotate_rounded, color: Colors.white, size: 24),
                                  tooltip: 'Kırp & Döndür',
                                  onPressed: _enterCropMode,
                                ),
                                // Pen & Drawing
                                IconButton(
                                  icon: Icon(
                                    Icons.edit_rounded,
                                    color: _drawnStrokes.isNotEmpty ? AppColors.accent : Colors.white,
                                    size: 24,
                                  ),
                                  tooltip: 'Kalem & Çizim',
                                  onPressed: _enterDrawingMode,
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
                              ] else ...[
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: AppColors.accent.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: AppColors.accent.withOpacity(0.5)),
                                  ),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.videocam_rounded, color: AppColors.accent, size: 16),
                                      SizedBox(width: 4),
                                      Text(
                                        'Video',
                                        style: TextStyle(
                                          color: AppColors.accent,
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                  ),

                  // DRAWING TOOLBAR (Colors & Thickness)
                  if (_isDrawingMode && !isCurrentVideo)
                    Container(
                      color: const Color(0xFF141D22),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Thickness presets row
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              _buildStrokeWidthChip('İnce', 3.0),
                              const SizedBox(width: 6),
                              _buildStrokeWidthChip('Normal', 6.0),
                              const SizedBox(width: 6),
                              _buildStrokeWidthChip('Kalın', 12.0),
                              const SizedBox(width: 6),
                              _buildStrokeWidthChip('Vurgulayıcı', 24.0, isHighlighter: true),
                            ],
                          ),
                          const SizedBox(height: 8),
                          // Color Palette
                          SizedBox(
                            height: 36,
                            child: ListView.separated(
                              scrollDirection: Axis.horizontal,
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              itemCount: _drawColors.length,
                              separatorBuilder: (_, __) => const SizedBox(width: 10),
                              itemBuilder: (context, idx) {
                                final color = _drawColors[idx];
                                final isSel = (_selectedDrawColor.value == color.value);
                                return GestureDetector(
                                  onTap: () => setState(() => _selectedDrawColor = color),
                                  child: Container(
                                    width: isSel ? 34 : 28,
                                    height: isSel ? 34 : 28,
                                    decoration: BoxDecoration(
                                      color: color,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: isSel ? Colors.white : Colors.white24,
                                        width: isSel ? 2.5 : 1.2,
                                      ),
                                      boxShadow: isSel
                                          ? [
                                              BoxShadow(
                                                color: color.withOpacity(0.6),
                                                blurRadius: 8,
                                                spreadRadius: 1,
                                              ),
                                            ]
                                          : null,
                                    ),
                                    child: isSel
                                        ? Icon(
                                            Icons.check,
                                            size: 16,
                                            color: color.computeLuminance() > 0.5 ? Colors.black : Colors.white,
                                          )
                                        : null,
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),

                  // CENTER CANVAS (Image + Filter + Overlays + Drawings)
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: () {
                        if (_selectedOverlayId != null) {
                          setState(() => _selectedOverlayId = null);
                        }
                      },
                      onHorizontalDragEnd: (details) {
                        if (_isDrawingMode) return;
                        if (_selectedOverlayId != null) return;
                        final velocity = details.primaryVelocity ?? 0;
                        if (velocity < -200 && _currentIndex < _items.length - 1) {
                          _switchPhoto(_currentIndex + 1);
                        } else if (velocity > 200 && _currentIndex > 0) {
                          _switchPhoto(_currentIndex - 1);
                        }
                      },
                      child: Center(
                        child: RepaintBoundary(
                          key: _repaintKey,
                          child: Stack(
                            alignment: Alignment.center,
                            clipBehavior: Clip.hardEdge,
                            children: [
                              // The Cropped Filtered Base Image / Video
                              _buildFilteredImage(selectedFilter),

                              // Overlays (Draggable & scalable text, emojis, location)
                              if (!isCurrentVideo)
                                ..._overlays.map((item) => _buildOverlayWidget(item)),

                              // Drawn Strokes (CustomPaint)
                              if (!isCurrentVideo)
                                Positioned.fill(
                                  child: IgnorePointer(
                                    child: CustomPaint(
                                      painter: DrawingPainter(
                                        strokes: _drawnStrokes,
                                        currentStroke: _currentStroke,
                                      ),
                                    ),
                                  ),
                                ),

                              // Drawing Gesture Detector (when in drawing mode)
                              if (!isCurrentVideo && _isDrawingMode)
                                Positioned.fill(
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onPanStart: (details) {
                                      final Color strokeColor = _isHighlighter
                                          ? _selectedDrawColor.withOpacity(0.45)
                                          : _selectedDrawColor;
                                      setState(() {
                                        _currentStroke = DrawnStroke(
                                          points: [details.localPosition],
                                          color: strokeColor,
                                          strokeWidth: _selectedStrokeWidth,
                                        );
                                      });
                                    },
                                    onPanUpdate: (details) {
                                      if (_currentStroke == null) return;
                                      setState(() {
                                        _currentStroke!.points.add(details.localPosition);
                                      });
                                    },
                                    onPanEnd: (details) {
                                      if (_currentStroke != null) {
                                        setState(() {
                                          _drawnStrokes.add(_currentStroke!);
                                          _currentStroke = null;
                                          _syncCurrentItemDrawnStrokes();
                                        });
                                      }
                                    },
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),

                  // FLOATING SIZE SLIDER (When an overlay is selected)
                  if (selectedItem != null && !isCurrentVideo && !_isDrawingMode)
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
                  if (_showFilterTray && !isCurrentVideo && !_isDrawingMode)
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

                  // THUMBNAIL STRIP (WhatsApp style horizontal photo selector)
                  if (!_isDrawingMode)
                    _buildThumbnailStrip(),

                  // BOTTOM BAR (WhatsApp style caption input & send button)
                  if (!_isDrawingMode)
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
                                      onChanged: (val) {
                                        if (_items.isNotEmpty && _currentIndex < _items.length) {
                                          _items[_currentIndex].caption = val;
                                        }
                                      },
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
                                    : (_items.length > 1
                                        ? Stack(
                                            clipBehavior: Clip.none,
                                            alignment: Alignment.center,
                                            children: [
                                              const Icon(Icons.send_rounded, color: Colors.white, size: 20),
                                              Positioned(
                                                top: -7,
                                                right: -7,
                                                child: Container(
                                                  padding: const EdgeInsets.all(4),
                                                  decoration: BoxDecoration(
                                                    color: const Color(0xFF00A884),
                                                    shape: BoxShape.circle,
                                                    border: Border.all(color: Colors.white, width: 1.2),
                                                  ),
                                                  child: Text(
                                                    '${_items.length}',
                                                    style: const TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 10,
                                                      fontWeight: FontWeight.bold,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          )
                                        : const Icon(Icons.send_rounded, color: Colors.white, size: 22)),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),

              // EXPORTING / PROCESSING OVERLAY
              if (_isExporting)
                Container(
                  color: Colors.black.withOpacity(0.7),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1F2C34),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: AppColors.accent.withOpacity(0.3)),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.5),
                            blurRadius: 16,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: const Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(color: AppColors.accent),
                          SizedBox(height: 16),
                          Text(
                            'Fotoğraflar Hazırlanıyor...',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          SizedBox(height: 6),
                          Text(
                            'Lütfen bekleyin',
                            style: TextStyle(
                              color: Colors.white60,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // --- WHATSAPP-STYLE THUMBNAIL STRIP ---
  Widget _buildThumbnailStrip() {
    return Container(
      height: 86,
      color: Colors.black.withOpacity(0.85),
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: ListView.separated(
        controller: _thumbScrollController,
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _items.length + 1,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          if (index == _items.length) {
            // "+" Add More Media Button
            return GestureDetector(
              onTap: _isExporting ? null : _addMoreMedia,
              child: Container(
                width: 52,
                height: 56,
                decoration: BoxDecoration(
                  color: const Color(0xFF1F2C34),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white24, width: 1.2),
                ),
                child: const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.add_photo_alternate_rounded, color: AppColors.accent, size: 22),
                    SizedBox(height: 2),
                    Text(
                      'Ekle',
                      style: TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            );
          }

          final item = _items[index];
          final bool isSelected = (index == _currentIndex);
          final bool hasEdits = item.overlays.isNotEmpty ||
              item.drawnStrokes.isNotEmpty ||
              item.selectedFilterIndex != 0 ||
              item.cropRotationQuarter != 0 ||
              item.cropIsFlipped ||
              item.currentImageFile.path != item.originalFile.path;

          return GestureDetector(
            onTap: () => _selectThumbnail(index),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: isSelected ? 56 : 50,
                  height: 56,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isSelected ? AppColors.accent : Colors.white24,
                      width: isSelected ? 2.5 : 1.0,
                    ),
                    boxShadow: isSelected
                        ? [
                            BoxShadow(
                              color: AppColors.accent.withOpacity(0.4),
                              blurRadius: 6,
                              spreadRadius: 1,
                            ),
                          ]
                        : null,
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        item.isVideo
                            ? (item.videoController != null && item.isVideoInitialized
                                ? FittedBox(
                                    fit: BoxFit.cover,
                                    clipBehavior: Clip.hardEdge,
                                    child: SizedBox(
                                      width: item.videoController!.value.size.width > 0
                                          ? item.videoController!.value.size.width
                                          : 100,
                                      height: item.videoController!.value.size.height > 0
                                          ? item.videoController!.value.size.height
                                          : 100,
                                      child: VideoPlayer(item.videoController!),
                                    ),
                                  )
                                : Container(
                                    color: const Color(0xFF141D22),
                                    child: const Center(
                                      child: SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent),
                                      ),
                                    ),
                                  ))
                            : Image.file(
                                item.currentImageFile,
                                fit: BoxFit.cover,
                              ),
                        if (!isSelected)
                          Container(
                            color: Colors.black.withOpacity(0.35),
                          ),
                        if (item.isVideo)
                          Positioned(
                            bottom: 2,
                            left: 2,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.85),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 10),
                                  if (item.videoController != null && item.isVideoInitialized) ...[
                                    const SizedBox(width: 2),
                                    Text(
                                      _formatDuration(item.videoController!.value.duration),
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 8.5,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                // Edited indicator badge
                if (hasEdits)
                  Positioned(
                    bottom: 2,
                    left: 2,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: AppColors.accent,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.black87, width: 1),
                      ),
                      child: const Icon(Icons.edit_rounded, color: Colors.black, size: 10),
                    ),
                  ),
                // Delete button (X) on thumbnails if multiple items
                if (_items.length > 1)
                  Positioned(
                    top: -6,
                    right: -6,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _deleteItemAtIndex(index),
                      child: Container(
                        width: isSelected ? 22 : 20,
                        height: isSelected ? 22 : 20,
                        decoration: BoxDecoration(
                          color: isSelected ? const Color(0xFFFF3B30) : const Color(0xFF333333),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 1.8),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.6),
                              blurRadius: 4,
                              offset: const Offset(0, 1),
                            ),
                          ],
                        ),
                        child: Center(
                          child: Icon(
                            Icons.close_rounded,
                            color: Colors.white,
                            size: isSelected ? 13 : 11,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildFilteredImage(FilterOption filter) {
    if (_items.isNotEmpty && _currentIndex < _items.length && _items[_currentIndex].isVideo) {
      return _buildVideoPlayerArea(_items[_currentIndex]);
    }

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

  Widget _buildVideoPlayerArea(PhotoItemState item) {
    final controller = item.videoController;
    if (controller == null || !item.isVideoInitialized) {
      return Container(
        color: const Color(0xFF10191F),
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: AppColors.accent),
              SizedBox(height: 14),
              Text(
                'Video hazırlanıyor...',
                style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
      );
    }

    final bool isPlaying = controller.value.isPlaying;

    return Center(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          setState(() {
            if (controller.value.isPlaying) {
              controller.pause();
            } else {
              controller.play();
            }
          });
        },
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Video Frame
            AspectRatio(
              aspectRatio: controller.value.aspectRatio > 0 ? controller.value.aspectRatio : 16 / 9,
              child: VideoPlayer(controller),
            ),

            // Play / Pause Glass Overlay button
            AnimatedOpacity(
              opacity: isPlaying ? 0.0 : 0.9,
              duration: const Duration(milliseconds: 180),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.6),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white38, width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.5),
                      blurRadius: 10,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 46,
                ),
              ),
            ),

            // Duration and time indicator at bottom
            Positioned(
              bottom: 12,
              left: 14,
              right: 14,
              child: ValueListenableBuilder<VideoPlayerValue>(
                valueListenable: controller,
                builder: (context, val, _) {
                  final totalMs = val.duration.inMilliseconds.toDouble();
                  final curMs = val.position.inMilliseconds.toDouble().clamp(0.0, totalMs > 0 ? totalMs : 1.0);
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.65),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Row(
                      children: [
                        Text(
                          _formatDuration(val.position),
                          style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                        Expanded(
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              activeTrackColor: AppColors.accent,
                              inactiveTrackColor: Colors.white24,
                              thumbColor: AppColors.accent,
                              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                              trackHeight: 2.5,
                              overlayShape: const RoundSliderOverlayShape(overlayRadius: 8),
                            ),
                            child: Slider(
                              min: 0.0,
                              max: totalMs > 0 ? totalMs : 1.0,
                              value: curMs,
                              onChanged: (newMs) {
                                controller.seekTo(Duration(milliseconds: newMs.toInt()));
                              },
                            ),
                          ),
                        ),
                        Text(
                          _formatDuration(val.duration),
                          style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
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

/// Custom painter for smooth freehand drawing (Pen & Marker)
class DrawingPainter extends CustomPainter {
  final List<DrawnStroke> strokes;
  final DrawnStroke? currentStroke;

  DrawingPainter({
    required this.strokes,
    this.currentStroke,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final allStrokes = currentStroke != null ? [...strokes, currentStroke!] : strokes;

    for (final stroke in allStrokes) {
      if (stroke.points.isEmpty) continue;

      final paint = Paint()
        ..color = stroke.color
        ..strokeWidth = stroke.strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;

      if (stroke.points.length == 1) {
        canvas.drawCircle(stroke.points.first, stroke.strokeWidth / 2, paint..style = PaintingStyle.fill);
      } else {
        final path = Path();
        path.moveTo(stroke.points[0].dx, stroke.points[0].dy);
        for (int i = 1; i < stroke.points.length; i++) {
          final p0 = stroke.points[i - 1];
          final p1 = stroke.points[i];
          path.quadraticBezierTo(
            p0.dx,
            p0.dy,
            (p0.dx + p1.dx) / 2,
            (p0.dy + p1.dy) / 2,
          );
        }
        path.lineTo(stroke.points.last.dx, stroke.points.last.dy);
        canvas.drawPath(path, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant DrawingPainter oldDelegate) => true;
}
