import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'constants.dart';
import 'api_endpoints.dart';
import 'models.dart';
import 'utils.dart';

class TholeApiClient {
  TholeApiClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<List<Post>> fetchLatestPosts({
    required String token,
    required String baseUrl,
    int page = 1,
    int roomId = 1,
    int orderMode = 0,
  }) async {
    final uri = _buildUri(
      baseUrl,
      ApiEndpoints.latestPosts,
      queryParameters: {
        'p': '$page',
        'order_mode': '$orderMode',
        'room_id': '$roomId',
        if (kIsWeb) 'token': token,
      },
    );
    final data = await _get(uri, token: token);
    final list = (data['data'] as List<dynamic>)
        .map((item) => Post.fromJson(item as Map<String, dynamic>))
        .toList();
    await PostCache.putMany(baseUrl, list);
    return list;
  }

  Future<Post> fetchPostById({
    required String token,
    required String baseUrl,
    required int pid,
    bool bypassCache = false,
  }) async {
    final cached = await PostCache.get(
      baseUrl,
      pid,
      bypassCache: bypassCache,
    );
    if (cached != null) return cached;
    final uri = _buildUri(
      baseUrl,
      ApiEndpoints.postById,
      queryParameters: {
        'pid': '$pid',
        if (kIsWeb) 'token': token,
      },
    );
    final data = await _get(uri, token: token);
    final item = data['data'] as Map<String, dynamic>;
    final post = Post.fromJson(item);
    await PostCache.putMany(baseUrl, [post]);
    return post;
  }

  Future<List<Post>> fetchAttentionPosts({
    required String token,
    required String baseUrl,
  }) async {
    final uri = _buildUri(
      baseUrl,
      ApiEndpoints.attentionPosts,
      queryParameters: {
        if (kIsWeb) 'token': token,
      },
    );
    final data = await _get(uri, token: token);
    final raw = data['data'];
    if (raw is! List) return [];
    if (raw.isEmpty) return [];
    if (raw.first is Map<String, dynamic>) {
      final posts = raw
          .map((item) => Post.fromJson(item as Map<String, dynamic>))
          .toList();
      await PostCache.putMany(baseUrl, posts);
      return posts;
    }
    final pids = raw
        .map((item) => parseInt(item))
        .where((pid) => pid > 0)
        .toList();
    final posts = <Post>[];
    for (final pid in pids) {
      try {
        final post = await fetchPostById(
          token: token,
          baseUrl: baseUrl,
          pid: pid,
        );
        posts.add(post);
      } catch (_) {}
    }
    return posts;
  }

  Future<List<Post>> fetchMultiPosts({
    required String token,
    required String baseUrl,
    required List<int> pids,
    bool bypassCache = false,
  }) async {
    if (pids.isEmpty) return [];
    final uniquePids = pids.where((pid) => pid > 0).toSet().toList();
    final cachedMap = <int, Post>{};
    if (!bypassCache) {
      for (final pid in uniquePids) {
        final cached = await PostCache.get(baseUrl, pid);
        if (cached != null) {
          cachedMap[pid] = cached;
        }
      }
    }
    final missing = uniquePids.where((pid) => !cachedMap.containsKey(pid)).toList();
    final fetched = <Post>[];
    if (missing.isNotEmpty) {
      try {
        final query = missing.map((pid) => 'pids=$pid').join('&');
        final tokenQuery = kIsWeb ? 'token=$token&' : '';
        final uri = Uri.parse(
          '$baseUrl/${ApiEndpoints.multiPosts}?$tokenQuery$query',
        );
        final data = await _get(uri, token: token);
        final raw = data['data'];
        if (raw is List) {
          fetched.addAll(
            raw.map((item) => Post.fromJson(item as Map<String, dynamic>)),
          );
        }
      } catch (_) {
        for (final pid in missing) {
          try {
            final post = await fetchPostById(
              token: token,
              baseUrl: baseUrl,
              pid: pid,
              bypassCache: true,
            );
            fetched.add(post);
          } catch (_) {}
        }
      }
    }
    if (fetched.isNotEmpty) {
      await PostCache.putMany(baseUrl, fetched);
    }
    final resultMap = {
      for (final entry in cachedMap.entries) entry.key: entry.value,
      for (final post in fetched) post.pid: post,
    };
    return uniquePids
        .where((pid) => resultMap.containsKey(pid))
        .map((pid) => resultMap[pid]!)
        .toList();
  }

  Future<List<Post>> searchPosts({
    required String token,
    required String baseUrl,
    required int roomId,
    required String keywords,
    required int page,
    required int pageSize,
    required SearchMode searchMode,
  }) async {
    final uri = _buildUri(
      baseUrl,
      ApiEndpoints.searchPosts,
      queryParameters: {
        'search_mode': searchMode == SearchMode.tag ? '0' : '1',
        'page': '$page',
        'room_id': '$roomId',
        'keywords': keywords,
        'pagesize': '$pageSize',
        if (kIsWeb) 'token': token,
      },
    );
    final data = await _get(uri, token: token);
    final raw = data['data'];
    if (raw is! List) return [];
    final posts = raw
        .map((item) => Post.fromJson(item as Map<String, dynamic>))
        .toList();
    await PostCache.putMany(baseUrl, posts);
    return posts;
  }

  Future<List<Comment>> fetchComments({
    required String token,
    required String baseUrl,
    required int pid,
  }) async {
    final uri = _buildUri(
      baseUrl,
      ApiEndpoints.comments,
      queryParameters: {
        'pid': '$pid',
        if (kIsWeb) 'token': token,
      },
    );
    final data = await _get(uri, token: token);
    final list = (data['data'] as List<dynamic>)
        .map((item) => Comment.fromJson(item as Map<String, dynamic>))
        .toList();
    return list;
  }

  Future<void> toggleAttention({
    required String token,
    required String baseUrl,
    required int pid,
    required bool enable,
  }) async {
    final uri = _buildUri(
      baseUrl,
      ApiEndpoints.toggleAttention,
      queryParameters: {
        if (kIsWeb) 'token': token,
      },
    );
    await _post(
      uri,
      token: token,
      body: {'pid': '$pid', 'switch': enable ? '1' : '0'},
    );
  }

  Future<void> createPost({
    required String token,
    required String baseUrl,
    required int roomId,
    required String text,
    String cw = '',
  }) async {
    final uri = _buildUri(
      baseUrl,
      ApiEndpoints.createPost,
      queryParameters: {
        if (kIsWeb) 'token': token,
      },
    );
    await _post(
      uri,
      token: token,
      body: {
        'cw': cw,
        'text': text,
        'allow_search': '1',
        'use_title': '',
        'room_id': '$roomId',
      },
    );
  }

  Future<void> createComment({
    required String token,
    required String baseUrl,
    required int pid,
    required String text,
  }) async {
    final uri = _buildApiV2Uri(baseUrl, ApiEndpoints.createCommentV2(pid));
    final uriWithToken = kIsWeb
        ? uri.replace(queryParameters: {'token': token})
        : uri;
    await _post(
      uriWithToken,
      token: token,
      body: {
        'text': text,
        'use_title': '',
      },
    );
  }

  Uri _buildUri(
    String baseUrl,
    String path, {
    Map<String, String>? queryParameters,
  }) {
    var sanitized = baseUrl;
    while (sanitized.endsWith('/')) {
      sanitized = sanitized.substring(0, sanitized.length - 1);
    }
    final full = '$sanitized/$path';
    return Uri.parse(full).replace(queryParameters: queryParameters);
  }

  Uri _buildApiV2Uri(String baseUrl, String path) {
    var sanitized = baseUrl;
    while (sanitized.endsWith('/')) {
      sanitized = sanitized.substring(0, sanitized.length - 1);
    }
    if (sanitized.endsWith('/_api/v1')) {
      sanitized = sanitized.substring(0, sanitized.length - '/_api/v1'.length);
    } else if (sanitized.endsWith('/_api/v2')) {
      sanitized = sanitized.substring(0, sanitized.length - '/_api/v2'.length);
    }
    final full = '$sanitized/_api/v2/$path';
    return Uri.parse(full);
  }

  Future<Map<String, dynamic>> _get(Uri uri, {required String token}) async {
    if (token.isEmpty) {
      throw const ApiException('Token 不能为空');
    }
    final headers = kIsWeb
        ? <String, String>{}
        : {'User-Agent': userAgent, 'User-Token': token};
    final response = await _client.get(
      uri,
      headers: headers,
    );
    if (response.statusCode != 200) {
      throw ApiException('请求失败: HTTP ${response.statusCode}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final code = body['code'] as int? ?? 0;
    if (code != 0) {
      throw ApiException('接口错误: code $code');
    }
    return body;
  }

  Future<Map<String, dynamic>> _post(
    Uri uri, {
    required String token,
    required Map<String, String> body,
  }) async {
    if (token.isEmpty) {
      throw const ApiException('Token 不能为空');
    }
    final headers = kIsWeb
        ? <String, String>{}
        : {'User-Agent': userAgent, 'User-Token': token};
    final response = await _client.post(
      uri,
      headers: headers,
      body: body,
    );
    if (response.statusCode != 200) {
      throw ApiException('请求失败: HTTP ${response.statusCode}');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final code = data['code'] as int? ?? 0;
    if (code != 0) {
      throw ApiException('接口错误: code $code');
    }
    return data;
  }
}

class ApiException implements Exception {
  const ApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class FavoritesStore {
  static String _key(String backendKey) => 'local_favorites_$backendKey';

  static Future<List<int>> load(String backendKey) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_key(backendKey)) ?? const <String>[];
    return list
        .map((value) => int.tryParse(value) ?? 0)
        .where((v) => v > 0)
        .toList();
  }

  static Future<void> update(String backendKey, int pid, bool enabled) async {
    final current = await load(backendKey);
    final set = current.toSet();
    if (enabled) {
      set.add(pid);
    } else {
      set.remove(pid);
    }
    await _save(backendKey, set.toList());
  }

  static Future<void> saveFromText(String backendKey, String text) async {
    final matches = RegExp(r'#?(\d{1,9})').allMatches(text);
    final set = <int>{};
    for (final match in matches) {
      final value = int.tryParse(match.group(1) ?? '');
      if (value != null && value > 0) {
        set.add(value);
      }
    }
    await _save(backendKey, set.toList());
  }

  static Future<void> _save(String backendKey, List<int> values) async {
    final prefs = await SharedPreferences.getInstance();
    final sorted = values.toSet().toList()..sort();
    await prefs.setStringList(
      _key(backendKey),
      sorted.map((value) => value.toString()).toList(),
    );
  }
}

class PostCache {
  static const _prefsKey = 'post_cache_v1';
  static const _ttl = Duration(hours: 1);
  static final Map<String, _PostCacheEntry> _entries = {};
  static bool _loaded = false;
  static bool _enabled = true;
  static Duration _dynamicTtl = _ttl;

  static String _key(String baseUrl, int pid) => '$baseUrl|$pid';

  static Future<Post?> get(
    String baseUrl,
    int pid, {
    bool bypassCache = false,
  }) async {
    if (bypassCache) return null;
    await _ensureLoaded();
    if (!_enabled) return null;
    final entry = _entries[_key(baseUrl, pid)];
    if (entry == null) return null;
    if (_isExpired(entry.timestampMs)) {
      _entries.remove(_key(baseUrl, pid));
      await _persist();
      return null;
    }
    return Post.fromJson(entry.data);
  }

  static Future<void> putMany(String baseUrl, List<Post> posts) async {
    if (posts.isEmpty) return;
    await _ensureLoaded();
    if (!_enabled) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final post in posts) {
      _entries[_key(baseUrl, post.pid)] = _PostCacheEntry(
        timestampMs: now,
        data: post.toJson(),
      );
    }
    await _persist();
  }

  static Future<void> applyConfig({
    required bool enabled,
    required int ttlMinutes,
  }) async {
    _enabled = enabled;
    _dynamicTtl = Duration(minutes: ttlMinutes > 0 ? ttlMinutes : 0);
    await _ensureLoaded();
    if (!enabled) {
      _entries.clear();
      await _persist();
    }
  }

  static bool _isExpired(int timestampMs) {
    if (!_enabled) return true;
    if (_dynamicTtl == Duration.zero) return true;
    final expiresAt = timestampMs + _dynamicTtl.inMilliseconds;
    return DateTime.now().millisecondsSinceEpoch > expiresAt;
  }

  static Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_prefsKey);
    if (json == null || json.isEmpty) return;
    try {
      final raw = jsonDecode(json) as Map<String, dynamic>;
      for (final entry in raw.entries) {
        final value = entry.value;
        if (value is Map<String, dynamic>) {
          _entries[entry.key] = _PostCacheEntry.fromJson(value);
        }
      }
    } catch (_) {}
  }

  static Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final payload = {
      for (final entry in _entries.entries) entry.key: entry.value.toJson(),
    };
    await prefs.setString(_prefsKey, jsonEncode(payload));
  }
}

class _PostCacheEntry {
  _PostCacheEntry({required this.timestampMs, required this.data});

  final int timestampMs;
  final Map<String, dynamic> data;

  factory _PostCacheEntry.fromJson(Map<String, dynamic> json) {
    return _PostCacheEntry(
      timestampMs: json['timestamp_ms'] as int? ?? 0,
      data: (json['data'] as Map<String, dynamic>?) ?? const {},
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'timestamp_ms': timestampMs,
      'data': data,
    };
  }
}
