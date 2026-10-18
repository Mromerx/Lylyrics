/// Estado de reproducción capturado en un instante concreto.
///
/// [timestamp] es el momento de la lectura y es lo que permite interpolar la
/// posición: los reproductores MPRIS no emiten señales de posición, así que
/// reconstruimos `posición = position + (ahora - timestamp) * speed`.
class PlaybackState {
  const PlaybackState({
    required this.isPlaying,
    required this.position,
    required this.timestamp,
    this.speed = 1.0,
    this.status = PlaybackStatus.stopped,
  });

  final bool isPlaying;

  /// Posición reportada por el reproductor en el momento de [timestamp].
  final Duration position;

  /// Reloj del sistema usado como base para interpolar.
  final DateTime timestamp;

  /// Velocidad de reproducción (1.0 = normal). Puede ser > 1 o < 1.
  final double speed;

  /// Estado bruto MPRIS, útil para diagnóstico en la UI.
  final PlaybackStatus status;

  /// Posición extrapolada a [now].
  Duration positionAt(DateTime now) {
    if (!isPlaying) return position;
    final elapsedMs = now.difference(timestamp).inMilliseconds;
    if (elapsedMs <= 0) return position;
    final scaled = elapsedMs * (speed.isFinite ? speed : 1.0);
    return position + Duration(microseconds: (scaled * 1000).round());
  }

  PlaybackState copyWith({
    bool? isPlaying,
    Duration? position,
    DateTime? timestamp,
    double? speed,
    PlaybackStatus? status,
  }) {
    return PlaybackState(
      isPlaying: isPlaying ?? this.isPlaying,
      position: position ?? this.position,
      timestamp: timestamp ?? this.timestamp,
      speed: speed ?? this.speed,
      status: status ?? this.status,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PlaybackState &&
      other.isPlaying == isPlaying &&
      other.position == position &&
      other.timestamp == timestamp &&
      other.speed == speed &&
      other.status == status;

  @override
  int get hashCode =>
      Object.hash(isPlaying, position, timestamp, speed, status);

  @override
  String toString() => 'PlaybackState(playing: $isPlaying, pos: $position, '
      'speed: $speed, status: ${status.name})';
}

/// Traducción directa de la propiedad `PlaybackStatus` de MPRIS.
enum PlaybackStatus {
  playing,
  paused,
  stopped;

  static PlaybackStatus fromMpris(String value) {
    switch (value) {
      case 'Playing':
        return PlaybackStatus.playing;
      case 'Paused':
        return PlaybackStatus.paused;
      default:
        return PlaybackStatus.stopped;
    }
  }

  String get name => switch (this) {
        PlaybackStatus.playing => 'playing',
        PlaybackStatus.paused => 'paused',
        PlaybackStatus.stopped => 'stopped',
      };
}

