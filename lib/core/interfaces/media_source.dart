import '../models/playback_state.dart';
import '../models/track_info.dart';

/// Fuente de metadatos de reproducción.
///
/// Contrato clave de la app: la UI y los servicios nunca conocen MPRIS ni
/// D-Bus. En la fase 1 solo existe la implementación Linux, pero añadir
/// Android/NewPipe o un reproductor de Spotify en otra plataforma significa
/// implementar esta interfaz y registrarla en el provider de Riverpod, sin
/// tocar servicios ni widgets.
abstract class MediaSource {
  /// Pista actual. Emite `null` cuando no hay nada reproduciéndose.
  Stream<TrackInfo?> get trackStream;

  /// Estado de reproducción. Emite en cada recálculo (polling de posición,
  /// cambios de `PropertiesChanged` y la señal `Seeked`).
  Stream<PlaybackState> get playbackStream;

  /// Identificadores de los reproductores detectados, para el selector
  /// manual de la UI. Lista vacía si la fuente no admite selección.
  List<String> get availablePlayers;

  /// Reproductor actualmente elegido. `null` = automático.
  String? get selectedPlayer;

  /// Fuerza un reproductor concreto. `null` vuelve al modo automático.
  void selectPlayer(String? busName);

  /// Libera timers, suscripciones D-Bus y cualquier otro recurso.
  Future<void> dispose();
}