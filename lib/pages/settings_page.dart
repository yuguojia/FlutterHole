import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:file_picker/file_picker.dart';
import 'package:archive/archive_io.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:porter_2_stemmer/porter_2_stemmer.dart';
import 'package:porter_2_stemmer/extensions.dart'; // <--- 新增这行，用于支持 String 扩展方法

import '../constants.dart';
import '../models.dart';
import '../services.dart';
import '../theme_controller.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, this.onChanged});

  final ValueChanged<SettingsResult>? onChanged;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _tokenTController = TextEditingController();
  final _tokenQController = TextEditingController();
  final _cacheHoursController = TextEditingController();
  bool _cacheEnabled = true;
  bool _collapseTaggedPosts = false;
  bool _autoHideBottomBar = true;
  bool _enableTImageRefererSpoof = true;
  // 新增：用于记录本地是否已经导入了数据
  bool _hasOldData = false;
  ThemeMode _themeMode = themeModeNotifier.value;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tokenTController.dispose();
    _tokenQController.dispose();
    _cacheHoursController.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final tokenT = prefs.getString('token_t') ?? defaultTokenT;
    final tokenQ = prefs.getString('token_q') ?? defaultTokenQ;
    final cacheEnabled = prefs.getBool('post_cache_enabled') ?? true;
    final ttlMinutes = prefs.getInt('post_cache_ttl_minutes') ?? 60;
    final collapseTagged = prefs.getBool('collapse_tagged_posts') ?? false;
    final autoHideBottomBar =
        prefs.getBool('auto_hide_bottom_bar') ?? true;
    final enableTImageRefererSpoof =
        prefs.getBool('t_image_referer_spoof') ?? true;
    // --- 新增：检查数据库文件是否存在 ---
    final appDocDir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(appDocDir.path, 'old_hole.db');
    final hasDb = await File(dbPath).exists();
    // -----------------------------------

    if (!mounted) return;
    setState(() {
      _tokenTController.text = tokenT;
      _tokenQController.text = tokenQ;
      _cacheEnabled = cacheEnabled;
      _cacheHoursController.text = (ttlMinutes / 60).round().toString();
      _collapseTaggedPosts = collapseTagged;
      _autoHideBottomBar = autoHideBottomBar;
      _enableTImageRefererSpoof = enableTImageRefererSpoof;
      _themeMode = themeModeNotifier.value;

      _hasOldData = hasDb; // 更新状态
    });
  }

  Future<void> _persist({bool showError = false}) async {
    try {
      final tokenT = _tokenTController.text.trim();
      final tokenQ = _tokenQController.text.trim();
      final hours = int.tryParse(_cacheHoursController.text.trim()) ?? 0;
      if (_cacheEnabled && hours <= 0) {
        throw const FormatException('缓存时长需要大于 0');
      }
      final ttlMinutes = _cacheEnabled ? hours * 60 : 0;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('token_t', tokenT.isEmpty ? defaultTokenT : tokenT);
      await prefs.setString('token_q', tokenQ.isEmpty ? defaultTokenQ : tokenQ);
      await prefs.setBool('post_cache_enabled', _cacheEnabled);
      await prefs.setInt('post_cache_ttl_minutes', ttlMinutes);
      await prefs.setBool('collapse_tagged_posts', _collapseTaggedPosts);
      await prefs.setBool('auto_hide_bottom_bar', _autoHideBottomBar);
      await prefs.setBool(
        't_image_referer_spoof',
        _enableTImageRefererSpoof,
      );
      if (!mounted) return;
      await PostCache.applyConfig(
        enabled: _cacheEnabled,
        ttlMinutes: ttlMinutes,
      );
      widget.onChanged?.call(
        SettingsResult(
          tokenT: tokenT.isEmpty ? defaultTokenT : tokenT,
          tokenQ: tokenQ.isEmpty ? defaultTokenQ : tokenQ,
          cacheEnabled: _cacheEnabled,
          cacheTtlMinutes: ttlMinutes,
          collapseTaggedPosts: _collapseTaggedPosts,
          autoHideBottomBar: _autoHideBottomBar,
          enableTImageRefererSpoof: _enableTImageRefererSpoof,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      if (showError) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败: $error')),
        );
      }
    }
  }

  void _schedulePersist() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _persist(showError: false);
    });
  }

  Future<void> _openExternalUrl(String url) async {
    final uri = Uri.parse(url);
    if (!await canLaunchUrl(uri)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法打开链接')),
      );
      return;
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  // ================= 新增：定制的混合分词算法 =================
  String _tokenizeText(String text) {
    if (text.isEmpty) return '';
    final tokens = <String>[];

    // 正则：匹配连续的英文字母，或者连续的非英文字母且非空白字符
    final RegExp regex = RegExp(r'[a-zA-Z]+|[^a-zA-Z\s]+');
    final matches = regex.allMatches(text);

    for (final match in matches) {
      final str = match.group(0)!;
      if (RegExp(r'^[a-zA-Z]+$').hasMatch(str)) {
        // 1. 如果是纯英文单词：转小写并直接调用扩展方法提取词干 (例如: running -> run)
        tokens.add(str.toLowerCase().stemPorter2());
      } else {
        // 2. 如果是中文、标点、数字、Emoji等：按 Unicode 字符逐字拆分
        for (final rune in str.runes) {
          tokens.add(String.fromCharCode(rune));
        }
      }
    }
    // 最后用空格将所有 token 拼起来。SQLite FTS5 默认用空格区分词汇
    return tokens.join(' ');
  }
  // ========================================================

  // ================= 新增：导入旧洞数据的核心逻辑 =================
  Future<void> _importOldData() async {
    // 1. 调用系统文件选择器，选择 ZIP 文件
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );

    if (result == null || result.files.single.path == null) {
      return; // 用户取消了选择
    }

    String zipPath = result.files.single.path!;

    // 弹窗显示进度
    int totalFiles = 0;
    int currentFiles = 0;
    String statusText = "正在解析 ZIP 文件目录，请稍候...";

    showDialog(
      context: context,
      barrierDismissible: false, // 导入期间不允许点击外部关闭
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('正在导入数据'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(statusText),
                  const SizedBox(height: 16),
                  if (totalFiles > 0) ...[
                    LinearProgressIndicator(
                      value: currentFiles / totalFiles,
                    ),
                    const SizedBox(height: 8),
                    Text('$currentFiles / $totalFiles'),
                  ] else
                    const CircularProgressIndicator(),
                ],
              ),
            );
          },
        );
      },
    );

    try {
      // 2. 在应用内部存储空间创建并初始化 SQLite 表
      Directory appDocDir = await getApplicationDocumentsDirectory();
      String dbPath = p.join(appDocDir.path, 'old_hole.db');

      Database db = await openDatabase(
        dbPath,
        version: 1,
        onCreate: (Database db, int version) async {
          // 创建 posts 表
          await db.execute('''
            CREATE TABLE posts (
                pid INTEGER PRIMARY KEY,
                text TEXT,
                type TEXT,
                tag TEXT,
                likenum INTEGER,
                reply_count INTEGER,
                timestamp INTEGER,
                updated_at INTEGER,
                deleted BOOLEAN,
                url TEXT,
                image_metadata TEXT,
                vote TEXT
            )
          ''');
          // 创建 replies 表
          await db.execute('''
            CREATE TABLE replies (
                cid INTEGER PRIMARY KEY,
                pid INTEGER,
                reply_to INTEGER,
                name TEXT,
                is_dz BOOLEAN,
                text TEXT,
                type TEXT,
                tag TEXT,
                timestamp INTEGER,
                deleted BOOLEAN,
                url TEXT,
                image_metadata TEXT,
                FOREIGN KEY (pid) REFERENCES posts (pid)
            )
          ''');

          // --- 新增：创建 FTS4 虚拟搜索表 (解决部分安卓设备报 no such module:fts5 的问题) ---
          await db.execute('''
            CREATE VIRTUAL TABLE IF NOT EXISTS posts_fts USING fts4(
                text
            )
          ''');
          await db.execute('''
            CREATE VIRTUAL TABLE IF NOT EXISTS replies_fts USING fts4(
                pid,
                text,
                notindexed=pid -- FTS4 中声明不参与分词索引的语法
            )
          ''');
        },
      );

      // 为了安全起见，防止数据库存在但表没建好的情况
      // await db.execute('CREATE TABLE IF NOT EXISTS posts (...)'); // 这里省略重复代码，实际 sqflite 会处理好 onCreate

      // 极致写入速度优化（关闭同步，开启 WAL 模式）
      await db.execute("PRAGMA synchronous = OFF;");
      await db.rawQuery("PRAGMA journal_mode = WAL;"); // 修改为 rawQuery

      // 3. 读取 ZIP 并筛选出符合路径的 JSON 文件
      final inputStream = InputFileStream(zipPath);
      final archive = ZipDecoder().decodeBuffer(inputStream);

      // 筛选在 THU_Tree-master/DataSet/json/ 目录下且以 .json 结尾的文件
      List<ArchiveFile> jsonFiles = archive.files.where((file) {
        return file.isFile &&
            file.name.contains('THU_Tree-master/DataSet/json/') &&
            file.name.endsWith('.json');
      }).toList();

      totalFiles = jsonFiles.length;

      // 取消弹窗状态更新方法，用于后续循环内部调用
      void updateProgress() {
        // 使用 Navigator 查找当前 dialog 的 context 并更新状态
        (context as Element).markNeedsBuild(); // 给主界面保底
      }

      // 4. 解析并批量存入 SQLite
      Batch batch = db.batch();
      for (int i = 0; i < totalFiles; i++) {
        ArchiveFile file = jsonFiles[i];

        // 读取字节并转换为字符串解析 JSON
        final content = utf8.decode(file.content as List<int>);
        final Map<String, dynamic> rawJson = jsonDecode(content);

        final post = rawJson['post'] as Map<String, dynamic>?;
        final dataList = rawJson['data'] as List<dynamic>? ?? [];

        if (post != null) {
          batch.insert('posts', {
            'pid': post['pid'],
            'text': post['text'],
            'type': post['type'],
            'tag': post['tag'],
            'likenum': post['likenum'],
            'reply_count': post['reply'],
            'timestamp': post['timestamp'],
            'updated_at': post['updated_at'],
            'deleted': post['deleted'] == true ? 1 : 0, // SQLite没有bool，存 0/1
            'url': post['url'],
            'image_metadata': jsonEncode(post['image_metadata'] ?? {}),
            'vote': post['vote'] != null ? jsonEncode(post['vote']) : null,
          }, conflictAlgorithm: ConflictAlgorithm.replace);

          // --- 新增：写入主帖全文搜索索引 ---
          batch.insert('posts_fts', {
            'rowid': post['pid'], // 强制把 FTS 的底层主键设为 pid，防重复且方便后续查表
            'text': _tokenizeText(post['text'] ?? ''),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }

        for (var replyRaw in dataList) {
          final reply = replyRaw as Map<String, dynamic>;
          batch.insert('replies', {
            'cid': reply['cid'],
            'pid': reply['pid'],
            'reply_to': reply['reply_to'],
            'name': reply['name'],
            'is_dz': reply['is_dz'] == true ? 1 : 0,
            'text': reply['text'],
            'type': reply['type'],
            'tag': reply['tag'],
            'timestamp': reply['timestamp'],
            'deleted': reply['deleted'] == true ? 1 : 0,
            'url': reply['url'],
            'image_metadata': jsonEncode(reply['image_metadata'] ?? {}),
          }, conflictAlgorithm: ConflictAlgorithm.replace);

          // --- 新增：写入回复全文搜索索引 ---
          batch.insert('replies_fts', {
            'rowid': reply['cid'], // 强制把 FTS 的底层主键设为 cid
            'pid': reply['pid'],   // 冗余记录一下属于哪个帖子，方便搜索展示
            'text': _tokenizeText(reply['text'] ?? ''),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }

        currentFiles++;

        // 每处理 1000 个文件，提交一次事务并刷新UI，防止内存溢出和UI卡死
        if (currentFiles % 1000 == 0) {
          await batch.commit(noResult: true);
          batch = db.batch();

          // 刷新主线程UI
          Navigator.of(context).pop(); // 先关掉旧弹窗
          showDialog(                  // 再开一个新弹窗（Flutter 更新局部 Dialog 状态较麻烦，这样能确保刷新）
            context: context,
            barrierDismissible: false,
            builder: (context) {
              return AlertDialog(
                title: const Text('正在导入数据'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text("正在将 JSON 写入数据库..."),
                    const SizedBox(height: 16),
                    LinearProgressIndicator(value: currentFiles / totalFiles),
                    const SizedBox(height: 8),
                    Text('$currentFiles / $totalFiles'),
                  ],
                ),
              );
            },
          );
          // 让出时间片给 UI 线程渲染
          await Future.delayed(const Duration(milliseconds: 10));
        }
      }

      // 提交最后剩余的批次
      if (currentFiles % 1000 != 0) {
        await batch.commit(noResult: true);
      }

      await db.execute("PRAGMA synchronous = NORMAL;"); // 恢复安全模式
      await db.close();
      inputStream.close();

      // 关闭进度条弹窗
      if (mounted) {
        setState(() {
          _hasOldData = true; // <--- 新增这行，导入成功后切换为“删除数据”状态
        });
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('数据导入完成！')),
        );
      }

    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop(); // 关闭进度弹窗
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入失败: $e')),
        );
      }
    }
  }
  // ================= 导入核心逻辑 END =================

  // ================= 新增：删除旧洞数据的逻辑 =================
  Future<void> _deleteOldData() async {
    // 1. 弹出二次确认对话框
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('删除旧洞数据'),
          content: const Text('确定要删除本地所有的旧洞数据吗？此操作不可恢复。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              child: const Text('确认删除'),
            ),
          ],
        );
      },
    );

    if (confirm != true) return;

    // 2. 执行删除文件操作
    try {
      Directory appDocDir = await getApplicationDocumentsDirectory();
      String dbPath = p.join(appDocDir.path, 'old_hole.db');
      File dbFile = File(dbPath);

      if (await dbFile.exists()) {
        await dbFile.delete();
      }

      // 3. 刷新页面状态
      if (mounted) {
        setState(() {
          _hasOldData = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('旧洞数据已成功删除！')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Token 设置',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _tokenTController,
            decoration: const InputDecoration(
              labelText: '新 T 树洞 Token',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => _schedulePersist(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _tokenQController,
            decoration: const InputDecoration(
              labelText: '新 Q 树洞 / 新 Q 旧洞 Token',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => _schedulePersist(),
          ),
          const SizedBox(height: 24),

          // --- 旧洞数据导入部分 ---
          Text(
            '旧洞数据导入',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                // 动态根据 _hasOldData 状态渲染按钮
                child: ElevatedButton.icon(
                  onPressed: _hasOldData ? _deleteOldData : _importOldData,
                  icon: Icon(_hasOldData ? Icons.delete_forever : Icons.data_object),
                  label: Text(_hasOldData ? '删除数据' : '导入数据'),
                  style: _hasOldData
                      ? ElevatedButton.styleFrom(
                    // 如果是删除状态，将按钮文字和图标变成红色（错误警告色）
                    foregroundColor: Theme.of(context).colorScheme.error,
                  )
                      : null,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () {
                    // TODO: 在此处实现导入图片的逻辑
                  },
                  icon: const Icon(Icons.image),
                  label: const Text('导入图片'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          // --- 旧洞数据导入部分 END ---

          Text(
            '帖子缓存',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '启用缓存',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    Switch(
                      value: _cacheEnabled,
                      onChanged: (value) {
                        setState(() {
                          _cacheEnabled = value;
                        });
                        _persist(showError: true);
                      },
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 120,
                      child: TextField(
                        controller: _cacheHoursController,
                        enabled: _cacheEnabled,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '时长(小时)',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        onChanged: (_) => _schedulePersist(),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '开启后，一段时间内访问过的帖子将使用本地缓存。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('折叠含 tag 树洞'),
            value: _collapseTaggedPosts,
            onChanged: (value) {
              setState(() {
                _collapseTaggedPosts = value;
              });
              _persist(showError: false);
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('下滑隐藏底栏'),
            value: _autoHideBottomBar,
            onChanged: (value) {
              setState(() {
                _autoHideBottomBar = value;
              });
              _persist(showError: false);
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Referer 伪装（修复新 T 图片显示异常）'),
            value: _enableTImageRefererSpoof,
            onChanged: (value) {
              setState(() {
                _enableTImageRefererSpoof = value;
              });
              _persist(showError: false);
            },
          ),
          const SizedBox(height: 12),
          Text(
            '主题模式',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(
                value: ThemeMode.system,
                label: Text('跟随系统'),
              ),
              ButtonSegment(
                value: ThemeMode.light,
                label: Text('浅色'),
              ),
              ButtonSegment(
                value: ThemeMode.dark,
                label: Text('深色'),
              ),
            ],
            selected: {_themeMode},
            onSelectionChanged: (selection) async {
              final next = selection.first;
              setState(() {
                _themeMode = next;
              });
              await setThemeMode(next);
            },
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Text(
                '网站入口',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const Spacer(),
              TextButton(
                onPressed: () => _openExternalUrl(
                  'https://thuhollow.github.io',
                ),
                child: const Text('新 T 树洞'),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => _openExternalUrl(
                  'https://new-q.thuhole.site',
                ),
                child: const Text('新 Q 树洞'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}