import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../../../constants/app_colors.dart';
import '../../../services/encryption_service.dart';

class DecryptedImageWidget extends StatefulWidget {
  final String imageUrl;
  final String senderId;
  final String receiverId;
  final double? width;
  final double? height;
  final BoxFit fit;

  const DecryptedImageWidget({
    super.key,
    required this.imageUrl,
    required this.senderId,
    required this.receiverId,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
  });

  @override
  State<DecryptedImageWidget> createState() => _DecryptedImageWidgetState();
}

class _DecryptedImageWidgetState extends State<DecryptedImageWidget> {
  static final Map<String, Uint8List> _memoryBytesCache = {};
  Uint8List? _imageBytes;
  bool _isLoading = true;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  @override
  void didUpdateWidget(covariant DecryptedImageWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      _loadImage();
    }
  }

  Future<void> _loadImage() async {
    final url = widget.imageUrl;

    // 1. In-memory check
    if (_memoryBytesCache.containsKey(url)) {
      if (mounted) {
        setState(() {
          _imageBytes = _memoryBytesCache[url];
          _isLoading = false;
        });
      }
      return;
    }

    try {
      // 2. Check local disk cache (e.g. sender's original file or previously decrypted file)
      final prefs = await SharedPreferences.getInstance();
      final savedPath = prefs.getString('ifile_${url.hashCode}');
      if (savedPath != null) {
        final localFile = File(savedPath);
        if (localFile.existsSync()) {
          final bytes = await localFile.readAsBytes();
          _memoryBytesCache[url] = bytes;
          if (mounted) {
            setState(() {
              _imageBytes = bytes;
              _isLoading = false;
            });
          }
          return;
        }
      }

      // Check persistent image cache directory
      final appDir = await getApplicationDocumentsDirectory();
      final cacheDir = Directory(p.join(appDir.path, 'image_cache'));
      if (!cacheDir.existsSync()) {
        cacheDir.createSync(recursive: true);
      }
      final diskCachedFile = File(p.join(cacheDir.path, '${url.hashCode}.jpg'));

      if (diskCachedFile.existsSync() && diskCachedFile.lengthSync() > 0) {
        final bytes = await diskCachedFile.readAsBytes();
        _memoryBytesCache[url] = bytes;
        if (mounted) {
          setState(() {
            _imageBytes = bytes;
            _isLoading = false;
          });
        }
        return;
      }

      // 3. Download encrypted bytes from server and decrypt locally
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final encryptedRaw = response.bodyBytes;
        final decryptedBytes = EndToEndEncryptionService.decryptBytes(
          encryptedRaw,
          widget.senderId,
          widget.receiverId,
        ) ?? encryptedRaw;

        // Save decrypted file to local cache for instant future loads
        try {
          await diskCachedFile.writeAsBytes(decryptedBytes, flush: true);
          await prefs.setString('ifile_${url.hashCode}', diskCachedFile.path);
        } catch (_) {}

        _memoryBytesCache[url] = decryptedBytes;
        if (mounted) {
          setState(() {
            _imageBytes = decryptedBytes;
            _isLoading = false;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _hasError = true;
            _isLoading = false;
          });
        }
      }
    } catch (e) {
      debugPrint('[DECRYPT IMAGE WIDGET ERR] $e');
      if (mounted) {
        setState(() {
          _hasError = true;
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_imageBytes != null) {
      return Image.memory(
        _imageBytes!,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
      );
    }

    if (_hasError) {
      return Container(
        width: widget.width,
        height: widget.height ?? 200,
        color: Colors.black26,
        child: const Center(
          child: Icon(Icons.broken_image, color: Colors.white54, size: 40),
        ),
      );
    }

    return Container(
      width: widget.width,
      height: widget.height ?? 200,
      color: Colors.black12,
      child: const Center(
        child: CircularProgressIndicator(color: AppColors.accent, strokeWidth: 2),
      ),
    );
  }
}
