# CONTRATOS (fijados por el Orquestador — no modificar sin acuerdo)

Paquete: `lib/`. Dependencias ya resueltas en pubspec.yaml: `dbus ^0.8.0`,
`http`, `flutter_riverpod ^3.4.3`, `sqflite_common_ffi`, `window_manager`,
`scrollable_positioned_list`.

## core/models/track_info.dart  (YA EXISTE — no lo edites)
```dart
class TrackInfo {
  const TrackInfo({required String title, required String artist,
                   String? album, Duration? duration, String? sourceApp});
  String get cacheKey;              // "artista_slug|titulo_slug|segundos"
  TrackInfo copyWith({...});
  // == y hashCode por todos los campos
}
```

## core/models/playback_state.dart  (YA EXISTE)
```dart
class PlaybackState {
  const PlaybackState({required bool isPlaying, required Duration position,
      required DateTime timestamp, double speed = 1.0,
      PlaybackStatus status = PlaybackStatus.stopped});
  Duration positionAt(DateTime now);  // extrapola usando timestamp + speed
}
enum PlaybackStatus { playing, paused, stopped;
  static PlaybackStatus fromMpris(String value);
}
```

## core/models/lyrics.dart  (YA EXISTE)
```dart
class LyricLine { const LyricLine({required Duration time, required String text});
                 bool get isBlank; }
class Lyrics {
  const Lyrics({required List<LyricLine> lines, required bool isSynced,
                String? plainText, bool instrumental = false});
  List<LyricLine> get visibleLines;
  factory Lyrics.fromPlain(String text, {bool instrumental = false});
}
```

## core/interfaces/media_source.dart  (YA EXISTE)
```dart
abstract class MediaSource {
  Stream<TrackInfo?> get trackStream;
  Stream<PlaybackState> get playbackStream;
  List<String> get availablePlayers;
  String? get selectedPlayer;
  void selectPlayer(String? busName);
  Future<void> dispose();
}
```

## core/interfaces/lyrics_provider.dart  (YA EXISTE)
```dart
abstract class LyricsProvider { Future<Lyrics?> fetch(TrackInfo track); }
```

## Reglas
- Comentarios y documentación en español.
- Cada agente SOLO escribe en sus archivos.
- `flutter analyze` sin issues y `flutter test` en verde antes de entregar.
- Añade los tests en `test/<nombre>_test.dart`.