// Sonda REAL contra lrclib.net: sin mocks y sin UI.
//
// Útil para depurar la parte de búsqueda sin depender del reproductor.
//   dart run tool/probe_lrclib.dart
import 'dart:io';

import 'package:lylyrics/core/models/track_info.dart';
import 'package:lylyrics/services/lrclib_provider.dart';

Future<void> main() async {
  // Metadatos tal cual los entrega FreeTube por MPRIS: títulos sucios con
  // "(official video)", artista que a veces es el canal, duraciones reales.
  final casos = <String, TrackInfo>{
    // El primero estaba sonando en el bus durante el desarrollo.
    'FreeTube en vivo': TrackInfo(
      title: '2hollis - flash (official video)',
      artist: '2HOLLISVEVO',
      duration: const Duration(milliseconds: 193101),
    ),
    'Artista = canal': TrackInfo(
      title: 'Tití Me Preguntó',
      artist: 'Bad Bunny - Topic',
      duration: const Duration(minutes: 4, seconds: 1),
    ),
    'Artista - Canción': TrackInfo(
      title: 'Ed Sheeran - Shape of You [Official Video]',
      artist: 'Ed Sheeran',
      duration: const Duration(minutes: 4, seconds: 3),
    ),
    'Título limpio': TrackInfo(
      title: 'Resaca',
      artist: 'Quevedo',
      duration: const Duration(minutes: 2, seconds: 55),
    ),
    'Video oficial': TrackInfo(
      title: 'KAROL G - PROVENZA (Official Video)',
      artist: 'KAROL G',
      duration: const Duration(minutes: 2, seconds: 58),
    ),
    'Guion en el nombre': TrackInfo(
      title: 'a-ha - Take On Me (Official Music Video)',
      artist: 'a-ha',
      duration: const Duration(minutes: 3, seconds: 49),
    ),
    'Sin artista': TrackInfo(
      title: 'Tití Me Preguntó',
      artist: '',
      duration: const Duration(minutes: 4, seconds: 1),
    ),
    'Duración incorrecta': TrackInfo(
      title: 'Tití Me Preguntó',
      artist: 'Bad Bunny',
      duration: const Duration(minutes: 9, seconds: 99),
    ),
  };

  for (final entry in casos.entries) {
    final provider = LrclibProvider(
      userAgent: 'Lylyrics/0.1.0 (+https://github.com/maxi/lylyrics; Linux MPRIS)',
      timeout: const Duration(seconds: 8),
    );
    final track = entry.value;

    stdout.writeln('=== ${entry.key}');
    stdout.writeln('    título="${track.title}"  artista="${track.artist}"');

    try {
      final lyrics = await provider.fetch(track);
      if (lyrics == null) {
        stdout.writeln('    → no encontrada (LRCLIB no la tiene)');
      } else if (lyrics.instrumental) {
        stdout.writeln('    → instrumental');
      } else {
        stdout.writeln('    → sincronizada=${lyrics.isSynced} '
            'líneas=${lyrics.lines.length}');
        for (final line in lyrics.lines.take(3)) {
          final ms = line.time.inMilliseconds;
          final stamp = '${(ms ~/ 60000).toString().padLeft(2, '0')}:'
              '${((ms % 60000) ~/ 1000).toString().padLeft(2, '0')}.'
              '${(ms % 1000).toString().padLeft(3, '0')}';
          stdout.writeln('      [$stamp] ${line.text}');
        }
      }
    } on LrclibException catch (e) {
      stdout.writeln('    → ERROR ${e.kind.name}: ${e.message}');
    }
    await provider.dispose();
  }

  stdout.writeln('\n(Fin. "no encontrada" es una respuesta válida: no todas '
      'las canciones están en LRCLIB.)');
  exit(0);
}