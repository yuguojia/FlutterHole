import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:porter_2_stemmer/porter_2_stemmer.dart';
import 'package:porter_2_stemmer/extensions.dart';

import '../models.dart';
import '../services.dart';
import '../utils.dart';
import '../widgets.dart';
import 'post_detail_page.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({
    super.key,
    required this.token,
    required this.baseUrl,
    required this.roomId,
    required this.backendKey,
    required this.supportsComment,
    this.imageHeaders,
  });

  final String token;
  final String baseUrl;
  final int roomId;
  final String backendKey;
  final bool supportsComment;
  final Map<String, String>? imageHeaders;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _apiClient = TholeApiClient();
  final _controller = TextEditingController();
  final List<Post> _results = [];
  bool _isLoading = false;
  bool _isFetchingMore = false;
  bool _hasMore = true;
  int _page = 1;
  SearchMode _mode = SearchMode.full;
  String? _errorMessage;
  final Set<int> _togglingAttention = {};

  bool get _isLocal => widget.backendKey == 'local';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // ================= 搜索词处理：与导入时建立索引的算法保持一致 =================
  String _tokenizePhrase(String text) {
    if (text.isEmpty) return '';
    final tokens = <String>[];
    final RegExp regex = RegExp(r'[a-zA-Z]+|[^a-zA-Z\s]+');
    final matches = regex.allMatches(text);
    for (final match in matches) {
      final str = match.group(0)!;
      if (RegExp(r'^[a-zA-Z]+$').hasMatch(str)) {
        tokens.add(str.toLowerCase().stemPorter2());
      } else {
        for (final rune in str.runes) {
          tokens.add(String.fromCharCode(rune));
        }
      }
    }
    return tokens.join(' ');
  }

  // ================= 跳转到指定 PID 详情页 =================
  Future<void> _jumpToPid(int pid) async {
    // 隐藏键盘
    FocusScope.of(context).unfocus();
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => PostDetailPage(
          post: null, // 传入 null 让详情页自己去 fetch 该 PID 的数据
          pid: pid,
          token: widget.token,
          baseUrl: widget.baseUrl,
          backendKey: widget.backendKey,
          supportsComment: widget.supportsComment,
          imageHeaders: widget.imageHeaders,
        ),
      ),
    );
  }

  // ================= 本地 SQLite 检索引擎 =================
  Future<List<Post>> _localSearch(String keywords, int page, int pageSize) async {
    Directory appDocDir = await getApplicationDocumentsDirectory();
    String dbPath = p.join(appDocDir.path, 'old_hole.db');
    Database db = await openDatabase(dbPath);

    int offset = (page - 1) * pageSize;
    List<Map<String, dynamic>> maps;

    // 1. 将用户的搜索词用空格切分（支持多关键词 AND 搜索）
    final userKeywords = keywords.split(RegExp(r'\s+')).where((e) => e.isNotEmpty);

    if (_mode == SearchMode.tag) {
      // 标签模式搜索：使用原生的 LIKE 匹配
      String whereClause = userKeywords.map((_) => 'tag LIKE ?').join(' AND ');
      List<String> whereArgs = userKeywords.map((kw) => '%$kw%').toList();

      maps = await db.query(
        'posts',
        where: whereClause,
        whereArgs: whereArgs,
        orderBy: 'pid DESC',
        limit: pageSize,
        offset: offset,
      );
    } else {
      // 全文检索模式：转换为 FTS MATCH 语句
      // 例如用户输入 "大物 实验" -> FTS 语法为: '"大 物" "实 验"' (用双引号包裹短语，空格代表 AND)
      final matchQuery = userKeywords.map((kw) {
        final tokenized = _tokenizePhrase(kw);
        return '"$tokenized"';
      }).join(' ');

      // 同时检索主帖表和回复表。如果回复命中，取其 pid 并连结主帖表
      final sql = '''
         SELECT p.* FROM posts p
         WHERE p.pid IN (
           SELECT rowid FROM posts_fts WHERE posts_fts MATCH ?
           UNION
           SELECT pid FROM replies_fts WHERE replies_fts MATCH ?
         )
         ORDER BY p.pid DESC
         LIMIT ? OFFSET ?
      ''';
      maps = await db.rawQuery(sql, [matchQuery, matchQuery, pageSize, offset]);
    }

    // 查询本地关注列表状态
    final localFavorites = await FavoritesStore.load(widget.backendKey);

    await db.close();

    return maps.map((m) {
      final pid = m['pid'] as int;
      return Post(
        pid: pid,
        text: m['text'] as String,
        timestamp: m['timestamp'] as int?,
        commentCount: m['reply_count'] as int? ?? 0,
        attention: localFavorites.contains(pid), // 如果在本地关注表中，点亮星星
        tags: m['tag'] != null && m['tag'].toString().trim().isNotEmpty
            ? [m['tag'].toString()]
            : [],
      );
    }).toList();
  }

  Future<void> _search({bool append = false}) async {
    final keywords = _controller.text.trim();
    if (keywords.isEmpty) {
      setState(() {
        _results.clear();
        _errorMessage = null;
        _hasMore = false;
      });
      return;
    }

    // 拦截 1: 判断是否为 "#数字" 格式，如果是则直接跳转，跳过下方搜索流程
    final pidMatch = RegExp(r'^#(\d+)$').firstMatch(keywords);
    if (pidMatch != null) {
      final pid = int.parse(pidMatch.group(1)!);
      _jumpToPid(pid);
      return;
    }

    if (!mounted) return;
    setState(() {
      if (append) {
        _isFetchingMore = true;
      } else {
        _isLoading = true;
        _errorMessage = null;
      }
    });

    try {
      final nextPage = append ? _page + 1 : 1;
      List<Post> posts;

      if (_isLocal) {
        // 执行本地 SQLite 多关键词 AND 搜索
        posts = await _localSearch(keywords, nextPage, 50);
      } else {
        // 执行线上 API 搜索
        posts = await _apiClient.searchPosts(
          token: widget.token,
          baseUrl: widget.baseUrl,
          roomId: widget.roomId,
          keywords: keywords,
          page: nextPage,
          pageSize: 50,
          searchMode: _mode,
        );
      }

      if (!mounted) return;
      setState(() {
        if (append) {
          _results.addAll(posts);
          _page = nextPage;
        } else {
          _results
            ..clear()
            ..addAll(posts);
          _page = 1;
        }
        _hasMore = posts.isNotEmpty;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        if (append) {
          _results.clear();
        }
        _errorMessage = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isFetchingMore = false;
        });
      }
    }
  }

  bool _onScrollNotification(ScrollNotification notification) {
    final atBottom = notification.metrics.extentAfter == 0;
    final isPullUp = notification is OverscrollNotification
        ? notification.overscroll > 0
        : notification is ScrollEndNotification && atBottom;
    if (atBottom && isPullUp) {
      if (_isLoading || _isFetchingMore || !_hasMore) return false;
      _search(append: true);
    }
    return false;
  }

  Future<void> _openDetail(Post post) async {
    final updated = await Navigator.of(context).push<Post>(
      MaterialPageRoute(
        builder: (context) => PostDetailPage(
          post: post,
          pid: post.pid,
          token: widget.token,
          baseUrl: widget.baseUrl,
          backendKey: widget.backendKey,
          supportsComment: widget.supportsComment,
          imageHeaders: widget.imageHeaders,
        ),
      ),
    );
    if (updated != null) {
      setState(() {
        _replacePostAttention(_results, updated.pid, updated.attention ?? false);
      });
    }
  }

  void _replacePostAttention(List<Post> list, int pid, bool next) {
    final index = list.indexWhere((item) => item.pid == pid);
    if (index == -1) return;
    list[index] = list[index].copyWith(attention: next);
  }

  Future<void> _togglePostAttention(Post post) async {
    if (_togglingAttention.contains(post.pid)) return;
    setState(() {
      _togglingAttention.add(post.pid);
    });
    final next = !(post.attention ?? false);
    try {
      // 拦截本地模式的网络接口请求
      if (!_isLocal) {
        await _apiClient.toggleAttention(
          token: widget.token,
          baseUrl: widget.baseUrl,
          pid: post.pid,
          enable: next,
        );
      }
      await FavoritesStore.update(widget.backendKey, post.pid, next);
      if (!mounted) return;
      setState(() {
        _replacePostAttention(_results, post.pid, next);
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('操作失败: $error')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _togglingAttention.remove(post.pid);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('搜索'),
        actions: [
          IconButton(
            onPressed: () {
              FocusScope.of(context).unfocus();
              _search();
            },
            tooltip: '搜索',
            icon: const Icon(Icons.search),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                TextField(
                  controller: _controller,
                  textInputAction: TextInputAction.search, // 键盘上显示搜索按钮
                  decoration: const InputDecoration(
                    labelText: '关键词',
                    hintText: '使用空格分隔以进行多词检索，输入 #PID 可直接跳转',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) {
                    FocusScope.of(context).unfocus();
                    _search();
                  },
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    ChoiceChip(
                      label: const Text('全文搜索'),
                      selected: _mode == SearchMode.full,
                      onSelected: (value) {
                        setState(() {
                          _mode = SearchMode.full;
                        });
                        // 切换模式后如果有内容则自动重新搜索
                        if (_controller.text.isNotEmpty) _search();
                      },
                    ),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: const Text('Tag 搜索'),
                      selected: _mode == SearchMode.tag,
                      onSelected: (value) {
                        setState(() {
                          _mode = SearchMode.tag;
                        });
                        if (_controller.text.isNotEmpty) _search();
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(child: _buildSearchResults()),
        ],
      ),
    );
  }

  Widget _buildSearchResults() {
    if (_isLoading && _results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '搜索失败\n$_errorMessage',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _search,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_results.isEmpty) {
      return const Center(child: Text('暂无结果'));
    }
    return NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _results.length + (_isFetchingMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= _results.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(child: Text('加载中...')),
            );
          }
          final post = _results[index];
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Card(
              elevation: 0,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => _openDetail(post),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Stack(
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TagPidRow(tags: post.tags, pid: post.pid),
                          const SizedBox(height: 8),
                          MarkdownContent(
                            text: truncateMarkdown(post.text, 200),
                            maxImageHeight: 220,
                            token: widget.token,
                            baseUrl: widget.baseUrl,
                            currentPostId: post.pid,
                            onOpenPost: _openDetail,
                            imageHeaders: widget.imageHeaders,
                            selectable: false,
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            children: [
                              if (post.timestamp != null)
                                Text(
                                  formatTimestamp(post.timestamp!),
                                  style: Theme.of(context).textTheme.labelSmall,
                                ),
                              Text(
                                '评论 ${post.commentCount}',
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                            ],
                          ),
                        ],
                      ),
                      Positioned(
                        top: -6,
                        right: -6,
                        child: AttentionButton(
                          isActive: post.attention ?? false,
                          isLoading: _togglingAttention.contains(post.pid),
                          onPressed: () => _togglePostAttention(post),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}