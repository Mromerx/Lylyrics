import 'package:flutter_test/flutter_test.dart';
import 'package:lylyrics/services/genius_scraper.dart';

const _songPage = '''
<html><body>
<div data-lyrics-container="true">[Verse 1]<br>Hello &amp; goodbye<br><br>Second line</div>
<div data-lyrics-container="true">[Chorus]<br/>Sing it <i>loud</i><br>Yeah</div>
<div class="other">No tocar esto</div>
</body></html>
''';

const _searchJson = '''
{"response": {"sections": [{"type": "song", "hits": [
  {"result": {"url": "https://genius.com/The-weeknd-blinding-lights-lyrics", "title": "Blinding Lights"}},
  {"result": {"url": "https://genius.com/artists/The-weeknd", "title": "The Weeknd"}}
]}]}}
''';

void main() {
  group('extractGeniusLyrics', () {
    test('une contenedores, convierte br y desescapa entidades', () {
      expect(
        extractGeniusLyrics(_songPage),
        '[Verse 1]\nHello & goodbye\n\nSecond line\n[Chorus]\nSing it loud\nYeah',
      );
    });

    test('sin contenedores devuelve vacío', () {
      expect(extractGeniusLyrics('<html><body>nada</body></html>'), isEmpty);
    });
  });

  group('geniusUrlsFromSearchJson', () {
    test('solo recoge urls de temas', () {
      expect(
        geniusUrlsFromSearchJson(_searchJson),
        ['https://genius.com/The-weeknd-blinding-lights-lyrics'],
      );
    });

    test('json roto devuelve vacío', () {
      expect(geniusUrlsFromSearchJson('no json'), isEmpty);
    });
  });

  group('geniusUrlsFromHtml', () {
    test('extrae enlaces -lyrics sin duplicar', () {
      const html =
          '<a href="https://genius.com/Abc-def-lyrics">x</a>'
          '<a href="https://genius.com/Abc-def-lyrics">x</a>'
          '<a href="https://genius.com/artists/Abc">y</a>';
      expect(
        geniusUrlsFromHtml(html),
        ['https://genius.com/Abc-def-lyrics'],
      );
    });
  });

  group('pickGeniusUrl', () {
    const urls = [
      'https://genius.com/Queen-bohemian-rhapsody-lyrics',
      'https://genius.com/The-weeknd-blinding-lights-lyrics',
    ];

    test('elige por título y artista', () {
      expect(
        pickGeniusUrl(urls, 'Blinding Lights', 'The Weeknd'),
        urls[1],
      );
    });

    test('sin nada del título no se fía', () {
      expect(pickGeniusUrl(urls, 'Canción Inexistente Zzz', 'Nadie'), isNull);
      expect(pickGeniusUrl([], 'Hola', 'Adiós'), isNull);
    });
  });
}
