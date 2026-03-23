import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../constants.dart';
import '../models.dart';
import '../services.dart';
import '../utils.dart';
import '../widgets.dart';
import 'compose_page.dart';
import 'favorites_view.dart';
import 'post_detail_page.dart';
import 'search_page.dart';
import 'settings_page.dart';

enum MainTab { feed, favorites }

class LatestPostsPage extends StatefulWidget {
  const LatestPostsPage({super.key});

  @override
  State<LatestPostsPage> createState() => _LatestPostsPageState();
}

class _LatestPostsPageState extends State<LatestPostsPage> {
  final _apiClient = TholeApiClient();
  final GlobalKey<FavoritesViewState> _favoritesKey =
  GlobalKey<FavoritesViewState>();
  final List<Post> _posts = [];
  final ScrollController _feedScrollController = ScrollController();
  final int _previewMaxChars = 160;
  String _token = defaultTokenT;
  BackendType _backend = BackendType.t;
  FeedMode _feedMode = FeedMode.latestPost;
  MainTab _tab = MainTab.feed;
  bool _collapseTaggedPosts = false;
  final Set<int> _togglingAttention = {};
  bool _isLoading = false;
  bool _isFetchingMore = false;
  bool _hasMore = true;
  bool _showBottomBar = true;
  bool _autoHideBottomBar = true;
  bool _enableTImageRefererSpoof = false;
  bool _showScrollToTop = false;
  bool _isRefreshing = false;
  int _page = 1;
  String? _errorMessage;
  Post? _selectedPost;

  // 新增：判断本地是否存在旧洞数据
  bool _hasLocalDb = false;

  BackendConfig get _activeBackend =>
      switch (_backend) {
        BackendType.t => BackendConfig.t,
        BackendType.q => BackendConfig.q,
        BackendType.qOld => BackendConfig.qOld,
        BackendType.local => BackendConfig.local, // 处理本地类型
      };

  String get _activeBaseUrl =>
      kIsWeb ? _activeBackend.webProxyBaseUrl : _activeBackend.baseUrl;
  int get _activeRoomId => _activeBackend.roomId;
  int get _activeOrderMode => _feedMode.orderMode;

  @override
  void initState() {
    super.initState();
    _feedScrollController.addListener(_handleFeedScroll);
    _initialize();
  }

  @override
  void dispose() {
    _feedScrollController.removeListener(_handleFeedScroll);
    _feedScrollController.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    await _loadPreferences();
    if (!mounted) return;
    await _fetchPosts(showLoadingIndicator: true);
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();

    // --- 新增：检测本地数据库文件是否存在 ---
    final appDocDir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(appDocDir.path, 'old_hole.db');
    final hasDb = await File(dbPath).exists();
    // ------------------------------------

    final raw = prefs.getString('backend') ?? BackendType.t.name;
    final tokenT = prefs.getString('token_t') ?? defaultTokenT;
    final tokenQ = prefs.getString('token_q') ?? defaultTokenQ;
    final modeT = prefs.getInt('mode_t') ?? FeedMode.latestPost.orderMode;
    final modeQ = prefs.getInt('mode_q') ?? FeedMode.latestPost.orderMode;
    final modeQ2 = prefs.getInt('mode_q2') ?? FeedMode.latestPost.orderMode;
    final modeLocal = prefs.getInt('mode_local') ?? FeedMode.latestPost.orderMode;

    var selected = BackendType.values.firstWhere(
          (value) => value.name == raw,
      orElse: () => BackendType.t,
    );

    // 如果用户之前选了本地旧洞，但文件后来被删了，强制切回 T 洞
    if (selected == BackendType.local && !hasDb) {
      selected = BackendType.t;
    }

    final selectedMode = switch (selected) {
      BackendType.t => modeT,
      BackendType.q => modeQ,
      BackendType.qOld => modeQ2,
      BackendType.local => modeLocal, // 处理本地类型
    };

    if (!mounted) return;
    setState(() {
      _hasLocalDb = hasDb;
      _backend = selected;
      _token = switch (selected) {
        BackendType.t => tokenT,
        BackendType.q => tokenQ,
        BackendType.qOld => tokenQ,
        BackendType.local => '', // 本地不需要 token
      };
      _feedMode = FeedMode.values.firstWhere(
            (mode) => mode.orderMode == selectedMode,
        orElse: () => FeedMode.latestPost,
      );
      _collapseTaggedPosts =
          prefs.getBool('collapse_tagged_posts') ?? false;
      _autoHideBottomBar = prefs.getBool('auto_hide_bottom_bar') ?? true;
      _enableTImageRefererSpoof =
          prefs.getBool('t_image_referer_spoof') ?? false;
      _showBottomBar = _autoHideBottomBar ? _showBottomBar : true;
    });
  }

  bool _onPostScrollNotification(ScrollNotification notification) {
    if (notification is ScrollUpdateNotification) {
      final delta = notification.scrollDelta;
      if (delta != null && delta.abs() > 2) {
        _setBottomBarVisible(delta <= 0);
      }
    }
    final atBottom = notification.metrics.extentAfter == 0;
    final isPullUp = notification is OverscrollNotification
        ? notification.overscroll > 0
        : notification is ScrollEndNotification && atBottom;
    if (atBottom && isPullUp) {
      if (_isLoading || _isFetchingMore || !_hasMore) return false;
      _fetchPosts(page: _page + 1, append: true, showLoadingIndicator: false);
    }
    return false;
  }

  void _handleFeedScroll() {
    final shouldShow = _feedScrollController.offset > 400;
    if (_showScrollToTop == shouldShow) return;
    setState(() {
      _showScrollToTop = shouldShow;
    });
  }

  void _scrollToTop() {
    _feedScrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  void _setBottomBarVisible(bool visible) {
    final nextVisible = _autoHideBottomBar ? visible : true;
    if (_showBottomBar == nextVisible) return;
    setState(() {
      _showBottomBar = nextVisible;
    });
  }

  // ================= 新增：执行本地 SQLite 查询的方法 =================
  Future<List<Post>> _fetchLocalPosts({required int page}) async {
    Directory appDocDir = await getApplicationDocumentsDirectory();
    String dbPath = p.join(appDocDir.path, 'old_hole.db');
    Database db = await openDatabase(dbPath);

    String orderBy;
    switch (_feedMode) {
      case FeedMode.latestPost:
        orderBy = 'pid DESC';
        break;
      case FeedMode.latestReply:
      // 如果没有更新时间则回退到发布时间
        orderBy = 'COALESCE(updated_at, timestamp) DESC';
        break;
      case FeedMode.hot:
        orderBy = 'reply_count DESC';
        break;
      case FeedMode.classic:
        orderBy = 'likenum DESC';
        break;
      case FeedMode.random:
        orderBy = 'RANDOM()';
        break;
    }

    int limit = 20; // 每次加载 20 条
    int offset = (page - 1) * limit;

    List<Map<String, dynamic>> maps = await db.query(
      'posts',
      orderBy: orderBy,
      limit: limit,
      offset: offset,
    );

    await db.close();

    return maps.map((m) {
      return Post(
        pid: m['pid'] as int,
        text: m['text'] as String,
        timestamp: m['timestamp'] as int?,
        commentCount: m['reply_count'] as int? ?? 0,
        attention: false,
        tags: m['tag'] != null && m['tag'].toString().trim().isNotEmpty
            ? [m['tag'].toString()]
            : [],
      );
    }).toList();
  }
  // =============================================================

  Future<void> _fetchPosts({
    int page = 1,
    bool append = false,
    bool showLoadingIndicator = true,
  }) async {
    if (!mounted) return;
    setState(() {
      if (!append && showLoadingIndicator) {
        _isLoading = true;
      }
      if (append) {
        _isFetchingMore = true;
      } else {
        _errorMessage = null;
      }
    });

    try {
      List<Post> posts = [];

      // 判断当前是否是“本地旧洞”模式，如果是则拦截 API 调用，转向本地 SQL 查询
      if (_backend == BackendType.local) {
        posts = await _fetchLocalPosts(page: page);
      } else {
        posts = await _apiClient.fetchLatestPosts(
          token: _token,
          baseUrl: _activeBaseUrl,
          roomId: _activeRoomId,
          orderMode: _activeOrderMode,
          page: page,
        );
      }

      if (!mounted) return;
      setState(() {
        if (append) {
          _posts.addAll(posts);
          _page = page;
        } else {
          _posts
            ..clear()
            ..addAll(posts);
          _page = 1;
        }
        _hasMore = posts.isNotEmpty;
      });
    } catch (error) {
      if (!mounted) return;
      if (append) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载更多失败: $error')),
        );
      } else {
        setState(() {
          _errorMessage = error.toString();
          _posts.clear();
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isFetchingMore = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isWide = _isWide(context);
    final isSplit = _isSplitView(context);
    final showDetailPane = isSplit && _selectedPost != null;
    final imageHeaders = _buildImageHeaders();
    return Scaffold(
      appBar: _buildAppBar(context, showDetailPane),
      body: _tab == MainTab.feed
          ? _buildFeedBody(context, isWide, showDetailPane)
          : FavoritesView(
        key: _favoritesKey,
        token: _token,
        baseUrl: _activeBaseUrl,
        backendKey: _backend.name,
        supportsComment: _activeBackend.supportsComment,
        showInlineActions: true,
        imageHeaders: imageHeaders,
        onBottomBarVisibilityChanged: _setBottomBarVisible,
      ),
      floatingActionButton: _tab == MainTab.feed && !showDetailPane
          ? Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_showScrollToTop)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: FloatingActionButton.small(
                heroTag: 'scroll_to_top',
                onPressed: _scrollToTop,
                tooltip: '回顶部',
                child: const Icon(Icons.arrow_upward),
              ),
            ),
          if (_activeBackend.supportsPost)
            FloatingActionButton(
              heroTag: 'compose_post',
              onPressed: _openComposePage,
              tooltip: '发帖',
              child: const Icon(Icons.edit),
            ),
        ],
      )
          : null,
      bottomNavigationBar: _buildBottomBar(isWide),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context, bool showDetailPane) {
    return AppBar(
      leading: showDetailPane
          ? IconButton(
        onPressed: () {
          setState(() {
            _selectedPost = null;
          });
        },
        tooltip: '返回',
        icon: const Icon(Icons.arrow_back),
      )
          : null,
      title: _buildBackendSwitcherTitle(),
      bottom: _tab == MainTab.feed ? _buildModeBar(context) : null,
      actions: [
        if (_activeBackend.supportsSearch)
          IconButton(
            onPressed: _openSearchPage,
            tooltip: '搜索',
            icon: const Icon(Icons.search),
          ),
        IconButton(
          onPressed: _isRefreshing ? null : _refreshCurrent,
          tooltip: '刷新',
          icon: _isRefreshing
              ? const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
              : const Icon(Icons.refresh),
        ),
        IconButton(
          onPressed: _openSettings,
          tooltip: '设置',
          icon: const Icon(Icons.settings),
        ),
      ],
    );
  }

  PreferredSizeWidget? _buildModeBar(BuildContext context) {
    const barHeight = 72.0;
    return PreferredSize(
      preferredSize: const Size.fromHeight(barHeight),
      child: SizedBox(
        height: barHeight,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: FeedMode.values.map((mode) {
                final selected = mode == _feedMode;
                return ChoiceChip(
                  label: Text(mode.label),
                  selected: selected,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 12),
                  onSelected: (value) => _switchMode(mode),
                );
              }).toList(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFeedBody(
      BuildContext context, bool isWide, bool showDetailPane) {
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
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 120),
          Center(child: Text('暂无帖子')),
        ],
      );
    }
    final width = MediaQuery.of(context).size.width;
    final contentWidth = isWide ? width * 0.7 : width;
    final imageHeaders = _buildImageHeaders();
    final feedList = RefreshIndicator(
      onRefresh: _refresh,
      child: NotificationListener<ScrollNotification>(
        onNotification: _onPostScrollNotification,
        child: ListView.builder(
          controller: _feedScrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          cacheExtent: 800,
          itemCount: _posts.length + (_isFetchingMore ? 1 : 0),
          itemBuilder: (context, index) {
            if (index >= _posts.length) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              );
            }
            final post = _posts[index];
            final collapsed = _collapseTaggedPosts && post.tags.isNotEmpty;
            final preview = collapsed
                ? ''
                : truncateMarkdown(post.text, _previewMaxChars);
            final isSelected = _selectedPost?.pid == post.pid;
            return Center(
              child: SizedBox(
                width: contentWidth,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Card(
                    elevation: 0,
                    color: isSelected
                        ? Theme.of(context).colorScheme.secondaryContainer
                        : Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => _openDetail(context, post),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Stack(
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                TagPidRow(tags: post.tags, pid: post.pid),
                                const SizedBox(height: 8),
                                if (collapsed)
                                  Text(
                                    '含 tag 的帖子已折叠',
                                    style:
                                    Theme.of(context).textTheme.bodySmall,
                                  )
                                else
                                  MarkdownContent(
                                    text: preview,
                                    maxImageHeight: 240,
                                    token: _token,
                                    baseUrl: _activeBaseUrl,
                                    currentPostId: post.pid,
                                    onOpenPost: (value) =>
                                        _openDetail(context, value),
                                    imageHeaders: imageHeaders,
                                    selectable: false,
                                  ),
                                const SizedBox(height: 12),
                                Wrap(
                                  spacing: 8,
                                  children: [
                                    if (post.timestamp != null)
                                      Text(
                                        formatTimestamp(post.timestamp!),
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelSmall,
                                      ),
                                    Text(
                                      '评论 ${post.commentCount}',
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall,
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
                                isLoading:
                                _togglingAttention.contains(post.pid),
                                onPressed: () => _togglePostAttention(post),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );

    if (!showDetailPane) {
      return feedList;
    }

    final leftPane = Stack(
      children: [
        Positioned.fill(child: feedList),
        Positioned(
          right: 16,
          bottom: 16,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_showScrollToTop)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: FloatingActionButton.small(
                    heroTag: 'scroll_to_top_split',
                    onPressed: _scrollToTop,
                    tooltip: '回顶部',
                    child: const Icon(Icons.arrow_upward),
                  ),
                ),
              if (_activeBackend.supportsPost)
                FloatingActionButton(
                  heroTag: 'compose_post_split',
                  onPressed: _openComposePage,
                  tooltip: '发帖',
                  child: const Icon(Icons.edit),
                ),
            ],
          ),
        ),
      ],
    );

    return Row(
      children: [
        Expanded(flex: 6, child: leftPane),
        const VerticalDivider(width: 1),
        Expanded(
          flex: 5,
          child: _buildDetailPane(imageHeaders),
        ),
      ],
    );
  }

  Widget _buildBottomBar(bool isWide) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: ClipRect(
        child: Align(
          alignment: Alignment.topCenter,
          heightFactor: _showBottomBar ? 1 : 0,
          child: AnimatedSlide(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            offset: _showBottomBar ? Offset.zero : const Offset(0, 0.2),
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOut,
              opacity: _showBottomBar ? 1 : 0,
              child: NavigationBar(
                key: const ValueKey('bottom_bar'),
                selectedIndex: _tab.index,
                onDestinationSelected: (index) {
                  setState(() {
                    _tab = MainTab.values[index];
                  });
                },
                destinations: const [
                  NavigationDestination(icon: Icon(Icons.home), label: '最新'),
                  NavigationDestination(icon: Icon(Icons.star), label: '关注'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBackendSwitcherTitle() {
    return DropdownButtonHideUnderline(
      child: DropdownButton<BackendType>(
        value: _backend,
        onChanged: (value) {
          if (value == null) return;
          _switchBackend(value);
        },
        items: BackendType.values
        // 如果本地没有数据库文件，就隐藏“本地旧洞”选项
            .where((backend) => backend != BackendType.local || _hasLocalDb)
            .map(
              (backend) => DropdownMenuItem(
            value: backend,
            child: Text(_configFor(backend).name),
          ),
        )
            .toList(),
      ),
    );
  }

  void _switchBackend(BackendType backend) async {
    if (_backend == backend) return;
    final prefs = await SharedPreferences.getInstance();
    final tokenT = prefs.getString('token_t') ?? defaultTokenT;
    final tokenQ = prefs.getString('token_q') ?? defaultTokenQ;
    final modeT = prefs.getInt('mode_t') ?? FeedMode.latestPost.orderMode;
    final modeQ = prefs.getInt('mode_q') ?? FeedMode.latestPost.orderMode;
    final modeQ2 = prefs.getInt('mode_q2') ?? FeedMode.latestPost.orderMode;
    final modeLocal = prefs.getInt('mode_local') ?? FeedMode.latestPost.orderMode;

    final selectedMode = switch (backend) {
      BackendType.t => modeT,
      BackendType.q => modeQ,
      BackendType.qOld => modeQ2,
      BackendType.local => modeLocal, // 处理本地类型
    };

    setState(() {
      _backend = backend;
      _token = switch (backend) {
        BackendType.t => tokenT,
        BackendType.q => tokenQ,
        BackendType.qOld => tokenQ,
        BackendType.local => '', // 本地无 token
      };
      _feedMode = FeedMode.values.firstWhere(
            (mode) => mode.orderMode == selectedMode,
        orElse: () => FeedMode.latestPost,
      );
    });
    await prefs.setString('backend', backend.name);
    if (_tab == MainTab.feed) {
      await _fetchPosts(showLoadingIndicator: true);
    } else {
      await _favoritesKey.currentState?.refresh();
    }
  }

  BackendConfig _configFor(BackendType backend) {
    return switch (backend) {
      BackendType.t => BackendConfig.t,
      BackendType.q => BackendConfig.q,
      BackendType.qOld => BackendConfig.qOld,
      BackendType.local => BackendConfig.local, // 处理本地类型
    };
  }

  bool _isWide(BuildContext context) {
    return MediaQuery.of(context).size.width > 720;
  }

  bool _isSplitView(BuildContext context) {
    return MediaQuery.of(context).size.width >= 1100;
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => SettingsPage(
          onChanged: (result) {
            setState(() {
              _token = switch (_backend) {
                BackendType.t => result.tokenT,
                BackendType.q => result.tokenQ,
                BackendType.qOld => result.tokenQ,
                BackendType.local => '', // 处理本地类型
              };
              _collapseTaggedPosts = result.collapseTaggedPosts;
              _autoHideBottomBar = result.autoHideBottomBar;
              _enableTImageRefererSpoof = result.enableTImageRefererSpoof;
              if (!_autoHideBottomBar) {
                _showBottomBar = true;
              }
            });
          },
        ),
      ),
    );
    // 当从设置页面返回时，重新检查本地数据库是否存在并刷新状态
    _loadPreferences();
  }

  Future<void> _openSearchPage() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => SearchPage(
          token: _token,
          baseUrl: _activeBaseUrl,
          roomId: _activeRoomId,
          backendKey: _backend.name,
          supportsComment: _activeBackend.supportsComment,
          imageHeaders: _buildImageHeaders(),
        ),
      ),
    );
  }

  Future<void> _openComposePage() async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) => ComposePage(
          token: _token,
          baseUrl: _activeBaseUrl,
          roomId: _activeRoomId,
        ),
      ),
    );
    if (result == true) {
      await _refresh();
    }
  }

  Future<void> _refresh() async {
    await _fetchPosts(page: 1, append: false, showLoadingIndicator: false);
  }

  Future<void> _refreshCurrent() async {
    if (_isRefreshing) return;
    setState(() {
      _isRefreshing = true;
    });
    try {
      if (_tab == MainTab.feed) {
        await _refresh();
      } else {
        await _favoritesKey.currentState?.refresh();
      }
    } finally {
      if (!mounted) return;
      setState(() {
        _isRefreshing = false;
      });
    }
  }

  void _switchMode(FeedMode mode) async {
    if (mode == _feedMode) return;
    final prefs = await SharedPreferences.getInstance();
    switch (_backend) {
      case BackendType.t:
        await prefs.setInt('mode_t', mode.orderMode);
        break;
      case BackendType.q:
        await prefs.setInt('mode_q', mode.orderMode);
        break;
      case BackendType.qOld:
        await prefs.setInt('mode_q2', mode.orderMode);
        break;
      case BackendType.local:
        await prefs.setInt('mode_local', mode.orderMode); // 记忆本地模式偏好
        break;
    }
    setState(() {
      _feedMode = mode;
    });
    await _fetchPosts(showLoadingIndicator: true);
  }

  Future<void> _openDetail(BuildContext context, Post post) async {
    if (_isSplitView(context)) {
      setState(() {
        _selectedPost = post;
      });
      return;
    }
    final updated = await Navigator.of(context).push<Post>(
      MaterialPageRoute(
        builder: (context) => PostDetailPage(
          post: post,
          pid: post.pid,
          token: _token,
          baseUrl: _activeBaseUrl,
          backendKey: _backend.name,
          supportsComment: _activeBackend.supportsComment,
          imageHeaders: _buildImageHeaders(),
        ),
      ),
    );
    if (updated != null) {
      setState(() {
        _replacePostAttention(_posts, updated.pid, updated.attention ?? false);
      });
    }
  }

  Widget _buildDetailPane(Map<String, String>? imageHeaders) {
    final post = _selectedPost;
    if (post == null) {
      return Center(
        child: Text(
          '选择一条帖子查看详情',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }
    return PostDetailPage(
      key: ValueKey(post.pid),
      post: post,
      pid: post.pid,
      token: _token,
      baseUrl: _activeBaseUrl,
      backendKey: _backend.name,
      supportsComment: _activeBackend.supportsComment,
      imageHeaders: imageHeaders,
    );
  }

  Future<void> _togglePostAttention(Post post) async {
    if (_togglingAttention.contains(post.pid)) return;
    setState(() {
      _togglingAttention.add(post.pid);
    });
    final next = !(post.attention ?? false);
    try {
      // 避免在本地旧洞模式下调用网络关注接口
      if (_backend != BackendType.local) {
        await _apiClient.toggleAttention(
          token: _token,
          baseUrl: _activeBaseUrl,
          pid: post.pid,
          enable: next,
        );
      }
      await FavoritesStore.update(_backend.name, post.pid, next);
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

  Map<String, String>? _buildImageHeaders() {
    if (!_enableTImageRefererSpoof || _backend != BackendType.t) {
      return null;
    }
    return const {'Referer': 'https://thuhollow.github.io/'};
  }
}