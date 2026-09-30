import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/media_item.dart';
import '../services/library_service.dart';
import '../services/media_library_service.dart';
import '../services/platform_caps.dart';
import '../services/playlist_service.dart';
import '../services/security_scoped.dart';
import '../utils/natural_sort.dart';
import 'network_page.dart';
import 'player_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _query = '';
  String _typeFilter = 'all'; // all | local | network

  @override
  Widget build(BuildContext context) {
    final body = DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('媒体库'),
          actions: [
            IconButton(
              tooltip: '打开网络流',
              icon: const Icon(Icons.link),
              onPressed: () => _openNetworkStream(context),
            ),
            if (PlatformCaps.isDesktop)
              IconButton(
                tooltip: '打开文件夹（整季连播）',
                icon: const Icon(Icons.folder_copy_outlined),
                onPressed: () => unawaited(_openFolder(context)),
              ),
            IconButton(
              tooltip: '打开视频文件',
              icon: const Icon(Icons.folder_open),
              onPressed: () => unawaited(_pickAndPlay(context)),
            ),
            PopupMenuButton<String>(
              tooltip: '更多',
              onSelected: (value) {
                if (value == 'clear') {
                  LibraryService.instance.clear();
                  PlaylistService.instance.clear();
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'clear', child: Text('清空播放记录')),
              ],
            ),
          ],
          bottom: const TabBar(
            tabs: [Tab(text: '最近播放'), Tab(text: '视频库'), Tab(text: '网络')],
          ),
        ),
        body: TabBarView(
          children: [_recentTab(), _libraryTab(), _networkTab()],
        ),
      ),
    );
    if (!PlatformCaps.isDesktop) return body;
    return DropTarget(
      onDragDone: (details) => _handleDroppedFiles(context, details),
      child: body,
    );
  }

  // ---- 最近播放 ----

  Widget _recentTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: TextField(
            onChanged: (value) => setState(() => _query = value.trim()),
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search),
              hintText: '搜索标题或路径',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              for (final entry in const {
                'all': '全部',
                'local': '本地',
                'network': '网络流',
              }.entries)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(entry.value),
                    selected: _typeFilter == entry.key,
                    onSelected: (_) =>
                        setState(() => _typeFilter = entry.key),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: AnimatedBuilder(
            animation: LibraryService.instance,
            builder: (context, _) {
              final items = LibraryService.instance.items.where(_matches).toList();
              if (items.isEmpty) {
                return _buildEmpty(context);
              }
              return ListView.separated(
                itemCount: items.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) => _buildTile(context, items[index]),
              );
            },
          ),
        ),
      ],
    );
  }

  bool _matches(MediaItem item) {
    if (_query.isNotEmpty &&
        !item.title.toLowerCase().contains(_query.toLowerCase()) &&
        !item.path.toLowerCase().contains(_query.toLowerCase())) {
      return false;
    }
    return switch (_typeFilter) {
      'local' => !item.isNetwork,
      'network' => item.isNetwork,
      _ => true,
    };
  }

  // ---- 网络来源 ----

  Widget _networkTab() {
    return NetworkTab(onPlay: (context, url, playlist) {
      PlaylistService.instance.setList(playlist);
      unawaited(_play(context, url));
    });
  }

  // ---- 视频库 ----

  Widget _libraryTab() {
    return AnimatedBuilder(
      animation: MediaLibraryService.instance,
      builder: (context, _) {
        final library = MediaLibraryService.instance;
        if (library.folders.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.video_library_outlined,
                    size: 72, color: Theme.of(context).colorScheme.outline),
                const SizedBox(height: 16),
                const Text('添加常用文件夹，集中浏览其中的视频'),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: () => unawaited(_addLibraryFolder(context)),
                  icon: const Icon(Icons.create_new_folder_outlined),
                  label: const Text('添加文件夹'),
                ),
              ],
            ),
          );
        }
        return Column(
          children: [
            SizedBox(
              height: 52,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                children: [
                  for (final folder in library.folders)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: InputChip(
                        label: Text(MediaItem.titleOf(folder)),
                        tooltip: folder,
                        onDeleted: () =>
                            unawaited(library.removeFolder(folder)),
                        onPressed: () => unawaited(library.scan()),
                      ),
                    ),
                  ActionChip(
                    avatar: const Icon(Icons.add, size: 18),
                    label: const Text('添加'),
                    onPressed: () => unawaited(_addLibraryFolder(context)),
                  ),
                ],
              ),
            ),
            if (library.scanning) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: library.videos.isEmpty
                  ? Center(
                      child: Text(
                        library.scanning ? '正在扫描…' : '文件夹中没有视频文件',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    )
                  : GridView.builder(
                      padding: const EdgeInsets.all(12),
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 180,
                        mainAxisSpacing: 10,
                        crossAxisSpacing: 10,
                        childAspectRatio: 0.85,
                      ),
                      itemCount: library.videos.length,
                      itemBuilder: (context, index) =>
                          _buildLibraryTile(context, library, index),
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildLibraryTile(
    BuildContext context,
    MediaLibraryService library,
    int index,
  ) {
    final path = library.videos[index];
    final record = LibraryService.instance.byPath(path);
    final progress = record?.progress ?? 0.0;
    final showProgress = progress > 0 && !(record?.isFinished ?? false);
    return Material(
      color: Colors.white.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () {
          PlaylistService.instance.setList(library.videos, startIndex: index);
          unawaited(_play(context, path));
        },
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Center(
                  child: Icon(Icons.movie_outlined,
                      size: 36,
                      color:
                          Theme.of(context).colorScheme.outline),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                MediaItem.titleOf(path),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: showProgress ? progress : 0,
                  minHeight: 3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _addLibraryFolder(BuildContext context) async {
    final dirPath = await FilePicker.getDirectoryPath();
    if (dirPath == null) return;
    await MediaLibraryService.instance.addFolder(dirPath);
  }

  // ---- 共用 ----

  /// 桌面端拖拽视频文件/文件夹到窗口即播放。
  void _handleDroppedFiles(BuildContext context, DropDoneDetails details) {
    final paths = details.files
        .map((item) => item.path)
        .where(MediaItem.isVideoFile)
        .toList()
      ..sort(naturalCompare);
    if (paths.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('拖入的内容中没有可播放的视频文件')),
      );
      return;
    }
    if (paths.length > 1) {
      PlaylistService.instance.setList(paths);
    } else {
      PlaylistService.instance.clear();
    }
    unawaited(_play(context, paths.first));
  }

  /// 打开文件夹：扫描其中视频文件并按自然顺序连播。
  Future<void> _openFolder(BuildContext context) async {
    final dirPath = await FilePicker.getDirectoryPath();
    if (dirPath == null) return;
    final videos = <String>[];
    try {
      await for (final entity in Directory(dirPath).list(followLinks: false)) {
        if (entity is File && MediaItem.isVideoFile(entity.path)) {
          videos.add(entity.path);
        }
      }
    } catch (_) {
      // 目录不可读时按空处理
    }
    videos.sort(naturalCompare);
    if (!context.mounted) return;
    if (videos.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该文件夹下没有视频文件')),
      );
      return;
    }
    PlaylistService.instance.setList(videos);
    await _play(context, videos.first);
  }

  Widget _buildEmpty(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.movie_outlined,
              size: 72, color: theme.colorScheme.outline),
          const SizedBox(height: 16),
          Text('还没有播放记录', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            PlatformCaps.isDesktop ? '也可以把视频文件直接拖进窗口' : '支持本地视频与网络流',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: () => unawaited(_pickAndPlay(context)),
                icon: const Icon(Icons.play_arrow),
                label: const Text('打开视频文件'),
              ),
              if (PlatformCaps.isDesktop)
                OutlinedButton.icon(
                  onPressed: () => unawaited(_openFolder(context)),
                  icon: const Icon(Icons.folder_copy_outlined),
                  label: const Text('打开文件夹'),
                ),
              OutlinedButton.icon(
                onPressed: () => unawaited(_openNetworkStream(context)),
                icon: const Icon(Icons.link),
                label: const Text('打开网络流'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTile(BuildContext context, MediaItem item) {
    final theme = Theme.of(context);
    final showProgress = item.lastPositionMs > 0 && !item.isFinished;
    return ListTile(
      leading: Icon(
        item.isNetwork ? Icons.cloud_outlined : Icons.movie_outlined,
        color: theme.colorScheme.primary,
      ),
      title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          Text(
            [
              if (item.durationMs > 0) MediaItem.formatMs(item.durationMs),
              if (showProgress)
                '看到 ${MediaItem.formatMs(item.lastPositionMs)}',
            ].join(' · '),
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(
            value: showProgress ? item.progress : 0,
            minHeight: 3,
            borderRadius: BorderRadius.circular(2),
          ),
        ],
      ),
      isThreeLine: true,
      trailing: PopupMenuButton<String>(
        onSelected: (value) {
          if (value == 'restart') {
            unawaited(_play(context, item.path, startOver: true));
          } else if (value == 'remove') {
            LibraryService.instance.remove(item.path);
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'restart', child: Text('从头播放')),
          PopupMenuItem(value: 'remove', child: Text('移除记录')),
        ],
      ),
      onTap: () => unawaited(_play(context, item.path)),
    );
  }

  Future<void> _pickAndPlay(BuildContext context) async {
    final file = await FilePicker.pickFile(type: FileType.video);
    final path = file?.path;
    if (path == null) return;
    // 趁授权仍在，创建沙盒安全作用域书签供下次播放使用
    final bookmark = await SecurityScoped.createBookmark(path);
    if (!context.mounted) return;
    PlaylistService.instance.clear();
    await _play(context, path, bookmark: bookmark);
  }

  /// 校验流媒体链接：必须带受支持的协议前缀
  static String? _validateStreamUrl(String? value) {
    final url = (value ?? '').trim();
    if (url.isEmpty) return '请输入链接';
    final scheme = Uri.tryParse(url)?.scheme.toLowerCase() ?? '';
    if (!MediaItem.networkSchemes.contains(scheme)) {
      return '链接需以 http(s) / rtsp / rtmp / ftp 等协议开头';
    }
    return null;
  }

  Future<void> _openNetworkStream(BuildContext context) async {
    final controller = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final url = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('打开网络流'),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: controller,
            autofocus: true,
            autofillHints: const [AutofillHints.url],
            decoration: InputDecoration(
              hintText: '视频直链 / HLS(m3u8) / RTSP / RTMP',
              helperText: '支持 http(s)、rtsp、rtmp、srt、ftp 等协议',
              suffixIcon: IconButton(
                tooltip: '粘贴剪贴板链接',
                icon: const Icon(Icons.content_paste),
                onPressed: () async {
                  final data = await Clipboard.getData('text/plain');
                  final text = data?.text?.trim();
                  if (text == null || text.isEmpty) return;
                  controller.text = text;
                  controller.selection =
                      TextSelection.collapsed(offset: text.length);
                },
              ),
            ),
            validator: _validateStreamUrl,
            onFieldSubmitted: (value) {
              if (formKey.currentState?.validate() ?? false) {
                Navigator.of(context).pop(value.trim());
              }
            },
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
                Navigator.of(context).pop(controller.text.trim());
              }
            },
            child: const Text('播放'),
          ),
        ],
      ),
    );
    if (url == null || url.trim().isEmpty) return;
    if (!context.mounted) return;
    PlaylistService.instance.clear();
    await _play(context, url.trim());
  }

  Future<void> _play(
    BuildContext context,
    String path, {
    bool startOver = false,
    String? bookmark,
  }) async {
    LibraryService.instance.markPlayed(path, bookmark: bookmark);
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerPage(path: path, startOver: startOver),
      ),
    );
  }
}
