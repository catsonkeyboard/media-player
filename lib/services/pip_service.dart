import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'platform_caps.dart';

/// 画中画/小窗：
/// - Android 8.0+：系统级画中画（Activity PiP，Flutter 纹理照常渲染）
/// - macOS/Windows：迷你置顶小窗（window_manager 调整主窗口实现）
/// - iOS：系统画中画只认 AVPlayer 画面，与 media_kit 纹理渲染不兼容，暂不支持
class PipService {
  static const _channel = MethodChannel('app/native');

  /// Android 系统画中画状态（原生侧回推 pipChanged）
  static final ValueNotifier<bool> active = ValueNotifier(false);

  static bool _androidSupported = false;

  static bool get mobileSupported =>
      !kIsWeb && Platform.isAndroid && _androidSupported;

  static bool get desktopSupported => PlatformCaps.isDesktop;

  static bool get supported => mobileSupported || desktopSupported;

  static Future<void> init() async {
    if (kIsWeb) return;
    if (desktopSupported) {
      try {
        await windowManager.ensureInitialized();
      } on MissingPluginException catch (_) {}
    }
    if (Platform.isAndroid) {
      try {
        _androidSupported =
            await _channel.invokeMethod<bool>('isPipSupported') ?? false;
      } on PlatformException catch (_) {
        _androidSupported = false;
      }
    }
  }

  /// 进入 Android 系统画中画；宽高用于设置画中画窗口宽高比。
  static Future<void> enterAndroid({int? width, int? height}) async {
    try {
      await _channel.invokeMethod('enterPip', {
        'width': width ?? 16,
        'height': height ?? 9,
      });
    } on PlatformException catch (_) {}
  }
}
