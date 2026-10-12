class GroupModel {
  final int id;
  final String name;
  final String photoUrl;
  final String description;
  final int createdBy;
  final String myRole; // 'admin' or 'member'
  final int memberCount;
  final String lastMessage;
  final String lastSenderId;
  final DateTime? lastTime;

  GroupModel({
    required this.id,
    required this.name,
    this.photoUrl = '',
    this.description = '',
    required this.createdBy,
    this.myRole = 'member',
    this.memberCount = 1,
    this.lastMessage = '',
    this.lastSenderId = '',
    this.lastTime,
  });

  bool get isAdmin => myRole == 'admin';

  factory GroupModel.fromJson(Map<String, dynamic> json) {
    DateTime? parsedTime;
    if (json['lastTime'] != null && json['lastTime'] != '') {
      parsedTime = DateTime.tryParse(json['lastTime'].toString());
    }

    return GroupModel(
      id: json['id'] is int ? json['id'] : int.tryParse(json['id']?.toString() ?? '0') ?? 0,
      name: json['name']?.toString() ?? 'Grup',
      photoUrl: json['photoUrl']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      createdBy: json['createdBy'] is int ? json['createdBy'] : int.tryParse(json['createdBy']?.toString() ?? '0') ?? 0,
      myRole: json['myRole']?.toString() ?? 'member',
      memberCount: json['memberCount'] is int ? json['memberCount'] : int.tryParse(json['memberCount']?.toString() ?? '1') ?? 1,
      lastMessage: json['lastMessage']?.toString() ?? '',
      lastSenderId: json['lastSenderId']?.toString() ?? '',
      lastTime: parsedTime,
    );
  }

  GroupModel copyWith({
    int? id,
    String? name,
    String? photoUrl,
    String? description,
    int? createdBy,
    String? myRole,
    int? memberCount,
    String? lastMessage,
    DateTime? lastTime,
  }) {
    return GroupModel(
      id: id ?? this.id,
      name: name ?? this.name,
      photoUrl: photoUrl ?? this.photoUrl,
      description: description ?? this.description,
      createdBy: createdBy ?? this.createdBy,
      myRole: myRole ?? this.myRole,
      memberCount: memberCount ?? this.memberCount,
      lastMessage: lastMessage ?? this.lastMessage,
      lastTime: lastTime ?? this.lastTime,
    );
  }
}

class GroupMemberModel {
  final int userId;
  final String username;
  final String displayName;
  final String photoUrl;
  final String phoneNumber;
  final String role; // 'admin' or 'member'
  final DateTime? joinedAt;

  GroupMemberModel({
    required this.userId,
    required this.username,
    required this.displayName,
    this.photoUrl = '',
    this.phoneNumber = '',
    this.role = 'member',
    this.joinedAt,
  });

  bool get isAdmin => role == 'admin';

  factory GroupMemberModel.fromJson(Map<String, dynamic> json) {
    DateTime? jAt;
    if (json['joinedAt'] != null && json['joinedAt'] != '') {
      jAt = DateTime.tryParse(json['joinedAt'].toString());
    }

    return GroupMemberModel(
      userId: json['userId'] is int ? json['userId'] : int.tryParse(json['userId']?.toString() ?? '0') ?? 0,
      username: json['username']?.toString() ?? '',
      displayName: json['displayName']?.toString() ?? json['username']?.toString() ?? 'Kullanıcı',
      photoUrl: json['photoUrl']?.toString() ?? '',
      phoneNumber: json['phoneNumber']?.toString() ?? '',
      role: json['role']?.toString() ?? 'member',
      joinedAt: jAt,
    );
  }
}

class GroupMessageModel {
  final String id;
  final int groupId;
  final String senderId;
  final String senderName;
  final String senderPhoto;
  final String content;
  final String type; // text, image, video, doc, location
  final String? mediaUrl;
  final bool isDeleted;
  final bool isEdited;
  final DateTime timestamp;

  GroupMessageModel({
    required this.id,
    required this.groupId,
    required this.senderId,
    required this.senderName,
    this.senderPhoto = '',
    required this.content,
    this.type = 'text',
    this.mediaUrl,
    this.isDeleted = false,
    this.isEdited = false,
    required this.timestamp,
  });

  factory GroupMessageModel.fromJson(Map<String, dynamic> json) {
    DateTime t = DateTime.now();
    if (json['timestamp'] != null && json['timestamp'] != '') {
      t = DateTime.tryParse(json['timestamp'].toString()) ?? DateTime.now();
    }

    return GroupMessageModel(
      id: json['id']?.toString() ?? '',
      groupId: json['groupId'] is int ? json['groupId'] : int.tryParse(json['groupId']?.toString() ?? '0') ?? 0,
      senderId: json['senderId']?.toString() ?? '',
      senderName: json['senderName']?.toString() ?? 'Üye',
      senderPhoto: json['senderPhoto']?.toString() ?? '',
      content: json['content']?.toString() ?? '',
      type: json['type']?.toString() ?? 'text',
      mediaUrl: json['mediaUrl']?.toString(),
      isDeleted: json['isDeleted'] == 1 || json['isDeleted'] == true,
      isEdited: json['isEdited'] == 1 || json['isEdited'] == true,
      timestamp: t,
    );
  }

  GroupMessageModel copyWith({
    String? id,
    int? groupId,
    String? senderId,
    String? senderName,
    String? senderPhoto,
    String? content,
    String? type,
    String? mediaUrl,
    bool? isDeleted,
    bool? isEdited,
    DateTime? timestamp,
  }) {
    return GroupMessageModel(
      id: id ?? this.id,
      groupId: groupId ?? this.groupId,
      senderId: senderId ?? this.senderId,
      senderName: senderName ?? this.senderName,
      senderPhoto: senderPhoto ?? this.senderPhoto,
      content: content ?? this.content,
      type: type ?? this.type,
      mediaUrl: mediaUrl ?? this.mediaUrl,
      isDeleted: isDeleted ?? this.isDeleted,
      isEdited: isEdited ?? this.isEdited,
      timestamp: timestamp ?? this.timestamp,
    );
  }
}
