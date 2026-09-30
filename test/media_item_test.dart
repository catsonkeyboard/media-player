import 'package:flutter_test/flutter_test.dart';
import 'package:media_player/models/media_item.dart';

void main() {
  group('MediaItem.formatMs', () {
    test('formats under one hour', () {
      expect(MediaItem.formatMs(65000), '01:05');
    });

    test('formats over one hour', () {
      expect(MediaItem.formatMs(3723000), '1:02:03');
    });
  });

  group('MediaItem progress', () {
    test('computes and clamps progress', () {
      final item = MediaItem(path: '/a/b.mp4', title: 'b')
        ..lastPositionMs = 50
        ..durationMs = 100;
      expect(item.progress, 0.5);
      expect(item.isFinished, isFalse);
    });

    test('unknown duration has zero progress', () {
      expect(MediaItem(path: '/a/c.mkv', title: 'c').progress, 0.0);
    });
  });

  test('json round trip', () {
    final item = MediaItem(
      path: '/x/a.mp4',
      title: 'a',
      lastPositionMs: 10,
      durationMs: 100,
    );
    final restored = MediaItem.fromJson(item.toJson());
    expect(restored.path, item.path);
    expect(restored.lastPositionMs, 10);
    expect(restored.durationMs, 100);
  });

  test('json round trip keeps bookmark', () {
    final item = MediaItem(path: '/x/a.mp4', title: 'a', bookmark: 'Ym9vaw==');
    final restored = MediaItem.fromJson(item.toJson());
    expect(restored.bookmark, 'Ym9vaw==');
    expect(MediaItem(path: '/x/b.mp4', title: 'b').bookmark, isNull);
  });

  group('MediaItem.isNetworkPath', () {
    test('detects stream protocols', () {
      expect(MediaItem.isNetworkPath('https://a.com/b.m3u8'), isTrue);
      expect(MediaItem.isNetworkPath('http://a.com/c.mp4'), isTrue);
      expect(MediaItem.isNetworkPath('rtsp://cam.local/stream'), isTrue);
      expect(MediaItem.isNetworkPath('rtmp://server/live'), isTrue);
    });

    test('local paths are not network', () {
      expect(MediaItem.isNetworkPath('/Users/x/a.mp4'), isFalse);
      expect(MediaItem.isNetworkPath('C:\\video\\b.mkv'), isFalse);
      expect(MediaItem.isNetworkPath('plain text'), isFalse);
    });
  });

  group('MediaItem.isVideoFile', () {
    test('recognizes video extensions', () {
      expect(MediaItem.isVideoFile('/a/movie.MKV'), isTrue);
      expect(MediaItem.isVideoFile('/a/EP01.mp4'), isTrue);
      expect(MediaItem.isVideoFile('C:\\b\\c.webm'), isTrue);
    });

    test('rejects non-video', () {
      expect(MediaItem.isVideoFile('/a/sub.srt'), isFalse);
      expect(MediaItem.isVideoFile('/a/readme'), isFalse);
      expect(MediaItem.isVideoFile('/a/.hidden'), isFalse);
    });
  });

  group('MediaItem.titleOf', () {
    test('strips extension and path', () {
      expect(MediaItem.titleOf('/a/b/EP01.mp4'), 'EP01');
      expect(MediaItem.titleOf('C:\\x\\y.mkv'), 'y');
    });

    test('trailing-slash URL falls back to host', () {
      expect(MediaItem.titleOf('https://example.com/hls/'), 'example.com');
    });
  });
}
