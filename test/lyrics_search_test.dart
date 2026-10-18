import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lylyrics/services/genius_scraper.dart';
import 'package:lylyrics/services/lrclib_provider.dart';
import 'package:lylyrics/services/lyrics_search.dart';
import 'package:lylyrics/services/netease_provider.dart';

const _neteaseSearchBody = '''
{"result":{"songs":[
  {"id":1,"name":"Shape of You","artists":[{"name":"Ed Sheeran"}],
   "album":{"name":"Divide"},"duration":254000}
]}}
''';

const _neteaseLyricBody = '''
{"code":200,"lrc":{"version":1,"lyric":"[00:01.00]Shape of my heart"}}
''';

const _lrclibSearchBody = '''
[
  {
    "id": 1,
    "trackName": "Shape of You",
    "artistName": "Ed Sheeran",
    "albumName": "Divide",
    "duration": 234.0,
    "instrumental": false,
    "plainLyrics": "The club isn't the best place",
    "syncedLyrics": "[00:01.00]The club isn't the best place"
  },
  {
    "id": 2,
    "trackName": "Shape of You (Cover)",
    "artistName": "Someone",
    "duration": 200.0,
    "instrumental": false,
    "plainLyrics": null,
    "syncedLyrics": null
  }
]
''';

const _geniusSearchBody = '''
{"meta":{"status":200},"response":{"sections":[
  {"type":"top_hit","hits":[{"result":{
     "_type":"song","title":"Shape of You","artist_names":"Ed Sheeran",
     "url":"https://genius.com/Ed-sheeran-shape-of-you-lyrics"}}]},
  {"type":"song","hits":[
    {"result":{"_type":"song","title":"Shape of You (Stormzy Remix)",
       "artist_names":"Ed Sheeran (Ft. Stormzy)",
       "url":"https://genius.com/Ed-sheeran-shape-of-you-stormzy-remix-lyrics"}},
    {"result":{"_type":"song","title":"Shape of You (Remix)",
       "artist_names":"Yxng Bane",
       "url":"https://genius.com/Yxng-bane-shape-of-you-remix-lyrics"}}
  ]},
  {"type":"artist","hits":[{"result":{"_type":"artist","url":"https://genius.com/artists/Shape-of-you"}}]}
]}}
''';

const _geniusSongPage = '''
<html><body>
<div data-lyrics-container="true">[Verse 1]<br>Hello &amp; goodbye<br>Second line</div>
</body></html>
''';

void main() {
  group('geniusMatchesFromSearchJson', () {
    test('recoge título, artista y url de temas, y deduplica', () {
      final matches = geniusMatchesFromSearchJson(_geniusSearchBody);
      expect(matches, hasLength(3));
      expect(matches.first.title, 'Shape of You');
      expect(matches.first.artist, 'Ed Sheeran');
      expect(matches.first.url,
          'https://genius.com/Ed-sheeran-shape-of-you-lyrics');
      // El top_hit repetido no vuelve a aparecer.
      expect(
        matches.where((m) => m.url.endsWith('shape-of-you-lyrics')),
        hasLength(1),
      );
    });

    test('json roto devuelve vacío', () {
      expect(geniusMatchesFromSearchJson('no json'), isEmpty);
    });
  });

  group('extractGeniusLyrics', () {
    test('descarta el bloque de cabecera data-exclude-from-selection', () {
      const page = '<div data-lyrics-container="true">'
          '<div data-exclude-from-selection="true">'
          'ContributorsTranslationsEspañol</div>'
          '[Verse 1]<br>Hello<br>World</div>';
      final text = extractGeniusLyrics(page);
      expect(text, '[Verse 1]\nHello\nWorld');
      expect(text, isNot(contains('Contributors')));
    });
  });

  group('GeniusScraper.search', () {
    test('consulta la API con per_page permitido (<= 5)', () async {
      final client = MockClient((request) async {
        if (request.url.path == '/api/search/multi') {
          // Genius responde 422 si per_page > 5, así que debe ir acotado.
          expect(
            int.parse(request.url.queryParameters['per_page']!),
            inInclusiveRange(1, 5),
          );
          return http.Response(_geniusSearchBody, 200);
        }
        return http.Response('', 404);
      });
      final scraper = GeniusScraper(client: client);

      final matches = await scraper.search('Shape of You', artist: 'Ed Sheeran');
      expect(matches.map((m) => m.title), contains('Shape of You'));
      expect(matches, hasLength(3));
    });

    test('sin título ni artista no llama a la red', () async {
      var called = false;
      final client = MockClient((request) async {
        called = true;
        return http.Response('', 500);
      });
      final matches = await GeniusScraper(client: client).search('  ', artist: ' ');
      expect(matches, isEmpty);
      expect(called, isFalse);
    });
  });

  group('GeniusScraper.fetchFromUrl', () {
    test('extrae la letra plana de la página', () async {
      final client = MockClient((request) async {
        return http.Response(_geniusSongPage, 200);
      });
      final lyrics = await GeniusScraper(client: client)
          .fetchFromUrl('https://genius.com/Ed-sheeran-shape-of-you-lyrics');
      expect(lyrics, isNotNull);
      expect(lyrics!.isSynced, isFalse);
      expect(lyrics.plainText, contains('Hello & goodbye'));
    });

    test('página sin contenedores devuelve null', () async {
      final client = MockClient((request) async {
        return http.Response('<html><body>nada</body></html>', 200);
      });
      final lyrics = await GeniusScraper(client: client)
          .fetchFromUrl('https://genius.com/x-lyrics');
      expect(lyrics, isNull);
    });
  });

  group('LrclibProvider.searchTracks', () {
    test('devuelve solo resultados con letra', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/api/search');
        expect(request.url.queryParameters['track_name'], 'Shape of You');
        expect(request.url.queryParameters['artist_name'], 'Ed Sheeran');
        return http.Response(_lrclibSearchBody, 200);
      });
      final provider = LrclibProvider(httpClient: client);

      final tracks = await provider.searchTracks(
        'Shape of You',
        artist: 'Ed Sheeran',
      );
      expect(tracks, hasLength(1));
      expect(tracks.first.trackName, 'Shape of You');
      await provider.dispose();
    });

    test('sin artista consulta por texto libre (q)', () async {
      final client = MockClient((request) async {
        expect(request.url.queryParameters['q'], 'shape of you');
        expect(request.url.queryParameters.containsKey('track_name'), isFalse);
        return http.Response(_lrclibSearchBody, 200);
      });
      final provider = LrclibProvider(httpClient: client);

      final tracks = await provider.searchTracks('shape of you');
      expect(tracks, isNotEmpty);
      await provider.dispose();
    });
  });

  group('LyricsSearchService', () {
    LyricsSearchService buildService() {
    final lrclibClient = MockClient((request) async {
      if (request.url.host == 'lrclib.net') {
        return http.Response(_lrclibSearchBody, 200);
      }
      return http.Response('', 404);
    });
    final neteaseClient = MockClient((request) async {
      if (request.url.host == 'music.163.com') {
        if (request.url.path == '/api/search/get') {
          return http.Response(_neteaseSearchBody, 200);
        }
        if (request.url.path == '/api/song/lyric') {
          return http.Response(_neteaseLyricBody, 200);
        }
      }
      return http.Response('', 404);
    });
    final geniusClient = MockClient((request) async {
      if (request.url.path == '/api/search/multi') {
        return http.Response(_geniusSearchBody, 200);
      }
      if (request.url.path.endsWith('-lyrics')) {
        return http.Response(_geniusSongPage, 200);
      }
      return http.Response('', 404);
    });
    return LyricsSearchService(
      lrclib: LrclibProvider(httpClient: lrclibClient),
      netease: NeteaseProvider(client: neteaseClient),
      genius: GeniusScraper(client: geniusClient),
    );
  }

  test('mezcla LRCLIB, NetEase y Genius, sincronizadas primero', () async {
    final results =
        await buildService().search('Shape of You', artist: 'Ed Sheeran');
    expect(results.whereType<LrclibSearchResult>(), hasLength(1));
    expect(results.whereType<NeteaseSearchResult>(), hasLength(1));
    expect(results.whereType<GeniusSearchResult>(), hasLength(3));
    // La única sincronizada (LRCLIB) va primero.
    expect(results.first, isA<LrclibSearchResult>());
    expect(results.first.synced, isTrue);
    expect(
      results.whereType<NeteaseSearchResult>().first.sourceLabel,
      'NetEase',
    );
  });

  test('sin consulta no busca nada', () async {
    final results = await buildService().search('   ', artist: ' ');
    expect(results, isEmpty);
  });

  test('load materializa cada fuente', () async {
    final service = buildService();
    final results = await service.search('Shape of You', artist: 'Ed Sheeran');

    final fromLrclib =
        await service.load(results.whereType<LrclibSearchResult>().first);
    expect(fromLrclib, isNotNull);
    expect(fromLrclib!.isSynced, isTrue);

    final fromNetease =
        await service.load(results.whereType<NeteaseSearchResult>().first);
    expect(fromNetease, isNotNull);
    expect(fromNetease!.isSynced, isTrue);

    final fromGenius =
        await service.load(results.whereType<GeniusSearchResult>().first);
    expect(fromGenius, isNotNull);
    expect(fromGenius!.isSynced, isFalse);
  });

  test('una fuente caída no tumba a la otra', () async {
    final lrclibClient = MockClient((request) async {
      throw http.ClientException('sin red');
    });
    final geniusClient = MockClient((request) async {
      if (request.url.path == '/api/search/multi') {
        return http.Response(_geniusSearchBody, 200);
      }
      return http.Response('', 404);
    });
    final service = LyricsSearchService(
      lrclib: LrclibProvider(httpClient: lrclibClient),
      genius: GeniusScraper(client: geniusClient),
    );

    final results = await service.search('Shape of You', artist: 'Ed Sheeran');
    expect(results.whereType<LrclibSearchResult>(), isEmpty);
    expect(results.whereType<GeniusSearchResult>(), isNotEmpty);
    });
  });
}
