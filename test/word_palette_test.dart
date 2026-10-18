import 'package:flutter_test/flutter_test.dart';
import 'package:lylyrics/ui/widgets/lyric_line_tile.dart';

void main() {
  group('wordPalette', () {
    test('vacía o cero no revienta', () {
      expect(wordPalette(0), isEmpty);
      expect(wordPalette(-3), isEmpty);
    });

    test('ningún tono se repite en la misma línea (1-20 palabras)', () {
      for (var n = 1; n <= 20; n++) {
        final palette = wordPalette(n);
        expect(palette, hasLength(n));
        expect(palette.toSet(), hasLength(n),
            reason: 'se repite un tono con n=$n');
      }
    });

    test('tonos vecinos bien distintos (ángulo dorado)', () {
      final palette = wordPalette(8);
      for (var i = 0; i + 1 < palette.length; i++) {
        expect(palette[i], isNot(palette[i + 1]));
      }
    });
  });
}
