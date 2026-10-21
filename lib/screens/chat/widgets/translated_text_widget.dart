import 'package:flutter/material.dart';
import '../../../constants/app_colors.dart';
import '../../../services/translation_service.dart';

class TranslatedTextWidget extends StatefulWidget {
  final String messageId;
  final String chatId;
  final String text;
  final bool isMe;
  final TextStyle? style;

  const TranslatedTextWidget({
    super.key,
    required this.messageId,
    required this.chatId,
    required this.text,
    required this.isMe,
    this.style,
  });

  @override
  State<TranslatedTextWidget> createState() => _TranslatedTextWidgetState();
}

class _TranslatedTextWidgetState extends State<TranslatedTextWidget> {
  bool _requestedTranslation = false;

  @override
  void didUpdateWidget(covariant TranslatedTextWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.chatId != widget.chatId || oldWidget.messageId != widget.messageId) {
      _requestedTranslation = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: TranslationService.notifier,
      builder: (context, _, __) {
        final shouldTranslate = TranslationService.shouldShowTranslated(
          messageId: widget.messageId,
          chatId: widget.chatId,
        );
        final targetLang = TranslationService.getChatTargetLanguage(widget.chatId);
        final targetLangName = TranslationService.getLanguageName(targetLang);
        final translated = TranslationService.getMessageTranslation(widget.messageId);

        // If should translate but not yet cached or fetched, trigger fetch
        if (shouldTranslate && translated == null && !_requestedTranslation && widget.text.trim().isNotEmpty) {
          _requestedTranslation = true;
          TranslationService.translateForMessage(
            messageId: widget.messageId,
            text: widget.text,
            targetLang: targetLang,
          );
        }

        final isShowingTranslated = shouldTranslate && translated != null;
        final hasCachedTranslation = translated != null;
        final displayText = isShowingTranslated ? translated : widget.text;

        final defaultStyle = TextStyle(
          color: widget.isMe ? Colors.white : AppColors.textPrimary,
          fontSize: 14.5,
          height: 1.35,
        );

        return Column(
          crossAxisAlignment: widget.isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              displayText,
              style: widget.style ?? defaultStyle,
            ),
            if (isShowingTranslated) ...[
              const SizedBox(height: 4),
              GestureDetector(
                onTap: () => TranslationService.toggleOriginalMessage(widget.messageId),
                child: Padding(
                  padding: const EdgeInsets.only(top: 2, bottom: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.g_translate_rounded,
                        size: 13,
                        color: widget.isMe ? Colors.white70 : AppColors.accent,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Çevrildi ($targetLangName) • Orijinali Göster',
                        style: TextStyle(
                          fontSize: 11,
                          color: widget.isMe ? Colors.white70 : AppColors.accent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ] else if (hasCachedTranslation) ...[
              const SizedBox(height: 4),
              GestureDetector(
                onTap: () => TranslationService.toggleOriginalMessage(widget.messageId),
                child: Padding(
                  padding: const EdgeInsets.only(top: 2, bottom: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.g_translate_rounded,
                        size: 13,
                        color: widget.isMe ? Colors.white54 : AppColors.accent.withOpacity(0.8),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Çeviriyi Göster ($targetLangName)',
                        style: TextStyle(
                          fontSize: 11,
                          color: widget.isMe ? Colors.white54 : AppColors.accent.withOpacity(0.8),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
