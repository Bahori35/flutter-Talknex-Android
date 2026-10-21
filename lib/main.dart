import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_core/firebase_core.dart';
import 'constants/app_colors.dart';
import 'services/custom_auth_service.dart';
import 'services/live_location_service.dart';
import 'services/emergency_service.dart';
import 'services/translation_service.dart';
import 'services/ai_assistant_service.dart';
import 'screens/auth/login_screen.dart';
import 'screens/home/home_screen.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'services/notification_service.dart';

import 'package:http/http.dart' as http;
import 'dart:convert';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp();
    final notificationService = NotificationService();
    await notificationService.init();

    final data = message.data;
    final msgType = data['type'] ?? 'message';

    if (msgType == 'call') {
      final callerName = data['callerName'] ?? 'Biri';
      final callType = data['callType'] == 'video' ? 'Görüntülü' : 'Sesli';
      await notificationService.showIncomingCallNotification(
        id: 9999,
        callerName: callerName,
        callType: callType,
      );
    } else {
      final senderName = data['senderName'] ?? message.notification?.title ?? 'Yeni Mesaj';
      final content = data['content'] ?? message.notification?.body ?? 'Mesaj içeriği';
      await notificationService.showMessageNotification(
        id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        senderName: senderName,
        messageContent: content,
      );

      // Report delivery back to server so sender immediately sees gray double tick (done_all)
      try {
        final senderId = int.tryParse(data['senderId'] ?? '0');
        final receiverId = int.tryParse(data['receiverId'] ?? '0');
        final messageId = int.tryParse(data['messageId'] ?? '0');

        if (receiverId != null && receiverId > 0) {
          http.post(
            Uri.parse('http://46.197.188.20:3000/api/messages/delivered'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'receiverId': receiverId,
              'senderId': senderId,
              'messageId': messageId,
            }),
          ).timeout(const Duration(seconds: 3));
        }
      } catch (_) {}
    }
  } catch (e) {
    debugPrint('[FCM BG HANDLER] Hata: $e');
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await initializeDateFormatting('tr_TR', null);
    await initializeDateFormatting('tr', null);
  } catch (e) {
    debugPrint('[INTL] Date formatting init error: $e');
  }

  try {
    await LiveLocationService().init();
  } catch (e) {
    debugPrint('[LIVE LOCATION] Init error: $e');
  }

  try {
    await EmergencyService().init();
  } catch (e) {
    debugPrint('[EMERGENCY] Init error: $e');
  }

  try {
    await TranslationService.init();
  } catch (e) {
    debugPrint('[TRANSLATION] Init error: $e');
  }

  try {
    await NotificationService().init();
  } catch (e) {
    debugPrint('[NOTIFICATION] Init error: $e');
  }

  try {
    await AiAssistantService.init();
  } catch (e) {
    debugPrint('[AI ASSISTANT] Init error: $e');
  }

  try {
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  } catch (e) {
    debugPrint('[FIREBASE] Init error: $e');
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => CustomAuthService()),
        ChangeNotifierProvider.value(value: EmergencyService()),
      ],
      child: const TalknexApp(),
    ),
  );
}

class TalknexApp extends StatelessWidget {
  const TalknexApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Talknex',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.background,
        primaryColor: AppColors.primary,
        textTheme: GoogleFonts.plusJakartaSansTextTheme(
          ThemeData.dark().textTheme.apply(
            bodyColor: AppColors.textPrimary,
            displayColor: AppColors.textPrimary,
          ),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: AppColors.surface,
          elevation: 0,
          centerTitle: false,
          iconTheme: IconThemeData(color: AppColors.textPrimary),
        ),
        colorScheme: const ColorScheme.dark(
          primary: AppColors.primary,
          secondary: AppColors.accent,
          surface: AppColors.surface,
          background: AppColors.background,
        ),
      ),
      home: const AuthWrapper(),
    );
  }
}

class AuthWrapper extends StatelessWidget {
  const AuthWrapper({super.key});

  @override
  Widget build(BuildContext context) {
    final authService = Provider.of<CustomAuthService>(context);

    if (authService.isInitializing) {
      return const Scaffold(
        backgroundColor: AppColors.background,
        body: Center(
          child: CircularProgressIndicator(color: AppColors.primaryLight),
        ),
      );
    }

    if (authService.currentUser != null) {
      return const HomeScreen();
    } else {
      return const LoginScreen();
    }
  }
}
