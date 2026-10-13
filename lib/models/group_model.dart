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

class GroupEventAttendeeModel {
  final int userId;
  final String name;
  final String photoUrl;
  final String status; // 'going', 'maybe', 'declined'
  final int guestCount;

  GroupEventAttendeeModel({
    required this.userId,
    required this.name,
    this.photoUrl = '',
    required this.status,
    this.guestCount = 0,
  });

  factory GroupEventAttendeeModel.fromJson(Map<String, dynamic> json) {
    return GroupEventAttendeeModel(
      userId: json['userId'] is int ? json['userId'] : int.tryParse(json['userId']?.toString() ?? '0') ?? 0,
      name: json['name']?.toString() ?? 'Üye',
      photoUrl: json['photoUrl']?.toString() ?? '',
      status: json['status']?.toString() ?? 'going',
      guestCount: json['guestCount'] is int ? json['guestCount'] : int.tryParse(json['guestCount']?.toString() ?? '0') ?? 0,
    );
  }
}

class GroupEventModel {
  final int id;
  final int messageId;
  final int groupId;
  final int creatorId;
  final String creatorName;
  final String title;
  final String description;
  final String location;
  final DateTime startTime;
  final DateTime endTime;
  final int reminderValue;
  final String reminderUnit; // 'minutes', 'hours', 'days'
  final bool allowGuests;
  final int goingCount;
  final int maybeCount;
  final int declinedCount;
  final int totalGuests;
  final String myStatus; // 'going', 'maybe', 'declined', or ''
  final int myGuestCount;
  final List<GroupEventAttendeeModel> attendees;
  final bool isPast;

  GroupEventModel({
    required this.id,
    required this.messageId,
    required this.groupId,
    required this.creatorId,
    this.creatorName = '',
    required this.title,
    this.description = '',
    required this.location,
    required this.startTime,
    required this.endTime,
    this.reminderValue = 1,
    this.reminderUnit = 'hours',
    this.allowGuests = false,
    this.goingCount = 0,
    this.maybeCount = 0,
    this.declinedCount = 0,
    this.totalGuests = 0,
    this.myStatus = '',
    this.myGuestCount = 0,
    this.attendees = const [],
    this.isPast = false,
  });

  factory GroupEventModel.fromJson(Map<String, dynamic> json) {
    DateTime sTime = DateTime.now();
    if (json['startTime'] != null && json['startTime'] != '') {
      sTime = DateTime.tryParse(json['startTime'].toString()) ?? DateTime.now();
    }
    DateTime eTime = sTime.add(const Duration(hours: 2));
    if (json['endTime'] != null && json['endTime'] != '') {
      eTime = DateTime.tryParse(json['endTime'].toString()) ?? eTime;
    }

    final attList = (json['attendees'] as List?)
            ?.map((e) => GroupEventAttendeeModel.fromJson(Map<String, dynamic>.from(e)))
            .toList() ??
        [];

    final past = json['isPast'] == true || DateTime.now().isAfter(eTime);

    return GroupEventModel(
      id: json['id'] is int ? json['id'] : int.tryParse(json['id']?.toString() ?? '0') ?? 0,
      messageId: json['messageId'] is int ? json['messageId'] : int.tryParse(json['messageId']?.toString() ?? '0') ?? 0,
      groupId: json['groupId'] is int ? json['groupId'] : int.tryParse(json['groupId']?.toString() ?? '0') ?? 0,
      creatorId: json['creatorId'] is int ? json['creatorId'] : int.tryParse(json['creatorId']?.toString() ?? '0') ?? 0,
      creatorName: json['creatorName']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      location: json['location']?.toString() ?? '',
      startTime: sTime,
      endTime: eTime,
      reminderValue: json['reminderValue'] is int ? json['reminderValue'] : int.tryParse(json['reminderValue']?.toString() ?? '1') ?? 1,
      reminderUnit: json['reminderUnit']?.toString() ?? 'hours',
      allowGuests: json['allowGuests'] == true || json['allowGuests'] == 1,
      goingCount: json['goingCount'] is int ? json['goingCount'] : int.tryParse(json['goingCount']?.toString() ?? '0') ?? 0,
      maybeCount: json['maybeCount'] is int ? json['maybeCount'] : int.tryParse(json['maybeCount']?.toString() ?? '0') ?? 0,
      declinedCount: json['declinedCount'] is int ? json['declinedCount'] : int.tryParse(json['declinedCount']?.toString() ?? '0') ?? 0,
      totalGuests: json['totalGuests'] is int ? json['totalGuests'] : int.tryParse(json['totalGuests']?.toString() ?? '0') ?? 0,
      myStatus: json['myStatus']?.toString() ?? '',
      myGuestCount: json['myGuestCount'] is int ? json['myGuestCount'] : int.tryParse(json['myGuestCount']?.toString() ?? '0') ?? 0,
      attendees: attList,
      isPast: past,
    );
  }

  GroupEventModel copyWith({
    int? id,
    int? messageId,
    int? groupId,
    int? creatorId,
    String? creatorName,
    String? title,
    String? description,
    String? location,
    DateTime? startTime,
    DateTime? endTime,
    int? reminderValue,
    String? reminderUnit,
    bool? allowGuests,
    int? goingCount,
    int? maybeCount,
    int? declinedCount,
    int? totalGuests,
    String? myStatus,
    int? myGuestCount,
    List<GroupEventAttendeeModel>? attendees,
    bool? isPast,
  }) {
    return GroupEventModel(
      id: id ?? this.id,
      messageId: messageId ?? this.messageId,
      groupId: groupId ?? this.groupId,
      creatorId: creatorId ?? this.creatorId,
      creatorName: creatorName ?? this.creatorName,
      title: title ?? this.title,
      description: description ?? this.description,
      location: location ?? this.location,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      reminderValue: reminderValue ?? this.reminderValue,
      reminderUnit: reminderUnit ?? this.reminderUnit,
      allowGuests: allowGuests ?? this.allowGuests,
      goingCount: goingCount ?? this.goingCount,
      maybeCount: maybeCount ?? this.maybeCount,
      declinedCount: declinedCount ?? this.declinedCount,
      totalGuests: totalGuests ?? this.totalGuests,
      myStatus: myStatus ?? this.myStatus,
      myGuestCount: myGuestCount ?? this.myGuestCount,
      attendees: attendees ?? this.attendees,
      isPast: isPast ?? this.isPast,
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
  final String type; // text, image, video, doc, location, poll, event
  final String? mediaUrl;
  final GroupPollModel? poll;
  final GroupEventModel? event;
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
    this.event,
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

    GroupEventModel? eModel;
    if (json['event'] != null && json['event'] is Map) {
      eModel = GroupEventModel.fromJson(Map<String, dynamic>.from(json['event']));
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
      event: eModel,
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
    GroupEventModel? event,
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
      event: event ?? this.event,
      isDeleted: isDeleted ?? this.isDeleted,
      isEdited: isEdited ?? this.isEdited,
      timestamp: timestamp ?? this.timestamp,
    );
  }
}
