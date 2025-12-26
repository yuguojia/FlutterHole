class ApiEndpoints {
  static const String latestPosts = 'getlist';
  static const String postById = 'getone';
  static const String attentionPosts = 'getattention';
  static const String multiPosts = 'getmulti';
  static const String searchPosts = 'search';
  static const String comments = 'getcomment';
  static const String toggleAttention = 'attention';
  static const String createPost = 'dopost';

  static String createCommentV2(int pid) => 'post/$pid/comment';
}
