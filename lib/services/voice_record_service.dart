import 'dart:async';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

class VoiceRecordResult {
  final String filePath;
  final int durationMs;

  VoiceRecordResult({
    required this.filePath,
    required this.durationMs,
  });
}

class VoiceRecordService {
  static const MethodChannel _channel = MethodChannel('com.safechat.app/voice');

  static Future<bool> requestPermission() async {
    final status = await Permission.microphone.request();
    return status.isGranted;
  }

  static Future<bool> hasPermission() async {
    return await Permission.microphone.isGranted;
  }

  static Future<String?> startRecording() async {
    final bool granted = await requestPermission();
    if (!granted) return null;
    try {
      final String? path = await _channel.invokeMethod<String>('startRecording');
      return path;
    } catch (e) {
      return null;
    }
  }

  static Future<VoiceRecordResult?> stopRecording() async {
    try {
      final Map<dynamic, dynamic>? res = await _channel.invokeMapMethod('stopRecording');
      if (res == null) return null;
      return VoiceRecordResult(
        filePath: res['filePath'] as String,
        durationMs: (res['durationMs'] as num).toInt(),
      );
    } catch (e) {
      return null;
    }
  }

  static Future<void> cancelRecording() async {
    try {
      await _channel.invokeMethod('cancelRecording');
    } catch (_) {}
  }

  static Future<int> getAmplitude() async {
    try {
      final int? amp = await _channel.invokeMethod<int>('getAmplitude');
      return amp ?? 0;
    } catch (_) {
      return 0;
    }
  }
}
