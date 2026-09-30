import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:volume_controller/volume_controller.dart';

import '../services/player_settings.dart';

/// 移动端手势层：左半屏上下滑调亮度、右半屏上下滑调音量、长按 2 倍速松开恢复。
/// 透明覆盖层（translucent），点击/双击事件仍由内置控件处理。
class MobileGestureLayer extends StatefulWidget {
  const MobileGestureLayer({
    super.key,
    required this.player,
    required this.settings,
  });

  final Player player;
  final PlayerSettings settings;

  @override
  State<MobileGestureLayer> createState() => _MobileGestureLayerState();
}

class _MobileGestureLayerState extends State<MobileGestureLayer> {
  final ValueNotifier<String> _hint = ValueNotifier('');
  bool _adjustingBrightness = false;
  double _startValue = 0;

  @override
  void dispose() {
    _hint.dispose();
    // 离开播放页时恢复系统亮度（手势只在应用内生效）
    unawaited(() async {
      try {
        await ScreenBrightness().resetApplicationScreenBrightness();
      } catch (_) {}
    }());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: _onDragStart,
      onVerticalDragUpdate: _onDragUpdate,
      onVerticalDragEnd: (_) => _hideHint(),
      onLongPressStart: (_) async {
        await widget.player.setRate(2.0);
        _showHint('2x 倍速播放中');
      },
      onLongPressEnd: (_) async {
        await widget.player.setRate(widget.settings.rate);
        _hideHint();
      },
      child: Stack(
        children: [
          const SizedBox.expand(),
          Positioned(
            top: 90,
            left: 0,
            right: 0,
            child: ValueListenableBuilder<String>(
              valueListenable: _hint,
              builder: (_, text, __) => text.isEmpty
                  ? const SizedBox.shrink()
                  : Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          text,
                          style:
                              const TextStyle(color: Colors.white, fontSize: 13),
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _onDragStart(DragStartDetails details) async {
    final width = MediaQuery.of(context).size.width;
    _adjustingBrightness = details.localPosition.dx < width / 2;
    try {
      _startValue = _adjustingBrightness
          ? await ScreenBrightness().application
          : await VolumeController.instance.getVolume();
    } catch (_) {
      _startValue = 0.5;
    }
  }

  Future<void> _onDragUpdate(DragUpdateDetails details) async {
    final height = MediaQuery.of(context).size.height;
    final delta = -details.delta.dy / (height * 0.6);
    final value = (_startValue + delta).clamp(0.0, 1.0);
    final percent = (value * 100).round();
    try {
      if (_adjustingBrightness) {
        await ScreenBrightness().setApplicationScreenBrightness(value);
        _showHint('亮度 $percent%');
      } else {
        await VolumeController.instance.setVolume(value);
        _showHint('音量 $percent%');
      }
    } catch (_) {}
  }

  void _showHint(String text) => _hint.value = text;

  void _hideHint() => _hint.value = '';
}
