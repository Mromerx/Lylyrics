import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lylyrics/core/models/lyrics.dart';
import 'package:lylyrics/ui/widgets/lyric_line_tile.dart';
import 'package:lylyrics/ui/widgets/plain_lyrics_view.dart';

void main() {
  testWidgets('PlainLyricsView indexa traducciones por el índice real de la línea',
      (tester) async {
    const lyrics = Lyrics(
      lines: [
        LyricLine(time: Duration.zero, text: 'Ja'),
        LyricLine(time: Duration.zero, text: 'Mucho viaje, mucho show'),
        LyricLine(time: Duration.zero, text: ''),
        LyricLine(time: Duration.zero, text: 'Ah, no sé si seguimo'),
        LyricLine(time: Duration.zero, text: 'Fuck, fuck, fuck'),
      ],
      isSynced: false,
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PlainLyricsView(
            lyrics: lyrics,
            fontSize: 16,
            translations: {
              0: 'Ha',
              1: 'Lots of travel',
              3: "Ah, I don't know",
            },
            wordLinks: {},
          ),
        ),
      ),
    );

    final tiles = tester.widgetList<LyricLineTile>(find.byType(LyricLineTile));
    final byText = {for (final tile in tiles) tile.text: tile.translation};

    expect(byText['Mucho viaje, mucho show'], 'Lots of travel');
    expect(byText['Ah, no sé si seguimo'], "Ah, I don't know");
    expect(byText['Fuck, fuck, fuck'], isNull);
    expect(tiles, hasLength(4), reason: 'la línea vacía no produce tile');
  });
}
