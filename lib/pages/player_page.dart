import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import '../models/chapter_info.dart';
import '../models/media_item.dart';
import '../services/app_shutdown.dart';
import '../services/library_service.dart';
import '../services/now_playing_service.dart';
import '../services/pip_service.dart';
import '../services/platform_caps.dart';
import '../services/player_settings.dart';
import '../services/playlist_service.dart';
import '../services/security_scoped.dart';
import '../services/skip_markers_service.dart';
import '../services/window_service.dart';
import 'desktop_controls.dart';
import 'mobile_gestures.dart';
import 'player_sheets.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key, required this.path, this.startOver = false});

  final String path;
  final bool startOver;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  final Player _player = Player();
  late final VideoController _controller;
  late final PlayerSettings _settings;

  /// 当前播放路径；列表播放时可切换
  late String _path;
  Timer? _progressTimer;
  Timer? _chapterTimer;

  /// 通过书签获得的沙盒访问路径，退出播放页时停止访问。
  String? _accessPath;
  bool _released = false;

  /// 桌面迷你小窗（画中画）状态与进入前的窗口位置
  bool _desktopPip = false;
  Rect? _windowBoundsBeforePip;

  /// 视频全屏状态（窗口全屏，由自定义桌面控件切换）
  bool _videoFullscreen = false;

  /// 章节（mpv chapter-list），duration 事件后异步加载
  List<ChapterInfo> _chapters = const [];
  int _currentChapter = -1;

  /// 字幕字号（Flutter SubtitleView 渲染，会话级）
  double _subtitleFontSize = 45;

  /// A-B 循环状态：off -> a -> loop -> off
  String _abState = 'off';

  String get _abLabel => switch (_abState) {
        'a' => 'A-B:A',
        'loop' => 'A-B:循环',
        _ => 'A-B',
      };

  /// 播放信息面板
  bool _showStats = false;
  List<(String, String)> _statsLines = const [];
  Timer? _statsTimer;

  /// 片尾自动连播每次播放只触发一次
  bool _outroTriggered = false;

  String get _rateLabel {
    final rate = _settings.rate;
    return rate == rate.roundToDouble() ? '${rate.toInt()}x' : '${rate}x';
  }

  @override
  void initState() {
    super.initState();
    _path = widget.path;
    _controller = VideoController(_player);
    _settings = PlayerSettings(_player);
    // 应用持久化的硬解/反交错/HDR/均衡器/倍速
    unawaited(_settings.applyAll());

    // 播放完成：按播放模式决定连播/单曲循环/结束
    _player.stream.completed.listen((completed) {
      if (!completed || !mounted) return;
      unawaited(_onCompleted());
    });

    // 解码/打开失败提示
    _player.stream.error.listen((message) {
      if (!mounted || message.isEmpty) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('播放出错：$message')),
      );
    });

    // 媒体加载完成（时长就绪）后读取章节
    _player.stream.duration.listen((_) => unawaited(_loadChapters()));
    _player.stream.playing.listen((_) => NowPlayingService.refresh());

    AppShutdown.register(_release);
    NowPlayingService.attach(
      _player,
      title: MediaItem.titleOf(_path),
      onCommand: _handleRemoteCommand,
    );
    unawaited(_openMedia());
    _progressTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      LibraryService.instance
          .updateProgress(_path, _player.state.position, _player.state.duration);
      _checkOutroSkip();
    });
    _chapterTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_updateCurrentChapter());
    });
  }

  /// 片尾到达后自动连播（列表播放时）。
  void _checkOutroSkip() {
    if (_outroTriggered || !PlaylistService.instance.active) return;
    final outro = SkipMarkersService.instance.outroStartOf(_path);
    if (outro == null) return;
    if (_player.state.position >= outro) {
      _outroTriggered = true;
      unawaited(_playNext());
    }
  }

  Future<void> _onCompleted() async {
    if (PlaylistService.instance.mode == PlayMode.repeatOne) {
      LibraryService.instance
          .updateProgress(_path, Duration.zero, _player.state.duration);
      await _player.seek(Duration.zero);
      await _player.play();
      return;
    }
    final next = PlaylistService.instance.next();
    if (next != null && next != _path) {
      await _switchTo(next);
      return;
    }
    LibraryService.instance
        .updateProgress(_path, Duration.zero, _player.state.duration);
    if (mounted) Navigator.of(context).maybePop();
  }

  Future<void> _playPrevious() async {
    final previous = PlaylistService.instance.previous();
    if (previous != null) await _switchTo(previous);
  }

  Future<void> _playNext() async {
    final next = PlaylistService.instance.nextManual();
    if (next != null) await _switchTo(next);
  }

  /// 列表内切换视频：保存旧进度、复位会话级画面调整、打开新路径。
  Future<void> _switchTo(String path) async {
    if (path == _path) return;
    LibraryService.instance.updateProgress(
        _path, _player.state.position, _player.state.duration);
    final oldAccess = _accessPath;
    _accessPath = null;
    if (oldAccess != null) {
      await SecurityScoped.stopAccess(oldAccess);
    }
    await _settings.resetPicture();
    await _resetAbLoop();
    LibraryService.instance.markPlayed(path);
    if (!mounted) return;
    setState(() {
      _path = path;
      _chapters = const [];
      _currentChapter = -1;
    });
    NowPlayingService.updateTitle(MediaItem.titleOf(path));
    await _openMedia();
  }

  /// 落盘进度并销毁 libmpv；页面退出与进程退出共用。
  Future<void> _release() async {
    if (_released) return;
    _released = true;
    _progressTimer?.cancel();
    _chapterTimer?.cancel();
    _statsTimer?.cancel();
    // dispose 发生在帧收尾的锁树阶段，先对播放状态取快照
    final position = _player.state.position;
    final duration = _player.state.duration;
    final accessPath = _accessPath;
    _accessPath = null;
    NowPlayingService.detach();
    if (accessPath != null) {
      await SecurityScoped.stopAccess(accessPath);
    }
    _settings.dispose();
    await _player.dispose();
    // 首个 await 之后才脱离锁树窗口；此时再落盘并通知媒体库刷新，
    // 否则 notifyListeners 会在锁定阶段触发 home 页重建异常
    LibraryService.instance.updateProgress(_path, position, duration);
  }

  Future<void> _openMedia() async {
    final record = LibraryService.instance.byPath(_path);
    final savedMs = record?.lastPositionMs ?? 0;
    final totalMs = record?.durationMs ?? 0;
    final shouldResume = !widget.startOver &&
        savedMs > 5000 &&
        (totalMs <= 0 || savedMs < totalMs * 0.95);

    var playPath = _path;
    final hints = <String>[];
    if (SecurityScoped.enabled && !MediaItem.isNetworkPath(_path)) {
      final bookmark = record?.bookmark;
      if (bookmark != null) {
        final resolved = await SecurityScoped.resolveBookmark(bookmark);
        if (resolved != null) {
          playPath = resolved;
          _accessPath = resolved;
        } else {
          hints.add('无法访问该文件（可能已被移动、重命名或删除）');
        }
      } else if (record != null) {
        hints.add('该记录缺少沙盒授权，可能无法播放；请通过右上角"打开视频文件"重新选择一次，之后即可长期播放');
      }
    }

    await _player.open(Media(playPath));
    if (shouldResume) {
      await _player.seek(Duration(milliseconds: savedMs));
    }
    _outroTriggered = false;

    // 自动加载同目录的同名字幕（EP01.mp4 -> EP01.srt / EP01.zh.srt）
    await _loadMatchingSubtitle(playPath);

    // 自动跳过已标记的片头
    final introEnd = SkipMarkersService.instance.introEndOf(_path);
    if (introEnd != null &&
        introEnd > const Duration(seconds: 3) &&
        _player.state.position < introEnd) {
      await _player.seek(introEnd);
    }

    // initState 的同步阶段不能访问 inherited widget（ScaffoldMessenger 等），
    // 提示必须在首个 await 之后发出
    if (mounted && hints.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(hints.join('；'))),
      );
    }
  }

  @override
  void dispose() {
    AppShutdown.unregister(_release);
    // 页面在迷你小窗状态下被关闭（如播完自动退出）时恢复窗口
    if (_desktopPip) {
      unawaited(_setDesktopPip(false));
    }
    if (_videoFullscreen) {
      unawaited(windowManager.setFullScreen(false));
    }
    unawaited(_release());
    super.dispose();
  }

  /// 窗口级全屏切换；状态供自定义控件与 Esc 快捷键使用
  Future<void> _toggleVideoFullscreen() async {
    _videoFullscreen = !_videoFullscreen;
    await windowManager.setFullScreen(_videoFullscreen);
    if (mounted) setState(() {});
  }

  Future<void> _togglePip() async {
    if (PipService.mobileSupported) {
      await PipService.enterAndroid(
        width: _player.state.width,
        height: _player.state.height,
      );
      return;
    }
    if (PipService.desktopSupported) {
      await _setDesktopPip(!_desktopPip);
    }
  }

  /// 桌面迷你小窗：主窗口缩为视频比例、置顶、隐藏标题栏；
  /// 退出时恢复进入前的窗口位置。
  Future<void> _setDesktopPip(bool enter) async {
    if (enter) {
      _windowBoundsBeforePip ??= await windowManager.getBounds();
      final w = _player.state.width ?? 16;
      final h = _player.state.height ?? 9;
      const pipHeight = 300.0;
      final pipWidth = (pipHeight * w / h).clamp(220.0, 560.0).toDouble();
      WindowService.instance.setSuspended(true);
      await windowManager.setMinimumSize(const Size(160, 90));
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
      await windowManager.setSize(Size(pipWidth, pipHeight));
      await windowManager.setAlignment(Alignment.bottomRight);
      await windowManager.setAlwaysOnTop(true);
      _desktopPip = true;
    } else {
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setTitleBarStyle(TitleBarStyle.normal);
      final bounds = _windowBoundsBeforePip;
      if (bounds != null) {
        await windowManager.setBounds(bounds);
        _windowBoundsBeforePip = null;
      }
      WindowService.instance.setSuspended(false);
      _desktopPip = false;
    }
    if (mounted) setState(() {});
  }

  // ---- 播放控制（快捷键 / 遥控命令共用） ----

  Future<void> _togglePlay() async {
    if (_player.state.playing) {
      await _player.pause();
    } else {
      await _player.play();
    }
    NowPlayingService.refresh();
  }

  Future<void> _seekBy(Duration offset) async {
    final target = _player.state.position + offset;
    final duration = _player.state.duration;
    final clamped = target < Duration.zero
        ? Duration.zero
        : (duration > Duration.zero && target > duration ? duration : target);
    await _player.seek(clamped);
  }

  Future<void> _volumeBy(double delta) async {
    await _player.setVolume((_player.state.volume + delta).clamp(0.0, 100.0));
  }

  /// 截取当前帧（含字幕）保存到图片目录。
  Future<void> _screenshot() async {
    try {
      final dirPath = _picturesDir();
      if (dirPath == null) throw Exception('找不到可用的保存目录');
      final dir = Directory(dirPath);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final now = DateTime.now();
      String p2(int v) => v.toString().padLeft(2, '0');
      final stamp =
          '${now.year}${p2(now.month)}${p2(now.day)}_${p2(now.hour)}${p2(now.minute)}${p2(now.second)}';
      final file =
          File('${dir.path}${Platform.pathSeparator}media_player_$stamp.png');
      final bytes = await _player.screenshot(format: 'image/png');
      if (bytes == null || bytes.isEmpty) {
        throw Exception('当前没有可截取的画面');
      }
      await file.writeAsBytes(bytes);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('截图已保存：${file.path}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('截图失败：$e')),
        );
      }
    }
  }

  String? _picturesDir() {
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home == null || home.isEmpty) return null;
    return '$home${Platform.pathSeparator}Pictures';
  }

  // ---- 章节 ----

  Future<void> _loadChapters() async {
    final native = _player.platform;
    if (native is! NativePlayer) return;
    try {
      final count =
          int.tryParse(await native.getProperty('chapter-list/count')) ?? 0;
      if (count <= 1) {
        if (mounted && _chapters.isNotEmpty) {
          setState(() => _chapters = const []);
        }
        return;
      }
      final chapters = <ChapterInfo>[];
      for (var i = 0; i < count; i++) {
        final title = await native.getProperty('chapter-list/$i/title');
        final seconds =
            double.tryParse(await native.getProperty('chapter-list/$i/time'));
        if (seconds == null) continue;
        chapters.add(ChapterInfo(
          index: i,
          title: title.isEmpty ? '章节 ${i + 1}' : title,
          start: Duration(milliseconds: (seconds * 1000).round()),
        ));
      }
      if (mounted) setState(() => _chapters = chapters);
    } catch (_) {
      // 无章节或属性读取失败时静默跳过
    }
  }

  Future<void> _updateCurrentChapter() async {
    if (_chapters.isEmpty) return;
    final native = _player.platform;
    if (native is! NativePlayer) return;
    try {
      final index = int.tryParse(await native.getProperty('chapter')) ?? -1;
      if (index != _currentChapter && mounted) {
        setState(() => _currentChapter = index);
      }
    } catch (_) {}
  }

  // ---- A-B 循环 / 逐帧 / 信息面板 ----

  /// A-B 循环：无 -> 标记A -> 循环 -> 取消
  Future<void> _cycleAbLoop() async {
    final native = _player.platform;
    if (native is! NativePlayer) return;
    switch (_abState) {
      case 'a':
        await native.setProperty('ab-loop-b', _seconds(_player.state.position));
        if (mounted) setState(() => _abState = 'loop');
      case 'loop':
        await _resetAbLoop();
      default:
        await native.setProperty('ab-loop-a', _seconds(_player.state.position));
        if (mounted) setState(() => _abState = 'a');
    }
  }

  Future<void> _resetAbLoop() async {
    final native = _player.platform;
    if (native is! NativePlayer) return;
    await native.setProperty('ab-loop-a', 'no');
    await native.setProperty('ab-loop-b', 'no');
    if (mounted) setState(() => _abState = 'off');
  }

  String _seconds(Duration d) => (d.inMilliseconds / 1000).toStringAsFixed(3);

  /// 逐帧步进（自动暂停由 mpv 处理）
  Future<void> _frameStep(bool forward) async {
    final native = _player.platform;
    if (native is! NativePlayer) return;
    await native.command([forward ? 'frame-step' : 'frame-back-step']);
  }

  Future<void> _toggleStats() async {
    final show = !_showStats;
    if (mounted) setState(() => _showStats = show);
    _statsTimer?.cancel();
    if (show) {
      await _refreshStats();
      _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        unawaited(_refreshStats());
      });
    }
  }

  Future<void> _refreshStats() async {
    final native = _player.platform;
    if (native is! NativePlayer) return;
    Future<String> prop(String name) async {
      try {
        return await native.getProperty(name);
      } catch (_) {
        return '';
      }
    }

    final format = await prop('video-format');
    final fps = await prop('container-fps');
    final bitrate = await prop('video-bitrate');
    final hwdec = await prop('hwdec-current');
    final audio = await prop('audio-codec-name');
    final drops = await prop('frame-drop-count');
    final cache = await prop('demuxer-cache-duration');

    final lines = <(String, String)>[];
    if (format.isNotEmpty) {
      lines.add(('视频', fps.isNotEmpty ? '$format  ${fps}fps' : format));
    }
    if (bitrate.isNotEmpty) {
      lines.add(('码率', '$bitrate kbps'));
    }
    lines.add(('硬解', hwdec.isEmpty || hwdec == 'no' ? '软解' : hwdec));
    if (audio.isNotEmpty) {
      lines.add(('音频', audio));
    }
    if (drops.isNotEmpty) {
      lines.add(('丢帧', drops));
    }
    if (cache.isNotEmpty) {
      final seconds = double.tryParse(cache);
      if (seconds != null) {
        lines.add(('缓冲', '${seconds.toStringAsFixed(1)}s'));
      }
    }
    if (mounted) setState(() => _statsLines = lines);
  }

  // ---- 系统媒体控制 ----

  void _handleRemoteCommand(String action, int? positionMs) {
    switch (action) {
      case 'play':
        unawaited(_player.play());
      case 'pause':
        unawaited(_player.pause());
      case 'toggle':
        unawaited(_togglePlay());
      case 'seek':
        if (positionMs != null) {
          unawaited(_player.seek(Duration(milliseconds: positionMs)));
        }
      case 'nextTrack':
        unawaited(_playNext());
      case 'previousTrack':
        unawaited(_playPrevious());
    }
  }

  PlayerSheetApi _sheetApi() => PlayerSheetApi(
        player: _player,
        settings: _settings,
        rate: _settings.rate,
        chapters: _chapters,
        currentChapterIndex: _currentChapter,
        path: _path,
        subtitleFontSize: _subtitleFontSize,
        onPickSubtitle: _pickSubtitle,
        onSpeedChanged: (value) {
          unawaited(_settings.setRate(value));
          setState(() {});
        },
        onPlayFromList: (path) => unawaited(_switchTo(path)),
        onNext: _playNext,
        onPrevious: _playPrevious,
        onSubtitleFontSizeChanged: (value) {
          setState(() => _subtitleFontSize = value);
        },
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      // 桌面快捷键：空格/方向键/F/S/N/P/Esc
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (_videoFullscreen) {
              unawaited(_toggleVideoFullscreen());
            } else {
              Navigator.of(context).maybePop();
            }
          },
          const SingleActivator(LogicalKeyboardKey.space): () =>
              unawaited(_togglePlay()),
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
              unawaited(_seekBy(const Duration(seconds: -10))),
          const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
              unawaited(_seekBy(const Duration(seconds: 10))),
          const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
              unawaited(_volumeBy(10)),
          const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
              unawaited(_volumeBy(-10)),
          const SingleActivator(LogicalKeyboardKey.keyF): () =>
              unawaited(_toggleVideoFullscreen()),
          const SingleActivator(LogicalKeyboardKey.keyS): () =>
              unawaited(_screenshot()),
          const SingleActivator(LogicalKeyboardKey.keyN): () =>
              unawaited(_playNext()),
          const SingleActivator(LogicalKeyboardKey.keyP): () =>
              unawaited(_playPrevious()),
          const SingleActivator(LogicalKeyboardKey.keyA): () =>
              unawaited(_cycleAbLoop()),
          const SingleActivator(LogicalKeyboardKey.keyI): () =>
              unawaited(_toggleStats()),
          const SingleActivator(LogicalKeyboardKey.period): () =>
              unawaited(_frameStep(true)),
          const SingleActivator(LogicalKeyboardKey.comma): () =>
              unawaited(_frameStep(false)),
        },
        child: Focus(
          autofocus: true,
          child: Stack(
            // Scaffold body 高度是宽松约束：必须强制 expand，
            // 否则 Stack 按非定位子组件（顶部工具行）塌缩，视频被压成一条
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                child: Stack(
                  children: [
                    Video(
                      controller: _controller,
                      subtitleViewConfiguration: SubtitleViewConfiguration(
                        style: TextStyle(
                          height: 1.4,
                          fontSize: _subtitleFontSize,
                          color: Colors.white,
                          backgroundColor: const Color(0xaa000000),
                        ),
                      ),
                      controls: (state) {
                    if (_desktopPip) return const SizedBox.shrink();
                    // 桌面端用自定义极简控件（内置桌面控件底部栏有布局溢出问题）；
                    // 移动端继续用内置 Material/Cupertino 控件（含触摸手势）
                    if (PlatformCaps.isDesktop) {
                      return DesktopVideoControls(
                        player: _player,
                        fullscreen: _videoFullscreen,
                        onToggleFullscreen: () =>
                            unawaited(_toggleVideoFullscreen()),
                        showPlaylistControls: PlaylistService.instance.active,
                        onPrevious: () => unawaited(_playPrevious()),
                        onNext: () => unawaited(_playNext()),
                      );
                    }
                    return AdaptiveVideoControls(state);
                  },
                    ),
                    if (PlatformCaps.isMobile)
                      MobileGestureLayer(player: _player, settings: _settings),
                  ],
                ),
              ),
              // 左上角返回 + 右上角功能按钮。必须锚定顶部：StackFit.expand 下
              // 非定位子组件被拉伸到全高，Row 默认垂直居中会把按钮推到窗口中央
              Positioned(
                left: 0,
                top: 0,
                right: 0,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    child: ValueListenableBuilder<bool>(
                      valueListenable: PipService.active,
                      builder: (context, androidPipActive, _) {
                        // Android 系统画中画：窗口控制交给系统控件
                        if (androidPipActive) return const SizedBox.shrink();
                        if (_desktopPip) return _miniWindowOverlay();
                        return ListenableBuilder(
                          listenable: PlaylistService.instance,
                          builder: (context, _) => Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              _overlayIconButton(Icons.arrow_back, '返回媒体库',
                                  () => Navigator.of(context).maybePop()),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _overlayButton(
                                      '字幕',
                                      () => showSubtitleSheet(
                                          context, _sheetApi())),
                                  const SizedBox(width: 8),
                                  _overlayButton(
                                      '音轨',
                                      () =>
                                          showAudioSheet(context, _sheetApi())),
                                  const SizedBox(width: 8),
                                  _overlayButton(_rateLabel,
                                      () => showSpeedSheet(context, _sheetApi())),
                                  const SizedBox(width: 8),
                                  _overlayButton('截图',
                                      () => unawaited(_screenshot())),
                                  const SizedBox(width: 8),
                                  _overlayButton(
                                      _abLabel, () => unawaited(_cycleAbLoop())),
                                  const SizedBox(width: 8),
                                  _overlayButton(
                                      _showStats ? '信息✓' : '信息',
                                      () => unawaited(_toggleStats())),
                                  if (_chapters.length > 1) ...[
                                    const SizedBox(width: 8),
                                    _overlayButton('章节',
                                        () => showChaptersSheet(context, _sheetApi())),
                                  ],
                                  if (PlaylistService.instance.active) ...[
                                    const SizedBox(width: 8),
                                    _overlayButton(
                                        '列表 ${PlaylistService.instance.displayPosition}/${PlaylistService.instance.items.length}',
                                        () => showPlaylistSheet(context, _sheetApi())),
                                  ],
                                  if (PipService.supported) ...[
                                    const SizedBox(width: 8),
                                    _overlayButton('画中画', _togglePip),
                                  ],
                                  const SizedBox(width: 8),
                                  _overlayButton('设置',
                                      () => showSettingsSheet(context, _sheetApi())),
                                ],
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
              // 播放信息面板（I 键或"信息"按钮切换）
              if (_showStats)
                Positioned(
                  left: 12,
                  top: 0,
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 56),
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final line in _statsLines)
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 1),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    SizedBox(
                                      width: 64,
                                      child: Text(
                                        line.$1,
                                        style: const TextStyle(
                                            color: Colors.white54,
                                            fontSize: 11),
                                      ),
                                    ),
                                    Text(
                                      line.$2,
                                      style: const TextStyle(
                                          color: Colors.white, fontSize: 11),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _miniWindowOverlay() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _overlayIconButton(Icons.close, '关闭并返回媒体库',
            () => Navigator.of(context).maybePop()),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            DragToMoveArea(
              child: const Padding(
                padding: EdgeInsets.all(8),
                child:
                    Icon(Icons.drag_indicator, size: 18, color: Colors.white70),
              ),
            ),
            const SizedBox(width: 4),
            _overlayButton('退出', () => _setDesktopPip(false)),
          ],
        ),
      ],
    );
  }

  /// 圆形图标按钮（返回/关闭等），与文字按钮同风格
  Widget _overlayIconButton(IconData icon, String tooltip, VoidCallback onTap) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.black.withValues(alpha: 0.45),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(icon, size: 20, color: Colors.white),
          ),
        ),
      ),
    );
  }

  Widget _overlayButton(String label, VoidCallback onTap) {
    return Material(
      color: Colors.black.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
        ),
      ),
    );
  }

  /// 自动加载同目录同名字幕：精确同名优先，其次同前缀（EP01.zh.srt 匹配 EP01.mp4）。
  Future<void> _loadMatchingSubtitle(String mediaPath) async {
    if (MediaItem.isNetworkPath(mediaPath)) return;
    try {
      final mediaFile = File(mediaPath);
      if (!await mediaFile.exists()) return;
      final dir = mediaFile.parent;
      final basename = MediaItem.titleOf(mediaPath);
      final subtitleExtensions = ['srt', 'ass', 'ssa', 'vtt'];
      String? match;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final ext = entity.path.split('.').last.toLowerCase();
        if (!subtitleExtensions.contains(ext)) continue;
        final name = MediaItem.titleOf(entity.path);
        if (name == basename) {
          match = entity.path; // 精确同名，直接采用
          break;
        }
        if (match == null && name.startsWith(basename)) {
          match = entity.path; // 同前缀（带语言后缀），先记住
        }
      }
      if (match == null) return;
      await _player.setSubtitleTrack(
        SubtitleTrack.uri(
          Uri.file(match).toString(),
          title: MediaItem.titleOf(match),
        ),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已自动加载字幕：${MediaItem.titleOf(match)}')),
        );
      }
    } catch (_) {
      // 自动匹配失败不影响播放
    }
  }

  Future<void> _pickSubtitle() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['srt', 'ass', 'ssa', 'vtt'],
    );
    final path = file?.path;
    if (path == null) return;
    await _player.setSubtitleTrack(
      SubtitleTrack.uri(
        Uri.file(path).toString(),
        title: file!.name,
      ),
    );
  }
}
