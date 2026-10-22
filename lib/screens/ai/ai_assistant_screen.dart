import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../constants/app_colors.dart';
import '../../models/ai_message_model.dart';
import '../../models/ai_reminder_model.dart';
import '../../models/ai_weather_model.dart';
import '../../services/ai_assistant_service.dart';

class AiAssistantScreen extends StatefulWidget {
  const AiAssistantScreen({super.key});

  @override
  State<AiAssistantScreen> createState() => _AiAssistantScreenState();
}

class _AiAssistantScreenState extends State<AiAssistantScreen> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isSending = false;

  final List<String> _quickSuggestions = [
    'Bugün İstanbul\'da hava durumu nasıl?',
    'Ankara hava durumu',
    'Yarın saat 14:00\'te toplantım var, 30 dk önce hatırlat',
    'Akşam 20:00\'de ilaç içeceğim, 15 dk önce haber ver',
    'İzmir hava nasıl?',
    '20 dakika sonra fırını kapatmamı hatırlat',
    'Aktif planlarımı göster',
    'Zaman yönetimi için tavsiye ver',
    'Bana motive edici bir söz söyle',
  ];

  @override
  void initState() {
    super.initState();
    AiAssistantService.init().then((_) => _scrollToBottom());
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _handleSend([String? textToSend]) async {
    final text = textToSend ?? _textController.text;
    if (text.trim().isEmpty || _isSending) return;

    if (textToSend == null) {
      _textController.clear();
    }

    setState(() => _isSending = true);
    _scrollToBottom();

    try {
      await AiAssistantService.handleUserMessage(text);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Hata: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSending = false);
        _scrollToBottom();
      }
    }
  }

  void _showAiSettingsDialog() {
    final textController = TextEditingController(text: AiAssistantService.geminiApiKey ?? '');
    bool isObscured = true;
    bool isTesting = false;
    String? statusMessage;
    bool isSuccess = false;

    showDialog(
      context: context,
      builder: (dlgCtx) {
        return StatefulBuilder(
          builder: (context, setDlgState) {
            final hasKey = AiAssistantService.hasGeminiApiKey;

            return AlertDialog(
              backgroundColor: AppColors.surface,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              title: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF8A2387), Color(0xFFE94057), Color(0xFFF27121)],
                      ),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.psychology_rounded, color: Colors.white, size: 22),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Yapay Zeka Asistanı',
                          style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          'Model & Yapılandırma',
                          style: TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Primary Active Model: Free Cloud AI
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppColors.onlineGreen.withAlpha(20),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: AppColors.onlineGreen.withAlpha(90)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.check_circle_rounded, color: AppColors.onlineGreen, size: 18),
                              const SizedBox(width: 8),
                              const Expanded(
                                child: Text(
                                  'Ücretsiz Bulut Yapay Zeka',
                                  style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: AppColors.onlineGreen.withAlpha(40),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Text(
                                  'AKTİF ✨',
                                  style: TextStyle(color: AppColors.onlineGreen, fontSize: 10, fontWeight: FontWeight.bold),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            '• Model: Pollinations (Reasoning LLM)\n'
                            '• API Anahtarı: Gerekmez (Tamamen Ücretsiz)\n'
                            '• Yetenek: Tıpkı Gemini / ChatGPT gibi düşünerek cevap verir, sohbet geçmişinizi hatırlar.',
                            style: TextStyle(color: Colors.white70, fontSize: 12.5, height: 1.45),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Optional Custom Gemini API Key Section
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white.withAlpha(8),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.tune_rounded, color: Colors.white60, size: 16),
                              const SizedBox(width: 6),
                              const Expanded(
                                child: Text(
                                  'İsteğe Bağlı: Özel Gemini Anahtarı',
                                  style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                                ),
                              ),
                              if (hasKey)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.blueAccent.withAlpha(40),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Text('Bağlı', style: TextStyle(color: Colors.blueAccent, fontSize: 10)),
                                ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'Kişisel Google Gemini API anahtarınızı kullanmak isterseniz ekleyebilirsiniz. Zorunlu değildir; anahtar girmeseniz de yukarıdaki ücretsiz bulut yapay zeka kesintisiz çalışır.\n\n'
                            '💡 İpucu: Google AI Studio\'dan (aistudio.google.com/apikey) tamamen ÜCRETSİZ kişisel anahtar alıp bağlayabilirsiniz.',
                            style: TextStyle(color: Colors.white70, fontSize: 11.5, height: 1.35),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: textController,
                            obscureText: isObscured,
                            style: const TextStyle(color: Colors.white, fontSize: 12.5),
                            decoration: InputDecoration(
                              hintText: 'Opsiyonel Gemini Key (AIzaSy...)',
                              hintStyle: const TextStyle(color: Colors.white30, fontSize: 12),
                              filled: true,
                              fillColor: AppColors.chatBackground,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide.none,
                              ),
                              suffixIcon: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: Icon(
                                      isObscured ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                                      color: Colors.white60,
                                      size: 16,
                                    ),
                                    onPressed: () => setDlgState(() => isObscured = !isObscured),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.paste_rounded, color: AppColors.accent, size: 16),
                                    tooltip: 'Yapıştır',
                                    onPressed: () async {
                                      final data = await Clipboard.getData('text/plain');
                                      if (data?.text != null) {
                                        textController.text = data!.text!.trim();
                                        setDlgState(() {});
                                      }
                                    },
                                  ),
                                ],
                              ),
                            ),
                          ),
                          if (statusMessage != null) ...[
                            const SizedBox(height: 8),
                            Text(
                              statusMessage!,
                              style: TextStyle(
                                color: isSuccess ? AppColors.onlineGreen : AppColors.callRed,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              if (hasKey)
                                TextButton(
                                  onPressed: isTesting
                                      ? null
                                      : () async {
                                          await AiAssistantService.setGeminiApiKey(null);
                                          textController.clear();
                                          setDlgState(() {
                                            statusMessage = 'Özel anahtar kaldırıldı. Ücretsiz bulut modu aktif.';
                                            isSuccess = true;
                                          });
                                          setState(() {});
                                        },
                                  child: const Text('Anahtarı Kaldır', style: TextStyle(color: AppColors.callRed, fontSize: 12)),
                                ),
                              const SizedBox(width: 8),
                              ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.accent,
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                ),
                                onPressed: isTesting
                                    ? null
                                    : () async {
                                        final keyToSave = textController.text.trim();
                                        if (keyToSave.isEmpty) {
                                          setDlgState(() {
                                            statusMessage = 'Lütfen bir anahtar girin veya boş bırakın.';
                                            isSuccess = false;
                                          });
                                          return;
                                        }

                                        setDlgState(() {
                                          isTesting = true;
                                          statusMessage = 'Bağlantı test ediliyor... ⏳';
                                        });

                                        final ok = await AiAssistantService.testGeminiApiKey(keyToSave);

                                        if (ok) {
                                          await AiAssistantService.setGeminiApiKey(keyToSave);
                                          setDlgState(() {
                                            isTesting = false;
                                            isSuccess = true;
                                            statusMessage = '✅ Gemini bağlandı ve öncelikli yapıldı.';
                                          });
                                          setState(() {});
                                        } else {
                                          setDlgState(() {
                                            isTesting = false;
                                            isSuccess = false;
                                            statusMessage = '❌ Anahtar doğrulanamadı.';
                                          });
                                        }
                                      },
                                child: isTesting
                                    ? const SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                      )
                                    : const Text('Kaydet', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dlgCtx),
                  child: const Text('Kapat', style: TextStyle(color: Colors.white70, fontSize: 13)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showRemindersSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withAlpha(160),
      builder: (ctx) {
        return Container(
          decoration: const BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: SafeArea(
            top: false,
            child: ValueListenableBuilder<int>(
              valueListenable: AiAssistantService.notifier,
              builder: (context, _, __) {
                final active = AiAssistantService.activeReminders;

                return Padding(
                  padding: EdgeInsets.only(
                    left: 20,
                    right: 20,
                    top: 14,
                    bottom: MediaQuery.of(context).viewInsets.bottom + 16,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: AppColors.accent.withAlpha(30),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(Icons.alarm_on_rounded, color: AppColors.accent, size: 22),
                          ),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Text(
                              'Aktif Hatırlatıcılar & Planlar',
                              style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
                            ),
                          ),
                          if (active.isNotEmpty)
                            TextButton(
                              onPressed: () async {
                                await AiAssistantService.cancelReminder('all');
                                if (ctx.mounted) Navigator.pop(ctx);
                              },
                              child: const Text('Tümünü Sil', style: TextStyle(color: AppColors.callRed, fontSize: 13, fontWeight: FontWeight.bold)),
                            ),
                        ],
                      ),
                      const Divider(color: Colors.white12, height: 20),
                      if (active.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 36),
                          child: Column(
                            children: [
                              Icon(Icons.event_available_rounded, color: Colors.white24, size: 48),
                              SizedBox(height: 12),
                              Text(
                                'Henüz kayıtlı bir planınız yok.',
                                style: TextStyle(color: Colors.white54, fontSize: 14),
                              ),
                            ],
                          ),
                        )
                      else
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight: MediaQuery.of(context).size.height * 0.55,
                          ),
                          child: ListView.separated(
                            shrinkWrap: true,
                            itemCount: active.length,
                            separatorBuilder: (_, __) => const Divider(color: Colors.white10, height: 1),
                            itemBuilder: (context, i) {
                              final r = active[i];
                              return ListTile(
                                contentPadding: const EdgeInsets.symmetric(vertical: 4),
                                leading: Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: AppColors.accent.withAlpha(35),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(Icons.event_note_rounded, color: AppColors.accent, size: 22),
                                ),
                                title: Text(
                                  r.title,
                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                                ),
                                subtitle: Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    '${r.formattedEventTime} (${r.leadTimeText})\n⏳ ${r.remainingTimeText}',
                                    style: const TextStyle(color: Colors.white70, fontSize: 12.5, height: 1.3),
                                  ),
                                ),
                                isThreeLine: true,
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.notifications_active_outlined, color: AppColors.accent, size: 20),
                                      tooltip: 'Test Bildirimi Gönder',
                                      onPressed: () async {
                                        try {
                                          await AiAssistantService.testTriggerReminder(r);
                                          if (ctx.mounted) {
                                            ScaffoldMessenger.of(ctx).showSnackBar(
                                              SnackBar(
                                                content: Text('🔔 "${r.title}" için bildirim gönderildi!'),
                                                duration: const Duration(seconds: 2),
                                              ),
                                            );
                                          }
                                        } catch (e) {
                                          if (ctx.mounted) {
                                            ScaffoldMessenger.of(ctx).showSnackBar(
                                              SnackBar(
                                                content: Text('Bildirim hatası: $e'),
                                                duration: const Duration(seconds: 3),
                                              ),
                                            );
                                          }
                                        }
                                      },
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.delete_outline_rounded, color: AppColors.callRed, size: 20),
                                      tooltip: 'Sil',
                                      onPressed: () async {
                                        await AiAssistantService.cancelReminder(r.id);
                                      },
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
              },
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.chatBackground,
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 1,
        titleSpacing: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white70, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF8A2387), Color(0xFFE94057), Color(0xFFF27121)],
                ),
                shape: BoxShape.circle,
              ),
              child: const Center(
                child: Icon(Icons.auto_awesome, color: Colors.white, size: 20),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Talknex Asistan',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  ValueListenableBuilder<int>(
                    valueListenable: AiAssistantService.notifier,
                    builder: (context, _, __) {
                      final hasGemini = AiAssistantService.hasGeminiApiKey;
                      return Row(
                        children: [
                          const Icon(
                            Icons.circle,
                            color: AppColors.onlineGreen,
                            size: 8,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            hasGemini ? 'Gemini 1.5 Flash Aktif ✨' : 'Bulut Yapay Zeka Aktif ✨',
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppColors.onlineGreen,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          ValueListenableBuilder<int>(
            valueListenable: AiAssistantService.notifier,
            builder: (context, _, __) {
              final count = AiAssistantService.activeReminders.length;
              return Stack(
                alignment: Alignment.center,
                children: [
                  IconButton(
                    icon: const Icon(Icons.calendar_month_rounded, color: Colors.white70),
                    tooltip: 'Hatırlatıcılar',
                    onPressed: _showRemindersSheet,
                  ),
                  if (count > 0)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: const BoxDecoration(
                          color: AppColors.accent,
                          shape: BoxShape.circle,
                        ),
                        constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                        child: Text(
                          '$count',
                          style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded, color: Colors.white70),
            color: AppColors.surface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            onSelected: (val) {
              if (val == 'clear') {
                AiAssistantService.clearHistory();
              } else if (val == 'reminders') {
                _showRemindersSheet();
              } else if (val == 'settings') {
                _showAiSettingsDialog();
              }
            },
            itemBuilder: (ctx) => [
              PopupMenuItem(
                value: 'settings',
                child: Row(
                  children: [
                    Icon(
                      AiAssistantService.hasGeminiApiKey ? Icons.auto_awesome : Icons.psychology_rounded,
                      color: AiAssistantService.hasGeminiApiKey ? AppColors.onlineGreen : AppColors.accent,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    const Text('Yapay Zeka Modeli & Bilgi', style: TextStyle(color: Colors.white, fontSize: 14)),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'reminders',
                child: Row(
                  children: [
                    Icon(Icons.alarm_on_rounded, color: AppColors.accent, size: 20),
                    SizedBox(width: 10),
                    Text('Aktif Hatırlatıcılar', style: TextStyle(color: Colors.white, fontSize: 14)),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'clear',
                child: Row(
                  children: [
                    Icon(Icons.delete_sweep_rounded, color: AppColors.callRed, size: 20),
                    SizedBox(width: 10),
                    Text('Sohbeti Temizle', style: TextStyle(color: Colors.white, fontSize: 14)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          // Messages List
          Expanded(
            child: ValueListenableBuilder<int>(
              valueListenable: AiAssistantService.notifier,
              builder: (context, _, __) {
                final msgs = AiAssistantService.messages;
                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  itemCount: msgs.length,
                  itemBuilder: (context, index) {
                    final msg = msgs[index];
                    return _buildMessageItem(msg);
                  },
                );
              },
            ),
          ),

          // Typing indicator
          if (_isSending)
            Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 8),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: const BoxDecoration(
                      color: AppColors.surfaceLight,
                      shape: BoxShape.circle,
                    ),
                    child: const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'Talknex Asistan düşünüyor...',
                    style: TextStyle(color: Colors.white60, fontSize: 12, fontStyle: FontStyle.italic),
                  ),
                ],
              ),
            ),

          // Quick Suggestion Chips
          SizedBox(
            height: 38,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              itemCount: _quickSuggestions.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final s = _quickSuggestions[i];
                return ActionChip(
                  label: Text(s),
                  labelStyle: const TextStyle(color: Colors.white70, fontSize: 12),
                  backgroundColor: AppColors.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                    side: BorderSide(color: AppColors.accent.withAlpha(60)),
                  ),
                  onPressed: () => _handleSend(s),
                );
              },
            ),
          ),

          const SizedBox(height: 8),

          // Message Input Field
          Container(
            color: AppColors.surface,
            child: SafeArea(
              top: false,
              bottom: true,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: AppColors.surfaceLight,
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(color: Colors.white12),
                        ),
                        child: TextField(
                          controller: _textController,
                          style: const TextStyle(color: Colors.white, fontSize: 15),
                          maxLines: null,
                          textCapitalization: TextCapitalization.sentences,
                          decoration: const InputDecoration(
                            hintText: 'Bir plan söyle veya soru sor...',
                            hintStyle: TextStyle(color: Colors.white38, fontSize: 14),
                            contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            border: InputBorder.none,
                          ),
                          onSubmitted: (_) => _handleSend(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => _handleSend(),
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            colors: [Color(0xFF8A2387), Color(0xFFE94057)],
                          ),
                          shape: BoxShape.circle,
                        ),
                        child: const Center(
                          child: Icon(Icons.send_rounded, color: Colors.white, size: 20),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageItem(AiMessageModel msg) {
    final isUser = msg.isUser;
    final timeStr = DateFormat('HH:mm').format(msg.timestamp);

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.82,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          gradient: isUser
              ? const LinearGradient(
                  colors: [Color(0xFF8A2387), Color(0xFFE94057)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                )
              : null,
          color: isUser ? null : AppColors.surface,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isUser ? 16 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 16),
          ),
          border: Border.all(
            color: isUser ? Colors.transparent : Colors.white12,
            width: 0.8,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(25),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isUser) ...[
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: AppColors.accent.withAlpha(30),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.auto_awesome, color: AppColors.accent, size: 12),
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    'Talknex Asistan',
                    style: TextStyle(
                      color: AppColors.accent,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
            ],
            Text(
              msg.text,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14.5,
                height: 1.38,
              ),
            ),
            if (msg.reminder != null) ...[
              const SizedBox(height: 10),
              _buildReminderCard(msg.reminder!),
            ],
            if (msg.weather != null) ...[
              const SizedBox(height: 10),
              _buildWeatherCard(msg.weather!),
            ],
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                timeStr,
                style: const TextStyle(color: Colors.white54, fontSize: 10),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReminderCard(AiReminderModel r) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.accent.withAlpha(80)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.alarm_on_rounded, color: AppColors.accent, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  r.title,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.accent.withAlpha(40),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  r.leadTimeText,
                  style: const TextStyle(color: AppColors.accent, fontSize: 10, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.event_rounded, color: Colors.white60, size: 14),
              const SizedBox(width: 6),
              Text(
                'Plan: ${r.formattedEventTime}',
                style: const TextStyle(color: Colors.white70, fontSize: 12.5),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              const Icon(Icons.notifications_active_rounded, color: Colors.amberAccent, size: 14),
              const SizedBox(width: 6),
              Text(
                'Hatırlatma: ${r.formattedReminderTime}',
                style: const TextStyle(color: Colors.amberAccent, fontSize: 12.5),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white70,
                  side: const BorderSide(color: Colors.white24),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: const Icon(Icons.notifications_outlined, size: 14),
                label: const Text('Test Et', style: TextStyle(fontSize: 11)),
                onPressed: () async {
                  try {
                    await AiAssistantService.testTriggerReminder(r);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('🔔 Test bildirimi gönderildi!'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Bildirim hatası: $e'),
                          duration: const Duration(seconds: 3),
                        ),
                      );
                    }
                  }
                },
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.callRed.withAlpha(40),
                  foregroundColor: AppColors.callRed,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: const Icon(Icons.close_rounded, size: 14),
                label: const Text('İptal Et', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                onPressed: () async {
                  await AiAssistantService.cancelReminder(r.id);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Hatırlatıcı iptal edildi'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildWeatherCard(AiWeatherModel w) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFF1E3A8A).withOpacity(0.45),
            AppColors.surfaceLight,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF38BDF8).withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.location_on_rounded, color: Color(0xFF38BDF8), size: 16),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  w.location,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13.5),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFF38BDF8).withOpacity(0.18),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(w.icon, style: const TextStyle(fontSize: 12)),
                    const SizedBox(width: 4),
                    Text(
                      w.description,
                      style: const TextStyle(
                        color: Color(0xFF38BDF8),
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                '${w.temp}°',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 38,
                  fontWeight: FontWeight.w900,
                  height: 1,
                  letterSpacing: -1,
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    w.description,
                    style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Hissedilen: ${w.feelsLike}°C',
                    style: const TextStyle(color: Colors.white60, fontSize: 11.5),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildWeatherStat(Icons.water_drop_outlined, 'Nem', '%${w.humidity}'),
                Container(width: 1, height: 22, color: Colors.white12),
                _buildWeatherStat(Icons.air_rounded, 'Rüzgar', '${w.windSpeed} km/s'),
                if (w.maxTemp != null && w.minTemp != null) ...[
                  Container(width: 1, height: 22, color: Colors.white12),
                  _buildWeatherStat(Icons.thermostat_rounded, 'En Y/D', '${w.maxTemp}° / ${w.minTemp}°'),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWeatherStat(IconData icon, String label, String value) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: const Color(0xFF38BDF8), size: 12),
            const SizedBox(width: 3),
            Text(label, style: const TextStyle(color: Colors.white60, fontSize: 10)),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }
}
