import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_item.dart';
import '../utils/natural_sort.dart';

/// “视频库”：常用文件夹列表与其中的视频扫描结果（递归）。
class MediaLibraryService extends ChangeNotifier {
  MediaLibraryService._();

  static final MediaLibraryService instance = MediaLibraryService._();

  static const String _foldersKey = 'library.folders.v1';

  List<String> _folders = [];
  bool _scanning = false;
  List<String> _videos = const [];

  List<String> get folders => List.unmodifiable(_folders);
  bool get scanning => _scanning;

  /// 按自然顺序排序的全部视频（自然排序：EP2 < EP10）。
  List<String> get videos => _videos;

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_foldersKey);
      if (raw != null && raw.isNotEmpty) {
        _folders = List<String>.from(jsonDecode(raw) as List);
      }
    } catch (_) {}
    if (_folders.isNotEmpty) {
      unawaited(scan());
    }
  }

  Future<void> _persistFolders() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_foldersKey, jsonEncode(_folders));
    } catch (_) {}
  }

  /// 仅测试用：清空内存状态（不落盘）。
  @visibleForTesting
  void reset() {
    _folders = [];
    _videos = const [];
    _scanning = false;
    notifyListeners();
  }

  Future<void> addFolder(String path) async {
    if (!_folders.contains(path)) {
      _folders.add(path);
      await _persistFolders();
      notifyListeners();
    }
    await scan();
  }

  Future<void> removeFolder(String path) async {
    _folders.remove(path);
    await _persistFolders();
    notifyListeners();
    await scan();
  }

  Future<void> scan() async {
    _scanning = true;
    notifyListeners();
    final found = <String>{};
    for (final folder in _folders) {
      try {
        await for (final entity
            in Directory(folder).list(recursive: true, followLinks: false)) {
          if (entity is File && MediaItem.isVideoFile(entity.path)) {
            found.add(entity.path);
          }
        }
      } catch (_) {
        // 目录不可读时跳过
      }
    }
    _videos = found.toList()..sort(naturalCompare);
    _scanning = false;
    notifyListeners();
  }
}
