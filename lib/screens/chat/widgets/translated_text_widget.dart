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
  String? _lastRequestedLang;

  @override
  void didUpdateWidget(covariant TranslatedTextWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.chatId != widget.chatId || oldWidget.messageId != widget.messageId) {
      _lastRequestedLang = null;
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
        final translated = TranslationService.getMessageTranslation(widget.messageId, targetLang);

        // If should translate but not yet cached or fetched for targetLang, trigger fetch
        if (shouldTranslate && translated == null && _lastRequestedLang != targetLang && widget.text.trim().isNotEmpty) {
          _lastRequestedLang = targetLang;
          TranslationService.translateForMessage(
            messageId: widget.messageId,
            text: widget.text,
            targetLang: targetLang,
          );
        }

        final isShowingTranslated = shouldTranslate && translated != null;
        final displayText = isShowingTranslated ? translated : widget.text;

        final defaultStyle = TextStyle(
          color: widget.isMe ? Colors.white : AppColors.textPrimary,
          fontSize: 14.5,
          height: 1.35,
        );

        return Text(
          displayText,
          style: widget.style ?? defaultStyle,
        );
      },
    );
  }
}
