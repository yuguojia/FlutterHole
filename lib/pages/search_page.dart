import 'package:flutter/material.dart';

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

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
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
      final posts = await _apiClient.searchPosts(
        token: widget.token,
        baseUrl: widget.baseUrl,
        roomId: widget.roomId,
        keywords: keywords,
        page: nextPage,
        pageSize: 50,
        searchMode: _mode,
      );
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
      await _apiClient.toggleAttention(
        token: widget.token,
        baseUrl: widget.baseUrl,
        pid: post.pid,
        enable: next,
      );
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
            onPressed: _search,
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
                  decoration: const InputDecoration(
                    labelText: '关键词',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _search(),
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
