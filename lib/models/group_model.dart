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

class GroupPollOptionModel {
  final int index;
  final String text;
  final int voteCount;
  final double percentage;
  final bool hasVoted;
  final List<String> voterNames;

  GroupPollOptionModel({
    required this.index,
    required this.text,
    this.voteCount = 0,
    this.percentage = 0.0,
    this.hasVoted = false,
    this.voterNames = const [],
  });

  factory GroupPollOptionModel.fromJson(Map<String, dynamic> json) {
    return GroupPollOptionModel(
      index: json['index'] is int ? json['index'] : int.tryParse(json['index']?.toString() ?? '0') ?? 0,
      text: json['text']?.toString() ?? '',
      voteCount: json['voteCount'] is int ? json['voteCount'] : int.tryParse(json['voteCount']?.toString() ?? '0') ?? 0,
      percentage: (json['percentage'] is num) ? (json['percentage'] as num).toDouble() : 0.0,
      hasVoted: json['hasVoted'] == true || json['hasVoted'] == 1,
      voterNames: (json['voterNames'] as List?)?.map((e) => e.toString()).toList() ?? [],
    );
  }
}

class GroupPollModel {
  final int id;
  final int messageId;
  final int groupId;
  final int creatorId;
  final String title;
  final List<GroupPollOptionModel> options;
  final int totalVotes;
  final DateTime expiresAt;
  final bool isExpired;
  final bool canChangeVote;

  GroupPollModel({
    required this.id,
    required this.messageId,
    required this.groupId,
    required this.creatorId,
    required this.title,
    required this.options,
    this.totalVotes = 0,
    required this.expiresAt,
    this.isExpired = false,
    this.canChangeVote = true,
  });

  factory GroupPollModel.fromJson(Map<String, dynamic> json) {
    DateTime exp = DateTime.now();
    if (json['expiresAt'] != null && json['expiresAt'] != '') {
      exp = DateTime.tryParse(json['expiresAt'].toString()) ?? DateTime.now();
    }

    final opts = (json['options'] as List?)
            ?.map((e) => GroupPollOptionModel.fromJson(Map<String, dynamic>.from(e)))
            .toList() ??
        [];

    final isExp = json['isExpired'] == true || DateTime.now().isAfter(exp);
    final diff = exp.difference(DateTime.now());
    final canChange = !isExp && diff.inMinutes > 60;

    return GroupPollModel(
      id: json['id'] is int ? json['id'] : int.tryParse(json['id']?.toString() ?? '0') ?? 0,
      messageId: json['messageId'] is int ? json['messageId'] : int.tryParse(json['messageId']?.toString() ?? '0') ?? 0,
      groupId: json['groupId'] is int ? json['groupId'] : int.tryParse(json['groupId']?.toString() ?? '0') ?? 0,
      creatorId: json['creatorId'] is int ? json['creatorId'] : int.tryParse(json['creatorId']?.toString() ?? '0') ?? 0,
      title: json['title']?.toString() ?? '',
      options: opts,
      totalVotes: json['totalVotes'] is int ? json['totalVotes'] : int.tryParse(json['totalVotes']?.toString() ?? '0') ?? 0,
      expiresAt: exp,
      isExpired: isExp,
      canChangeVote: json['canChangeVote'] != null ? json['canChangeVote'] == true : canChange,
    );
  }

  GroupPollModel copyWith({
    int? id,
    int? messageId,
    int? groupId,
    int? creatorId,
    String? title,
    List<GroupPollOptionModel>? options,
    int? totalVotes,
    DateTime? expiresAt,
    bool? isExpired,
    bool? canChangeVote,
  }) {
    return GroupPollModel(
      id: id ?? this.id,
      messageId: messageId ?? this.messageId,
      groupId: groupId ?? this.groupId,
      creatorId: creatorId ?? this.creatorId,
      title: title ?? this.title,
      options: options ?? this.options,
      totalVotes: totalVotes ?? this.totalVotes,
      expiresAt: expiresAt ?? this.expiresAt,
      isExpired: isExpired ?? this.isExpired,
      canChangeVote: canChangeVote ?? this.canChangeVote,
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
  final String type; // text, image, video, doc, location, poll
  final String? mediaUrl;
  final GroupPollModel? poll;
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
    this.poll,
    this.isDeleted = false,
    this.isEdited = false,
    required this.timestamp,
  });

  factory GroupMessageModel.fromJson(Map<String, dynamic> json) {
    DateTime t = DateTime.now();
    if (json['timestamp'] != null && json['timestamp'] != '') {
      t = DateTime.tryParse(json['timestamp'].toString()) ?? DateTime.now();
    }

    GroupPollModel? pModel;
    if (json['poll'] != null && json['poll'] is Map) {
      pModel = GroupPollModel.fromJson(Map<String, dynamic>.from(json['poll']));
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
      poll: pModel,
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
    GroupPollModel? poll,
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
      poll: poll ?? this.poll,
      isDeleted: isDeleted ?? this.isDeleted,
      isEdited: isEdited ?? this.isEdited,
      timestamp: timestamp ?? this.timestamp,
    );
  }
}
