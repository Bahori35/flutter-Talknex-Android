import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:video_player/video_player.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:audioplayers/audioplayers.dart';
import '../../constants/app_colors.dart';
import 'location_picker_screen.dart';
import 'photo_editor_screen.dart' show OverlayType, OverlayItem, DrawnStroke, DrawingPainter, FilterOption;

const MethodChannel _nativeVideoChannel = MethodChannel('com.safechat.app/video');

/// The result returned when video editing is completed
class VideoEditorResult {
  final File file;
  final String caption;

  VideoEditorResult({
    required this.file,
    required this.caption,
  });
}

class VideoClipItem {
  final String id;
  final File file;
  Duration totalDuration;
  Duration startTrim;
  Duration endTrim;

  VideoClipItem({
    required this.id,
    required this.file,
    required this.totalDuration,
    required this.startTrim,
    required this.endTrim,
  });

  Duration get trimmedDuration {
    if (endTrim <= startTrim) return Duration.zero;
    return endTrim - startTrim;
  }
}

class VideoEditorScreen extends StatefulWidget {
  final File initialVideoFile;

  const VideoEditorScreen({
    super.key,
    required this.initialVideoFile,
  });

  @override
  State<VideoEditorScreen> createState() => _VideoEditorScreenState();
}

class _VideoEditorScreenState extends State<VideoEditorScreen> {
  final ImagePicker _picker = ImagePicker();
  final TextEditingController _captionController = TextEditingController();

  final List<VideoClipItem> _clips = [];
  final Map<int, VideoPlayerController> _controllers = {};

  int _playingClipIndex = 0; // The clip currently active on the player
  int _selectedClipIndex = 0; // The clip currently selected for trimming
  bool _isPlaying = false;
  bool _isMuted = false;
  double _videoVolume = 1.0; // 0.0 to 1.0

  // Background Audio / Music Track
  File? _bgMusicFile;
  String? _bgMusicName;
  double _bgMusicVolume = 0.7; // 0.0 to 1.0
  AudioPlayer? _bgMusicPlayer;
  Duration _bgMusicTotalDuration = Duration.zero;
  Duration _bgMusicStartTrim = Duration.zero;
  Duration _bgMusicEndTrim = Duration.zero;
  int _activeEditorTab = 0; // 0: Video Kırp, 1: Şarkı Kırp, 2: Ses Mikseri

  Duration get _bgMusicTrimmedDuration {
    if (_bgMusicEndTrim <= _bgMusicStartTrim) return Duration.zero;
    return _bgMusicEndTrim - _bgMusicStartTrim;
  }

  bool _isProcessing = false;
  double _processingProgress = 0.0;
  String _processingStatus = '';

  // --- PHOTO EDITING TOOLS: OVERLAYS, DRAWINGS & FILTERS ---
  final GlobalKey _videoOverlayRepaintKey = GlobalKey();

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

  // Overlays (Text, Emoji, Location)
  final List<OverlayItem> _overlays = [];
  String? _selectedOverlayId;
  double _activeOverlayBaseScale = 1.0;
  double _activeOverlayBaseRotation = 0.0;

  OverlayItem? get _selectedOverlay {
    if (_selectedOverlayId == null) return null;
    try {
      return _overlays.firstWhere((o) => o.id == _selectedOverlayId);
    } catch (_) {
      return null;
    }
  }

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
    });
  }

  void _undoLastStroke() {
    if (_drawnStrokes.isNotEmpty) {
      setState(() {
        _drawnStrokes.removeLast();
      });
    }
  }

  void _clearAllStrokes() {
    setState(() {
      _drawnStrokes.clear();
      _currentStroke = null;
    });
  }

  void _undoLastOverlayOrStroke() {
    setState(() {
      if (_overlays.isNotEmpty) {
        _overlays.removeLast();
        _selectedOverlayId = null;
      } else if (_drawnStrokes.isNotEmpty) {
        _drawnStrokes.removeLast();
      }
    });
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
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: AppColors.callRed.withValues(alpha: 0.15),
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
                            color: const Color(0xFF00A884).withValues(alpha: 0.35),
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
                  Row(
                    children: [
                      const Expanded(child: Divider(color: Colors.white12)),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Text(
                          'veya konumu yazın',
                          style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 12),
                        ),
                      ),
                      const Expanded(child: Divider(color: Colors.white12)),
                    ],
                  ),
                  const SizedBox(height: 12),
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
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    onPressed: () {
                      final place = locCtrl.text.trim();
                      if (place.isNotEmpty) {
                        Navigator.pop(ctx);
                        setState(() {
                          final newItem = OverlayItem(
                            id: DateTime.now().millisecondsSinceEpoch.toString(),
                            type: OverlayType.location,
                            text: '📍 $place',
                            position: const Offset(80, 140),
                            fontSize: 16.0,
                          );
                          _overlays.add(newItem);
                          _selectedOverlayId = newItem.id;
                        });
                      }
                    },
                    child: const Text('Çıkartmayı Ekle', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _openTextDialog({OverlayItem? existing}) {
    final textCtrl = TextEditingController(text: existing?.text ?? '');
    Color selectedColor = existing?.color ?? Colors.white;
    Color selectedBg = existing?.backgroundColor ?? Colors.black54;

    final colors = [
      Colors.white,
      Colors.black,
      AppColors.accent,
      const Color(0xFFFF3B30),
      const Color(0xFF00B0FF),
      const Color(0xFFFFD600),
      const Color(0xFFFF4081),
      const Color(0xFFFF9100),
      const Color(0xFFE040FB),
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1F2C34),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
                top: 16,
                left: 16,
                right: 16,
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
                        backgroundColor: selectedBg == Colors.transparent ? AppColors.accent : const Color(0xFF243642),
                        labelStyle: TextStyle(color: selectedBg == Colors.transparent ? Colors.black : Colors.white),
                        onPressed: () => setSheetState(() => selectedBg = Colors.transparent),
                      ),
                      const SizedBox(width: 8),
                      ActionChip(
                        label: const Text('Koyu'),
                        backgroundColor: selectedBg == Colors.black54 ? AppColors.accent : const Color(0xFF243642),
                        labelStyle: TextStyle(color: selectedBg == Colors.black54 ? Colors.black : Colors.white),
                        onPressed: () => setSheetState(() => selectedBg = Colors.black54),
                      ),
                      const SizedBox(width: 8),
                      ActionChip(
                        label: const Text('Açık'),
                        backgroundColor: selectedBg == Colors.white70 ? AppColors.accent : const Color(0xFF243642),
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

  @override
  void initState() {
    super.initState();
    _initFirstClip();
  }

  Future<void> _initFirstClip() async {
    final firstClip = VideoClipItem(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      file: widget.initialVideoFile,
      totalDuration: Duration.zero,
      startTrim: Duration.zero,
      endTrim: Duration.zero,
    );

    setState(() {
      _clips.add(firstClip);
      _playingClipIndex = 0;
      _selectedClipIndex = 0;
    });

    await _initAllControllers();
  }

  Future<void> _initAllControllers() async {
    for (int i = 0; i < _clips.length; i++) {
      if (_controllers.containsKey(i)) continue;
      final clip = _clips[i];
      final controller = VideoPlayerController.file(clip.file);

      try {
        await controller.initialize();
        controller.setVolume(_isMuted ? 0.0 : _videoVolume);
        controller.setLooping(false);

        if (clip.totalDuration == Duration.zero) {
          clip.totalDuration = controller.value.duration;
          clip.endTrim = controller.value.duration;
        }

        final clipIndex = i;
        controller.addListener(() => _onControllerTick(clipIndex));
        _controllers[i] = controller;
      } catch (e) {
        debugPrint('[INIT CONTROLLER ERR FOR CLIP $i] $e');
      }
    }

    if (mounted) {
      setState(() {});
    }
  }

  bool _isTransitioning = false;
  Timer? _videoSeekDebounceTimer;
  Timer? _musicSeekDebounceTimer;

  void _debouncedVideoSeek(int clipIndex, Duration target) {
    _videoSeekDebounceTimer?.cancel();
    _videoSeekDebounceTimer = Timer(const Duration(milliseconds: 60), () {
      if (mounted && _controllers.containsKey(clipIndex)) {
        final c = _controllers[clipIndex];
        if (c != null && c.value.isInitialized) {
          c.seekTo(target);
        }
      }
    });
  }

  void _debouncedMusicSeek(Duration target) {
    _musicSeekDebounceTimer?.cancel();
    _musicSeekDebounceTimer = Timer(const Duration(milliseconds: 60), () {
      if (mounted) {
        _bgMusicPlayer?.seek(target);
      }
    });
  }

  void _onControllerTick(int clipIndex) {
    if (!mounted || _isTransitioning || clipIndex != _playingClipIndex) return;
    final controller = _controllers[clipIndex];
    if (controller == null || !controller.value.isInitialized) return;

    final pos = controller.value.position;
    if (clipIndex >= _clips.length) return;
    final clip = _clips[clipIndex];

    // Smooth transition to next clip when current clip reaches endTrim or finishes
    final bool reachedEnd = pos >= clip.endTrim || controller.value.isCompleted;

    if (reachedEnd && !_isTransitioning) {
      _isTransitioning = true;
      if (_isPlaying) {
        int nextIndex = clipIndex + 1;
        if (nextIndex >= _clips.length) {
          nextIndex = 0; // Loop back to start
        }
        _transitionToClip(nextIndex);
      } else {
        controller.pause();
        controller.seekTo(clip.startTrim).then((_) {
          if (mounted) {
            _isTransitioning = false;
          }
        });
      }
      return;
    }

    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _transitionToClip(int nextIndex) async {
    _isTransitioning = true;
    try {
      final currentController = _controllers[_playingClipIndex];
      await currentController?.pause();
      if (_playingClipIndex < _clips.length) {
        await currentController?.seekTo(_clips[_playingClipIndex].startTrim);
      }

      if (!mounted) return;

      setState(() {
        _playingClipIndex = nextIndex;
      });

      final nextController = _controllers[nextIndex];
      if (nextController != null && nextController.value.isInitialized && nextIndex < _clips.length) {
        await nextController.seekTo(_clips[nextIndex].startTrim);
        if (_isPlaying && mounted) {
          await nextController.play();
        }
      }

      if (nextIndex == 0 && mounted) {
        await _bgMusicPlayer?.seek(_bgMusicStartTrim);
      }
    } catch (e) {
      debugPrint('[TRANSITION ERR] $e');
    } finally {
      await Future.delayed(const Duration(milliseconds: 150));
      if (mounted) {
        _isTransitioning = false;
      }
    }
  }

  @override
  void dispose() {
    _videoSeekDebounceTimer?.cancel();
    _musicSeekDebounceTimer?.cancel();
    for (final c in _controllers.values) {
      c.dispose();
    }
    _captionController.dispose();
    _bgMusicPlayer?.stop();
    _bgMusicPlayer?.dispose();
    super.dispose();
  }

  // --- MERGED TIMELINE CALCULATIONS ---

  Duration get _totalMergedDuration {
    Duration total = Duration.zero;
    for (final c in _clips) {
      total += c.trimmedDuration;
    }
    return total;
  }

  Duration get _currentMergedPosition {
    Duration pos = Duration.zero;
    for (int i = 0; i < _clips.length; i++) {
      if (i < _playingClipIndex) {
        pos += _clips[i].trimmedDuration;
      } else if (i == _playingClipIndex) {
        final controller = _controllers[i];
        if (controller != null && controller.value.isInitialized) {
          final clipPos = controller.value.position;
          final offsetInClip = clipPos - _clips[i].startTrim;
          if (offsetInClip > Duration.zero) {
            final dur = _clips[i].trimmedDuration;
            pos += (offsetInClip > dur) ? dur : offsetInClip;
          }
        }
        break;
      }
    }
    return pos;
  }

  void _seekMergedPosition(Duration targetPos) {
    final musicWindow = _bgMusicTrimmedDuration;
    if (musicWindow > Duration.zero) {
      final offset = targetPos.inMilliseconds % musicWindow.inMilliseconds;
      _bgMusicPlayer?.seek(_bgMusicStartTrim + Duration(milliseconds: offset));
    } else {
      _bgMusicPlayer?.seek(_bgMusicStartTrim);
    }
    Duration accumulated = Duration.zero;
    for (int i = 0; i < _clips.length; i++) {
      final clipDur = _clips[i].trimmedDuration;
      if (targetPos <= accumulated + clipDur || i == _clips.length - 1) {
        final offsetInsideClip = targetPos - accumulated;
        final targetClipPos = _clips[i].startTrim +
            (offsetInsideClip < Duration.zero
                ? Duration.zero
                : (offsetInsideClip > clipDur ? clipDur : offsetInsideClip));

        if (_playingClipIndex != i) {
          _controllers[_playingClipIndex]?.pause();
          _playingClipIndex = i;
          _selectedClipIndex = i;
        }

        final targetController = _controllers[i];
        if (targetController != null && targetController.value.isInitialized) {
          targetController.seekTo(targetClipPos);
          if (_isPlaying) {
            targetController.play();
          }
        }
        setState(() {});
        break;
      }
      accumulated += clipDur;
    }
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) {
      final hours = d.inHours.toString().padLeft(2, '0');
      return '$hours:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  void _togglePlayPause() {
    if (_controllers.isEmpty) return;
    setState(() {
      _isPlaying = !_isPlaying;
      if (_isPlaying) {
        // If near end of entire merged video, restart from the very beginning
        if (_totalMergedDuration > Duration.zero &&
            _currentMergedPosition >= _totalMergedDuration - const Duration(milliseconds: 200)) {
          _seekMergedPosition(Duration.zero);
        }
        final activeController = _controllers[_playingClipIndex];
        if (activeController != null && activeController.value.isInitialized) {
          if (_playingClipIndex < _clips.length) {
            final currentClip = _clips[_playingClipIndex];
            if (activeController.value.position >= currentClip.endTrim) {
              activeController.seekTo(currentClip.startTrim).then((_) {
                if (_isPlaying && mounted) activeController.play();
              });
            } else {
              activeController.play();
            }
          } else {
            activeController.play();
          }
        }
        final musicWindow = _bgMusicTrimmedDuration;
        if (musicWindow > Duration.zero) {
          final offset = _currentMergedPosition.inMilliseconds % musicWindow.inMilliseconds;
          _bgMusicPlayer?.seek(_bgMusicStartTrim + Duration(milliseconds: offset));
        } else {
          _bgMusicPlayer?.seek(_bgMusicStartTrim);
        }
        _bgMusicPlayer?.resume();
      } else {
        _pauseAllControllers();
      }
    });
  }

  void _pauseAllControllers() {
    for (final c in _controllers.values) {
      if (c.value.isPlaying) c.pause();
    }
    _bgMusicPlayer?.pause();
  }

  void _toggleMute() {
    setState(() {
      _isMuted = !_isMuted;
      final targetVolume = _isMuted ? 0.0 : (_videoVolume > 0 ? _videoVolume : 1.0);
      if (!_isMuted && _videoVolume == 0.0) {
        _videoVolume = 1.0;
      }
      for (final c in _controllers.values) {
        c.setVolume(targetVolume);
      }
    });
  }

  void _setVideoVolume(double volume) {
    setState(() {
      _videoVolume = volume.clamp(0.0, 1.0);
      _isMuted = (_videoVolume == 0.0);
      for (final c in _controllers.values) {
        c.setVolume(_isMuted ? 0.0 : _videoVolume);
      }
    });
  }

  void _setBgMusicVolume(double volume) {
    setState(() {
      _bgMusicVolume = volume.clamp(0.0, 1.0);
      _bgMusicPlayer?.setVolume(_bgMusicVolume);
    });
  }


  void _setMusicTrimRange(Duration start, Duration end, {bool immediate = false}) {
    setState(() {
      _bgMusicStartTrim = start;
      _bgMusicEndTrim = end;
    });
    final musicWindow = _bgMusicTrimmedDuration;
    final target = _isPlaying
        ? (_bgMusicStartTrim + ((musicWindow.inMilliseconds > 0)
            ? Duration(milliseconds: _currentMergedPosition.inMilliseconds % musicWindow.inMilliseconds)
            : Duration.zero))
        : _bgMusicStartTrim;
    if (immediate) {
      _musicSeekDebounceTimer?.cancel();
      _bgMusicPlayer?.seek(target);
    } else {
      _debouncedMusicSeek(target);
    }
  }

  void _alignMusicWithVideo() {
    if (_bgMusicTotalDuration <= Duration.zero || _totalMergedDuration <= Duration.zero) return;
    setState(() {
      final neededDur = _totalMergedDuration;
      if (_bgMusicStartTrim + neededDur <= _bgMusicTotalDuration) {
        _bgMusicEndTrim = _bgMusicStartTrim + neededDur;
      } else {
        _bgMusicStartTrim = Duration.zero;
        _bgMusicEndTrim = neededDur <= _bgMusicTotalDuration ? neededDur : _bgMusicTotalDuration;
      }
    });
    _setMusicTrimRange(_bgMusicStartTrim, _bgMusicEndTrim, immediate: true);
  }

  Future<void> _pickMusic() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['mp3', 'm4a', 'aac', 'wav', 'ogg', 'opus', 'flac', 'wma'],
      );
      if (result == null || result.files.single.path == null) return;

      final pickedFile = File(result.files.single.path!);
      final name = result.files.single.name;

      await _bgMusicPlayer?.stop();
      await _bgMusicPlayer?.dispose();

      final player = AudioPlayer();
      // Disable Android AudioFocus arbitration so AudioPlayer and VideoPlayer can play simultaneously!
      await player.setAudioContext(
        AudioContext(
          android: const AudioContextAndroid(
            isSpeakerphoneOn: false,
            stayAwake: false,
            contentType: AndroidContentType.music,
            usageType: AndroidUsageType.media,
            audioFocus: AndroidAudioFocus.none,
          ),
        ),
      );
      await player.setReleaseMode(ReleaseMode.loop);
      await player.setSource(DeviceFileSource(pickedFile.path));
      await player.setVolume(_bgMusicVolume);

      Duration musicDur = Duration.zero;
      try {
        final d = await player.getDuration();
        if (d != null && d > Duration.zero) {
          musicDur = d;
        }
      } catch (_) {}

      final defaultEnd = (musicDur > Duration.zero) ? musicDur : const Duration(seconds: 30);
      setState(() {
        _bgMusicFile = pickedFile;
        _bgMusicName = name;
        _bgMusicPlayer = player;
        _bgMusicTotalDuration = musicDur;
        _bgMusicStartTrim = Duration.zero;
        _bgMusicEndTrim = defaultEnd;
        _activeEditorTab = 1; // Direct user to the music trimming tab!
      });

      player.onDurationChanged.listen((d) {
        if (mounted && d > Duration.zero && _bgMusicTotalDuration != d) {
          setState(() {
            _bgMusicTotalDuration = d;
            if (_bgMusicEndTrim == Duration.zero || _bgMusicEndTrim > d) {
              _bgMusicEndTrim = d;
            }
          });
        }
      });

      if (_isPlaying) {
        await _bgMusicPlayer?.seek(_bgMusicStartTrim + _currentMergedPosition);
        await _bgMusicPlayer?.resume();
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.music_note_rounded, color: AppColors.accent, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Müzik eklendi: $name',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            backgroundColor: const Color(0xFF1F2C34),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      debugPrint('[PICK MUSIC ERR] $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Ses dosyası seçilirken hata oluştu: $e'),
            backgroundColor: AppColors.callRed,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _removeMusic() async {
    try {
      await _bgMusicPlayer?.stop();
      await _bgMusicPlayer?.dispose();
    } catch (_) {}

    setState(() {
      _bgMusicFile = null;
      _bgMusicName = null;
      _bgMusicPlayer = null;
      _bgMusicTotalDuration = Duration.zero;
      _bgMusicStartTrim = Duration.zero;
      _bgMusicEndTrim = Duration.zero;
      _activeEditorTab = 0;
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Arka plan müziği kaldırıldı.'),
          backgroundColor: AppColors.surfaceLight,
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Widget _buildPresetChip({
    required String label,
    required IconData icon,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isActive ? AppColors.accent : const Color(0xFF1F2C34),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isActive ? AppColors.accent : Colors.white24,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14,
              color: isActive ? Colors.white : Colors.white70,
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color: isActive ? Colors.white : Colors.white70,
                fontSize: 11.5,
                fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _selectClipForTrimming(int index) {
    setState(() {
      _selectedClipIndex = index;
      _playingClipIndex = index;
    });
    final controller = _controllers[index];
    if (controller != null && controller.value.isInitialized) {
      controller.seekTo(_clips[index].startTrim);
      if (_isPlaying) {
        controller.play();
      }
    }
  }

  Future<void> _pickAndAddVideo() async {
    try {
      final XFile? file = await _picker.pickVideo(
        source: ImageSource.gallery,
        maxDuration: const Duration(minutes: 5),
      );
      if (file == null) return;

      final tempController = VideoPlayerController.file(File(file.path));
      await tempController.initialize();
      final duration = tempController.value.duration;
      await tempController.dispose();

      final newClip = VideoClipItem(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        file: File(file.path),
        totalDuration: duration,
        startTrim: Duration.zero,
        endTrim: duration,
      );

      final newIndex = _clips.length;
      setState(() {
        _clips.add(newClip);
        _selectedClipIndex = newIndex;
        // Keep merged playback active from start
        _playingClipIndex = 0;
      });

      await _initAllControllers();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${_clips.length} video birleştirildi. Kesintisiz izlemek için oynatın.'),
            backgroundColor: AppColors.surfaceLight,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
            action: SnackBarAction(
              label: 'Baştan Oynat',
              textColor: AppColors.accent,
              onPressed: () {
                _seekMergedPosition(Duration.zero);
                if (!_isPlaying) _togglePlayPause();
              },
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint('[ADD VIDEO CLIP ERR] $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Video eklenirken bir hata oluştu.'),
            backgroundColor: AppColors.callRed,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  void _removeClip(int index) {
    if (_clips.length <= 1) return;

    final controller = _controllers.remove(index);
    controller?.pause();
    controller?.dispose();

    setState(() {
      _clips.removeAt(index);
      // Re-map controllers map keys
      final Map<int, VideoPlayerController> remapped = {};
      int newKey = 0;
      for (final c in _controllers.values) {
        remapped[newKey] = c;
        newKey++;
      }
      _controllers.clear();
      _controllers.addAll(remapped);

      if (_selectedClipIndex >= _clips.length) {
        _selectedClipIndex = _clips.length - 1;
      }
      if (_playingClipIndex >= _clips.length) {
        _playingClipIndex = 0;
      }
    });

    final currentController = _controllers[_playingClipIndex];
    if (currentController != null && currentController.value.isInitialized) {
      currentController.seekTo(_clips[_playingClipIndex].startTrim);
      if (_isPlaying) currentController.play();
    }
  }

  // --- EXPORT & MERGE (CRASH-PROOF, 720P STANDARDIZED, OVERLAYS & FILTERS) ---

  Future<void> _processAndExport() async {
    if (_isProcessing || _clips.isEmpty) return;

    setState(() {
      _isProcessing = true;
      _processingProgress = 0.0;
      _processingStatus = 'Hazırlanıyor...';
      _selectedOverlayId = null;
      _showFilterTray = false;
      _isDrawingMode = false;
    });

    try {
      // 1. Capture overlay RepaintBoundary to transparent PNG before controllers are disposed
      String? overlayPngPath;
      final bool hasOverlays = _overlays.isNotEmpty || _drawnStrokes.isNotEmpty;
      if (hasOverlays) {
        final boundary = _videoOverlayRepaintKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
        if (boundary != null) {
          final image = await boundary.toImage(pixelRatio: 2.0);
          final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
          if (byteData != null) {
            final bytes = byteData.buffer.asUint8List();
            final tempDir = await getTemporaryDirectory();
            overlayPngPath = p.join(tempDir.path, 'video_overlay_${DateTime.now().millisecondsSinceEpoch}.png');
            await File(overlayPngPath).writeAsBytes(bytes);
          }
        }
      }

      // 2. Pause and release active VideoPlayerControllers & audio player to free Android MediaCodec hardware slots
      _pauseAllControllers();
      await _bgMusicPlayer?.stop();
      for (final c in _controllers.values) {
        await c.pause();
        await c.dispose();
      }
      _controllers.clear();

      await Future.delayed(const Duration(milliseconds: 300));

      final bool hasMultiClips = _clips.length > 1;
      final bool hasTrims = _clips.any((c) =>
          c.startTrim > Duration.zero ||
          (c.totalDuration > Duration.zero && c.endTrim < c.totalDuration));
      final bool hasBgMusic = _bgMusicFile != null;
      final bool hasVolumeChange = _isMuted || _videoVolume != 1.0;
      final bool needsMerge = hasMultiClips || hasTrims || hasBgMusic || hasVolumeChange;

      String baseVideoPath = _clips[0].file.path;

      if (needsMerge) {
        setState(() {
          _processingStatus = _clips.length > 1
              ? '${_clips.length} video birleştiriliyor...'
              : 'Video işleniyor...';
          _processingProgress = 0.4;
        });

        final videoPaths = _clips.map((c) => c.file.path).toList();
        final Map<String, int> trimStarts = {};
        final Map<String, int> trimEnds = {};
        final Map<String, int> totalDurations = {};

        for (final clip in _clips) {
          trimStarts[clip.file.path] = clip.startTrim.inMilliseconds;
          trimEnds[clip.file.path] = clip.endTrim.inMilliseconds;
          totalDurations[clip.file.path] = clip.totalDuration.inMilliseconds;
        }

        // Call native crash-proof Media3 video processor
        String? resultPath;
        try {
          resultPath = await _nativeVideoChannel.invokeMethod<String>(
            'mergeAndProcessVideos',
            {
              'videoPaths': videoPaths,
              'isMuted': _isMuted || _videoVolume == 0.0,
              'videoVolume': _isMuted ? 0.0 : _videoVolume,
              'audioTrackPath': _bgMusicFile?.path,
              'audioTrackVolume': _bgMusicVolume,
              'audioTrackStartMs': _bgMusicStartTrim.inMilliseconds,
              'audioTrackEndMs': _bgMusicEndTrim.inMilliseconds,
              'trimStarts': trimStarts,
              'trimEnds': trimEnds,
              'totalDurations': totalDurations,
            },
          );
        } catch (nativeErr) {
          debugPrint('[NATIVE VIDEO PROCESSING ERR] $nativeErr');
          if (hasMultiClips) {
            rethrow;
          }
        }

        if (hasMultiClips && (resultPath == null || !File(resultPath).existsSync())) {
          throw Exception('Videolar birleştirilemedi.');
        }

        if (resultPath != null && File(resultPath).existsSync()) {
          baseVideoPath = resultPath;
        }
      }

      // 3. Apply Overlays (drawings, text, stickers, location) and Filters if present
      final bool hasFilter = _selectedFilterIndex != 0;
      if (hasOverlays || hasFilter) {
        setState(() {
          _processingStatus = 'Efektler ve çıkartmalar uygulanıyor...';
          _processingProgress = 0.75;
        });

        List<double>? colorMatrix16;
        if (hasFilter) {
          final rawMatrix = _filters[_selectedFilterIndex].matrix;
          if (rawMatrix != null && rawMatrix.length >= 20) {
            // Convert Flutter Skia 4x5 row-major to OpenGL 4x4 column-major:
            colorMatrix16 = [
              rawMatrix[0], rawMatrix[5], rawMatrix[10], 0.0,
              rawMatrix[1], rawMatrix[6], rawMatrix[11], 0.0,
              rawMatrix[2], rawMatrix[7], rawMatrix[12], 0.0,
              rawMatrix[4] / 255.0, rawMatrix[9] / 255.0, rawMatrix[14] / 255.0, 1.0,
            ];
          }
        }

        try {
          final String? overlaidPath = await _nativeVideoChannel.invokeMethod<String>(
            'applyOverlayToVideo',
            {
              'videoPath': baseVideoPath,
              'overlayPath': overlayPngPath,
              'colorMatrix': colorMatrix16,
            },
          );

          if (overlaidPath != null && File(overlaidPath).existsSync()) {
            baseVideoPath = overlaidPath;
          }
        } catch (burnErr) {
          debugPrint('[VIDEO OVERLAY BURN ERROR] $burnErr');
        }
      }

      setState(() {
        _processingProgress = 1.0;
        _processingStatus = 'Tamamlandı';
      });

      if (!mounted) return;

      Navigator.pop(
        context,
        VideoEditorResult(
          file: File(baseVideoPath),
          caption: _captionController.text.trim(),
        ),
      );
    } catch (e) {
      debugPrint('[VIDEO EXPORT CRASH PREVENTED] $e');
      if (mounted) {
        await _initAllControllers();
        if (!mounted) return;
        setState(() => _isProcessing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Video işlenirken bir hata oluştu: $e'),
            backgroundColor: AppColors.callRed,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedClip = (_clips.isNotEmpty && _selectedClipIndex < _clips.length)
        ? _clips[_selectedClipIndex]
        : null;

    final totalMerged = _totalMergedDuration;
    final currentMerged = _currentMergedPosition;
    final isInitialized = _clips.isNotEmpty &&
        _controllers.containsKey(_playingClipIndex) &&
        _controllers[_playingClipIndex]!.value.isInitialized;

    return PopScope(
      canPop: !_isDrawingMode,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _isDrawingMode) {
          _exitDrawingMode();
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0B1014),
        body: SafeArea(
          child: Stack(
            children: [
              Column(
                children: [
                  // 1. Sleek Glass Header Bar
                  _buildHeaderBar(currentMerged, totalMerged),

                  // 1.5 Drawing Toolbar (Thickness & Colors)
                  if (_isDrawingMode) _buildDrawingToolbar(),

                  // 2. Center Video Canvas Viewport (Rounded studio frame with overlays)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      child: Center(
                        child: isInitialized
                            ? _buildVideoCanvas(currentMerged, totalMerged)
                            : const Center(
                                child: CircularProgressIndicator(
                                  color: AppColors.accent,
                                  strokeWidth: 3,
                                ),
                              ),
                      ),
                    ),
                  ),

                  // Floating Size Slider when an overlay is selected and not in drawing mode
                  if (_selectedOverlay != null && !_isDrawingMode)
                    _buildFloatingSizeSlider(_selectedOverlay!),

                  // Filter Tray when toggled open
                  if (_showFilterTray && !_isDrawingMode)
                    _buildFilterTray(),

                  // Studio editing panels (hidden during drawing mode for clean full-canvas drawing)
                  if (!_isDrawingMode) ...[
                    // 3. Merged Timeline Scrubber
                    if (totalMerged.inMilliseconds > 0)
                      _buildMergedTimelineScrubber(currentMerged, totalMerged),

                    // 4. Studio Segmented Mode Switcher (Klip Kırp / Şarkı Kırp / Mikser)
                    _buildStudioTabBar(),

                    // 5. Active Tool Panel (Switches smoothly between tabs)
                    Container(
                      color: const Color(0xFF131D24),
                      constraints: const BoxConstraints(minHeight: 110),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        child: _buildActiveTabContent(selectedClip),
                      ),
                    ),

                    // 6. Multi-Video Clips Carousel
                    _buildClipsCarousel(),

                    // 7. Bottom Bar (Caption Input + Send FAB)
                    _buildBottomBar(),
                  ],
                ],
              ),

              // Fullscreen Processing Overlay
              if (_isProcessing) _buildProcessingOverlay(),
            ],
          ),
        ),
      ),
    );
  }

  // --- UI COMPONENT: HEADER BAR ---
  Widget _buildHeaderBar(Duration currentMerged, Duration totalMerged) {
    if (_isDrawingMode) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: const BoxDecoration(
          color: Color(0xFF0E161B),
          border: Border(bottom: BorderSide(color: Colors.white10)),
        ),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back_rounded, color: Colors.white, size: 24),
              tooltip: 'Geri',
              onPressed: _exitDrawingMode,
            ),
            const SizedBox(width: 4),
            const Text(
              'Kalem & Çizim',
              style: TextStyle(
                color: Colors.white,
                fontSize: 15.5,
                fontWeight: FontWeight.bold,
              ),
            ),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.undo_rounded, size: 22),
              color: _drawnStrokes.isNotEmpty ? Colors.white : Colors.white38,
              tooltip: 'Son Çizgiyi Geri Al',
              onPressed: _drawnStrokes.isNotEmpty ? _undoLastStroke : null,
            ),
            IconButton(
              icon: const Icon(Icons.delete_sweep_rounded, size: 22),
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
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: const BoxDecoration(
        color: Color(0xFF0E161B),
        border: Border(bottom: BorderSide(color: Colors.white10)),
      ),
      child: Row(
        children: [
          IconButton(
            padding: const EdgeInsets.all(6),
            constraints: const BoxConstraints(),
            icon: const Icon(Icons.close_rounded, color: Colors.white, size: 24),
            onPressed: () => Navigator.pop(context),
            tooltip: 'Kapat',
          ),
          const SizedBox(width: 6),
          // Mute Toggle Icon Button
          IconButton(
            padding: const EdgeInsets.all(6),
            constraints: const BoxConstraints(),
            icon: Icon(
              _isMuted || _videoVolume == 0.0
                  ? Icons.volume_off_rounded
                  : Icons.volume_up_rounded,
              color: (_isMuted || _videoVolume == 0.0) ? AppColors.callRed : Colors.white70,
              size: 21,
            ),
            tooltip: _isMuted ? 'Sesi Aç' : 'Sesi Kapat',
            onPressed: _toggleMute,
          ),
          if (_clips.length > 1) ...[
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${_selectedClipIndex + 1}/${_clips.length}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
          const SizedBox(width: 6),
          // Scrollable Action Tools (Reversed so tools expand nicely)
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              physics: const BouncingScrollPhysics(),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Pen & Drawing
                  _buildTopActionButton(
                    icon: Icons.edit_rounded,
                    color: _drawnStrokes.isNotEmpty ? AppColors.accent : Colors.white,
                    tooltip: 'Kalem & Çizim',
                    onPressed: _enterDrawingMode,
                  ),
                  // Emoji
                  _buildTopActionButton(
                    icon: Icons.sentiment_satisfied_alt_rounded,
                    color: Colors.white,
                    tooltip: 'Emoji / Çıkartma Ekle',
                    onPressed: _openEmojiSheet,
                  ),
                  // Text
                  _buildTopActionButton(
                    icon: Icons.title_rounded,
                    color: Colors.white,
                    tooltip: 'Yazı Ekle',
                    onPressed: () => _openTextDialog(),
                  ),
                  // Location
                  _buildTopActionButton(
                    icon: Icons.location_on_rounded,
                    color: Colors.white,
                    tooltip: 'Konum Ekle',
                    onPressed: _openLocationDialog,
                  ),
                  // Filters & Effects Toggle
                  _buildTopActionButton(
                    icon: Icons.auto_awesome_rounded,
                    color: _showFilterTray ? AppColors.accent : Colors.white,
                    tooltip: 'Filtreler & Efektler',
                    onPressed: () {
                      setState(() {
                        _showFilterTray = !_showFilterTray;
                        _selectedOverlayId = null;
                      });
                    },
                  ),
                  // Undo Overlay or Stroke
                  if (_overlays.isNotEmpty || _drawnStrokes.isNotEmpty)
                    _buildTopActionButton(
                      icon: Icons.undo_rounded,
                      color: Colors.white,
                      tooltip: 'Geri Al',
                      onPressed: _undoLastOverlayOrStroke,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- UI COMPONENT: DRAWING TOOLBAR ---
  Widget _buildDrawingToolbar() {
    return Container(
      color: const Color(0xFF141D22),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
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
          SizedBox(
            height: 36,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _drawColors.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, idx) {
                final color = _drawColors[idx];
                final bool isSel = (_selectedDrawColor == color);
                return GestureDetector(
                  onTap: () {
                    setState(() => _selectedDrawColor = color);
                  },
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isSel ? Colors.white : Colors.white24,
                        width: isSel ? 2.5 : 1.0,
                      ),
                      boxShadow: isSel
                          ? [
                              BoxShadow(
                                color: color.withValues(alpha: 0.6),
                                blurRadius: 6,
                                spreadRadius: 1,
                              ),
                            ]
                          : null,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
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
          color: isSel ? AppColors.accent.withValues(alpha: 0.25) : const Color(0xFF1F2C34),
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

  // --- UI COMPONENT: FILTER TRAY ---
  Widget _buildFilterTray() {
    return Container(
      height: 82,
      color: Colors.black.withValues(alpha: 0.85),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: _filters.length,
        itemBuilder: (context, idx) {
          final f = _filters[idx];
          final isSel = idx == _selectedFilterIndex;
          return GestureDetector(
            onTap: () {
              setState(() {
                _selectedFilterIndex = idx;
              });
            },
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isSel ? AppColors.accent : Colors.transparent,
                        width: 2,
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: SizedBox(
                        width: 48,
                        height: 48,
                        child: f.matrix != null
                            ? ColorFiltered(
                                colorFilter: ColorFilter.matrix(f.matrix!),
                                child: _buildFilterThumbnailChild(),
                              )
                            : _buildFilterThumbnailChild(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    f.name,
                    style: TextStyle(
                      color: isSel ? AppColors.accent : Colors.white70,
                      fontSize: 10.5,
                      fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildFilterThumbnailChild() {
    final activeController = _controllers[_playingClipIndex];
    if (activeController != null && activeController.value.isInitialized) {
      return FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: activeController.value.size.width > 0 ? activeController.value.size.width : 100,
          height: activeController.value.size.height > 0 ? activeController.value.size.height : 100,
          child: VideoPlayer(activeController),
        ),
      );
    }
    return Container(
      color: const Color(0xFF1B2831),
      child: const Center(
        child: Icon(Icons.movie_filter_rounded, color: Colors.white70, size: 20),
      ),
    );
  }

  Widget _buildTopActionButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    Color color = Colors.white,
    double size = 22,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          child: Icon(icon, color: color, size: size),
        ),
      ),
    );
  }

  // --- UI COMPONENT: VIDEO CANVAS VIEWPORT ---
  Widget _buildVideoCanvas(Duration currentMerged, Duration totalMerged) {
    final activeController = _controllers[_playingClipIndex];
    if (activeController == null || !activeController.value.isInitialized) {
      return const SizedBox.shrink();
    }

    final selectedFilter = _filters[_selectedFilterIndex];

    Widget videoPlayerWidget = AspectRatio(
      aspectRatio: activeController.value.aspectRatio > 0
          ? activeController.value.aspectRatio
          : 16 / 9,
      child: VideoPlayer(activeController),
    );

    if (selectedFilter.matrix != null) {
      videoPlayerWidget = ColorFiltered(
        colorFilter: ColorFilter.matrix(selectedFilter.matrix!),
        child: videoPlayerWidget,
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.8),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (_isDrawingMode) return;
          if (_selectedOverlayId != null) {
            setState(() => _selectedOverlayId = null);
          } else {
            _togglePlayPause();
          }
        },
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Video Player with Filter applied
            videoPlayerWidget,

            // Overlays & Drawings in a dedicated transparent RepaintBoundary for video overlay capture
            Positioned.fill(
              child: RepaintBoundary(
                key: _videoOverlayRepaintKey,
                child: Stack(
                  children: [
                    ..._overlays.map((item) => _buildOverlayWidget(item)),
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
                  ],
                ),
              ),
            ),

            // Drawing Gesture Detector (when in drawing mode)
            if (_isDrawingMode)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (details) {
                    final Color strokeColor = _isHighlighter
                        ? _selectedDrawColor.withValues(alpha: 0.45)
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
                      });
                    }
                  },
                ),
              ),

            // Play / Pause Glass Overlay (hidden when playing or drawing)
            if (!_isDrawingMode)
              IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _isPlaying ? 0.0 : 0.9,
                  duration: const Duration(milliseconds: 200),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white30, width: 2),
                    ),
                    child: const Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 44,
                    ),
                  ),
                ),
              ),

            // Floating Top Overlay (Clip Tag & Music Pill)
            if (!_isDrawingMode)
              Positioned(
                top: 10,
                left: 10,
                right: 10,
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.75),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: AppColors.accent.withValues(alpha: 0.5)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.auto_awesome_motion_rounded,
                              color: AppColors.accent, size: 13),
                          const SizedBox(width: 5),
                          Text(
                            _clips.length > 1
                                ? 'Klip ${_playingClipIndex + 1}/${_clips.length}'
                                : 'Önizleme',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    // Floating Music Badge (Tap opens song trim tab)
                    GestureDetector(
                      onTap: () {
                        if (_bgMusicFile == null) {
                          _pickMusic();
                        } else {
                          setState(() => _activeEditorTab = 1);
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: _bgMusicFile != null
                              ? AppColors.accent.withValues(alpha: 0.92)
                              : Colors.black.withValues(alpha: 0.75),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: AppColors.accent,
                            width: 1.2,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.accent.withValues(alpha: 0.35),
                              blurRadius: 6,
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _bgMusicFile != null
                                  ? Icons.audiotrack_rounded
                                  : Icons.library_music_rounded,
                              color: _bgMusicFile != null ? Colors.white : AppColors.accent,
                              size: 13,
                            ),
                            const SizedBox(width: 5),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 110),
                              child: Text(
                                _bgMusicFile != null
                                    ? (_bgMusicName ?? 'Müzik')
                                    : '🎵 + Müzik Ekle',
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            // Floating Bottom Overlay (Quick Replay Button)
            if (!_isDrawingMode)
              Positioned(
                bottom: 10,
                right: 10,
                child: GestureDetector(
                  onTap: () {
                    _seekMergedPosition(Duration.zero);
                    if (!_isPlaying) _togglePlayPause();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.75),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.replay_rounded, color: AppColors.accent, size: 14),
                        SizedBox(width: 4),
                        Text(
                          'Baştan',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
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
    );
  }

  // --- UI COMPONENT: FLOATING SIZE SLIDER ---
  Widget _buildFloatingSizeSlider(OverlayItem selectedItem) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF1F2C34).withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.5), width: 1.2),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 8, offset: const Offset(0, 3)),
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
                color: Colors.white12,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check, color: Colors.white, size: 16),
            ),
          ),
        ],
      ),
    );
  }

  // --- UI COMPONENT: OVERLAY WIDGET (DRAG, ROTATE, PINCH-TO-ZOOM, EDIT & DELETE) ---
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
            colors: [
              Colors.black.withValues(alpha: 0.75),
              const Color(0xFF1F2C34).withValues(alpha: 0.85),
            ],
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.callRed.withValues(alpha: 0.8), width: 1.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
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
            item.position += details.focalPointDelta;
            if (details.scale != 1.0) {
              item.scale = (_activeOverlayBaseScale * details.scale).clamp(0.4, 4.0);
            }
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

  // --- UI COMPONENT: MERGED TIMELINE SCRUBBER ---
  Widget _buildMergedTimelineScrubber(Duration currentMerged, Duration totalMerged) {
    return Container(
      color: const Color(0xFF0F171B),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      child: Row(
        children: [
          Text(
            _formatDuration(currentMerged),
            style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: AppColors.accent,
                inactiveTrackColor: Colors.white12,
                thumbColor: AppColors.accent,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                trackHeight: 3,
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              ),
              child: Slider(
                min: 0.0,
                max: totalMerged.inMilliseconds.toDouble(),
                value: currentMerged.inMilliseconds
                    .toDouble()
                    .clamp(0.0, totalMerged.inMilliseconds.toDouble()),
                onChanged: (val) {
                  _seekMergedPosition(Duration(milliseconds: val.toInt()));
                },
              ),
            ),
          ),
          Text(
            _formatDuration(totalMerged),
            style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  // --- UI COMPONENT: STUDIO SEGMENTED MODE SWITCHER ---
  Widget _buildStudioTabBar() {
    return Container(
      color: const Color(0xFF101920),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: _buildStudioTabItem(
              tabIndex: 0,
              icon: Icons.content_cut_rounded,
              label: 'Klip Kırp',
              badgeText: null,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _buildStudioTabItem(
              tabIndex: 1,
              icon: Icons.music_note_rounded,
              label: 'Şarkı Kırp',
              badgeText: _bgMusicFile != null ? 'Aktif' : null,
              hasHighlight: _bgMusicFile != null,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _buildStudioTabItem(
              tabIndex: 2,
              icon: Icons.tune_rounded,
              label: 'Ses Mikseri',
              badgeText: null,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStudioTabItem({
    required int tabIndex,
    required IconData icon,
    required String label,
    String? badgeText,
    bool hasHighlight = false,
  }) {
    final isSelected = _activeEditorTab == tabIndex;
    return GestureDetector(
      onTap: () {
        setState(() => _activeEditorTab = tabIndex);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.accent.withValues(alpha: 0.2)
              : const Color(0xFF18232B),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected
                ? AppColors.accent
                : (hasHighlight ? AppColors.accent.withValues(alpha: 0.4) : Colors.white12),
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 15,
              color: isSelected ? AppColors.accent : (hasHighlight ? AppColors.accent : Colors.white70),
            ),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isSelected ? Colors.white : Colors.white70,
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                ),
              ),
            ),
            if (badgeText != null) ...[
              const SizedBox(width: 5),
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  color: AppColors.accent,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // --- ACTIVE TAB CONTENT DISPATCHER ---
  Widget _buildActiveTabContent(VideoClipItem? selectedClip) {
    switch (_activeEditorTab) {
      case 0:
        return _buildVideoTrimmingPanel(selectedClip);
      case 1:
        return _buildMusicTrimmingPanel();
      case 2:
        return _buildAudioMixerPanel();
      default:
        return _buildVideoTrimmingPanel(selectedClip);
    }
  }

  // --- TAB 0: VIDEO TRIMMING PANEL (DUAL RANGE SLIDER) ---
  Widget _buildVideoTrimmingPanel(VideoClipItem? selectedClip) {
    if (selectedClip == null || selectedClip.totalDuration <= Duration.zero) {
      return const SizedBox(
        height: 110,
        child: Center(
          child: Text('Kırpılacak klip bulunamadı.', style: TextStyle(color: Colors.white54)),
        ),
      );
    }

    final maxDur = selectedClip.totalDuration.inMilliseconds.toDouble();
    final startVal = selectedClip.startTrim.inMilliseconds
        .toDouble()
        .clamp(0.0, maxDur > 0 ? maxDur : 1.0);
    final endVal = selectedClip.endTrim.inMilliseconds
        .toDouble()
        .clamp(startVal, maxDur > 0 ? maxDur : 1.0);

    return Container(
      key: const ValueKey('tab_video_trim'),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Row(
                  children: [
                    const Icon(Icons.content_cut_rounded, color: AppColors.accent, size: 15),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        'Klip ${_selectedClipIndex + 1}:',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.accent.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.accent.withValues(alpha: 0.4)),
                    ),
                    child: Text(
                      '${_formatDuration(selectedClip.startTrim)} - ${_formatDuration(selectedClip.endTrim)} (${_formatDuration(selectedClip.trimmedDuration)})',
                      style: const TextStyle(
                        color: AppColors.accent,
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        selectedClip.startTrim = Duration.zero;
                        selectedClip.endTrim = selectedClip.totalDuration;
                      });
                      _debouncedVideoSeek(_selectedClipIndex, Duration.zero);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.white12,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        'Sıfırla',
                        style: TextStyle(color: Colors.white70, fontSize: 10.5, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 6),
          // RangeSlider with filmstrip track design
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: AppColors.accent,
              inactiveTrackColor: Colors.white24,
              thumbColor: Colors.white,
              rangeThumbShape: const RoundRangeSliderThumbShape(enabledThumbRadius: 8),
              trackHeight: 5,
              overlayColor: AppColors.accent.withValues(alpha: 0.25),
            ),
            child: RangeSlider(
              min: 0.0,
              max: maxDur > 0 ? maxDur : 1.0,
              values: RangeValues(startVal, endVal),
              onChanged: (RangeValues values) {
                setState(() {
                  selectedClip.startTrim = Duration(milliseconds: values.start.toInt());
                  selectedClip.endTrim = Duration(milliseconds: values.end.toInt());
                });
                if (_playingClipIndex == _selectedClipIndex) {
                  _debouncedVideoSeek(_selectedClipIndex, selectedClip.startTrim);
                }
              },
              onChangeEnd: (RangeValues values) {
                if (_playingClipIndex == _selectedClipIndex) {
                  _videoSeekDebounceTimer?.cancel();
                  _controllers[_selectedClipIndex]?.seekTo(selectedClip.startTrim);
                  final musicWindow = _bgMusicTrimmedDuration;
                  if (musicWindow > Duration.zero) {
                    _bgMusicPlayer?.seek(
                      _bgMusicStartTrim + Duration(
                        milliseconds: _currentMergedPosition.inMilliseconds % musicWindow.inMilliseconds,
                      ),
                    );
                  }
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  // --- TAB 1: MUSIC TRIMMING PANEL (DUAL HANDLE RANGE SLIDER + WAVEFORM) ---
  Widget _buildMusicTrimmingPanel() {
    if (_bgMusicFile == null) {
      return Container(
        key: const ValueKey('tab_music_empty'),
        padding: const EdgeInsets.all(14),
        child: GestureDetector(
          onTap: _pickMusic,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
            decoration: BoxDecoration(
              color: AppColors.accent.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: AppColors.accent.withValues(alpha: 0.6),
                width: 1.2,
              ),
            ),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.library_music_rounded, color: AppColors.accent, size: 22),
                SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '➕ Arka Plan Şarkısı / Ses Parçası Ekle',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'MP3 veya ses seçip baştan ve sondan dilediğiniz gibi kırpın.',
                      style: TextStyle(color: Colors.white54, fontSize: 11),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    final maxMusicDur = _bgMusicTotalDuration.inMilliseconds.toDouble();
    final effectiveMax = maxMusicDur > 0 ? maxMusicDur : 30000.0;
    final startMs = _bgMusicStartTrim.inMilliseconds.toDouble().clamp(0.0, effectiveMax);
    final endMs = (_bgMusicEndTrim > Duration.zero ? _bgMusicEndTrim.inMilliseconds.toDouble() : effectiveMax)
        .clamp(startMs, effectiveMax);

    return Container(
      key: const ValueKey('tab_music_trim_active'),
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header: Song name, duration, Change & Remove buttons
          Row(
            children: [
              const Icon(Icons.audiotrack_rounded, color: AppColors.accent, size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _bgMusicName ?? 'Müzik Parçası',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 12.5,
                  ),
                ),
              ),
              // Videoyla Eşitle Button
              GestureDetector(
                onTap: _alignMusicWithVideo,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.accent.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.accent.withValues(alpha: 0.5)),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.auto_fix_high_rounded, color: AppColors.accent, size: 12),
                      SizedBox(width: 4),
                      Text(
                        'Videoyla Eşitle',
                        style: TextStyle(
                          color: AppColors.accent,
                          fontSize: 10.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),
              // Change song
              GestureDetector(
                onTap: _pickMusic,
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.swap_horiz_rounded, color: Colors.white70, size: 19),
                ),
              ),
              // Delete song
              GestureDetector(
                onTap: _removeMusic,
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.delete_outline_rounded, color: AppColors.callRed, size: 19),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),

          // Simulated Audio Waveform Bar Visualizer
          _buildSimulatedWaveform(
            total: _bgMusicTotalDuration > Duration.zero ? _bgMusicTotalDuration : const Duration(seconds: 30),
            start: _bgMusicStartTrim,
            end: _bgMusicEndTrim > _bgMusicStartTrim ? _bgMusicEndTrim : _bgMusicTotalDuration,
          ),

          // DUAL HANDLE RANGE SLIDER (TRIM FROM BOTH START & END)
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: AppColors.accent,
              inactiveTrackColor: Colors.white24,
              thumbColor: Colors.white,
              rangeThumbShape: const RoundRangeSliderThumbShape(enabledThumbRadius: 8),
              trackHeight: 4,
              overlayColor: AppColors.accent.withValues(alpha: 0.2),
            ),
            child: RangeSlider(
              min: 0.0,
              max: effectiveMax,
              values: RangeValues(startMs, endMs),
              onChanged: (RangeValues values) {
                _setMusicTrimRange(
                  Duration(milliseconds: values.start.toInt()),
                  Duration(milliseconds: values.end.toInt()),
                  immediate: false,
                );
              },
              onChangeEnd: (RangeValues values) {
                _setMusicTrimRange(
                  Duration(milliseconds: values.start.toInt()),
                  Duration(milliseconds: values.end.toInt()),
                  immediate: true,
                );
              },
            ),
          ),

          // Range Duration Info Bar
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Başlangıç: ${_formatDuration(_bgMusicStartTrim)}',
                style: const TextStyle(color: Colors.white70, fontSize: 10.5, fontWeight: FontWeight.bold),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'Kırpılan: ${_formatDuration(_bgMusicTrimmedDuration)}',
                  style: const TextStyle(color: AppColors.accent, fontSize: 10.5, fontWeight: FontWeight.bold),
                ),
              ),
              Text(
                'Bitiş: ${_formatDuration(_bgMusicEndTrim > Duration.zero ? _bgMusicEndTrim : _bgMusicTotalDuration)}',
                style: const TextStyle(color: Colors.white70, fontSize: 10.5, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // Waveform Bar Graphic Visualizer
  Widget _buildSimulatedWaveform({
    required Duration total,
    required Duration start,
    required Duration end,
  }) {
    const int barCount = 38;
    const List<double> wavePattern = [
      0.3, 0.5, 0.8, 0.4, 0.9, 0.6, 0.7, 1.0, 0.85, 0.45, 0.75, 0.95,
      0.65, 0.5, 0.8, 0.9, 0.35, 0.6, 0.75, 1.0, 0.8, 0.55, 0.7, 0.9,
      0.4, 0.65, 0.85, 0.7, 0.5, 0.95, 0.8, 0.6, 0.45, 0.75, 0.9, 0.6, 0.4, 0.7
    ];

    final totalMs = total.inMilliseconds > 0 ? total.inMilliseconds : 1;
    final startRatio = (start.inMilliseconds / totalMs).clamp(0.0, 1.0);
    final endRatio = (end.inMilliseconds / totalMs).clamp(startRatio, 1.0);

    return Container(
      height: 24,
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: List.generate(barCount, (idx) {
          final barRatio = idx / (barCount - 1);
          final inRange = barRatio >= startRatio && barRatio <= endRatio;
          final heightFactor = wavePattern[idx % wavePattern.length];
          return Container(
            width: 3,
            height: (heightFactor * 22).clamp(4.0, 22.0),
            decoration: BoxDecoration(
              color: inRange ? AppColors.accent : Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          );
        }),
      ),
    );
  }

  // --- TAB 2: AUDIO MIXER PANEL (PRESETS & DUAL FADERS) ---
  Widget _buildAudioMixerPanel() {
    return Container(
      key: const ValueKey('tab_mixer'),
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Quick Presets Row
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildPresetChip(
                  label: 'Orijinal Video',
                  icon: Icons.videocam_rounded,
                  isActive: !_isMuted && _videoVolume == 1.0 && (_bgMusicFile == null || _bgMusicVolume == 0.0),
                  onTap: () {
                    _setVideoVolume(1.0);
                    _setBgMusicVolume(0.0);
                  },
                ),
                const SizedBox(width: 8),
                _buildPresetChip(
                  label: 'Dengeli (%50 / %50)',
                  icon: Icons.balance_rounded,
                  isActive: !_isMuted && _videoVolume == 0.5 && _bgMusicVolume == 0.5,
                  onTap: () {
                    _setVideoVolume(0.5);
                    _setBgMusicVolume(0.5);
                  },
                ),
                const SizedBox(width: 8),
                _buildPresetChip(
                  label: 'Müzik %85',
                  icon: Icons.music_note_rounded,
                  isActive: _videoVolume <= 0.2 && _bgMusicVolume >= 0.8,
                  onTap: () {
                    _setVideoVolume(0.15);
                    _setBgMusicVolume(0.85);
                  },
                ),
                const SizedBox(width: 8),
                _buildPresetChip(
                  label: 'Sessiz Video',
                  icon: Icons.volume_off_rounded,
                  isActive: _isMuted || _videoVolume == 0.0,
                  onTap: () {
                    _setVideoVolume(0.0);
                    _setBgMusicVolume(1.0);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),

          // Fader 1: Original Video Volume
          Row(
            children: [
              GestureDetector(
                onTap: _toggleMute,
                child: Icon(
                  _isMuted || _videoVolume == 0.0
                      ? Icons.volume_off_rounded
                      : Icons.videocam_rounded,
                  color: _isMuted || _videoVolume == 0.0
                      ? AppColors.callRed
                      : AppColors.accent,
                  size: 18,
                ),
              ),
              const SizedBox(width: 6),
              const Text(
                'Video Sesi:',
                style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: AppColors.accent,
                    inactiveTrackColor: Colors.white24,
                    thumbColor: AppColors.accent,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                    trackHeight: 3,
                  ),
                  child: Slider(
                    min: 0.0,
                    max: 1.0,
                    value: _isMuted ? 0.0 : _videoVolume,
                    onChanged: (val) {
                      _setVideoVolume(val);
                    },
                  ),
                ),
              ),
              Text(
                _isMuted || _videoVolume == 0.0 ? 'Sessiz' : '%${(_videoVolume * 100).round()}',
                style: TextStyle(
                  color: _isMuted || _videoVolume == 0.0 ? AppColors.callRed : AppColors.accent,
                  fontSize: 10.5,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),

          // Fader 2: Background Music Volume
          Row(
            children: [
              Icon(
                Icons.music_note_rounded,
                color: _bgMusicFile != null ? AppColors.accent : Colors.white30,
                size: 18,
              ),
              const SizedBox(width: 6),
              const Text(
                'Müzik Sesi:',
                style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold),
              ),
              Expanded(
                child: _bgMusicFile != null
                    ? SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          activeTrackColor: AppColors.accent,
                          inactiveTrackColor: Colors.white24,
                          thumbColor: AppColors.accent,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                          trackHeight: 3,
                        ),
                        child: Slider(
                          min: 0.0,
                          max: 1.0,
                          value: _bgMusicVolume,
                          onChanged: (val) {
                            _setBgMusicVolume(val);
                          },
                        ),
                      )
                    : Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: GestureDetector(
                          onTap: _pickMusic,
                          child: const Text(
                            '+ Müzik ekleyin',
                            style: TextStyle(color: AppColors.accent, fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
              ),
              if (_bgMusicFile != null)
                Text(
                  '%${(_bgMusicVolume * 100).round()}',
                  style: const TextStyle(
                    color: AppColors.accent,
                    fontSize: 10.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  // --- UI COMPONENT: MULTI-VIDEO CLIPS CAROUSEL ---
  Widget _buildClipsCarousel() {
    return Container(
      color: const Color(0xFF162027),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Icon(Icons.layers_rounded, color: AppColors.accent, size: 15),
                  const SizedBox(width: 6),
                  Text(
                    'Birleştirilen Klipler (${_clips.length})',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              Text(
                _clips.length > 1 ? '▶ Sıralı Kesintisiz Oynatma' : 'Tek Klip',
                style: const TextStyle(color: AppColors.accent, fontSize: 10.5, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 56,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _clips.length + 1,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, idx) {
                // Add Clip Card
                if (idx == _clips.length) {
                  return GestureDetector(
                    onTap: _pickAndAddVideo,
                    child: Container(
                      width: 84,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1B2730),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: AppColors.accent.withValues(alpha: 0.6),
                          width: 1.2,
                        ),
                      ),
                      child: const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.add_circle_outline_rounded,
                              color: AppColors.accent, size: 18),
                          SizedBox(height: 2),
                          Text(
                            '+ Video Ekle',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 10.5,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }

                final clip = _clips[idx];
                final isCurrentPlaying = (idx == _playingClipIndex);
                final isCurrentSelected = (idx == _selectedClipIndex);

                return GestureDetector(
                  onTap: () => _selectClipForTrimming(idx),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        width: 84,
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                        decoration: BoxDecoration(
                          color: isCurrentSelected
                              ? const Color(0xFF243642)
                              : const Color(0xFF1B2730),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: isCurrentPlaying
                                ? AppColors.accent
                                : (isCurrentSelected ? Colors.white60 : Colors.white12),
                            width: isCurrentPlaying ? 2 : 1,
                          ),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                if (isCurrentPlaying && _isPlaying)
                                  const Icon(Icons.play_arrow_rounded,
                                      color: AppColors.accent, size: 12),
                                Text(
                                  'Klip ${idx + 1}',
                                  style: TextStyle(
                                    color: isCurrentPlaying ? AppColors.accent : Colors.white,
                                    fontWeight: isCurrentPlaying || isCurrentSelected
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _formatDuration(clip.trimmedDuration),
                              style: TextStyle(
                                color: isCurrentPlaying ? AppColors.accent : Colors.white70,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Delete Clip Badge (if > 1 clip)
                      if (_clips.length > 1)
                        Positioned(
                          top: -5,
                          right: -5,
                          child: GestureDetector(
                            onTap: () => _removeClip(idx),
                            child: Container(
                              padding: const EdgeInsets.all(3),
                              decoration: const BoxDecoration(
                                color: AppColors.callRed,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.close, color: Colors.white, size: 11),
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // --- UI COMPONENT: BOTTOM ACTION BAR ---
  Widget _buildBottomBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      color: const Color(0xFF0C1318),
      child: Row(
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF1B2730),
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
                      style: const TextStyle(color: Colors.white, fontSize: 13.5),
                      decoration: const InputDecoration(
                        hintText: 'Bir başlık ekleyin...',
                        hintStyle: TextStyle(color: Colors.white54, fontSize: 13.5),
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          // Send Glowing FAB
          GestureDetector(
            onTap: _isProcessing ? null : _processAndExport,
            child: Container(
              width: 46,
              height: 46,
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
                child: _isProcessing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.send_rounded, color: Colors.white, size: 20),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- UI COMPONENT: PROCESSING OVERLAY ---
  Widget _buildProcessingOverlay() {
    return Container(
      color: Colors.black87,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          margin: const EdgeInsets.symmetric(horizontal: 32),
          decoration: BoxDecoration(
            color: const Color(0xFF1B2730),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppColors.accent.withValues(alpha: 0.4)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.6),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 44,
                height: 44,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: AppColors.accent,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                _processingStatus,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: _processingProgress.clamp(0.0, 1.0),
                  backgroundColor: Colors.white12,
                  valueColor: const AlwaysStoppedAnimation<Color>(AppColors.accent),
                  minHeight: 6,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '%${(_processingProgress * 100).round()}',
                style: const TextStyle(
                  color: AppColors.accent,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
