import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:lylyrics/services/lyrics_cache.dart';
import 'package:lylyrics/services/translation_service.dart';

SongTranslation _sample() => const SongTranslation(
      translations: {
        0: 'Hola mundo',
        1: 'Segunda línea',
        3: '',
      },
      segmentPairs: {
        0: [
          TextSegment(source: 'Hello', target: 'Hola'),
          TextSegment(source: 'world', target: 'mundo'),
        ],
        1: [
          TextSegment(source: 'Second', target: 'Segunda'),
          TextSegment(source: 'line', target: 'línea'),
        ],
      },
    );

void main() {
  sqfliteFfiInit();

  group('songTranslation serialization', () {
    test('roundtrip conserva traducciones y segmentos', () {
      final song = _sample();
      final json = songTranslationToJson(song);
      final restored = songTranslationFromJson(json);

      expect(restored.translations, song.translations);
      expect(restored.segmentPairs.keys.toSet(),
          song.segmentPairs.keys.toSet());
      for (final key in song.segmentPairs.keys) {
        final a = song.segmentPairs[key]!;
        final b = restored.segmentPairs[key]!;
        expect(b.length, a.length);
        for (var i = 0; i < a.length; i++) {
          expect(b[i].source, a[i].source);
          expect(b[i].target, a[i].target);
        }
      }
    });

    test('claves int se serializan como strings', () {
      final json = songTranslationToJson(_sample());
      expect(json['translations'], isA<Map>());
      expect((json['translations'] as Map).keys.every((k) => k is String),
          isTrue);
      expect((json['segments'] as Map).keys.every((k) => k is String), isTrue);
    });

    test('payload con forma incorrecta lanza FormatException', () {
      expect(() => songTranslationFromJson({'translations': 'x'}),
          throwsFormatException);
      expect(() => songTranslationFromJson({'translations': {}}),
          throwsFormatException);
      expect(
        () => songTranslationFromJson({
          'translations': {'0': 'ok'},
          'segments': {
            '0': [
              {'s': 'a'}
            ],
          },
        }),
        throwsFormatException,
      );
    });
  });

  group('LyricsCache translations', () {
    test('putTranslation + getTranslation devuelve lo mismo', () async {
      final cache = LyricsCache();
      await cache.init();
      await cache.putTranslation('k', _sample());

      final res = await cache.getTranslation('k');
      expect(res, isNotNull);
      expect(res!.translations, _sample().translations);
      expect(res.segmentPairs.length, _sample().segmentPairs.length);
      expect(res.segmentPairs[0]!.length, 2);
      expect(res.segmentPairs[0]![1].source, 'world');
      expect(res.segmentPairs[0]![1].target, 'mundo');
      await cache.close();
    });

    test('getTranslation de clave inexistente -> null', () async {
      final cache = LyricsCache();
      await cache.init();
      expect(await cache.getTranslation('no-existe'), isNull);
      await cache.close();
    });

    test('persistencia entre sesiones (mismo fichero)', () async {
      final dir = await Directory.systemTemp.createTemp('trans_cache_test_');
      final path = '${dir.path}/cache.db';
      try {
        var cache = LyricsCache(path: path);
        await cache.init();
        await cache.putTranslation('persist', _sample());
        await cache.close();

        cache = LyricsCache(path: path);
        await cache.init();
        final res = await cache.getTranslation('persist');
        expect(res, isNotNull);
        expect(res!.translations[0], 'Hola mundo');
        expect(res.segmentPairs[1]!.length, 2);
        await cache.close();
      } finally {
        try {
          await Directory(dir.path).delete(recursive: true);
        } catch (_) {}
      }
    });

    test('caduca pasadas 24h y se elimina', () async {
      DateTime now = DateTime(2026, 1, 1, 0, 0, 0);
      final cache = LyricsCache(clock: () => now);
      await cache.init();
      await cache.putTranslation('exp', _sample());
      expect(await cache.getTranslation('exp'), isNotNull);

      now = now.add(const Duration(hours: 24));
      expect(await cache.getTranslation('exp'), isNull);
      // La fila se borró: sigue devolviendo null.
      expect(await cache.getTranslation('exp'), isNull);
      await cache.close();
    });

    test('payload corrupto se descarta y devuelve null', () async {
      final dir = await Directory.systemTemp.createTemp('trans_corrupt_test_');
      final path = '${dir.path}/cache.db';
      try {
        final cache = LyricsCache(path: path);
        await cache.init();
        await cache.putTranslation('corrupt', _sample());
        await cache.close();

        // Corrompemos el payload directamente.
        final db = await databaseFactoryFfi.openDatabase(path);
        await db.update(
          'translations',
          {
            'payload': '{no es json',
            'created_at': DateTime.now().millisecondsSinceEpoch,
          },
          where: 'cache_key = ?',
          whereArgs: ['corrupt'],
        );
        await db.close();

        final reopened = LyricsCache(path: path);
        await reopened.init();
        expect(await reopened.getTranslation('corrupt'), isNull);
        await reopened.close();
      } finally {
        try {
          await Directory(dir.path).delete(recursive: true);
        } catch (_) {}
      }
    });
  });
}
