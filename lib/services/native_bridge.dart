import 'package:flutter/services.dart';

import 'app_shutdown.dart';
import 'now_playing_service.dart';
import 'pip_service.dart';

/// 与 macOS / Android 原生侧通信：优雅退出握手、画中画状态、系统媒体控制、
/// 文件关联打开事件。
class NativeBridge {
  static const MethodChannel channel = MethodChannel('app/native');

  static bool _initialized = false;

  /// macOS 双击文件 / Finder“打开方式”事件（main 注入，避免循环依赖）
  static void Function(String path)? onOpenFile;

  static void init() {
    if (_initialized) return;
    _initialized = true;
    channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'appWillTerminate':
          // 原生侧已挂起进程终止：先释放播放器（落盘进度、销毁 libmpv）再放行。
          await AppShutdown.runAll();
          try {
            await channel.invokeMethod('terminateNow');
          } on PlatformException catch (_) {}
        case 'pipChanged':
          PipService.active.value = call.arguments == true;
        case 'remoteCommand':
          final args = Map<String, dynamic>.from(call.arguments as Map);
          NowPlayingService.handleCommand(
            args['action'] as String,
            (args['positionMs'] as num?)?.toInt(),
          );
        case 'openFile':
          final path = call.arguments as String;
          onOpenFile?.call(path);
      }
      return null;
    });
  }

  /// 忽略结果的原生调用（Now Playing 等非关键路径）。
  static void safeInvoke(String method, [Map<String, dynamic>? arguments]) {
    channel.invokeMethod(method, arguments).then((_) {}, onError: (_) {});
  }
}
