import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 片头/片尾跳过标记：按文件记录，持久化。
/// 播放时自动跳过已标记的片头，片尾到达后自动切下一集（列表播放时）。
class SkipMarkersService {
  SkipMarkersService._();

  static final SkipMarkersService instance = SkipMarkersService._();

  static const String _storageKey = 'skip.markers.v1';
  Map<String, dynamic> _data = {};

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      if (raw != null && raw.isNotEmpty) {
        _data = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      }
    } catch (_) {
      _data = {};
    }
  }

  Duration? introEndOf(String path) => _of(path, 'introEndMs');
  Duration? outroStartOf(String path) => _of(path, 'outroStartMs');

  Duration? _of(String path, String field) {
    final entry = _data[path];
    if (entry is! Map<String, dynamic>) return null;
    final ms = (entry[field] as num?)?.toInt();
    return ms == null ? null : Duration(milliseconds: ms);
  }

  Future<void> setIntroEnd(String path, Duration d) =>
      _set(path, 'introEndMs', d);

  Future<void> setOutroStart(String path, Duration d) =>
      _set(path, 'outroStartMs', d);

  Future<void> clearIntroEnd(String path) => _remove(path, 'introEndMs');

  Future<void> clearOutroStart(String path) => _remove(path, 'outroStartMs');

  Future<void> _set(String path, String field, Duration d) async {
    final entry =
        Map<String, dynamic>.from(_data[path] as Map<String, dynamic>? ?? {});
    entry[field] = d.inMilliseconds;
    _data[path] = entry;
    await _persist();
  }

  Future<void> _remove(String path, String field) async {
    final entry =
        Map<String, dynamic>.from(_data[path] as Map<String, dynamic>? ?? {});
    entry.remove(field);
    if (entry.isEmpty) {
      _data.remove(path);
    } else {
      _data[path] = entry;
    }
    await _persist();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_storageKey, jsonEncode(_data));
    } catch (_) {}
  }
}
