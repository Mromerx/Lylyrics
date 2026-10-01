/// Información inmutable de la pista que se está reproduciendo.
///
/// Es la unidad de trabajo de toda la app: la produce un [MediaSource]
/// (MPRIS en esta fase) y la consumen el normalizador y el proveedor de
/// letras.
class TrackInfo {
  const TrackInfo({
    required this.title,
    required this.artist,
    this.album,
    this.duration,
    this.sourceApp,
  });

  final String title;
  final String artist;
  final String? album;
  final Duration? duration;

  /// Nombre del reproductor de origen (p. ej. `org.mpris.MediaPlayer2.freetube`).
  final String? sourceApp;

  /// Clave estable para caché y para guardar ajustes por canción (offset).
  ///
  /// Se construye con título + artista + duración en segundos para que dos
  /// versiones en vivo de la misma canción compartan ajustes, pero inevitable.
  String get cacheKey {
    final t = _slug(title);
    final a = _slug(artist);
    final d = duration?.inSeconds ?? -1;
    return '$a|$t|$d';
  }

  static String _slug(String s) {
    final lower = s.toLowerCase().trim();
    final buf = StringBuffer();
    for (final c in lower.codeUnits) {
      final isAlnum =
          (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x7a);
      buf.write(isAlnum ? String.fromCharCode(c) : '_');
    }
    return buf.toString();
  }

  TrackInfo copyWith({
    String? title,
    String? artist,
    String? album,
    Duration? duration,
    String? sourceApp,
  }) {
    return TrackInfo(
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      duration: duration ?? this.duration,
      sourceApp: sourceApp ?? this.sourceApp,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TrackInfo &&
      other.title == title &&
      other.artist == artist &&
      other.album == album &&
      other.duration == duration &&
      other.sourceApp == sourceApp;

  @override
  int get hashCode => Object.hash(title, artist, album, duration, sourceApp);

  @override
  String toString() =>
      'TrackInfo(title: $title, artist: $artist, album: $album, '
      'duration: $duration, sourceApp: $sourceApp)';
}