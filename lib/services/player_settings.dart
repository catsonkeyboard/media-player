import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 播放器画面/视频/音频设置：本地状态 + 即时下发 mpv 属性。
/// 生命周期与播放页一致（一个 Player 一份设置）；硬解/反交错/HDR/均衡器/倍速
/// 会持久化，下次启动自动恢复应用。宽高比/剪切/旋转按片调整，不持久化。
class PlayerSettings extends ChangeNotifier {
  PlayerSettings(this._player) {
    _restore();
  }

  final Player _player;

  NativePlayer? get _native =>
      _player.platform is NativePlayer ? _player.platform as NativePlayer : null;

  // 画面（会话级）
  String aspect = 'no';
  int crop = 0; // cropLabels 的下标
  int rotation = 0;

  // 画面微调（会话级，mpv 属性名 -> 取值 -100~100）
  int brightness = 0;
  int contrast = 0;
  int saturation = 0;
  int gamma = 0;
  int hue = 0;

  static const Map<String, String> pictureAdjustLabels = {
    'brightness': '亮度',
    'contrast': '对比度',
    'saturation': '饱和度',
    'gamma': '伽马',
    'hue': '色调',
  };

  int adjustValue(String name) => switch (name) {
        'brightness' => brightness,
        'contrast' => contrast,
        'saturation' => saturation,
        'gamma' => gamma,
        'hue' => hue,
        _ => 0,
      };

  Future<void> setPictureAdjust(String name, int value) async {
    switch (name) {
      case 'brightness':
        brightness = value;
      case 'contrast':
        contrast = value;
      case 'saturation':
        saturation = value;
      case 'gamma':
        gamma = value;
      case 'hue':
        hue = value;
    }
    notifyListeners();
    await _set(name, '$value');
  }

  Future<void> resetPictureAdjust() async {
    brightness = 0;
    contrast = 0;
    saturation = 0;
    gamma = 0;
    hue = 0;
    notifyListeners();
    for (final name in pictureAdjustLabels.keys) {
      await _set(name, '0');
    }
  }

  // 视频（持久化）
  bool hwdec = true;
  bool deinterlace = false;
  bool hdrToneMapping = true;

  // 音频均衡器（持久化）
  int eqPresetIndex = 0; // -1 表示自定义
  List<double> eqGains = List<double>.filled(eqBands.length, 0);

  // 播放速度（持久化）
  double rate = 1.0;

  static const String _storageKey = 'player.settings.v1';
  static Map<String, dynamic> _loaded = const {};

  static const Map<String, String> aspectOptions = {
    'no': '默认',
    '16:9': '16:9',
    '4:3': '4:3',
    '2.35': '2.35:1',
    '1:1': '1:1',
  };

  static const List<String> cropLabels = ['无', '上下½', '上下¼', '左右½', '左右¼'];

  static const Map<int, String> rotationOptions = {
    0: '0°',
    90: '90°',
    180: '180°',
    270: '270°',
  };

  static const List<String> eqBandLabels = [
    '31', '62', '125', '250', '500', '1k', '2k', '4k', '8k', '16k',
  ];
  static const List<int> eqBands = [
    31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000,
  ];

  static const Map<String, List<double>> eqPresets = {
    '关闭': [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    '流行': [-1, 1, 3, 4, 3, 1, -1, -1, 0, 1],
    '摇滚': [5, 4, 3, 1, -1, -1, 1, 3, 4, 5],
    '古典': [4, 3, 2, 1, -1, -1, 1, 2, 3, 4],
    '爵士': [3, 2, 1, 2, -1, -1, 0, 1, 2, 3],
    '人声': [-2, -1, 0, 2, 4, 4, 3, 1, 0, -1],
    '电子': [4, 3, 1, 0, -2, 1, 0, 2, 3, 4],
  };

  static Future<void> ensureLoaded() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      if (raw != null && raw.isNotEmpty) {
        _loaded = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      }
    } catch (_) {
      _loaded = const {};
    }
  }

  void _restore() {
    if (_loaded.isEmpty) return;
    hwdec = _loaded['hwdec'] as bool? ?? hwdec;
    deinterlace = _loaded['deinterlace'] as bool? ?? deinterlace;
    hdrToneMapping = _loaded['hdrToneMapping'] as bool? ?? hdrToneMapping;
    eqPresetIndex = (_loaded['eqPresetIndex'] as num?)?.toInt() ?? eqPresetIndex;
    final gains = (_loaded['eqGains'] as List?)
        ?.map((e) => (e as num).toDouble())
        .toList();
    if (gains != null && gains.length == eqGains.length) {
      eqGains = gains;
    }
    rate = (_loaded['rate'] as num?)?.toDouble() ?? rate;
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_storageKey, jsonEncode({
        'hwdec': hwdec,
        'deinterlace': deinterlace,
        'hdrToneMapping': hdrToneMapping,
        'eqPresetIndex': eqPresetIndex,
        'eqGains': eqGains,
        'rate': rate,
      }));
    } catch (_) {
      // 持久化失败不影响播放
    }
  }

  Future<void> _set(String property, String value) async {
    final native = _native;
    if (native == null) return;
    try {
      await native.setProperty(property, value);
    } catch (_) {
      // 属性不存在（旧版 libmpv）或值非法时静默忽略
    }
  }

  /// 播放页创建后把持久化配置应用到当前播放器。
  Future<void> applyAll() async {
    await setHwdec(hwdec);
    await setDeinterlace(deinterlace);
    await setHdrToneMapping(hdrToneMapping);
    _applyEq();
    await setRate(rate);
  }

  Future<void> setAspect(String value) {
    aspect = value;
    notifyListeners();
    return _set('video-aspect-override', value);
  }

  Future<void> setCrop(int index) {
    crop = index;
    notifyListeners();
    return _applyCrop();
  }

  Future<void> _applyCrop() async {
    final w = _player.state.width;
    final h = _player.state.height;
    if (w == null || h == null) return;
    // video-crop 需要 mpv >= 0.35；“无”用全幅裁剪等效复位
    final value = switch (crop) {
      1 => '${w}x${h ~/ 2}:0:${h ~/ 4}',
      2 => '${w}x${h ~/ 4}:0:${h * 3 ~/ 8}',
      3 => '${w ~/ 2}x$h:${w ~/ 4}:0',
      4 => '${w ~/ 4}x$h:${w * 3 ~/ 8}:0',
      _ => '${w}x$h:0:0',
    };
    return _set('video-crop', value);
  }

  Future<void> setRotation(int degrees) {
    rotation = degrees;
    notifyListeners();
    return _set('video-rotate', '$degrees');
  }

  /// 切换视频时复位会话级画面调整（裁剪/比例/旋转/微调对下一集通常不适用）。
  Future<void> resetPicture() async {
    aspect = 'no';
    crop = 0;
    rotation = 0;
    notifyListeners();
    await _set('video-aspect-override', 'no');
    final w = _player.state.width;
    final h = _player.state.height;
    if (w != null && h != null) {
      await _set('video-crop', '${w}x$h:0:0');
    }
    await _set('video-rotate', '0');
    await resetPictureAdjust();
  }

  Future<void> setHwdec(bool enabled) {
    hwdec = enabled;
    notifyListeners();
    return _set('hwdec', enabled ? 'auto' : 'no').then((_) => _persist());
  }

  Future<void> setDeinterlace(bool enabled) {
    deinterlace = enabled;
    notifyListeners();
    return _set('deinterlace', enabled ? 'yes' : 'no').then((_) => _persist());
  }

  Future<void> setHdrToneMapping(bool enabled) {
    hdrToneMapping = enabled;
    notifyListeners();
    return _set('tone-mapping', enabled ? 'auto' : 'clip')
        .then((_) => _persist());
  }

  Future<void> setRate(double value) {
    rate = value;
    notifyListeners();
    return _player.setRate(value).then((_) => _persist());
  }

  void setEqPreset(int index) {
    eqPresetIndex = index;
    eqGains = List<double>.of(eqPresets.values.elementAt(index));
    notifyListeners();
    _applyEq();
    _persist();
  }

  /// 拖动中只更新状态；松手后调用 applyEq 下发，避免频繁重建音频滤镜链。
  void updateEqBand(int band, double gain) {
    eqGains[band] = gain;
    eqPresetIndex = -1;
    notifyListeners();
  }

  void applyEq() {
    _applyEq();
    _persist();
  }

  void _applyEq() {
    final flat = eqGains.every((g) => g.abs() < 0.05);
    final value = flat
        ? ''
        : List<String>.generate(
            eqBands.length,
            (i) =>
                'equalizer=f=${eqBands[i]}:t=q:w=1.0:g=${eqGains[i].toStringAsFixed(1)}',
          ).join(',');
    _set('af', value);
  }
}
