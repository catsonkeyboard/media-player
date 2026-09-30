import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'models/media_item.dart';
import 'pages/home_page.dart';
import 'pages/player_page.dart';
import 'services/library_service.dart';
import 'services/media_library_service.dart';
import 'services/native_bridge.dart';
import 'services/pip_service.dart';
import 'services/player_settings.dart';
import 'services/playlist_service.dart';
import 'services/security_scoped.dart';
import 'services/skip_markers_service.dart';
import 'services/window_service.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await LibraryService.ensureCreated();
  await PlayerSettings.ensureLoaded();
  await SkipMarkersService.instance.init();
  await MediaLibraryService.instance.init();
  NativeBridge.init();
  await SecurityScoped.init();
  await PipService.init();
  await WindowService.instance.init();
  // macOS 文件关联/Finder 打开
  NativeBridge.onOpenFile = (path) {
    if (!MediaItem.isVideoFile(path)) return;
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    PlaylistService.instance.setList([path]);
    nav.push(MaterialPageRoute(builder: (_) => PlayerPage(path: path)));
  };
  // 调试用：MEDIA_PLAYER_TEST_VIDEO=<路径>（多个用 | 分隔）时直接进入播放页
  final testVideo = Platform.environment['MEDIA_PLAYER_TEST_VIDEO'];
  if (testVideo != null) {
    final paths = testVideo.split('|');
    if (paths.length > 1) {
      PlaylistService.instance.setList(paths);
    }
    runApp(MediaPlayerApp(home: PlayerPage(path: paths.first)));
    return;
  }
  runApp(MediaPlayerApp(home: const HomePage()));
}

class MediaPlayerApp extends StatelessWidget {
  const MediaPlayerApp({super.key, this.home = const HomePage()});

  final Widget home;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '媒体播放器',
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF5B8CFF),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0F1115),
      ),
      home: home,
    );
  }
}
