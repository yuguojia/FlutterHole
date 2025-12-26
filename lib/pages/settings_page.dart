import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

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
