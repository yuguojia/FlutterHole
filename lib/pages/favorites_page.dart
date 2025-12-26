import 'package:flutter/material.dart';

import 'favorites_view.dart';
import 'settings_page.dart';

class FavoritesPage extends StatelessWidget {
  const FavoritesPage({
    super.key,
    required this.token,
    required this.baseUrl,
    required this.backendKey,
    required this.supportsComment,
    this.imageHeaders,
  });

  final String token;
  final String baseUrl;
  final String backendKey;
  final bool supportsComment;
  final Map<String, String>? imageHeaders;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('收藏'),
        actions: [
          IconButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => const SettingsPage(),
                ),
              );
            },
            tooltip: '设置',
            icon: const Icon(Icons.settings),
          ),
        ],
      ),
      body: FavoritesView(
        token: token,
        baseUrl: baseUrl,
        backendKey: backendKey,
        supportsComment: supportsComment,
        showInlineActions: true,
        imageHeaders: imageHeaders,
      ),
    );
  }
}
