import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../constants/app_colors.dart';
import '../utils/media_url_helper.dart';

/// AppAvatar renders animated GIFs, PNGs, and JPEGs smoothly across
/// all chat lists, group headers, profile screens, and call overlays.
class AppAvatar extends StatelessWidget {
  final String? imageUrl;
  final double radius;
  final String? name;
  final bool isGroup;
  final VoidCallback? onTap;
  final Border? border;
  final Widget? badge;
  final bool isLoading;
  final Color? backgroundColor;

  const AppAvatar({
    super.key,
    required this.imageUrl,
    this.radius = 24,
    this.name,
    this.isGroup = false,
    this.onTap,
    this.border,
    this.badge,
    this.isLoading = false,
    this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    final size = radius * 2;
    final rawUrl = imageUrl ?? '';
    final formattedUrl = formatMediaUrl(rawUrl);

    Widget avatarImage;
    if (isLoading) {
      avatarImage = Container(
        color: backgroundColor ?? AppColors.surfaceLight,
        child: const Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primaryLight),
          ),
        ),
      );
    } else if (rawUrl.isNotEmpty) {
      final isLocalFile = !rawUrl.startsWith('http://') && !rawUrl.startsWith('https://');
      if (isLocalFile && File(rawUrl).existsSync()) {
        avatarImage = Image.file(
          File(rawUrl),
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => _buildFallback(size),
        );
      } else if (formattedUrl.isNotEmpty) {
        avatarImage = CachedNetworkImage(
          imageUrl: formattedUrl,
          width: size,
          height: size,
          fit: BoxFit.cover,
          fadeInDuration: const Duration(milliseconds: 150),
          placeholder: (context, url) => Container(
            width: size,
            height: size,
            color: backgroundColor ?? AppColors.surfaceLight,
            child: const Center(
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 1.5, color: AppColors.accent),
              ),
            ),
          ),
          errorWidget: (context, url, error) => _buildFallback(size),
        );
      } else {
        avatarImage = _buildFallback(size);
      }
    } else {
      avatarImage = _buildFallback(size);
    }

    Widget content = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: backgroundColor ?? AppColors.surfaceLight,
        shape: BoxShape.circle,
        border: border,
      ),
      child: ClipOval(
        child: avatarImage,
      ),
    );

    if (badge != null) {
      content = Stack(
        clipBehavior: Clip.none,
        children: [
          content,
          badge!,
        ],
      );
    }

    if (onTap != null) {
      return GestureDetector(onTap: onTap, child: content);
    }

    return content;
  }

  Widget _buildFallback(double size) {
    if (isGroup) {
      return Container(
        color: backgroundColor ?? AppColors.surfaceLight,
        child: Center(
          child: Icon(Icons.group_rounded, color: AppColors.accent, size: size * 0.52),
        ),
      );
    }

    final trimmed = name?.trim() ?? '';
    if (trimmed.isNotEmpty) {
      return Container(
        color: backgroundColor ?? AppColors.surfaceLight,
        child: Center(
          child: Text(
            trimmed[0].toUpperCase(),
            style: TextStyle(
              color: Colors.white70,
              fontWeight: FontWeight.bold,
              fontSize: size * 0.42,
            ),
          ),
        ),
      );
    }

    return Container(
      color: backgroundColor ?? AppColors.surfaceLight,
      child: Center(
        child: Icon(Icons.person, color: AppColors.textSecondary, size: size * 0.52),
      ),
    );
  }
}
