import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:lylyrics/core/models/lyrics.dart';
import 'package:lylyrics/services/lyrics_cache.dart';

void main() {
  // Necesario para sqflite_common_ffi en tests.
  sqfliteFfiInit();

  group('LyricsCache serialization', () {
    test('roundtrip Lyrics SINCRONIZADA (varias líneas + línea vacía intercalada)', () {
      final lyrics = Lyrics(
        lines: [
          LyricLine(time: const Duration(milliseconds: 0), text: 'Intro'),
          LyricLine(time: const Duration(milliseconds: 1200), text: ''),
          LyricLine(time: const Duration(milliseconds: 2450), text: 'Verso 1'),
          LyricLine(time: const Duration(milliseconds: 5000), text: 'Coro'),
        ],
        isSynced: true,
        plainText: null,
        instrumental: false,
      );

      final json = lyricsToJson(lyrics);
      final restored = lyricsFromJson(json);

      expect(restored.lines.length, lyrics.lines.length);
      for (var i = 0; i < lyrics.lines.length; i++) {
        expect(restored.lines[i].time, lyrics.lines[i].time);
        expect(restored.lines[i].text, lyrics.lines[i].text);
      }
      expect(restored.isSynced, lyrics.isSynced);
      expect(restored.plainText, lyrics.plainText);
      expect(restored.instrumental, lyrics.instrumental);
    });

    test('roundtrip Lyrics PLANA (isSynced false, acentos y saltos)', () {
      final lyrics = Lyrics(
        lines: const [],
        isSynced: false,
        plainText: 'Hola mundo\nCon acentos: áéíóú ñ\nLínea vacía:\n\nFin',
        instrumental: false,
      );

      final json = lyricsToJson(lyrics);
      final restored = lyricsFromJson(json);

      expect(restored.lines.length, 0);
      expect(restored.isSynced, false);
      expect(restored.plainText, lyrics.plainText);
      expect(restored.instrumental, false);
    });

    test('roundtrip instrumental', () {
      final lyrics = Lyrics(
        lines: const [],
        isSynced: false,
        plainText: null,
        instrumental: true,
      );

      final json = lyricsToJson(lyrics);
      final restored = lyricsFromJson(json);

      expect(restored.instrumental, true);
      expect(restored.isSynced, false);
      expect(restored.plainText, null);
      expect(restored.lines.isEmpty, true);
    });

    test('líneas vacías (isBlank) y Durations cero se conservan', () {
      final lyrics = Lyrics(
        lines: [
          LyricLine(time: Duration.zero, text: ''),
          LyricLine(time: const Duration(milliseconds: 500), text: ' '),
          LyricLine(time: const Duration(seconds: 1), text: ''),
        ],
        isSynced: true,
        plainText: null,
        instrumental: false,
      );

      final json = lyricsToJson(lyrics);
      final restored = lyricsFromJson(json);

      expect(restored.lines.length, 3);
      expect(restored.lines[0].time, Duration.zero);
      expect(restored.lines[0].text, '');
      expect(restored.lines[1].time, const Duration(milliseconds: 500));
      expect(restored.lines[1].text, ' ');
      expect(restored.lines[2].time, const Duration(seconds: 1));
      expect(restored.lines[2].text, '');
    });
  });

  group('LyricsCache operaciones', () {
    test('get de clave inexistente -> null', () async {
      final cache = LyricsCache();
      await cache.init();
      final res = await cache.get('no-existe');
      expect(res, isNull);
      await cache.close();
    });

    test('putNegative + get -> isNegative true, lyrics null', () async {
      final cache = LyricsCache();
      await cache.init();
      await cache.putNegative('key-neg');
      final res = await cache.get('key-neg');
      expect(res, isNotNull);
      expect(res!.isNegative, true);
      expect(res.lyrics, isNull);
      expect(res.expiresAt, isNotNull);
      await cache.close();
    });

    test('TTL: negativo todavía vigente antes de 24h', () async {
      DateTime now = DateTime(2026, 1, 1, 0, 0, 0);
      final cache = LyricsCache(clock: () => now);
      await cache.init();
      await cache.putNegative('ttl-ok', ttl: const Duration(hours: 24));
      // Avanzamos 23h59m
      now = now.add(const Duration(hours: 23, minutes: 59));
      final res = await cache.get('ttl-ok');
      expect(res, isNotNull);
      expect(res!.isNegative, true);
      await cache.close();
    });

    test('TTL: pasados 24h get devuelve null', () async {
      DateTime now = DateTime(2026, 1, 1, 0, 0, 0);
      final cache = LyricsCache(clock: () => now);
      await cache.init();
      await cache.putNegative('ttl-exp', ttl: const Duration(hours: 24));
      // Exactamente 24h después debería expirar (expires_at > now ?)
      // expires_at = now + 24h; get con now+24h: expires_at > nowMs es false.
      now = now.add(const Duration(hours: 24));
      final res = await cache.get('ttl-exp');
      expect(res, isNull);
      await cache.close();
    });

    test('put sobre clave existente sobrescribe (no duplica)', () async {
      final cache = LyricsCache();
      await cache.init();
      final l1 = Lyrics(
        lines: [LyricLine(time: Duration.zero, text: 'A')],
        isSynced: true,
        plainText: null,
        instrumental: false,
      );
      final l2 = Lyrics(
        lines: [
          LyricLine(time: Duration.zero, text: 'B'),
          LyricLine(time: const Duration(seconds: 1), text: 'C'),
        ],
        isSynced: true,
        plainText: null,
        instrumental: false,
      );
      await cache.put('k', l1, id: 1);
      await cache.put('k', l2, id: 2, trackName: 'T', artistName: 'A');
      final res = await cache.get('k');
      expect(res, isNotNull);
      expect(res!.isNegative, false);
      expect(res.lyrics!.lines.length, 2);
      expect(res.lyrics!.lines[0].text, 'B');
      await cache.close();
    });

    test('claves distintas no chocan', () async {
      final cache = LyricsCache();
      await cache.init();
      final l = Lyrics(
        lines: [LyricLine(time: Duration.zero, text: 'X')],
        isSynced: true,
        plainText: null,
        instrumental: false,
      );
      await cache.put('k1', l, id: 1);
      await cache.put('k2', l, id: 2);
      final r1 = await cache.get('k1');
      final r2 = await cache.get('k2');
      expect(r1, isNotNull);
      expect(r2, isNotNull);
      await cache.close();
    });

    test('close() y re-init() sobre path temporal -> persisten datos', () async {
      final dir = await Directory.systemTemp.createTemp('lyrics_cache_test_');
      final path = '${dir.path}/cache.db';
      try {
        // Primera sesión
        var cache = LyricsCache(path: path);
        await cache.init();
        final l = Lyrics(
          lines: [
            LyricLine(time: const Duration(milliseconds: 100), text: 'Hola'),
            LyricLine(time: const Duration(milliseconds: 200), text: ''),
          ],
          isSynced: true,
          plainText: null,
          instrumental: false,
        );
        await cache.put('persist', l, id: 10, trackName: 'Song', artistName: 'Artist');
        await cache.putNegative('persist-neg', ttl: const Duration(hours: 2));
        await cache.close();

        // Segunda sesión
        cache = LyricsCache(path: path);
        await cache.init();
        final rPos = await cache.get('persist');
        final rNeg = await cache.get('persist-neg');
        expect(rPos, isNotNull);
        expect(rPos!.isNegative, false);
        expect(rPos.lyrics!.lines.length, 2);
        expect(rPos.lyrics!.lines[0].text, 'Hola');
        expect(rNeg, isNotNull);
        expect(rNeg!.isNegative, true);
        await cache.close();
      } finally {
        // Limpieza
        try {
          await Directory(dir.path).delete(recursive: true);
        } catch (_) {}
      }
    });

    test('init() llamado dos veces -> ok', () async {
      final cache = LyricsCache();
      await cache.init();
      await cache.init();
      await cache.close();
    });

    test('close() dos veces -> ok', () async {
      final cache = LyricsCache();
      await cache.init();
      await cache.close();
      await cache.close();
    });
  });
}