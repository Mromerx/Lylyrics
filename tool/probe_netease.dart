// Sonda REAL contra NetEase Cloud Music: sin mocks y sin UI.
//
// Útil para depurar la búsqueda y la letra de music.163.com sin depender del
// reproductor. Igual que probe_lrclib, usa títulos sucios tal como llegan
// del reproductor:
//   dart run tool/probe_netease.dart
import 'dart:io';

import 'package:lylyrics/core/models/track_info.dart';
import 'package:lylyrics/services/netease_provider.dart';

Future<void> main() async {
  final casos = <String, TrackInfo>{
    'Título limpio': TrackInfo(
      title: 'Shape of You',
      artist: 'Ed Sheeran',
      duration: const Duration(minutes: 3, seconds: 53),
    ),
    'Artista - Canción': TrackInfo(
      title: 'Ed Sheeran - Shape of You [Official Video]',
      artist: 'Ed Sheeran',
      duration: const Duration(minutes: 4, seconds: 3),
    ),
    'Artista = canal': TrackInfo(
      title: 'Tití Me Preguntó',
      artist: 'Bad Bunny - Topic',
      duration: const Duration(minutes: 4, seconds: 1),
    ),
    'Sin artista': TrackInfo(
      title: 'Tití Me Preguntó',
      artist: '',
      duration: const Duration(minutes: 4, seconds: 1),
    ),
    'En vivo': TrackInfo(
      title: '2hollis - flash (official video)',
      artist: '2HOLLISVEVO',
      duration: const Duration(milliseconds: 193101),
    ),
  };

  final provider = NeteaseProvider();
  for (final entry in casos.entries) {
    final track = entry.value;
    stdout.writeln('=== ${entry.key}');
    stdout.writeln('    título="${track.title}"  artista="${track.artist}"');

    final lyrics = await provider.fetch(track);
    if (lyrics == null) {
      stdout.writeln('    → no encontrada (NetEase no la tiene)');
    } else if (lyrics.instrumental) {
      stdout.writeln('    → instrumental');
    } else {
      stdout.writeln('    → sincronizada=${lyrics.isSynced} '
          'líneas=${lyrics.lines.length}');
      for (final line in lyrics.lines.take(3)) {
        final ms = line.time.inMilliseconds;
        final stamp = lyrics.isSynced
            ? '[${(ms ~/ 60000).toString().padLeft(2, '0')}:'
                '${((ms % 60000) ~/ 1000).toString().padLeft(2, '0')}.'
                '${(ms % 1000).toString().padLeft(3, '0')}]'
            : '[sin tiempo]';
        stdout.writeln('      $stamp ${line.text}');
      }
    }
  }

  stdout.writeln('\n(Fin. "no encontrada" es una respuesta válida: no todas '
      'las canciones están en NetEase.)');
  exit(0);
}
