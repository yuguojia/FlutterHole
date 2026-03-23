import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models.dart';
import '../services.dart';
import '../utils.dart';
import '../widgets.dart';

class PostDetailPage extends StatefulWidget {
  const PostDetailPage({
    super.key,
    this.post,
    required this.pid,
    required this.token,
    required this.baseUrl,
    required this.backendKey,
    required this.supportsComment,
    this.imageHeaders,
  });

  final Post? post;
  final int pid;
  final String token;
  final String baseUrl;
  final String backendKey;
  final bool supportsComment;
  final Map<String, String>? imageHeaders;

  @override
  State<PostDetailPage> createState() => _PostDetailPageState();
}

class _PostDetailPageState extends State<PostDetailPage> {
  final _apiClient = TholeApiClient();
  final List<Comment> _comments = [];
  final int _pageSize = 20;
  final _commentController = TextEditingController();
  int _visibleCount = 0;
  bool _isLoading = false;
  bool _isPostLoading = false;
  bool _isAttention = false;
  bool _isTogglingAttention = false;
  bool _isSendingComment = false;
  bool _isRefreshing = false;
  String? _errorMessage;
  String? _postErrorMessage;
  Post? _post;

  bool get _hasMore => _visibleCount < _comments.length;
  bool get _isLocal => widget.backendKey == 'local'; // 快捷判断是否为本地模式

  @override
  void initState() {
    super.initState();
    _post = widget.post;
    _isAttention = widget.post?.attention ?? false;
    if (_post == null) {
      _fetchPost();
    }
    _fetchComments();
  }

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  bool _onCommentScrollNotification(ScrollNotification notification) {
    final atBottom = notification.metrics.extentAfter == 0;
    final isPullUp = notification is OverscrollNotification
        ? notification.overscroll > 0
        : notification is ScrollEndNotification && atBottom;
    if (atBottom && isPullUp) {
      if (_isLoading || !_hasMore) return false;
      setState(() {
        _visibleCount = min(_visibleCount + _pageSize, _comments.length);
      });
    }
    return false;
  }

  // ================= 获取本地评论库 =================
  Future<void> _fetchLocalComments() async {
    Directory appDocDir = await getApplicationDocumentsDirectory();
    String dbPath = p.join(appDocDir.path, 'old_hole.db');
    Database db = await openDatabase(dbPath);

    List<Map<String, dynamic>> maps = await db.query(
      'replies',
      where: 'pid = ?',
      whereArgs: [widget.pid],
      orderBy: 'cid ASC', // 评论按时间升序
    );

    final comments = maps.map((m) {
      // 判断是否为洞主，如果是则强制标为洞主，否则使用它的名字 (Alice, Bob...)
      String name = m['name'] as String? ?? '匿名';
      if (m['is_dz'] == 1) {
        name = '洞主';
      }
      return Comment(
        cid: m['cid'] as int,
        nameId: 0, // 占位
        text: m['text'] as String,
        timestamp: m['timestamp'] as int?,
        localName: name, // 存入本地名字
      );
    }).toList();

    await db.close();

    if (!mounted) return;
    setState(() {
      _comments
        ..clear()
        ..addAll(comments);
      _visibleCount = min(_pageSize, _comments.length);
    });
  }

  // ================= 获取本地主帖详情 =================
  Future<void> _fetchLocalPost() async {
    Directory appDocDir = await getApplicationDocumentsDirectory();
    String dbPath = p.join(appDocDir.path, 'old_hole.db');
    Database db = await openDatabase(dbPath);

    List<Map<String, dynamic>> maps = await db.query(
      'posts',
      where: 'pid = ?',
      whereArgs: [widget.pid],
    );

    if (maps.isNotEmpty) {
      final m = maps.first;
      final post = Post(
        pid: m['pid'] as int,
        text: m['text'] as String,
        timestamp: m['timestamp'] as int?,
        commentCount: m['reply_count'] as int? ?? 0,
        attention: false,
        tags: m['tag'] != null && m['tag'].toString().trim().isNotEmpty
            ? [m['tag'].toString()]
            : [],
      );
      if (!mounted) return;
      setState(() {
        _post = post;
      });
    } else {
      throw Exception('在本地数据库中未找到该帖子');
    }
    await db.close();
  }

  Future<void> _fetchComments() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      if (_isLocal) {
        await _fetchLocalComments();
      } else {
        final comments = await _apiClient.fetchComments(
          token: widget.token,
          baseUrl: widget.baseUrl,
          pid: widget.pid,
        );
        if (!mounted) return;
        setState(() {
          _comments
            ..clear()
            ..addAll(comments);
          _visibleCount = min(_pageSize, _comments.length);
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = error.toString();
        _comments.clear();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _fetchPost() async {
    if (!mounted) return;
    setState(() {
      _isPostLoading = true;
      _postErrorMessage = null;
    });
    try {
      if (_isLocal) {
        await _fetchLocalPost();
      } else {
        final cached = await PostCache.get(widget.baseUrl, widget.pid);
        final post = cached ??
            await _apiClient.fetchPostById(
              token: widget.token,
              baseUrl: widget.baseUrl,
              pid: widget.pid,
            );
        if (!mounted) return;
        setState(() {
          _post = post;
          _isAttention = post.attention ?? _isAttention;
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _postErrorMessage = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isPostLoading = false;
        });
      }
    }
  }

  Future<void> _refreshComments() async {
    if (_isRefreshing) return;
    setState(() {
      _isRefreshing = true;
    });
    try {
      await _fetchComments();
    } finally {
      if (!mounted) return;
      setState(() {
        _isRefreshing = false;
      });
    }
  }

  Future<void> _toggleAttention() async {
    setState(() {
      _isTogglingAttention = true;
    });
    try {
      final next = !_isAttention;
      // 如果是本地旧洞，跳过网络请求，直接通过 FavoritesStore 存入本地关注列表
      if (!_isLocal) {
        await _apiClient.toggleAttention(
          token: widget.token,
          baseUrl: widget.baseUrl,
          pid: widget.pid,
          enable: next,
        );
      }
      await FavoritesStore.update(widget.backendKey, widget.pid, next);
      if (!mounted) return;
      setState(() {
        _isAttention = next;
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('操作失败: $error')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isTogglingAttention = false;
        });
      }
    }
  }

  Future<void> _openReferencedPost(Post post) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => PostDetailPage(
          post: post,
          pid: post.pid,
          token: widget.token,
          baseUrl: widget.baseUrl,
          backendKey: widget.backendKey,
          supportsComment: widget.supportsComment,
        ),
      ),
    );
  }

  Future<bool> _submitComment() async {
    // 拦截本地模式评论
    if (_isLocal) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('本地旧洞为只读模式，无法发送评论')),
      );
      return false;
    }

    final text = _commentController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('评论不能为空')),
      );
      return false;
    }
    setState(() {
      _isSendingComment = true;
    });
    try {
      await _apiClient.createComment(
        token: widget.token,
        baseUrl: widget.baseUrl,
        pid: widget.pid,
        text: text,
      );
      if (!mounted) return false;
      _commentController.clear();
      await _fetchComments();
      return true;
    } catch (error) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('评论失败: $error')),
      );
      return false;
    } finally {
      if (mounted) {
        setState(() {
          _isSendingComment = false;
        });
      }
    }
  }

  Future<void> _openCommentComposer() async {
    // 拦截本地模式底部弹出框
    if (_isLocal || !widget.supportsComment) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(context).viewInsets.bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _commentController,
                minLines: 2,
                maxLines: 6,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '写评论…',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: _isSendingComment
                      ? null
                      : () async {
                    final ok = await _submitComment();
                    if (ok && mounted) {
                      Navigator.of(context).pop();
                    }
                  },
                  icon: _isSendingComment
                      ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                      : const Icon(Icons.send),
                  label: const Text('发送'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('#${widget.pid}'),
        actions: [
          IconButton(
            onPressed: _isTogglingAttention ? null : _toggleAttention,
            tooltip: _isAttention ? '取消关注' : '关注',
            icon: _isTogglingAttention
                ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
                : Icon(_isAttention ? Icons.star : Icons.star_border),
          ),
          IconButton(
            onPressed: _isRefreshing ? null : _refreshComments,
            tooltip: '刷新',
            icon: _isRefreshing
                ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _fetchComments,
        child: _buildBody(),
      ),
      floatingActionButton: widget.supportsComment && !_isLocal
          ? FloatingActionButton(
        onPressed: _openCommentComposer,
        tooltip: '写评论',
        child: const Icon(Icons.chat_bubble_outline),
      )
          : null,
    );
  }

  Widget _buildBody() {
    if (_isLoading && _comments.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_errorMessage != null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Text(
                  '加载失败\n$_errorMessage',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _fetchComments,
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        ],
      );
    }

    final visible = _comments.take(_visibleCount).toList();
    final itemCount = 1 + visible.length + (_hasMore ? 1 : 0);
    return NotificationListener<ScrollNotification>(
      onNotification: _onCommentScrollNotification,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        itemCount: itemCount,
        itemBuilder: (context, index) {
          if (index == 0) {
            final post = _post;
            if (post != null) {
              return PostHeader(
                post: post,
                token: widget.token,
                baseUrl: widget.baseUrl,
                onOpenPost: _openReferencedPost,
                imageHeaders: widget.imageHeaders,
              );
            }
            if (_postErrorMessage != null) {
              return _PostDetailPlaceholder(
                message: '帖子加载失败\n$_postErrorMessage',
                isLoading: false,
              );
            }
            return _PostDetailPlaceholder(
              isLoading: _isPostLoading,
              message: '帖子加载中...',
            );
          }
          final commentIndex = index - 1;
          if (commentIndex >= visible.length) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: _hasMore
                    ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
                    : const Text('没有更多评论'),
              ),
            );
          }
          final comment = visible[commentIndex];
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Card(
              elevation: 0,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      // --- 新增：优先展示 localName，否则 fallback 到在线版 ID 解析 ---
                      comment.localName ?? formatAnonName(comment.nameId),
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 8),
                    MarkdownContent(
                      text: comment.text,
                      token: widget.token,
                      baseUrl: widget.baseUrl,
                      currentPostId: widget.pid,
                      onOpenPost: _openReferencedPost,
                      imageHeaders: widget.imageHeaders,
                    ),
                    const SizedBox(height: 12),
                    if (comment.timestamp != null)
                      Text(
                        formatTimestamp(comment.timestamp!),
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _PostDetailPlaceholder extends StatelessWidget {
  const _PostDetailPlaceholder({
    this.message = '加载中...',
    this.isLoading = true,
  });

  final String message;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        elevation: 0,
        color: scheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              if (isLoading)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              if (isLoading) const SizedBox(width: 12),
              Expanded(child: Text(message)),
            ],
          ),
        ),
      ),
    );
  }
}