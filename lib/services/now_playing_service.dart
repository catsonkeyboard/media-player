import 'dart:async';

import 'package:media_kit/media_kit.dart';

import 'native_bridge.dart';
import 'platform_caps.dart';

/// macOS 系统媒体控制：向 Now Playing 推送播放信息，遥控命令（播放/暂停/
/// 快进/上下曲）经 NativeBridge 转发到 attach 时注册的处理器。
class NowPlayingService {
  NowPlayingService._();

  static bool get isSupported => PlatformCaps.isMacOS;

  static Player? _player;
  static Timer? _timer;
  static String _title = '';
  static void Function(String action, int? positionMs)? _commandHandler;

  static void attach(
    Player player, {
    required String title,
    void Function(String action, int? positionMs)? onCommand,
  }) {
    _player = player;
    _title = title;
    _commandHandler = onCommand;
    if (!isSupported) return;
    _push();
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _push());
  }

  static void updateTitle(String title) {
    _title = title;
    if (isSupported && _player != null) _push();
  }

  /// 播放/暂停状态变化时立即刷新（平时每秒推送一次）。
  static void refresh() {
    if (isSupported && _player != null) _push();
  }

  static void detach() {
    _player = null;
    _commandHandler = null;
    _timer?.cancel();
    _timer = null;
    if (isSupported) {
      NativeBridge.safeInvoke('nowPlayingClear');
    }
  }

  static void _push() {
    final player = _player;
    if (!isSupported || player == null) return;
    NativeBridge.safeInvoke('nowPlayingUpdate', {
      'title': _title,
      'durationMs': player.state.duration.inMilliseconds,
      'positionMs': player.state.position.inMilliseconds,
      'rate': player.state.playing ? player.state.rate : 0.0,
    });
  }

  static void handleCommand(String action, int? positionMs) =>
      _commandHandler?.call(action, positionMs);
}
