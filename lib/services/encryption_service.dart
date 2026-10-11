import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;

class EndToEndEncryptionService {
  // App-level salt to ensure cross-app key uniqueness
  static const String _appSalt = "Talknex_Secure_E2EE_2026_Key";

  /// Generates a deterministic 256-bit AES key for a specific pair of users.
  /// Regardless of who is sender or receiver (sorted IDs), both users calculate the exact same key.
  static enc.Key getConversationKey(String user1, String user2) {
    final list = [user1.trim(), user2.trim()]..sort();
    final combined = "${list[0]}_e2ee_${list[1]}_$_appSalt";
    final shaDigest = sha256.convert(utf8.encode(combined));
    return enc.Key(Uint8List.fromList(shaDigest.bytes));
  }

  /// Encrypts text content using AES-256-CBC.
  /// Output format: "ENC::<base64_iv>::<base64_ciphertext>"
  static String encryptText(String plainText, String user1, String user2) {
    if (plainText.isEmpty) return plainText;
    try {
      final key = getConversationKey(user1, user2);
      final iv = enc.IV.fromSecureRandom(16);
      final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc, padding: 'PKCS7'));
      final encrypted = encrypter.encrypt(plainText, iv: iv);
      return 'ENC::${iv.base64}::${encrypted.base64}';
    } catch (e) {
      // In case of any error, fallback gracefully
      return plainText;
    }
  }

  /// Decrypts text content if it starts with "ENC::".
  /// If it is legacy unencrypted text, returns it directly.
  static String decryptText(String cipherText, String user1, String user2) {
    if (!cipherText.startsWith('ENC::')) return cipherText;
    try {
      final parts = cipherText.split('::');
      if (parts.length < 3) return cipherText;
      final iv = enc.IV.fromBase64(parts[1]);
      final encryptedData = enc.Encrypted.fromBase64(parts[2]);
      final key = getConversationKey(user1, user2);
      final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc, padding: 'PKCS7'));
      return encrypter.decrypt(encryptedData, iv: iv);
    } catch (e) {
      // If decryption fails (e.g. wrong key or corrupt data), return raw or lock placeholder
      return cipherText;
    }
  }

  /// Encrypts a binary file (photo, video, document) before uploading to the server.
  /// Writes encrypted bytes to a new temporary file and returns its path.
  static Future<File> encryptFile(File sourceFile, String user1, String user2) async {
    final key = getConversationKey(user1, user2);
    final iv = enc.IV.fromSecureRandom(16);
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc, padding: 'PKCS7'));

    final bytes = await sourceFile.readAsBytes();
    final encrypted = encrypter.encryptBytes(bytes, iv: iv);

    // Format binary header: 16 bytes IV + encrypted bytes
    final combined = Uint8List(16 + encrypted.bytes.length);
    combined.setRange(0, 16, iv.bytes);
    combined.setRange(16, combined.length, encrypted.bytes);

    final encryptedFile = File('${sourceFile.path}.enc');
    await encryptedFile.writeAsBytes(combined, flush: true);
    return encryptedFile;
  }

  /// Decrypts a downloaded binary file into its original readable file.
  static Future<File> decryptFile(File encryptedFile, String user1, String user2, String targetPath) async {
    final key = getConversationKey(user1, user2);
    final rawBytes = await encryptedFile.readAsBytes();

    if (rawBytes.length <= 16) {
      // Not a valid encrypted file or already plain
      return encryptedFile;
    }

    final ivBytes = rawBytes.sublist(0, 16);
    final cipherBytes = rawBytes.sublist(16);

    try {
      final iv = enc.IV(ivBytes);
      final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc, padding: 'PKCS7'));
      final decryptedBytes = encrypter.decryptBytes(enc.Encrypted(cipherBytes), iv: iv);

      final decryptedFile = File(targetPath);
      await decryptedFile.writeAsBytes(decryptedBytes, flush: true);
      return decryptedFile;
    } catch (e) {
      // If failed (e.g. was already unencrypted legacy file), return original
      return encryptedFile;
    }
  }

  /// Decrypts in-memory bytes for live image rendering.
  static Uint8List? decryptBytes(Uint8List rawBytes, String user1, String user2) {
    if (rawBytes.length <= 16) return rawBytes;
    try {
      final key = getConversationKey(user1, user2);
      final ivBytes = rawBytes.sublist(0, 16);
      final cipherBytes = rawBytes.sublist(16);
      final iv = enc.IV(ivBytes);
      final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc, padding: 'PKCS7'));
      final decrypted = encrypter.decryptBytes(enc.Encrypted(cipherBytes), iv: iv);
      return Uint8List.fromList(decrypted);
    } catch (_) {
      return rawBytes;
    }
  }
}
