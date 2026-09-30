import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../models/chapter_info.dart';
import '../models/media_item.dart';
import '../services/player_settings.dart';
import '../services/playlist_service.dart';
import '../services/skip_markers_service.dart';

/// 播放页各功能面板的入参。
class PlayerSheetApi {
  PlayerSheetApi({
    required this.player,
    required this.settings,
    required this.rate,
    required this.chapters,
    required this.currentChapterIndex,
    required this.path,
    required this.subtitleFontSize,
    required this.onPickSubtitle,
    required this.onSpeedChanged,
    required this.onPlayFromList,
    required this.onNext,
    required this.onPrevious,
    required this.onSubtitleFontSizeChanged,
  });

  final Player player;
  final PlayerSettings settings;
  final double rate;
  final List<ChapterInfo> chapters;
  final int currentChapterIndex;
  final String path;
  final double subtitleFontSize;
  final Future<void> Function() onPickSubtitle;
  final void Function(double value) onSpeedChanged;
  final void Function(String path) onPlayFromList;
  final Future<void> Function() onNext;
  final Future<void> Function() onPrevious;
  final void Function(double value) onSubtitleFontSizeChanged;
}

const List<double> _speedOptions = [
  0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 3.0,
];

const TextStyle _subtitleStyle = TextStyle(fontSize: 12, color: Colors.white54);

/// 字幕：内嵌轨道切换 + 外挂字幕 + 字号/同步调整。
Future<void> showSubtitleSheet(BuildContext context, PlayerSheetApi api) async {
  final tracks = api.player.state.tracks.subtitle
      .where((t) => t.id != 'auto' && t.id != 'no')
      .toList();
  final currentId = api.player.state.track.subtitle.id;

  // 读取当前字幕延迟（秒）
  var initialDelay = 0.0;
  final native = api.player.platform;
  if (native is NativePlayer) {
    try {
      initialDelay =
          double.tryParse(await native.getProperty('sub-delay')) ?? 0;
    } catch (_) {}
  }
  final delayNotifier = ValueNotifier<double>(initialDelay);

  Future<void> applyDelay(double value) async {
    delayNotifier.value = value;
    final n = api.player.platform;
    if (n is NativePlayer) {
      try {
        await n.setProperty('sub-delay', value.toStringAsFixed(1));
      } catch (_) {}
    }
  }

  if (!context.mounted) return;
  try {
    return await _showSheet(
      context,
      title: '字幕',
      builder: (sheetContext) => [
        _trackList(
          items: [
            for (final t in tracks)
              (id: t.id, label: _trackName(t.title, t.language, t.id), track: t),
          ],
          currentId: currentId,
          onSelect: api.player.setSubtitleTrack,
          emptyText: '该视频没有内嵌字幕',
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () async {
            await api.onPickSubtitle();
            if (sheetContext.mounted) Navigator.of(sheetContext).pop();
          },
          icon: const Icon(Icons.subtitles_outlined),
          label: const Text('加载外挂字幕（srt / ass / ssa / vtt）'),
        ),
        _section('字幕样式'),
        _label('字号'),
        _chipRow<double>(
          options: {32: '小', 45: '标准', 60: '大', 80: '特大'},
          current: api.subtitleFontSize,
          onSelect: api.onSubtitleFontSizeChanged,
        ),
        _section('字幕同步'),
        ValueListenableBuilder<double>(
          valueListenable: delayNotifier,
          builder: (_, value, __) => Row(
            children: [
              OutlinedButton(
                onPressed: () => applyDelay(value - 0.5),
                child: const Text('-0.5s'),
              ),
              Expanded(
                child: Center(
                  child: Text(
                    value == 0 ? '无偏移' : '${value.toStringAsFixed(1)}s',
                    style: _subtitleStyle,
                  ),
                ),
              ),
              OutlinedButton(
                onPressed: () => applyDelay(value + 0.5),
                child: const Text('+0.5s'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => applyDelay(0),
                child: const Text('复位'),
              ),
            ],
          ),
        ),
      ],
    );
  } finally {
    delayNotifier.dispose();
  }
}

/// 音轨切换。
Future<void> showAudioSheet(BuildContext context, PlayerSheetApi api) {
  final tracks = api.player.state.tracks.audio
      .where((t) => t.id != 'auto' && t.id != 'no')
      .toList();
  final currentId = api.player.state.track.audio.id;
  return _showSheet(
    context,
    title: '音轨',
    builder: (_) => [
      _trackList(
        items: [
          for (final t in tracks)
            (id: t.id, label: _trackName(t.title, t.language, t.id), track: t),
        ],
        currentId: currentId,
        onSelect: api.player.setAudioTrack,
        emptyText: '未检测到多音轨',
      ),
    ],
  );
}

/// 倍速。
Future<void> showSpeedSheet(BuildContext context, PlayerSheetApi api) {
  return _showSheet(
    context,
    title: '播放速度',
    builder: (_) => [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final v in _speedOptions)
            ChoiceChip(
              label: Text('${v}x'),
              selected: api.rate == v,
              onSelected: (_) {
                api.onSpeedChanged(v);
                Navigator.of(context).pop();
              },
            ),
        ],
      ),
    ],
  );
}

/// 章节列表与跳转。
Future<void> showChaptersSheet(BuildContext context, PlayerSheetApi api) {
  return _showSheet(
    context,
    title: '章节',
    builder: (_) => [
      if (api.chapters.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text('没有章节信息', style: _subtitleStyle),
        )
      else
        Column(
          children: [
            for (final c in api.chapters)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                selected: c.index == api.currentChapterIndex,
                leading: SizedBox(
                  width: 28,
                  child: Text(
                    '${c.index + 1}',
                    style: _subtitleStyle,
                  ),
                ),
                title: Text(
                  c.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: c.index == api.currentChapterIndex
                      ? const TextStyle(color: Colors.white)
                      : const TextStyle(color: Colors.white70),
                ),
                trailing: Text(
                  MediaItem.formatMs(c.start.inMilliseconds),
                  style: _subtitleStyle,
                ),
                onTap: () {
                  api.player.seek(c.start);
                  Navigator.of(context).pop();
                },
              ),
          ],
        ),
    ],
  );
}

/// 播放列表：模式切换、上下曲、队列跳转。
Future<void> showPlaylistSheet(BuildContext context, PlayerSheetApi api) {
  final playlist = PlaylistService.instance;
  return _showSheet(
    context,
    title: '播放列表',
    builder: (_) => [
      ListenableBuilder(
        listenable: playlist,
        builder: (_, __) {
          if (!playlist.active) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('当前不是列表播放', style: _subtitleStyle),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: '上一曲',
                    icon: const Icon(Icons.skip_previous, color: Colors.white),
                    onPressed: () => api.onPrevious(),
                  ),
                  Text(
                    '${playlist.displayPosition} / ${playlist.items.length}',
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: '下一曲',
                    icon: const Icon(Icons.skip_next, color: Colors.white),
                    onPressed: () => api.onNext(),
                  ),
                ],
              ),
              _label('播放模式'),
              _chipRow<PlayMode>(
                options: {
                  for (final m in PlayMode.values) m: m.label,
                },
                current: playlist.mode,
                onSelect: (mode) => playlist.mode = mode,
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 300,
                child: ListView.builder(
                  itemCount: playlist.items.length,
                  itemBuilder: (context, index) {
                    final path = playlist.items[index];
                    final isCurrent = index == playlist.index;
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      selected: isCurrent,
                      leading: SizedBox(
                        width: 30,
                        child: Text(
                          '${index + 1}',
                          style: _subtitleStyle,
                        ),
                      ),
                      title: Text(
                        MediaItem.titleOf(path),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isCurrent ? Colors.white : Colors.white70,
                          fontSize: 13,
                        ),
                      ),
                      trailing: isCurrent
                          ? const Icon(Icons.play_arrow,
                              size: 16, color: Colors.white)
                          : null,
                      onTap: () {
                        Navigator.of(context).pop();
                        api.onPlayFromList(path);
                      },
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    ],
  );
}

/// 播放设置：视频处理、画面调整、均衡器。
Future<void> showSettingsSheet(BuildContext context, PlayerSheetApi api) {
  final s = api.settings;
  return _showSheet(
    context,
    title: '播放设置',
    builder: (sheetContext) => [
      ListenableBuilder(
        listenable: s,
        builder: (_, __) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _section('视频'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('硬件解码'),
              subtitle: const Text('硬解不可用时自动回退软解', style: _subtitleStyle),
              value: s.hwdec,
              onChanged: (v) => s.setHwdec(v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('反交错（去隔行）'),
              subtitle: const Text('适合老电视、录像带等隔行扫描片源', style: _subtitleStyle),
              value: s.deinterlace,
              onChanged: (v) => s.setDeinterlace(v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('HDR 色调映射'),
              subtitle: const Text('将 HDR 画面映射到 SDR 显示；关闭后高光直接裁切', style: _subtitleStyle),
              value: s.hdrToneMapping,
              onChanged: (v) => s.setHdrToneMapping(v),
            ),
            _section('画面'),
            _label('宽高比'),
            _chipRow<String>(
              options: PlayerSettings.aspectOptions,
              current: s.aspect,
              onSelect: s.setAspect,
            ),
            _label('剪切（保留的画面区域）'),
            _chipRow<int>(
              options: {
                for (var i = 0; i < PlayerSettings.cropLabels.length; i++)
                  i: PlayerSettings.cropLabels[i],
              },
              current: s.crop,
              onSelect: (i) {
                if (i != 0 && api.player.state.width == null) {
                  ScaffoldMessenger.of(sheetContext).showSnackBar(
                    const SnackBar(content: Text('尚未获取到视频尺寸')),
                  );
                  return;
                }
                s.setCrop(i);
              },
            ),
            _label('旋转'),
            _chipRow<int>(
              options: PlayerSettings.rotationOptions,
              current: s.rotation,
              onSelect: s.setRotation,
            ),
            _label('画面微调'),
            for (final entry in PlayerSettings.pictureAdjustLabels.entries)
              Row(
                children: [
                  SizedBox(
                    width: 44,
                    child: Text(entry.value, style: _subtitleStyle),
                  ),
                  Expanded(
                    child: Slider(
                      min: -100,
                      max: 100,
                      value: s.adjustValue(entry.key).toDouble(),
                      onChanged: (v) =>
                          s.setPictureAdjust(entry.key, v.round()),
                    ),
                  ),
                  SizedBox(
                    width: 36,
                    child: Text(
                      '${s.adjustValue(entry.key)}',
                      style: _subtitleStyle,
                      textAlign: TextAlign.right,
                    ),
                  ),
                ],
              ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => s.resetPictureAdjust(),
                icon: const Icon(Icons.restart_alt, size: 16),
                label: const Text('复位画面微调'),
              ),
            ),
            _section('跳过片头片尾'),
            _skipMarkerRow(context, api, intro: true),
            _skipMarkerRow(context, api, intro: false),
            _section('音频均衡器'),
            _chipRow<int>(
              options: {
                for (var i = 0; i < PlayerSettings.eqPresets.length; i++)
                  i: PlayerSettings.eqPresets.keys.elementAt(i),
              },
              current: s.eqPresetIndex,
              onSelect: s.setEqPreset,
            ),
            _label('自定义 10 段（-12 ~ +12 dB）'),
            for (var i = 0; i < PlayerSettings.eqBands.length; i++)
              Row(
                children: [
                  SizedBox(
                    width: 40,
                    child: Text(
                      PlayerSettings.eqBandLabels[i],
                      textAlign: TextAlign.center,
                      style: _subtitleStyle,
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      min: -12,
                      max: 12,
                      divisions: 24,
                      label: '${_gainText(s.eqGains[i])} dB',
                      value: s.eqGains[i],
                      onChanged: (v) => s.updateEqBand(i, v),
                      onChangeEnd: (_) => s.applyEq(),
                    ),
                  ),
                  SizedBox(
                    width: 56,
                    child: Text(
                      '${_gainText(s.eqGains[i])} dB',
                      style: _subtitleStyle,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    ],
  );
}

String _gainText(double gain) =>
    '${gain >= 0 ? '+' : ''}${gain.toStringAsFixed(1)}';

/// 片头/片尾标记行：显示当前标记值，"设为此刻"记录当前位置。
Widget _skipMarkerRow(
  BuildContext context,
  PlayerSheetApi api, {
  required bool intro,
}) {
  final markers = SkipMarkersService.instance;
  final value =
      intro ? markers.introEndOf(api.path) : markers.outroStartOf(api.path);
  final label = intro ? '片头跳过点' : '片尾起点';
  return Row(
    children: [
      Expanded(
        child: Text.rich(
          TextSpan(
            style: _subtitleStyle,
            children: [
              TextSpan(text: '$label：'),
              TextSpan(
                text: value == null
                    ? '未设置'
                    : MediaItem.formatMs(value.inMilliseconds),
                style: const TextStyle(color: Colors.white),
              ),
            ],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      TextButton(
        onPressed: () {
          final position = api.player.state.position;
          if (intro) {
            markers.setIntroEnd(api.path, position);
          } else {
            markers.setOutroStart(api.path, position);
          }
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已标记为 ${MediaItem.formatMs(position.inMilliseconds)}')),
          );
        },
        child: const Text('设为此刻'),
      ),
      if (value != null)
        TextButton(
          onPressed: () {
            if (intro) {
              markers.clearIntroEnd(api.path);
            } else {
              markers.clearOutroStart(api.path);
            }
          },
          child: const Text('清除'),
        ),
    ],
  );
}

Widget _section(String text) => Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 4),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
    );

Widget _label(String text) => Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 6),
      child: Text(text, style: _subtitleStyle),
    );

Widget _chipRow<T>({
  required Map<T, String> options,
  required T current,
  required ValueChanged<T> onSelect,
}) {
  return Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final entry in options.entries)
        ChoiceChip(
          label: Text(entry.value),
          selected: current == entry.key,
          onSelected: (_) => onSelect(entry.key),
          visualDensity: VisualDensity.compact,
        ),
    ],
  );
}

Widget _trackList<T>({
  required List<({String id, String label, T track})> items,
  required String currentId,
  required ValueChanged<T> onSelect,
  required String emptyText,
}) {
  if (items.isEmpty) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(emptyText, style: _subtitleStyle),
    );
  }
  return RadioGroup<String>(
    groupValue: currentId,
    onChanged: (value) {
      if (value == null) return;
      for (final item in items) {
        if (item.id == value) {
          onSelect(item.track);
          break;
        }
      }
    },
    child: Column(
      children: [
        for (final item in items)
          RadioListTile<String>(
            value: item.id,
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(item.label),
          ),
      ],
    ),
  );
}

String _trackName(String? title, String? language, String id) {
  final parts = [
    if (title != null && title.isNotEmpty) title,
    if (language != null && language.isNotEmpty) language,
  ];
  return parts.isEmpty ? '轨道 $id' : parts.join(' · ');
}

Future<void> _showSheet(
  BuildContext context, {
  required String title,
  required List<Widget> Function(BuildContext sheetContext) builder,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF171A20),
    showDragHandle: true,
    isScrollControlled: true,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.of(context).size.height * 0.75,
    ),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            ...builder(sheetContext),
          ],
        ),
      ),
    ),
  );
}
