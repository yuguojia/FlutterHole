import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:photo_view/photo_view.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'constants.dart';
import 'models.dart';
import 'services.dart';
import 'utils.dart';

class PostHeader extends StatelessWidget {
  const PostHeader({
    super.key,
    required this.post,
    required this.token,
    required this.baseUrl,
    required this.onOpenPost,
    this.imageHeaders,
  });

  final Post post;
  final String token;
  final String baseUrl;
  final ValueChanged<Post> onOpenPost;
  final Map<String, String>? imageHeaders;

  @override
  Widget build(BuildContext context) {
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
              TagPidRow(
                tags: post.tags,
                pid: post.pid,
                textStyle: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 10),
              MarkdownContent(
                text: post.text,
                token: token,
                baseUrl: baseUrl,
                currentPostId: post.pid,
                onOpenPost: onOpenPost,
                imageHeaders: imageHeaders,
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
        ),
      ),
    );
  }
}

class MarkdownContent extends StatelessWidget {
  const MarkdownContent({
    super.key,
    required this.text,
    this.maxImageHeight,
    this.token,
    this.baseUrl,
    this.currentPostId,
    this.onOpenPost,
    this.imageHeaders,
    this.selectable = true,
  });

  final String text;
  final double? maxImageHeight;
  final String? token;
  final String? baseUrl;
  final int? currentPostId;
  final ValueChanged<Post>? onOpenPost;
  final Map<String, String>? imageHeaders;
  final bool selectable;
  static const _tholeImageHost = 'file.tholeapis.top';

  @override
  Widget build(BuildContext context) {
    final style = MarkdownStyleSheet.fromTheme(Theme.of(context));
    final refs = extractPostRefs(text, excludePid: currentPostId);
    final canShowRefs =
        refs.isNotEmpty && token != null && baseUrl != null;
    final markdownBody = MarkdownBody(
      data: text,
      styleSheet: style,
      onTapLink: (label, href, title) => _openLink(context, href),
      imageBuilder: (uri, title, alt) {
        final imageUri = _resolveImageUri(uri);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: maxImageHeight != null
                  ? BoxConstraints(maxHeight: maxImageHeight!)
                  : const BoxConstraints(),
              child: InkWell(
                onTap: () => _openImage(context, imageUri),
                child: Image.network(
                  imageUri.toString(),
                  headers: _resolveImageHeaders(imageUri),
                  fit: BoxFit.contain,
                  width: double.infinity,
                  errorBuilder: (context, error, stackTrace) {
                    return _MarkdownImageFallback(uri: imageUri);
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
    final markdown =
    selectable ? SelectionArea(child: markdownBody) : markdownBody;
    if (!canShowRefs) {
      return markdown;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        markdown,
        const SizedBox(height: 8),
        QuotePreviewList(
          pids: refs,
          token: token!,
          baseUrl: baseUrl!,
          onOpenPost: onOpenPost,
        ),
      ],
    );
  }

  void _openImage(BuildContext context, Uri uri) {
    final imageUri = _resolveImageUri(uri);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => ImageViewerPage(
          imageUrl: imageUri.toString(),
          imageHeaders: _resolveImageHeaders(imageUri),
        ),
      ),
    );
  }

  Map<String, String>? _resolveImageHeaders(Uri uri) {
    if (imageHeaders == null) return null;
    if (kIsWeb) return null;
    if (uri.host != _tholeImageHost) return null;
    return imageHeaders;
  }

  Uri _resolveImageUri(Uri uri) {
    if (!kIsWeb) return uri;
    if (uri.host != _tholeImageHost) return uri;
    final base = Uri.parse(tholeWebProxyBaseUrl);
    final origin = '${base.scheme}://${base.host}'
        '${base.hasPort ? ':${base.port}' : ''}';
    final encoded = Uri.encodeComponent(uri.toString());
    return Uri.parse('$origin/img?url=$encoded');
  }

  Future<void> _openLink(BuildContext context, String? href) async {
    if (href == null) return;
    final uri = Uri.tryParse(href);
    if (uri == null) return;
    final launched =
    await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('无法打开链接: $href')),
      );
    }
  }
}

class TagRow extends StatelessWidget {
  const TagRow({super.key, required this.tags});

  final List<String> tags;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: tags
          .map(
            (tag) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: scheme.secondaryContainer,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            '#$tag',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: scheme.onSecondaryContainer,
            ),
          ),
        ),
      )
          .toList(),
    );
  }
}

class TagPidRow extends StatelessWidget {
  const TagPidRow({
    super.key,
    required this.tags,
    required this.pid,
    this.textStyle,
  });

  final List<String> tags;
  final int pid;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final labelStyle =
        textStyle ?? Theme.of(context).textTheme.labelLarge;
    if (tags.isEmpty) {
      return Text('#$pid', style: labelStyle);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text('#$pid', style: labelStyle),
        const SizedBox(width: 12),
        Expanded(
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            alignment: WrapAlignment.start,
            children: tags
                .map(
                  (tag) => Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  '#$tag',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.onSecondaryContainer,
                  ),
                ),
              ),
            )
                .toList(),
          ),
        ),
      ],
    );
  }

  Future<void> _openLink(BuildContext context, String? href) async {
    if (href == null) return;
    final uri = Uri.tryParse(href);
    if (uri == null) return;
    final launched =
    await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('无法打开链接: $href')),
      );
    }
  }
}

class AttentionButton extends StatelessWidget {
  const AttentionButton({
    super.key,
    required this.isActive,
    required this.isLoading,
    required this.onPressed,
  });

  final bool isActive;
  final bool isLoading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const SizedBox(
        width: 32,
        height: 32,
        child: Padding(
          padding: EdgeInsets.all(6),
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return IconButton(
      tooltip: isActive ? '取消关注' : '关注',
      icon: Icon(isActive ? Icons.star : Icons.star_border),
      onPressed: onPressed,
    );
  }
}

class ImageViewerPage extends StatelessWidget {
  const ImageViewerPage({
    super.key,
    required this.imageUrl,
    this.imageHeaders,
  });

  final String imageUrl;
  final Map<String, String>? imageHeaders;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('图片预览')),
      body: Center(
        child: PhotoView(
          imageProvider: NetworkImage(imageUrl, headers: imageHeaders),
          minScale: PhotoViewComputedScale.contained * 0.8,
          maxScale: PhotoViewComputedScale.covered * 3,
          errorBuilder: (context, error, stackTrace) {
            return _MarkdownImageFallback(uri: Uri.parse(imageUrl));
          },
          backgroundDecoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
          ),
        ),
      ),
    );
  }
}

class QuotePreviewList extends StatefulWidget {
  const QuotePreviewList({
    super.key,
    required this.pids,
    required this.token,
    required this.baseUrl,
    this.onOpenPost,
  });

  final List<int> pids;
  final String token;
  final String baseUrl;
  final ValueChanged<Post>? onOpenPost;

  @override
  State<QuotePreviewList> createState() => _QuotePreviewListState();
}

class _QuotePreviewListState extends State<QuotePreviewList> {
  final _client = TholeApiClient();
  final Map<int, Future<Post?>> _futures = {};

  @override
  void initState() {
    super.initState();
    for (final pid in widget.pids) {
      _futures[pid] = _loadPost(pid);
    }
  }

  @override
  void didUpdateWidget(covariant QuotePreviewList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pids.toString() == widget.pids.toString()) return;
    _futures.clear();
    for (final pid in widget.pids) {
      _futures[pid] = _loadPost(pid);
    }
  }

  // ================= 修改：修复并发查询导致数据库关闭的 Bug =================
  Future<Post?> _loadPost(int pid) async {
    try {
      if (widget.baseUrl == 'local://') {
        Directory appDocDir = await getApplicationDocumentsDirectory();
        String dbPath = p.join(appDocDir.path, 'old_hole.db');

        // sqflite 默认会复用这个连接
        Database db = await openDatabase(dbPath);

        List<Map<String, dynamic>> maps = await db.query(
          'posts',
          where: 'pid = ?',
          whereArgs: [pid],
        );

        // ⚠️ 删除了这里的 await db.close();
        // 保持连接处于开启状态，让其他并行的 Future 能够继续使用它查询

        if (maps.isNotEmpty) {
          final m = maps.first;
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
        }
        return null;
      }

      // 线上环境逻辑保持不变
      final cached = await PostCache.get(widget.baseUrl, pid);
      if (cached != null) return cached;
      return await _client.fetchPostById(
        token: widget.token,
        baseUrl: widget.baseUrl,
        pid: pid,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widget.pids
          .map(
            (pid) => FutureBuilder<Post?>(
          future: _futures[pid],
          builder: (context, snapshot) {
            return _QuotePreviewTile(
              pid: pid,
              post: snapshot.data,
              onTap: snapshot.data != null && widget.onOpenPost != null
                  ? () => widget.onOpenPost!(snapshot.data!)
                  : null,
            );
          },
        ),
      )
          .toList(),
    );
  }
}

class _QuotePreviewTile extends StatelessWidget {
  const _QuotePreviewTile({
    required this.pid,
    required this.post,
    this.onTap,
  });

  final int pid;
  final Post? post;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = post == null
        ? const _QuotePreviewShell(title: '引用加载失败')
        : _QuotePreviewShell(
      title: '#$pid',
      subtitle: truncateMarkdown(post!.text, 80),
    );
    if (onTap == null) return content;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: content,
    );
  }
}

class _QuotePreviewShell extends StatelessWidget {
  const _QuotePreviewShell({
    required this.title,
    this.subtitle,
  });

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.labelLarge,
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

class _MarkdownImageFallback extends StatelessWidget {
  const _MarkdownImageFallback({required this.uri});

  final Uri uri;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Icon(
            Icons.broken_image,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 4),
          Text(
            uri.toString(),
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}