import 'package:flutter_test/flutter_test.dart';
import 'package:media_player/utils/natural_sort.dart';

void main() {
  group('naturalCompare', () {
    test('数字段按数值比较（EP2 < EP10）', () {
      final list = [
        '/tv/EP10.mkv',
        '/tv/EP2.mkv',
        '/tv/EP1.mkv',
      ]..sort(naturalCompare);
      expect(list, ['/tv/EP1.mkv', '/tv/EP2.mkv', '/tv/EP10.mkv']);
    });

    test('多位数字也按数值比较', () {
      expect(naturalCompare('第100集.mp4', '第99集.mp4'), greaterThan(0));
    });

    test('前缀相同短的在前', () {
      expect(naturalCompare('a.mp4', 'ab.mp4'), lessThan(0));
    });

    test('混合数字与文本', () {
      final list = [
        'show S02E12.mp4',
        'show S02E3.mp4',
        'show S01E10.mp4',
        'show S01E2.mp4',
      ]..sort(naturalCompare);
      expect(list, [
        'show S01E2.mp4',
        'show S01E10.mp4',
        'show S02E3.mp4',
        'show S02E12.mp4',
      ]);
    });
  });
}
