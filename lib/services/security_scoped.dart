import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'native_bridge.dart';

/// macOS 沙盒只放行"用户在文件对话框里选过的文件"，且授权仅限当次会话；
/// 安全作用域书签（security-scoped bookmark）用于跨会话恢复访问权。
///
/// 书签机制只在 [enabled]（macOS 且确实运行于沙盒中）时启用；
/// 非沙盒构建（开发期直接分发）按路径直接访问，行为与 VLC 等桌面播放器一致。
class SecurityScoped {
  static bool _enabled = false;

  static bool get enabled => _enabled;

  /// 启动时调用：向原生侧查询当前是否运行在沙盒中。
  static Future<void> init() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.macOS) return;
    try {
      _enabled =
          await NativeBridge.channel.invokeMethod<bool>('isSandboxed') ?? false;
    } on PlatformException catch (_) {
      _enabled = false;
    }
  }

  /// 用户刚选完文件时调用（此刻仍持有授权），返回 base64 书签数据。
  static Future<String?> createBookmark(String path) async {
    if (!enabled) return null;
    try {
      return await NativeBridge.channel
          .invokeMethod<String>('createBookmark', {'path': path});
    } on PlatformException catch (_) {
      return null;
    }
  }

  /// 解析书签并开始访问安全作用域资源，返回可用于播放的路径。
  /// 用完需调用 [stopAccess] 释放。
  static Future<String?> resolveBookmark(String bookmark) async {
    if (!enabled) return null;
    try {
      return await NativeBridge.channel
          .invokeMethod<String>('resolveBookmark', {'bookmark': bookmark});
    } on PlatformException catch (_) {
      return null;
    }
  }

  static Future<void> stopAccess(String path) async {
    if (!enabled) return;
    try {
      await NativeBridge.channel.invokeMethod('stopAccess', {'path': path});
    } on PlatformException catch (_) {}
  }
}
