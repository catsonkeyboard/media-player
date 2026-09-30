import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart' show Rect;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'platform_caps.dart';

/// 桌面窗口位置/大小记忆；迷你小窗期间挂起记录，退出小窗恢复原位后继续。
class WindowService with WindowListener {
  WindowService._();

  static final WindowService instance = WindowService._();

  static const String _storageKey = 'window.bounds.v1';
  Timer? _debounce;
  bool _suspended = false;

  Future<void> init() async {
    if (!PlatformCaps.isDesktop) return;
    windowManager.addListener(this);
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      if (raw == null) return;
      final list =
          (jsonDecode(raw) as List).map((e) => (e as num).toDouble()).toList();
      if (list.length != 4) return;
      final rect = Rect.fromLTWH(list[0], list[1], list[2], list[3]);
      // 明显异常的尺寸（如曾在小窗模式异常退出）不恢复
      if (rect.width < 300 || rect.height < 200) return;
      await windowManager.setBounds(rect);
    } catch (_) {
      // 恢复失败保持默认窗口
    }
  }

  /// 迷你小窗期间的移动/缩放不写入记忆。
  void setSuspended(bool value) => _suspended = value;

  void _schedulePersist() {
    if (_suspended || !PlatformCaps.isDesktop) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 800), () async {
      try {
        final bounds = await windowManager.getBounds();
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          _storageKey,
          jsonEncode([bounds.left, bounds.top, bounds.width, bounds.height]),
        );
      } catch (_) {}
    });
  }

  @override
  void onWindowMove() => _schedulePersist();

  @override
  void onWindowResize() => _schedulePersist();
}
