import 'constants.dart';
import 'utils.dart';

class Post {
  Post({
    required this.pid,
    required this.text,
    this.timestamp,
    this.commentCount = 0,
    this.attention,
    this.tags = const [],
  });

  final int pid;
  final String text;
  final int? timestamp;
  final int commentCount;
  final bool? attention;
  final List<String> tags;

  factory Post.fromJson(Map<String, dynamic> json) {
    final timestampValue = json['timestamp'] ?? json['create_time'];
    final textValue = (json['text'] as String?)?.trim() ?? '';
    final tags = parseTags(json, textValue);
    return Post(
      pid: parseInt(json['pid']),
      text: textValue,
      timestamp: timestampValue is int ? timestampValue : null,
      commentCount: json['n_comments'] is int
          ? json['n_comments'] as int
          : (json['reply'] is int ? json['reply'] as int : 0),
      attention: json['attention'] is bool ? json['attention'] as bool : null,
      tags: tags,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'pid': pid,
      'text': text,
      'timestamp': timestamp,
      'n_comments': commentCount,
      'attention': attention,
      'tags': tags,
    };
  }

  Post copyWith({
    bool? attention,
  }) {
    return Post(
      pid: pid,
      text: text,
      timestamp: timestamp,
      commentCount: commentCount,
      attention: attention ?? this.attention,
      tags: tags,
    );
  }
}

class Comment {
  Comment({
    required this.cid,
    required this.nameId,
    required this.text,
    this.timestamp,
  });

  final int cid;
  final int nameId;
  final String text;
  final int? timestamp;

  factory Comment.fromJson(Map<String, dynamic> json) {
    final timestampValue = json['timestamp'] ?? json['create_time'];
    return Comment(
      cid: parseInt(json['cid']),
      nameId: parseInt(json['name_id']),
      text: (json['text'] as String?)?.trim() ?? '',
      timestamp: timestampValue is int ? timestampValue : null,
    );
  }
}

enum BackendType { t, q, qOld }

enum FeedMode {
  latestReply(1, '最新回复'),
  latestPost(0, '最新发布'),
  hot(2, '热门'),
  random(3, '随机'),
  classic(4, '典藏');

  const FeedMode(this.orderMode, this.label);

  final int orderMode;
  final String label;
}

enum SearchMode { tag, full }

class BackendConfig {
  const BackendConfig({
    required this.name,
    required this.baseUrl,
    required this.webProxyBaseUrl,
    required this.roomId,
    this.supportsSearch = false,
    this.supportsPost = true,
    this.supportsComment = false,
  });

  final String name;
  final String baseUrl;
  final String webProxyBaseUrl;
  final int roomId;
  final bool supportsSearch;
  final bool supportsPost;
  final bool supportsComment;

  static const t = BackendConfig(
    name: '新 T 树洞',
    baseUrl: tholeBaseUrl,
    webProxyBaseUrl: tholeWebProxyBaseUrl,
    roomId: 1,
    supportsSearch: true,
    supportsPost: true,
    supportsComment: true,
  );

  static const q = BackendConfig(
    name: '新 Q 树洞',
    baseUrl: 'https://api.thuhole.site/_api/v1',
    webProxyBaseUrl: tholeWebProxyQBaseUrl,
    roomId: 0,
    supportsSearch: true,
    supportsComment: true,
    supportsPost: true,
  );

  static const qOld = BackendConfig(
    name: '新 Q 旧洞',
    baseUrl: 'https://api2.thuhole.site/_api/v1',
    webProxyBaseUrl: tholeWebProxyQ2BaseUrl,
    roomId: 0,
    supportsSearch: true,
    supportsPost: false,
    supportsComment: false,
  );
}

class SettingsResult {
  const SettingsResult({
    required this.tokenT,
    required this.tokenQ,
    required this.cacheEnabled,
    required this.cacheTtlMinutes,
    required this.collapseTaggedPosts,
    required this.autoHideBottomBar,
    required this.enableTImageRefererSpoof,
  });

  final String tokenT;
  final String tokenQ;
  final bool cacheEnabled;
  final int cacheTtlMinutes;
  final bool collapseTaggedPosts;
  final bool autoHideBottomBar;
  final bool enableTImageRefererSpoof;
}
