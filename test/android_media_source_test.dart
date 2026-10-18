import 'package:flutter_test/flutter_test.dart';
import 'package:lylyrics/core/models/playback_state.dart';
import 'package:lylyrics/platform/android/android_media_source.dart';

void main() {
  group('androidNormalizeTitle', () {
    test('colapsa espacios y minúsculas, null si vacío', () {
      expect(androidNormalizeTitle('  Blinding   Lights '), 'blinding lights');
      expect(androidNormalizeTitle('   '), isNull);
      expect(androidNormalizeTitle(null), isNull);
    });
  });

  group('androidTrackKey', () {
    test('paquete + título, null sin título', () {
      expect(
        androidTrackKey(package: 'com.spotify.music', title: 'Luz'),
        'com.spotify.music|luz',
      );
      expect(androidTrackKey(package: 'x', title: '  '), isNull);
    });

    test('cambios de clave', () {
      expect(androidTrackKeyChanged(previous: null, next: null), isFalse);
      expect(androidTrackKeyChanged(previous: 'a', next: 'a'), isFalse);
      expect(androidTrackKeyChanged(previous: 'a', next: 'b'), isTrue);
    });
  });

  group('androidStatusFromRaw', () {
    test('mapea estados del servicio', () {
      expect(androidStatusFromRaw('playing'), PlaybackStatus.playing);
      expect(androidStatusFromRaw('paused'), PlaybackStatus.paused);
      expect(androidStatusFromRaw('stopped'), PlaybackStatus.stopped);
      expect(androidStatusFromRaw('raro'), PlaybackStatus.stopped);
      expect(androidStatusFromRaw(null), PlaybackStatus.stopped);
    });
  });

  group('androidPlayerScore', () {
    test('música conocida puntúa por encima de YouTube genérico', () {
      expect(androidPlayerScore('com.spotify.music'), 400);
      expect(
        androidPlayerScore('com.spotify.music') >
            androidPlayerScore('com.google.android.youtube'),
        isTrue,
      );
      expect(androidPlayerScore('com.example.vlc') > 0, isTrue);
    });
  });

  group('selectBestAndroidPlayer', () {
    AndroidPlayerInfo info(String pkg, PlaybackStatus s) =>
        AndroidPlayerInfo(
          packageName: pkg,
          status: s,
          score: androidPlayerScore(pkg),
        );

    test('vacío -> null, forzado gana si existe', () {
      expect(
          selectBestAndroidPlayer(players: {}, forced: null), isNull);
      final players = {
        'a.x': info('a.x', PlaybackStatus.playing),
        'b.y': info('b.y', PlaybackStatus.paused),
      };
      expect(selectBestAndroidPlayer(players: players, forced: 'b.y'), 'b.y');
    });

    test('reproduciendo primero, luego puntuación', () {
      final players = {
        'com.spotify.music': info('com.spotify.music', PlaybackStatus.paused),
        'com.google.android.youtube':
            info('com.google.android.youtube', PlaybackStatus.paused),
        'com.example.player': info('com.example.player', PlaybackStatus.playing),
      };
      // Sonando gana aunque otro puntúe más en pausa.
      expect(selectBestAndroidPlayer(players: players, forced: null),
          'com.example.player');
      final paused = {
        'com.spotify.music': info('com.spotify.music', PlaybackStatus.paused),
        'com.google.android.youtube':
            info('com.google.android.youtube', PlaybackStatus.paused),
      };
      // En pausa gana el de mayor puntuación (Spotify).
      expect(selectBestAndroidPlayer(players: paused, forced: null),
          'com.spotify.music');
    });
  });

  group('androidTrackInfoFromSession', () {
    test('construye pista y null sin nada mostrable', () {
      final track = androidTrackInfoFromSession({
        'package': 'com.spotify.music',
        'title': 'Blinding Lights',
        'artist': 'The Weeknd',
        'album': 'After Hours',
        'durationMs': 200000,
      });
      expect(track?.title, 'Blinding Lights');
      expect(track?.artist, 'The Weeknd');
      expect(track?.duration, const Duration(milliseconds: 200000));
      expect(track?.sourceApp, 'com.spotify.music');

      expect(
          androidTrackInfoFromSession({'package': 'x'}), isNull);
    });

    test('sin título usa el artista', () {
      final track = androidTrackInfoFromSession(
          {'artist': 'Daft Punk', 'package': 'x'});
      expect(track?.title, 'Daft Punk');
    });
  });

  group('androidClampPosition', () {
    test('acota a [0, duración]', () {
      expect(
        androidClampPosition(
            const Duration(seconds: 99), const Duration(seconds: 60)),
        const Duration(seconds: 60),
      );
      expect(
        androidClampPosition(
            const Duration(seconds: -5), const Duration(seconds: 60)),
        Duration.zero,
      );
    });
  });
}
