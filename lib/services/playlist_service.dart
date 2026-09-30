import 'dart:math';

import 'package:flutter/foundation.dart';

enum PlayMode { sequence, loopList, repeatOne, shuffle }

extension PlayModeLabel on PlayMode {
  String get label => switch (this) {
        PlayMode.sequence => '顺序',
        PlayMode.loopList => '列表循环',
        PlayMode.repeatOne => '单曲循环',
        PlayMode.shuffle => '随机',
      };
}

/// 播放队列与播放模式。播放页通过 next()/previous()/nextManual() 取得应播放的路径。
class PlaylistService extends ChangeNotifier {
  PlaylistService._();

  static final PlaylistService instance = PlaylistService._();

  final Random _random = Random();
  List<String> _items = const [];
  int _index = -1;
  PlayMode _mode = PlayMode.sequence;

  bool get active => _items.isNotEmpty;
  List<String> get items => List.unmodifiable(_items);
  int get index => _index;

  /// 1 起的展示位置（第几个/共几个）。
  int get displayPosition => _index + 1;

  PlayMode get mode => _mode;

  set mode(PlayMode value) {
    if (_mode == value) return;
    _mode = value;
    notifyListeners();
  }

  void setList(List<String> paths, {int startIndex = 0}) {
    _items = List.of(paths);
    _index = _items.isEmpty ? -1 : startIndex.clamp(0, _items.length - 1);
    notifyListeners();
  }

  void jumpTo(int index) {
    if (index >= 0 && index < _items.length) {
      _index = index;
      notifyListeners();
    }
  }

  void clear() {
    _items = const [];
    _index = -1;
    notifyListeners();
  }

  /// 播完自动前进；顺序模式到达末尾返回 null（应结束播放）。
  String? next() {
    if (!active) return null;
    switch (_mode) {
      case PlayMode.repeatOne:
        return _items[_index];
      case PlayMode.loopList:
        _index = (_index + 1) % _items.length;
      case PlayMode.sequence:
        if (_index + 1 >= _items.length) return null;
        _index += 1;
      case PlayMode.shuffle:
        _index = _randomOther();
    }
    notifyListeners();
    return _items[_index];
  }

  /// 手动下一曲；顺序模式到达末尾时回绕到开头。
  String? nextManual() {
    if (!active) return null;
    _index = _mode == PlayMode.shuffle
        ? _randomOther()
        : (_index + 1) % _items.length;
    notifyListeners();
    return _items[_index];
  }

  /// 手动上一曲；回绕到末尾。
  String? previous() {
    if (!active) return null;
    _index = _mode == PlayMode.shuffle
        ? _randomOther()
        : (_index - 1 + _items.length) % _items.length;
    notifyListeners();
    return _items[_index];
  }

  int _randomOther() {
    if (_items.length <= 1) return 0;
    var next = _random.nextInt(_items.length);
    if (next == _index) next = (next + 1) % _items.length;
    return next;
  }
}
