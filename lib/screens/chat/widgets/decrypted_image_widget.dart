import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../../../constants/app_colors.dart';
import '../../../services/encryption_service.dart';
import '../../../utils/media_url_helper.dart';

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
    final rawUrl = widget.imageUrl.trim();
    if (rawUrl.isEmpty) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasError = true;
        });
      }
      return;
    }

    final url = formatMediaUrl(rawUrl);

    // Build candidate keys to cover both historical URLs (without :3000) and current normalized URLs
    final candidateKeys = <String>{
      url,
      rawUrl,
      if (url.contains(':3000')) url.replaceAll(':3000', ''),
      if (!url.contains(':3000') && url.contains('46.197.188.20/'))
        url.replaceFirst('46.197.188.20/', '46.197.188.20:3000/'),
    };

    // 1. In-memory cache check
    for (final key in candidateKeys) {
      if (_memoryBytesCache.containsKey(key) && _memoryBytesCache[key] != null && _memoryBytesCache[key]!.isNotEmpty) {
        if (mounted) {
          setState(() {
            _imageBytes = _memoryBytesCache[key];
            _isLoading = false;
            _hasError = false;
          });
        }
        return;
      }
    }

    try {
      // 2. Check local disk cache (e.g. sender's original file or previously decrypted file in prefs)
      final prefs = await SharedPreferences.getInstance();
      for (final key in candidateKeys) {
        final savedPath = prefs.getString('ifile_${key.hashCode}');
        if (savedPath != null) {
          final localFile = File(savedPath);
          if (localFile.existsSync() && localFile.lengthSync() > 16) {
            try {
              final bytes = await localFile.readAsBytes();
              if (bytes.isNotEmpty) {
                _memoryBytesCache[url] = bytes;
                if (mounted) {
                  setState(() {
                    _imageBytes = bytes;
                    _isLoading = false;
                    _hasError = false;
                  });
                }
                return;
              }
            } catch (_) {}
          }
        }
      }

      // 3. Check persistent disk cache directory by both URL hash codes AND file basename
      final appDir = await getApplicationDocumentsDirectory();
      final cacheDir = Directory(p.join(appDir.path, 'image_cache'));
      if (!cacheDir.existsSync()) {
        cacheDir.createSync(recursive: true);
      }

      final fileBasename = p.basenameWithoutExtension(url);
      final candidateFiles = <File>[
        for (final key in candidateKeys) File(p.join(cacheDir.path, '${key.hashCode}.jpg')),
        if (fileBasename.isNotEmpty) File(p.join(cacheDir.path, '$fileBasename.jpg')),
      ];

      for (final diskFile in candidateFiles) {
        if (diskFile.existsSync() && diskFile.lengthSync() > 16) {
          try {
            final bytes = await diskFile.readAsBytes();
            if (bytes.isNotEmpty) {
              _memoryBytesCache[url] = bytes;
              if (mounted) {
                setState(() {
                  _imageBytes = bytes;
                  _isLoading = false;
                  _hasError = false;
                });
              }
              return;
            }
          } catch (_) {}
        }
      }

      // 4. Download encrypted bytes from server and decrypt locally
      final downloadUri = Uri.parse(url);
      final response = await http.get(downloadUri).timeout(const Duration(seconds: 20));

      if (response.statusCode == 200 && response.bodyBytes.length > 16) {
        final encryptedRaw = response.bodyBytes;
        Uint8List decryptedBytes = encryptedRaw;

        // Decrypt using conversation key
        final decrypted = EndToEndEncryptionService.decryptBytes(
          encryptedRaw,
          widget.senderId,
          widget.receiverId,
        );

        if (decrypted != null && decrypted.isNotEmpty) {
          decryptedBytes = decrypted;
        }

        // Save decrypted file to local disk cache for instant future loads
        final primaryCachedFile = File(p.join(cacheDir.path, '${url.hashCode}.jpg'));
        final namedCachedFile = File(p.join(cacheDir.path, '$fileBasename.jpg'));

        try {
          await primaryCachedFile.writeAsBytes(decryptedBytes, flush: true);
          if (fileBasename.isNotEmpty) {
            await namedCachedFile.writeAsBytes(decryptedBytes, flush: true);
          }
          await prefs.setString('ifile_${url.hashCode}', primaryCachedFile.path);
          if (rawUrl.isNotEmpty) {
            await prefs.setString('ifile_${rawUrl.hashCode}', primaryCachedFile.path);
          }
        } catch (_) {}

        _memoryBytesCache[url] = decryptedBytes;
        if (mounted) {
          setState(() {
            _imageBytes = decryptedBytes;
            _isLoading = false;
            _hasError = false;
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
    if (_imageBytes != null && _imageBytes!.isNotEmpty) {
      return Image.memory(
        _imageBytes!,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        errorBuilder: (context, error, stackTrace) {
          return Container(
            width: widget.width,
            height: widget.height ?? 200,
            color: Colors.black26,
            child: const Center(
              child: Icon(Icons.broken_image, color: Colors.white54, size: 40),
            ),
          );
        },
      );
    }

    if (_hasError) {
      return Container(
        width: widget.width,
        height: widget.height ?? 200,
        color: Colors.black26,
        child: Center(
          child: IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Colors.white70, size: 36),
            onPressed: () {
              setState(() {
                _isLoading = true;
                _hasError = false;
              });
              _loadImage();
            },
          ),
        ),
      );
    }

    return Container(
      width: widget.width,
      height: widget.height ?? 200,
      color: Colors.black12,
      child: const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(color: AppColors.accent, strokeWidth: 2),
        ),
      ),
    );
  }
}
