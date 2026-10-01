import '../models/lyrics.dart';
import '../models/track_info.dart';

/// Proveedor de letras para una pista concreta.
///
/// La implementación de esta fase consulta LRCLIB. La interfaz permite
/// añadir más fuentes (Musixmatch, Genius, archivo local) componiendo
/// providers en el futuro sin modificar nada más.
abstract class LyricsProvider {
  /// Devuelve la letra de [track] o `null` si no se encuentra ninguna.
  Future<Lyrics?> fetch(TrackInfo track);
}