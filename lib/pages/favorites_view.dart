import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models.dart';
import '../services.dart';
import '../utils.dart';
import '../widgets.dart';
import 'post_detail_page.dart';

enum FavoritesMode { online, local }

class FavoritesView extends StatefulWidget {
  const FavoritesView({
    super.key,
    required this.token,
    required this.baseUrl,
    required this.backendKey,
    required this.supportsComment,
    required this.showInlineActions,
    this.imageHeaders,
    this.onBottomBarVisibilityChanged,
  });

  final String token;
  final String baseUrl;
  final String backendKey;
  final bool supportsComment;
  final bool showInlineActions;
  final Map<String, String>? imageHeaders;
  final ValueChanged<bool>? onBottomBarVisibilityChanged;

  @override
  State<FavoritesView> createState() => FavoritesViewState();
}

class FavoritesViewState extends State<FavoritesView> {
  final _apiClient = TholeApiClient();
  final _controller = TextEditingController();
  final List<Post> _posts = [];
  final Set<int> _togglingAttention = {};
  FavoritesMode _mode = FavoritesMode.online;
  bool _showLocalEditor = false;
  bool _isLoading = false;
  String? _errorMessage;
  String _cachedInput = '';

  bool get _isLocalBackend => widget.backendKey == 'local';

  @override
  void initState() {
    super.initState();
    if (_isLocalBackend) {
      _mode = FavoritesMode.local; // 本地旧洞强制使用本地收藏模式
    }
    _loadLocalFavorites();
    _loadPosts();
  }

  Future<void> _loadLocalFavorites() async {
    final list = await FavoritesStore.load(widget.backendKey);
    if (!mounted) return;
    setState(() {
      _controller.text = list.isEmpty
          ? '#pid1 #pid2'
          : list.map((pid) => '#$pid').join(' ');
      _cachedInput = _controller.text;
    });
  }

  @override
  void didUpdateWidget(covariant FavoritesView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.backendKey != widget.backendKey) {
      if (_isLocalBackend) {
        _mode = FavoritesMode.local;
      }
      _loadLocalFavorites();
      _loadPosts();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // ================= 新增：从 SQLite 批量查询收藏的帖子 =================
  Future<List<Post>> _fetchLocalFavoritesFromDb(List<int> ids) async {
    if (ids.isEmpty) return [];

    Directory appDocDir = await getApplicationDocumentsDirectory();
    String dbPath = p.join(appDocDir.path, 'old_hole.db');
    Database db = await openDatabase(dbPath);

    List<Post> localPosts = [];

    // SQLite 的 IN 语句参数上限通常是 999，所以按 900 分块查询防止崩溃
    for (int i = 0; i < ids.length; i += 900) {
      final chunk = ids.sublist(i, i + 900 > ids.length ? ids.length : i + 900);
      final placeholders = List.filled(chunk.length, '?').join(',');

      List<Map<String, dynamic>> maps = await db.query(
        'posts',
        where: 'pid IN ($placeholders)',
        whereArgs: chunk,
        orderBy: 'pid DESC',
      );

      localPosts.addAll(maps.map((m) {
        return Post(
          pid: m['pid'] as int,
          text: m['text'] as String,
          timestamp: m['timestamp'] as int?,
          commentCount: m['reply_count'] as int? ?? 0,
          attention: true, // 能查出来的肯定是被关注了的
          tags: m['tag'] != null && m['tag'].toString().trim().isNotEmpty
              ? [m['tag'].toString()]
              : [],
        );
      }));
    }

    await db.close();
    return localPosts;
  }

  Future<void> _loadPosts({bool bypassCache = false}) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      List<Post> posts;

      // 拦截本地旧洞模式
      if (_isLocalBackend) {
        final ids = await FavoritesStore.load(widget.backendKey);
        posts = await _fetchLocalFavoritesFromDb(ids);
      } else {
        if (_mode == FavoritesMode.online) {
          posts = await _apiClient.fetchAttentionPosts(
            token: widget.token,
            baseUrl: widget.baseUrl,
          );
        } else {
          final ids = await FavoritesStore.load(widget.backendKey);
          posts = await _apiClient.fetchMultiPosts(
            token: widget.token,
            baseUrl: widget.baseUrl,
            pids: ids,
            bypassCache: bypassCache,
          );
        }
      }

      if (!mounted) return;
      setState(() {
        _posts
          ..clear()
          ..addAll(posts);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = error.toString();
        _posts.clear();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _refresh() async {
    await _loadPosts(bypassCache: _mode == FavoritesMode.local);
  }

  Future<void> refresh() async {
    await _refresh();
  }

  Future<void> _togglePostAttention(Post post) async {
    if (_togglingAttention.contains(post.pid)) return;
    setState(() {
      _togglingAttention.add(post.pid);
    });
    final next = !(post.attention ?? false);
    try {
      // 拦截本地旧洞模式下的网络请求
      if (!_isLocalBackend) {
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
        _replacePostAttention(_posts, post.pid, next);
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

  void _replacePostAttention(List<Post> list, int pid, bool next) {
    final index = list.indexWhere((item) => item.pid == pid);
    if (index == -1) return;
    list[index] = list[index].copyWith(attention: next);
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification is ScrollUpdateNotification) {
      final delta = notification.scrollDelta;
      if (delta != null && delta.abs() > 2) {
        widget.onBottomBarVisibilityChanged?.call(delta <= 0);
      }
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
        _replacePostAttention(_posts, updated.pid, updated.attention ?? false);
      });
    }
  }

  Future<void> _saveLocalFavorites() async {
    final text = _controller.text.trim();
    await FavoritesStore.saveFromText(widget.backendKey, text);
    setState(() {
      _cachedInput = _controller.text.trim();
    });
    await _loadPosts();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (widget.showInlineActions)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                // 只有在线上版才显示切换芯片，本地旧洞隐藏
                if (!_isLocalBackend)
                  Row(
                    children: [
                      ChoiceChip(
                        label: const Text('线上收藏'),
                        selected: _mode == FavoritesMode.online,
                        onSelected: (value) {
                          setState(() {
                            _mode = FavoritesMode.online;
                            _showLocalEditor = false;
                          });
                          _loadPosts();
                        },
                      ),
                      const SizedBox(width: 8),
                      ChoiceChip(
                        label: const Text('本地收藏'),
                        selected: _mode == FavoritesMode.local,
                        onSelected: (value) {
                          setState(() {
                            _mode = FavoritesMode.local;
                            _showLocalEditor = false;
                          });
                          _loadPosts();
                        },
                      ),
                    ],
                  ),
                if (_mode == FavoritesMode.local) ...[
                  if (!_isLocalBackend) const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () {
                        setState(() {
                          _showLocalEditor = !_showLocalEditor;
                        });
                      },
                      icon: Icon(_showLocalEditor ? Icons.close : Icons.edit),
                      label: Text(_showLocalEditor ? '收起编辑' : '编辑列表'),
                    ),
                  ),
                ],
                if (_mode == FavoritesMode.local && _showLocalEditor) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: _controller,
                    decoration: const InputDecoration(
                      labelText: '本地收藏列表 (#pid1 #pid2)',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) {},
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      onPressed: _controller.text.trim() == _cachedInput.trim()
                          ? null
                          : _saveLocalFavorites,
                      child: const Text('更新列表'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        Expanded(child: _buildList()),
      ],
    );
  }

  Widget _buildList() {
    if (_isLoading && _posts.isEmpty) {
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
                '加载失败\n$_errorMessage',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _refresh,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_posts.isEmpty) {
      return NotificationListener<ScrollNotification>(
        onNotification: _handleScrollNotification,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 120),
            Center(child: Text('暂无收藏')),
          ],
        ),
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: _handleScrollNotification,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        cacheExtent: 800,
        itemCount: _posts.length,
        itemBuilder: (context, index) {
          final post = _posts[index];
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