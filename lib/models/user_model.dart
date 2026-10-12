import 'package:cloud_firestore/cloud_firestore.dart';

class UserModel {
  final String uid;
  final String username;
  final String email;
  final String displayName;
  final String photoUrl;
  final String phoneNumber;
  final String status;
  final bool isOnline;
  final DateTime? lastSeen;
  final String lastMessage;
  final DateTime? lastTime;

  UserModel({
    required this.uid,
    required this.username,
    required this.email,
    required this.displayName,
    this.photoUrl = '',
    this.phoneNumber = '',
    this.status = 'Hey there! I am using this app.',
    this.isOnline = false,
    this.lastSeen,
    this.lastMessage = '',
    this.lastTime,
  });

  Map<String, dynamic> toMap() {
    return {
      'uid': uid,
      'username': username.toLowerCase().trim(),
      'email': email,
      'displayName': displayName,
      'photoUrl': photoUrl,
      'phoneNumber': phoneNumber,
      'status': status,
      'isOnline': isOnline,
      'lastSeen': lastSeen?.toIso8601String(),
    };
  }

  factory UserModel.fromMap(Map<String, dynamic> map, String docId) {
    DateTime? parsedLastSeen;
    if (map['lastSeen'] != null) {
      if (map['lastSeen'] is String) {
        parsedLastSeen = DateTime.tryParse(map['lastSeen']);
      } else if (map['lastSeen'] is Timestamp) {
        parsedLastSeen = (map['lastSeen'] as Timestamp).toDate();
      }
    }

    return UserModel(
      uid: docId,
      username: map['username'] ?? '',
      email: map['email'] ?? '',
      displayName: map['displayName'] ?? map['username'] ?? 'User',
      photoUrl: map['photoUrl'] ?? '',
      phoneNumber: map['phoneNumber'] ?? '',
      status: map['status'] ?? 'Hey there! I am using this app.',
      isOnline: map['isOnline'] == true || map['isOnline'] == 1,
      lastSeen: parsedLastSeen,
      lastMessage: map['lastMessage'] ?? '',
      lastTime: map['lastTime'] != null ? DateTime.tryParse(map['lastTime'].toString()) : null,
    );
  }

  UserModel copyWith({
    String? uid,
    String? username,
    String? email,
    String? displayName,
    String? photoUrl,
    String? phoneNumber,
    String? status,
    bool? isOnline,
    DateTime? lastSeen,
    String? lastMessage,
    DateTime? lastTime,
  }) {
    return UserModel(
      uid: uid ?? this.uid,
      username: username ?? this.username,
      email: email ?? this.email,
      displayName: displayName ?? this.displayName,
      photoUrl: photoUrl ?? this.photoUrl,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      status: status ?? this.status,
      isOnline: isOnline ?? this.isOnline,
      lastSeen: lastSeen ?? this.lastSeen,
      lastMessage: lastMessage ?? this.lastMessage,
      lastTime: lastTime ?? this.lastTime,
    );
  }
}


