import '../services/custom_auth_service.dart';

/// Formats and sanitizes media URLs so that profile pictures,
/// group avatars, and story media always load properly across all screens.
///
/// Handles:
/// 1. Relative paths: `/uploads/xyz.jpg` -> `http://46.197.188.20:3000/uploads/xyz.jpg`
/// 2. Missing port 3000: `http://46.197.188.20/uploads/xyz.jpg` -> `http://46.197.188.20:3000/uploads/xyz.jpg`
/// 3. Normalizes null/empty strings to empty string.
String formatMediaUrl(dynamic rawUrl) {
  if (rawUrl == null) return '';
  String url = rawUrl.toString().trim();
  if (url.isEmpty) return '';

  // 1. Relative path (/uploads/...) -> prepend server base URL
  if (url.startsWith('/uploads/')) {
    final serverBase = CustomAuthService.baseUrl.replaceAll('/api', '');
    return '$serverBase$url';
  }

  // 2. Exact match for missing port 3000 on user server IP
  if (url.startsWith('http://46.197.188.20/uploads/')) {
    return url.replaceFirst('http://46.197.188.20/uploads/', 'http://46.197.188.20:3000/uploads/');
  }

  // 3. Any standard HTTP host without explicit port pointing to /uploads/
  final uri = Uri.tryParse(url);
  if (uri != null && uri.hasAuthority && uri.path.startsWith('/uploads/')) {
    if (!uri.hasPort || uri.port == 80) {
      if (uri.host == '46.197.188.20' || uri.host == 'localhost' || uri.host == '127.0.0.1') {
        return uri.replace(port: 3000).toString();
      }
    }
  }

  return url;
}
