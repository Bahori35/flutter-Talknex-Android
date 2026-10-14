import '../utils/media_url_helper.dart';

class StoryItem {
  final int id;
  final int userId;
  final String mediaUrl;
  final String caption;
  final String mediaType;
  final DateTime createdAt;
  final bool isViewed;
  final int viewCount;

  StoryItem({
    required this.id,
    required this.userId,
    required String mediaUrl,
    required this.caption,
    this.mediaType = 'image',
    required this.createdAt,
    this.isViewed = false,
    this.viewCount = 0,
  }) : mediaUrl = formatMediaUrl(mediaUrl);

  factory StoryItem.fromJson(Map<String, dynamic> json) {
    return StoryItem(
      id: json['id'] is int ? json['id'] : int.tryParse(json['id'].toString()) ?? 0,
      userId: json['userId'] is int ? json['userId'] : int.tryParse(json['userId'].toString()) ?? 0,
      mediaUrl: json['mediaUrl'] ?? '',
      caption: json['caption'] ?? '',
      mediaType: json['mediaType'] ?? 'image',
      createdAt: DateTime.tryParse(json['createdAt'] ?? '') ?? DateTime.now(),
      isViewed: json['isViewed'] == true || json['isViewed'] == 1,
      viewCount: json['viewCount'] is int ? json['viewCount'] : int.tryParse(json['viewCount'].toString()) ?? 0,
    );
  }
}

class UserStoryGroup {
  final int userId;
  final String username;
  final String displayName;
  final String userPhotoUrl;
  final List<StoryItem> stories;
  final bool allViewed;
  final DateTime latestTimestamp;

  UserStoryGroup({
    required this.userId,
    required this.username,
    required this.displayName,
    required String userPhotoUrl,
    required this.stories,
    required this.allViewed,
    required this.latestTimestamp,
  }) : userPhotoUrl = formatMediaUrl(userPhotoUrl);

  factory UserStoryGroup.fromJson(Map<String, dynamic> json) {
    var storyList = (json['stories'] as List<dynamic>? ?? [])
        .map((e) => StoryItem.fromJson(e as Map<String, dynamic>))
        .toList();

    return UserStoryGroup(
      userId: json['userId'] is int ? json['userId'] : int.tryParse(json['userId'].toString()) ?? 0,
      username: json['username'] ?? '',
      displayName: json['displayName'] ?? json['username'] ?? 'User',
      userPhotoUrl: json['userPhotoUrl'] ?? '',
      stories: storyList,
      allViewed: json['allViewed'] == true || json['allViewed'] == 1,
      latestTimestamp: DateTime.tryParse(json['latestTimestamp'] ?? '') ?? DateTime.now(),
    );
  }
}
