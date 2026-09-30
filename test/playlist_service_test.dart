import 'package:flutter_test/flutter_test.dart';
import 'package:media_player/services/playlist_service.dart';

void main() {
  setUp(() {
    PlaylistService.instance.clear();
  });

  group('PlaylistService', () {
    test('顺序模式播完返回 null', () {
      final playlist = PlaylistService.instance;
      playlist.setList(['a', 'b', 'c']);
      playlist.mode = PlayMode.sequence;

      playlist.jumpTo(2);
      expect(playlist.next(), isNull);
    });

    test('顺序模式依次前进', () {
      final playlist = PlaylistService.instance;
      playlist.setList(['a', 'b', 'c']);
      playlist.mode = PlayMode.sequence;

      expect(playlist.next(), 'b');
      expect(playlist.next(), 'c');
    });

    test('列表循环回绕', () {
      final playlist = PlaylistService.instance;
      playlist.setList(['a', 'b']);
      playlist.mode = PlayMode.loopList;

      playlist.jumpTo(1);
      expect(playlist.next(), 'a');
    });

    test('上一曲回绕到末尾', () {
      final playlist = PlaylistService.instance;
      playlist.setList(['a', 'b', 'c']);
      playlist.mode = PlayMode.sequence;

      expect(playlist.previous(), 'c');
    });

    test('随机模式返回队列中的元素', () {
      final playlist = PlaylistService.instance;
      playlist.setList(['a', 'b', 'c', 'd']);
      playlist.mode = PlayMode.shuffle;

      final next = playlist.next();
      expect(['a', 'b', 'c', 'd'], contains(next));
    });

    test('单个文件时随机/上下曲返回自身', () {
      final playlist = PlaylistService.instance;
      playlist.setList(['only']);
      playlist.mode = PlayMode.shuffle;

      expect(playlist.next(), 'only');
      expect(playlist.previous(), 'only');
      expect(playlist.nextManual(), 'only');
    });

    test('jumpTo 定位当前项', () {
      final playlist = PlaylistService.instance;
      playlist.mode = PlayMode.sequence; // 显式声明，避免随机测试残留模式
      playlist.setList(['a', 'b', 'c'], startIndex: 2);
      expect(playlist.items[playlist.index], 'c');

      playlist.jumpTo(0);
      expect(playlist.next(), 'b');
    });

    test('setList 后 active 与展示位置正确', () {
      final playlist = PlaylistService.instance;
      expect(playlist.active, isFalse);

      playlist.setList(['a', 'b']);
      expect(playlist.active, isTrue);
      expect(playlist.displayPosition, 1);

      playlist.clear();
      expect(playlist.active, isFalse);
    });
  });
}
