import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_item.dart';

/// 最近播放列表与播放进度的持久化（shared_preferences + JSON）。
/// MVP 数据量小够用；条目规模上来后再迁 SQLite/Isar。
class LibraryService extends ChangeNotifier {
  LibraryService._(this._prefs) {
    _load();
  }

  static const String _storageKey = 'library.v1';

  static LibraryService? _instance;
  static LibraryService get instance => _instance!;

  static Future<LibraryService> ensureCreated() async {
    if (_instance != null) return _instance!;
    final prefs = await SharedPreferences.getInstance();
    return _instance = LibraryService._(prefs);
  }

  final SharedPreferences _prefs;
  final List<MediaItem> _items = [];

  /// 按最近播放时间倒序。
  List<MediaItem> get items => List.unmodifiable(_items);

  MediaItem? byPath(String path) {
    for (final item in _items) {
      if (item.path == path) return item;
    }
    return null;
  }

  void _load() {
    final raw = _prefs.getString(_storageKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      _items
        ..clear()
        ..addAll(
          list.whereType<Map<String, dynamic>>().map(MediaItem.fromJson),
        );
      _sortByRecency();
    } catch (_) {
      // 记录损坏时丢弃重来，不影响播放。
    }
  }

  Future<void> _persist() async {
    final raw = jsonEncode(_items.map((e) => e.toJson()).toList());
    await _prefs.setString(_storageKey, raw);
  }

  void _sortByRecency() =>
      _items.sort((a, b) => b.lastPlayedAt.compareTo(a.lastPlayedAt));

  /// 标记开始播放：新条目入列，老条目提升到最前；传入书签时更新之。返回对应记录。
  MediaItem markPlayed(String path, {String? bookmark}) {
    final index = _items.indexWhere((e) => e.path == path);
    if (index >= 0) {
      _items[index].lastPlayedAt = DateTime.now();
      if (bookmark != null) _items[index].bookmark = bookmark;
    } else {
      _items.add(
        MediaItem(path: path, title: _defaultTitle(path), bookmark: bookmark),
      );
    }
    _sortByRecency();
    notifyListeners();
    _persist();
    return _items.firstWhere((e) => e.path == path);
  }

  /// 记录播放进度；条目不存在时忽略。
  void updateProgress(String path, Duration position, Duration duration) {
    final item = byPath(path);
    if (item == null) return;
    item.lastPositionMs = position.inMilliseconds;
    if (duration.inMilliseconds > 0) {
      item.durationMs = duration.inMilliseconds;
    }
    _persist();
    notifyListeners();
  }

  void remove(String path) {
    _items.removeWhere((e) => e.path == path);
    notifyListeners();
    _persist();
  }

  void clear() {
    _items.clear();
    notifyListeners();
    _persist();
  }

  static String _defaultTitle(String path) => MediaItem.titleOf(path);
}
