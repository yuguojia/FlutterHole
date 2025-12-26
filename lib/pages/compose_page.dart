import 'package:flutter/material.dart';

import '../services.dart';

class ComposePage extends StatefulWidget {
  const ComposePage({
    super.key,
    required this.token,
    required this.baseUrl,
    required this.roomId,
  });

  final String token;
  final String baseUrl;
  final int roomId;

  @override
  State<ComposePage> createState() => _ComposePageState();
}

class _ComposePageState extends State<ComposePage> {
  final _apiClient = TholeApiClient();
  final _cwController = TextEditingController();
  final _textController = TextEditingController();
  bool _isSending = false;

  @override
  void dispose() {
    _cwController.dispose();
    _textController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _textController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('正文不能为空')),
      );
      return;
    }
    setState(() {
      _isSending = true;
    });
    try {
      await _apiClient.createPost(
        token: widget.token,
        baseUrl: widget.baseUrl,
        roomId: widget.roomId,
        text: text,
        cw: _cwController.text.trim(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('发布成功')),
      );
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('发布失败: $error')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('发帖'),
        actions: [
          IconButton(
            onPressed: _isSending ? null : _submit,
            icon: _isSending
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send),
            tooltip: '发送',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _cwController,
            decoration: const InputDecoration(
              labelText: 'Tag',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _textController,
            maxLines: 10,
            decoration: const InputDecoration(
              labelText: '正文',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
    );
  }
}
