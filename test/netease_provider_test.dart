import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lylyrics/core/models/track_info.dart';
import 'package:lylyrics/services/netease_provider.dart';

const _neteaseSearchBody = '''
{"result":{"songs":[
  {"id":1,"name":"Shape of You","artists":[{"name":"Ed Sheeran","id":10}],
   "album":{"name":"Divide"},"duration":254000},
  {"id":2,"name":"Shape of You (Cover)","artists":[{"name":"Otro","id":11}],
   "album":{"name":"Covers"},"duration":200000}
], "songCount":2}}
''';

const _neteaseSyncedLyricBody = '''
{"code":200,"lrc":{"version":1,"lyric":"[00:01.00]The club isn't the best place\\n[00:03.00]Second line"},
 "tlyric":{"version":1,"lyric":"[00:01.00]El club no es el mejor lugar"}}
''';

const _neteaseCreditsLyricBody = '''
{"code":200,"lrc":{"version":1,
 "lyric":"[00:00.000] 作曲 : Alguien\\n[00:02.000] 制作人 : Otro\\n[00:10.286] Ey\\n[00:11.000] Sí"}}
''';

const _neteasePureMusicBody = '''
{"code":200,"lrc":{"version":1,"lyric":"[00:05.000] 纯音乐，请欣赏"}}
''';

const _neteasePlainLyricBody = '''
{"code":200,"lrc":{"version":1,"lyric":"Sin timestamps, solo texto"}}
''';

const _neteaseNoLyricBody = '{"code":200,"nolyric":true}';

void main() {
  group('neteaseSongsFromSearchJson', () {
    test('recoge canciones y deduplica por id', () {
      const duplicated = '''
{"result":{"songs":[
  {"id":1,"name":"Shape of You","artists":[{"name":"Ed Sheeran","id":10}],
   "album":{"name":"Divide"},"duration":254000},
  {"id":1,"name":"Shape of You","artists":[{"name":"Ed Sheeran","id":10}],
   "album":{"name":"Divide"},"duration":254000}
]}}
''';
      final songs = neteaseSongsFromSearchJson(duplicated);
      expect(songs, hasLength(1));
      expect(songs.first.id, 1);
      expect(songs.first.name, 'Shape of You');
      expect(songs.first.artists, 'Ed Sheeran');
      expect(songs.first.durationMs, 254000);
    });

    test('los artistas anidados no van a canciones', () {
      final songs = neteaseSongsFromSearchJson(_neteaseSearchBody);
      expect(songs, hasLength(2));
      expect(songs.every((s) => s.durationMs != null), isTrue);
    });

    test('json roto devuelve vacío', () {
      expect(neteaseSongsFromSearchJson('no json'), isEmpty);
    });
  });

  group('neteaseLyricsFromJson', () {
    test('extrae lrc y nolyric', () {
      final raw = neteaseLyricsFromJson(_neteaseSyncedLyricBody)!;
      expect(raw.lyric, contains('[00:01.00]'));
      expect(raw.noLyric, isFalse);

      expect(neteaseLyricsFromJson(_neteaseNoLyricBody)!.noLyric, isTrue);
      expect(neteaseLyricsFromJson('no json'), isNull);
    });
  });

  group('lyricsFromRaw', () {
    test('lrc con timestamps produce letra sincronizada', () async {
      final provider = NeteaseProvider(
        client: MockClient((request) async {
          expect(request.url.host, 'music.163.com');
          expect(request.url.path, '/api/song/lyric');
          expect(request.headers['Referer'], contains('music.163.com'));
          return http.Response.bytes(utf8.encode(_neteaseSyncedLyricBody), 200);
        }),
      );
      final lyrics = await provider.lyricsFromSong(
        const NeteaseSong(id: 1, name: 'Shape of You', artists: 'Ed Sheeran'),
      );
      expect(lyrics, isNotNull);
      expect(lyrics!.isSynced, isTrue);
      expect(lyrics.lines.first.text, contains('club'));
      expect(lyrics.lines.first.time, const Duration(seconds: 1));
    });

    test('lrc sin timestamps cae a letra plana', () async {
      final provider = NeteaseProvider(
        client: MockClient((request) async {
          return http.Response.bytes(utf8.encode(_neteasePlainLyricBody), 200);
        }),
      );
      final lyrics = await provider.lyricsFromSong(
        const NeteaseSong(id: 1, name: 'x', artists: ''),
      );
      expect(lyrics!.isSynced, isFalse);
      expect(lyrics.plainText, contains('Sin timestamps'));
    });

    test('elimina las líneas de créditos del LRC', () async {
      final provider = NeteaseProvider(
        client: MockClient((request) async {
          return http.Response.bytes(utf8.encode(_neteaseCreditsLyricBody), 200);
        }),
      );
      final lyrics = await provider.lyricsFromSong(
        const NeteaseSong(id: 1, name: 'x', artists: ''),
      );
      expect(lyrics!.isSynced, isTrue);
      expect(lyrics.lines, hasLength(2));
      expect(lyrics.lines.first.text, 'Ey');
      expect(lyrics.plainText, isNot(contains('作曲')));
    });

    test('un LRC con solo «纯音乐» cuenta como instrumental', () async {
      final provider = NeteaseProvider(
        client: MockClient((request) async {
          return http.Response.bytes(utf8.encode(_neteasePureMusicBody), 200);
        }),
      );
      final lyrics = await provider.lyricsFromSong(
        const NeteaseSong(id: 1, name: 'x', artists: ''),
      );
      expect(lyrics!.instrumental, isTrue);
    });

    test('nolyric produce letra instrumental', () async {
      final provider = NeteaseProvider(
        client: MockClient((request) async {
          return http.Response.bytes(utf8.encode(_neteaseNoLyricBody), 200);
        }),
      );
      final lyrics = await provider.lyricsFromSong(
        const NeteaseSong(id: 1, name: 'x', artists: ''),
      );
      expect(lyrics!.instrumental, isTrue);
    });

    test('sin letra utilizable devuelve null', () async {
      final provider = NeteaseProvider(
        client: MockClient((request) async {
          return http.Response('{"code":200}', 200);
        }),
      );
      final lyrics = await provider.lyricsFromSong(
        const NeteaseSong(id: 1, name: 'x', artists: ''),
      );
      expect(lyrics, isNull);
    });
  });

  group('NeteaseProvider.search', () {
    test('consulta la búsqueda web con type=1', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/api/search/get');
        expect(request.url.queryParameters['type'], '1');
        expect(request.url.queryParameters['s'], 'Shape of You Ed Sheeran');
        return http.Response.bytes(utf8.encode(_neteaseSearchBody), 200);
      });
      final songs = await NeteaseProvider(client: client)
          .search('Shape of You', artist: 'Ed Sheeran');
      expect(songs, hasLength(2));
    });

    test('sin título ni artista no llama a la red', () async {
      var called = false;
      final client = MockClient((request) async {
        called = true;
        return http.Response('', 500);
      });
      final songs = await NeteaseProvider(client: client).search('  ');
      expect(songs, isEmpty);
      expect(called, isFalse);
    });

    test('un 5xx devuelve lista vacía sin lanzar', () async {
      final client = MockClient((request) async {
        return http.Response('', 500);
      });
      final songs = await NeteaseProvider(client: client).search('x');
      expect(songs, isEmpty);
    });
  });

  group('pickNeteaseSong', () {
    final songs = neteaseSongsFromSearchJson(_neteaseSearchBody);

    test('escoge la de más palabras de título y artista', () {
      final best = pickNeteaseSong(songs, 'Shape of You', 'Ed Sheeran');
      expect(best!.id, 1);
    });

    test('sin nada del título devuelve null', () {
      expect(pickNeteaseSong(songs, 'QWERTY', ''), isNull);
    });

    test('lista vacía devuelve null', () {
      expect(pickNeteaseSong(const [], 'Shape of You', ''), isNull);
    });
  });

  group('NeteaseProvider.fetch', () {
    test('resuelve búsqueda + letra de la mejor candidata', () async {
      final client = MockClient((request) async {
        if (request.url.path == '/api/search/get') {
          return http.Response.bytes(utf8.encode(_neteaseSearchBody), 200);
        }
        if (request.url.path == '/api/song/lyric') {
          expect(request.url.queryParameters['id'], '1');
          return http.Response.bytes(utf8.encode(_neteaseSyncedLyricBody), 200);
        }
        return http.Response('', 404);
      });
      final lyrics = await NeteaseProvider(client: client).fetch(
        const TrackInfo(
          title: 'Shape of You',
          artist: 'Ed Sheeran',
          duration: Duration(seconds: 254),
        ),
      );
      expect(lyrics, isNotNull);
      expect(lyrics!.isSynced, isTrue);
    });

    test('candidata sin palabras del título devuelve null', () async {
      final client = MockClient((request) async {
        return http.Response(
          '{"result":{"songs":[{"id":9,"name":"Sin nombre","duration":1000}]}}',
          200,
        );
      });
      final lyrics = await NeteaseProvider(client: client).fetch(
        const TrackInfo(title: 'Otra Canción', artist: 'X'),
      );
      expect(lyrics, isNull);
    });
  });
}
