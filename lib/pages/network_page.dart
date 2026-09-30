import 'dart:async';

import 'package:flutter/material.dart';

import '../services/webdav_service.dart';
import '../utils/natural_sort.dart';

/// “网络”页签：WebDAV 服务器管理与目录浏览。
/// 选中视频后以当前目录内全部视频为播放列表连播。
class NetworkTab extends StatefulWidget {
  const NetworkTab({
    super.key,
    required this.onPlay,
  });

  /// (上下文, 视频 URL, 当前目录全部视频 URL 列表)
  final void Function(BuildContext context, String url, List<String> playlist)
      onPlay;

  @override
  State<NetworkTab> createState() => _NetworkTabState();
}

class _NetworkTabState extends State<NetworkTab> {
  WebdavServer? _server;
  String _path = '/';
  bool _loading = false;
  String? _error;
  List<WebdavEntry> _entries = const [];

  @override
  Widget build(BuildContext context) {
    if (_server == null) {
      return _buildServersView();
    }
    return _buildBrowserView();
  }

  // ---- 服务器列表 ----

  Widget _buildServersView() {
    return AnimatedBuilder(
      animation: WebdavService.instance,
      builder: (context, _) {
        final servers = WebdavService.instance.servers;
        if (servers.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.dns_outlined,
                    size: 72,
                    color: Theme.of(context).colorScheme.outline),
                const SizedBox(height: 16),
                const Text('添加 WebDAV 服务器，浏览并播放其中的视频'),
                const SizedBox(height: 8),
                const Text('兼容 Alist、群晖/威联通 NAS、坚果云等',
                    style: TextStyle(fontSize: 12, color: Colors.white54)),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: () => unawaited(_showServerDialog()),
                  icon: const Icon(Icons.add),
                  label: const Text('添加服务器'),
                ),
              ],
            ),
          );
        }
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            for (final server in servers)
              ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: Text(server.name.isEmpty ? server.url : server.name),
                subtitle: Text(server.url,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: '编辑',
                      icon: const Icon(Icons.edit_outlined, size: 20),
                      onPressed: () => unawaited(_showServerDialog(server: server)),
                    ),
                    IconButton(
                      tooltip: '删除',
                      icon: const Icon(Icons.delete_outline, size: 20),
                      onPressed: () =>
                          unawaited(WebdavService.instance.removeServer(server.id)),
                    ),
                  ],
                ),
                onTap: () => unawaited(_enterServer(server)),
              ),
            const SizedBox(height: 8),
            Center(
              child: OutlinedButton.icon(
                onPressed: () => unawaited(_showServerDialog()),
                icon: const Icon(Icons.add),
                label: const Text('添加服务器'),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showServerDialog({WebdavServer? server}) async {
    final nameController = TextEditingController(text: server?.name ?? '');
    final urlController = TextEditingController(text: server?.url ?? '');
    final userController = TextEditingController(text: server?.username ?? '');
    final passwordController = TextEditingController(text: server?.password ?? '');
    final formKey = GlobalKey<FormState>();

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(server == null ? '添加 WebDAV 服务器' : '编辑服务器'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: nameController,
                decoration: const InputDecoration(labelText: '名称（可选）'),
              ),
              TextFormField(
                controller: urlController,
                autofocus: server == null,
                decoration: const InputDecoration(
                  labelText: '地址',
                  hintText: 'http://192.168.1.10:5005/dav',
                ),
                validator: (value) {
                  final url = (value ?? '').trim();
                  final uri = Uri.tryParse(url);
                  if (url.isEmpty ||
                      uri == null ||
                      !uri.hasScheme ||
                      (uri.scheme != 'http' && uri.scheme != 'https')) {
                    return '请输入 http(s) 开头的地址';
                  }
                  return null;
                },
              ),
              TextFormField(
                controller: userController,
                decoration: const InputDecoration(labelText: '用户名（可选）'),
              ),
              TextFormField(
                controller: passwordController,
                obscureText: true,
                decoration: const InputDecoration(labelText: '密码（可选）'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) {
                Navigator.of(context).pop(true);
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved != true) return;
    final trimmedUrl = urlController.text.trim();
    await WebdavService.instance.saveServer(WebdavServer(
      id: server?.id ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      name: nameController.text.trim(),
      url: trimmedUrl.endsWith('/')
          ? trimmedUrl.substring(0, trimmedUrl.length - 1)
          : trimmedUrl,
      username: userController.text.trim(),
      password: passwordController.text,
    ));
  }

  // ---- 目录浏览 ----

  Future<void> _enterServer(WebdavServer server) async {
    setState(() {
      _server = server;
      _path = '/';
      _error = null;
    });
    await _load();
  }

  Future<void> _load() async {
    final server = _server;
    if (server == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await WebdavService.instance.listDirectory(server, _path);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _back() async {
    if (_path == '/') {
      setState(() => _server = null);
      return;
    }
    final segments = _path.split('/').where((s) => s.isNotEmpty).toList();
    segments.removeLast();
    setState(() {
      _path = segments.isEmpty ? '/' : '/${segments.join('/')}';
    });
    await _load();
  }

  Widget _buildBrowserView() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
          child: Row(
            children: [
              IconButton(
                tooltip: _path == '/' ? '返回服务器列表' : '上一级',
                icon: Icon(_path == '/' ? Icons.dns_outlined : Icons.arrow_back),
                onPressed: () => unawaited(_back()),
              ),
              Expanded(
                child: Text(
                  '${_server!.name}  $_path',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, color: Colors.white70),
                ),
              ),
              IconButton(
                tooltip: '刷新',
                icon: const Icon(Icons.refresh, size: 20),
                onPressed: () => unawaited(_load()),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_error!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 13)),
                          const SizedBox(height: 12),
                          OutlinedButton(
                              onPressed: () => unawaited(_load()),
                              child: const Text('重试')),
                        ],
                      ),
                    )
                  : ListView(
                      children: [
                        for (final entry in _entries)
                          ListTile(
                            dense: true,
                            leading: Icon(
                              entry.isDirectory
                                  ? Icons.folder_outlined
                                  : (entry.isVideo
                                      ? Icons.movie_outlined
                                      : Icons.insert_drive_file_outlined),
                              color: entry.isDirectory
                                  ? Theme.of(context).colorScheme.primary
                                  : (entry.isVideo
                                      ? Theme.of(context).colorScheme.primary
                                      : Colors.white24),
                            ),
                            title: Text(
                              entry.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: entry.isDirectory
                                ? null
                                : Text(entry.sizeText,
                                    style: const TextStyle(
                                        fontSize: 11, color: Colors.white38)),
                            trailing: entry.isDirectory
                                ? const Icon(Icons.chevron_right, size: 18)
                                : null,
                            onTap: () => unawaited(
                              entry.isDirectory
                                  ? _enterDirectory(entry)
                                  : _playVideo(entry),
                            ),
                          ),
                      ],
                    ),
        ),
      ],
    );
  }

  Future<void> _enterDirectory(WebdavEntry entry) async {
    setState(() => _path = entry.path);
    await _load();
  }

  Future<void> _playVideo(WebdavEntry entry) async {
    final videos = _entries
        .where((e) => e.isVideo)
        .toList()
      ..sort((a, b) => naturalCompare(a.name, b.name));
    final playlist = [
      for (final video in videos) _server!.urlForPath(video.path)
    ];
    final url = _server!.urlForPath(entry.path);
    widget.onPlay(context, url, playlist);
  }
}
