import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../../../constants/app_colors.dart';
import '../../../models/user_model.dart';
import '../../../services/custom_auth_service.dart';
import '../../../services/custom_chat_service.dart';

class TextStoryCreator extends StatefulWidget {
  final UserModel currentUser;

  const TextStoryCreator({super.key, required this.currentUser});

  @override
  State<TextStoryCreator> createState() => _TextStoryCreatorState();
}

class _TextStoryCreatorState extends State<TextStoryCreator> {
  final TextEditingController _textController = TextEditingController();
  final GlobalKey _repaintKey = GlobalKey();
  final CustomChatService _chatService = CustomChatService();
  bool _isLoading = false;

  int _selectedGradientIndex = 0;
  int _selectedFontIndex = 0;
  TextAlign _textAlign = TextAlign.center;

  final List<List<Color>> _gradients = [
    [const Color(0xFF8A2387), const Color(0xFFE94057), const Color(0xFFF27121)], // Sunset Fusion
    [const Color(0xFF00c6ff), const Color(0xFF0072ff)], // Ocean Cyan
    [const Color(0xFF11998e), const Color(0xFF38ef7d)], // Emerald Mint
    [const Color(0xFFFF512F), const Color(0xFFDD2476)], // Crimson Flame
    [const Color(0xFF7F00FF), const Color(0xFFE100FF)], // Neon Purple
    [const Color(0xFF1a2a6c), const Color(0xFFb21f1f), const Color(0xFFfdbb2d)], // Solar Fire
    [const Color(0xFF232526), const Color(0xFF414345)], // Obsidian Dark
  ];

  final List<String> _fontNames = ['Varsayılan', 'Serif', 'Modern', 'El Yazısı'];

  TextStyle _getFontStyle() {
    switch (_selectedFontIndex) {
      case 1:
        return GoogleFonts.lora(
          color: Colors.white,
          fontSize: _calculateFontSize(),
          fontWeight: FontWeight.w600,
        );
      case 2:
        return GoogleFonts.spaceMono(
          color: Colors.white,
          fontSize: _calculateFontSize(),
          fontWeight: FontWeight.bold,
        );
      case 3:
        return GoogleFonts.caveat(
          color: Colors.white,
          fontSize: _calculateFontSize() + 8,
          fontWeight: FontWeight.bold,
        );
      default:
        return GoogleFonts.poppins(
          color: Colors.white,
          fontSize: _calculateFontSize(),
          fontWeight: FontWeight.bold,
        );
    }
  }

  double _calculateFontSize() {
    final len = _textController.text.length;
    if (len < 20) return 36.0;
    if (len < 60) return 30.0;
    if (len < 120) return 24.0;
    return 20.0;
  }

  void _cycleGradient() {
    setState(() {
      _selectedGradientIndex = (_selectedGradientIndex + 1) % _gradients.length;
    });
  }

  void _cycleFont() {
    setState(() {
      _selectedFontIndex = (_selectedFontIndex + 1) % _fontNames.length;
    });
  }

  void _cycleAlign() {
    setState(() {
      if (_textAlign == TextAlign.center) {
        _textAlign = TextAlign.left;
      } else if (_textAlign == TextAlign.left) {
        _textAlign = TextAlign.right;
      } else {
        _textAlign = TextAlign.center;
      }
    });
  }

  Future<void> _publishTextStory() async {
    final text = _textController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Lütfen bir metin yazın.'),
          backgroundColor: AppColors.callRed,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      // 1. Convert RepaintBoundary to image
      final boundary = _repaintKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) throw Exception('Görsel oluşturulamadı');

      final ui.Image image = await boundary.toImage(pixelRatio: 2.5);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) throw Exception('Bayt verisi alınamadı');

      final pngBytes = byteData.buffer.asUint8List();
      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/text_story_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(pngBytes, flush: true);

      // 2. Upload file
      final authService = Provider.of<CustomAuthService>(context, listen: false);
      final uploadedUrl = await authService.uploadImage(file.path);

      if (uploadedUrl == null) {
        throw Exception('Görsel sunucuya yüklenemedi');
      }

      // 3. Create story
      final myUid = int.tryParse(widget.currentUser.uid) ?? 0;
      final success = await _chatService.createStory(
        userId: myUid,
        mediaUrl: uploadedUrl,
        caption: text,
        mediaType: 'text',
      );

      if (!mounted) return;

      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Metin durumu başarıyla paylaşıldı!'),
            backgroundColor: AppColors.primaryLight,
            behavior: SnackBarBehavior.floating,
          ),
        );
        Navigator.pop(context, true);
      } else {
        throw Exception('Durum sunucuya kaydedilemedi');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Hata: $e'),
            backgroundColor: AppColors.callRed,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentGradient = _gradients[_selectedGradientIndex];

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Captured Canvas
          RepaintBoundary(
            key: _repaintKey,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: currentGradient,
                ),
              ),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: TextField(
                    controller: _textController,
                    style: _getFontStyle(),
                    textAlign: _textAlign,
                    maxLines: null,
                    autofocus: true,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: 'Bir durum yazın...',
                      hintStyle: _getFontStyle().copyWith(color: Colors.white54),
                      border: InputBorder.none,
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Top Action Toolbar
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.close_rounded, color: Colors.white, size: 28),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const Spacer(),
                    // Color Palette Button
                    IconButton(
                      icon: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white70, width: 2),
                        ),
                        child: const Icon(Icons.palette_rounded, color: Colors.white, size: 20),
                      ),
                      tooltip: 'Renk Değiştir',
                      onPressed: _cycleGradient,
                    ),
                    // Font Switcher Button
                    IconButton(
                      icon: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          _fontNames[_selectedFontIndex],
                          style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                      ),
                      tooltip: 'Yazı Tipi',
                      onPressed: _cycleFont,
                    ),
                    // Align Switcher
                    IconButton(
                      icon: Icon(
                        _textAlign == TextAlign.center
                            ? Icons.format_align_center_rounded
                            : (_textAlign == TextAlign.left
                                ? Icons.format_align_left_rounded
                                : Icons.format_align_right_rounded),
                        color: Colors.white,
                        size: 22,
                      ),
                      tooltip: 'Hizala',
                      onPressed: _cycleAlign,
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Bottom Send Button
          Positioned(
            bottom: 24,
            right: 20,
            child: SafeArea(
              child: FloatingActionButton(
                backgroundColor: AppColors.primaryLight,
                onPressed: _isLoading ? null : _publishTextStory,
                child: _isLoading
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                      )
                    : const Icon(Icons.send_rounded, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
