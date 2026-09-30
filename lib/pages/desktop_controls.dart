import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../models/media_item.dart';

/// 桌面端自定义播放控件：底部一条极简控制栏（播放/上下曲/进度/全屏），
/// 鼠标移动或点击画面时出现，3 秒无操作自动隐藏。
/// 替代 media_kit 内置桌面控件——后者底部栏在部分窗口尺寸下布局溢出。
class DesktopVideoControls extends StatefulWidget {
  const DesktopVideoControls({
    super.key,
    required this.player,
    required this.fullscreen,
    required this.onToggleFullscreen,
    this.showPlaylistControls = false,
    this.onPrevious,
    this.onNext,
  });

  final Player player;
  final bool fullscreen;
  final VoidCallback onToggleFullscreen;
  final bool showPlaylistControls;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  State<DesktopVideoControls> createState() => _DesktopVideoControlsState();
}

class _DesktopVideoControlsState extends State<DesktopVideoControls> {
  bool _visible = true;
  bool _scrubbing = false;
  Duration? _scrubPosition;
  Timer? _hideTimer;

  Player get _player => widget.player;

  @override
  void initState() {
    super.initState();
    _restartHideTimer();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  void _restartHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _visible = false);
    });
  }

  void _showControls() {
    if (!mounted) return;
    setState(() => _visible = true);
    _restartHideTimer();
  }

  void _hideControls() {
    _hideTimer?.cancel();
    if (mounted) setState(() => _visible = false);
  }

  Future<void> _togglePlay() async {
    if (_player.state.playing) {
      await _player.pause();
    } else {
      await _player.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
          onHover: (_) => _showControls(),
          child: Stack(
        children: [
          // 点击画面：切换控件显隐
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _visible ? _hideControls() : _showControls(),
            child: const SizedBox.expand(),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              ignoring: !_visible,
              child: AnimatedOpacity(
                opacity: _visible ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x00000000), Color(0x99000000)],
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(12, 28, 12, 4),
                  child: _buildBar(context),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBar(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: _player.stream.duration,
      builder: (context, durationSnapshot) {
        final duration = durationSnapshot.data ?? _player.state.duration;
        return StreamBuilder<Duration>(
          stream: _player.stream.position,
          builder: (context, positionSnapshot) {
            final position = _scrubbing
                ? (_scrubPosition ?? _player.state.position)
                : (positionSnapshot.data ?? _player.state.position);
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildSeekBar(context, position, duration),
                Row(
                  children: [
                    _buildPlayButton(),
                    if (widget.showPlaylistControls) ...[
                      IconButton(
                        tooltip: '上一曲',
                        icon: const Icon(Icons.skip_previous,
                            color: Colors.white),
                        onPressed: widget.onPrevious,
                      ),
                      IconButton(
                        tooltip: '下一曲',
                        icon:
                            const Icon(Icons.skip_next, color: Colors.white),
                        onPressed: widget.onNext,
                      ),
                    ],
                    const SizedBox(width: 4),
                    Text(
                      MediaItem.formatMs(position.inMilliseconds),
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    const Spacer(),
                    Text(
                      MediaItem.formatMs(duration.inMilliseconds),
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    IconButton(
                      tooltip: widget.fullscreen ? '退出全屏' : '全屏',
                      icon: Icon(
                        widget.fullscreen
                            ? Icons.fullscreen_exit
                            : Icons.fullscreen,
                        color: Colors.white,
                      ),
                      onPressed: widget.onToggleFullscreen,
                    ),
                  ],
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildPlayButton() {
    return StreamBuilder<bool>(
      stream: _player.stream.playing,
      initialData: _player.state.playing,
      builder: (context, snapshot) {
        final playing = snapshot.data ?? false;
        return IconButton(
          tooltip: playing ? '暂停' : '播放',
          icon: Icon(
            playing ? Icons.pause : Icons.play_arrow,
            color: Colors.white,
          ),
          onPressed: _togglePlay,
        );
      },
    );
  }

  Widget _buildSeekBar(
    BuildContext context,
    Duration position,
    Duration duration,
  ) {
    final totalMs = duration.inMilliseconds;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        double fractionOf(Offset local) => totalMs <= 0
            ? 0.0
            : (local.dx / width).clamp(0.0, 1.0).toDouble();
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) {
            final ms = (fractionOf(details.localPosition) * totalMs).round();
            if (ms >= 0) _player.seek(Duration(milliseconds: ms));
          },
          onHorizontalDragStart: (details) {
            setState(() {
              _scrubbing = true;
              _scrubPosition = Duration(
                milliseconds:
                    (fractionOf(details.localPosition) * totalMs).round(),
              );
            });
          },
          onHorizontalDragUpdate: (details) {
            final ms = (fractionOf(details.localPosition) * totalMs).round();
            setState(() => _scrubPosition = Duration(milliseconds: ms));
          },
          onHorizontalDragEnd: (_) async {
            final target = _scrubPosition;
            if (mounted) {
              setState(() {
                _scrubbing = false;
                _scrubPosition = null;
              });
            }
            if (target != null) await _player.seek(target);
          },
          child: SizedBox(
            height: 20,
            child: Center(
              child: Container(
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: totalMs <= 0
                      ? 0.0
                      : (position.inMilliseconds / totalMs)
                          .clamp(0.0, 1.0)
                          .toDouble(),
                  alignment: Alignment.centerLeft,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      borderRadius: BorderRadius.circular(2),
                    ),
                    height: 4,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
