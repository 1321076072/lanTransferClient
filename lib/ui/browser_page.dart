import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../http_share/share_client.dart';

class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key, required this.rootUrl});
  final Uri rootUrl;

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  final _stack = <Uri>[];
  List<ShareEntry>? _entries;
  String? _error;
  bool _loading = true;
  String? _status;

  Uri get _current => _stack.last;

  @override
  void initState() {
    super.initState();
    _stack.add(widget.rootUrl);
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await ShareClient.listDirectory(_current);
      if (!mounted) return;
      setState(() {
        _entries = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _open(ShareEntry e) async {
    final uri = Uri.parse(e.url);
    if (e.isDir) {
      _stack.add(uri);
      await _load();
      return;
    }
    await Permission.storage.request();
    setState(() => _status = '下载中: ${e.name}');
    try {
      final file = await ShareClient.downloadFile(
        uri,
        onProgress: (r, t) {
          if (!mounted) return;
          final pct = t == null || t <= 0
              ? '${(r / 1024 / 1024).toStringAsFixed(1)} MB'
              : '${(100 * r / t).toStringAsFixed(0)}%';
          setState(() => _status = '下载中: ${e.name}  $pct');
        },
      );
      if (!mounted) return;
      setState(() => _status = '已保存: ${file.path}');
    } catch (err) {
      if (!mounted) return;
      setState(() => _status = null);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('失败: $err')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _stack.length <= 1,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _stack.length > 1) {
          _stack.removeLast();
          _load();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_current.toString(), overflow: TextOverflow.ellipsis),
          actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)],
        ),
        body: Column(
          children: [
            if (_status != null)
              MaterialBanner(
                content: Text(_status!),
                actions: [
                  TextButton(
                    onPressed: () => setState(() => _status = null),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            FilledButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    final list = _entries ?? [];
    if (list.isEmpty) return const Center(child: Text('目录为空'));
    return ListView.separated(
      itemCount: list.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final e = list[i];
        return ListTile(
          leading: Icon(e.isDir ? Icons.folder : Icons.insert_drive_file),
          title: Text(e.name),
          trailing: Icon(e.isDir ? Icons.chevron_right : Icons.download),
          onTap: () => _open(e),
        );
      },
    );
  }
}
