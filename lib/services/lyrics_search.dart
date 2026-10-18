import '../core/models/lyrics.dart';
import 'genius_scraper.dart';
import 'lrclib_provider.dart';
import 'netease_provider.dart';

/// Origen del resultado de búsqueda.
enum LyricsSource {
  lrclib,
  netease,
  genius,
}

/// Resultado de búsqueda mostrable en la lupa, venga de donde venga.
///
/// Es un tipo sellado para que el materializado ([LyricsSearchService.load])
/// sea exhaustivo: añadir una fuente nueva obliga a tratarla aquí.
sealed class SearchResult {
  const SearchResult();

  /// Título del tema tal y como lo devuelve la fuente.
  String get title;

  /// Artista. Cadena vacía si la fuente no lo da.
  String get artist;

  /// Etiqueta corta para el chip de la UI ("LRCLIB" / "Genius").
  String get sourceLabel;

  /// `true` si la letra trae marcas de tiempo (solo LRCLIB).
  bool get synced;

  /// Identificador estable para deduplicar entre fuentes.
  String get id;
}

/// Resultado procedente de lrclib.net (puede venir sincronizado).
class LrclibSearchResult extends SearchResult {
  const LrclibSearchResult(this.track);

  final LrcLibTrack track;

  @override
  String get title => track.trackName ?? '';

  @override
  String get artist => track.artistName ?? '';

  @override
  String get sourceLabel => 'LRCLIB';

  @override
  bool get synced => track.syncedLyrics?.trim().isNotEmpty ?? false;

  @override
  String get id => 'lrclib:${track.id ?? '${track.trackName}|${track.artistName}'}';
}

/// Resultado procedente de Genius (siempre letra plana, sin tiempos).
class GeniusSearchResult extends SearchResult {
  const GeniusSearchResult(this.match);

  final GeniusMatch match;

  @override
  String get title => match.title;

  @override
  String get artist => match.artist;

  @override
  String get sourceLabel => 'Genius';

  @override
  bool get synced => false;

  @override
  String get id => 'genius:${match.url}';
}

/// Resultado procedente de NetEase. La búsqueda solo trae metadatos, así que
/// no se sabe aún si la letra vendrá sincronizada: se marca plana a
/// conservadora y la materialización irá a `/api/song/lyric`.
class NeteaseSearchResult extends SearchResult {
  const NeteaseSearchResult(this.song);

  final NeteaseSong song;

  @override
  String get title => song.name;

  @override
  String get artist => song.artists;

  @override
  String get sourceLabel => 'NetEase';

  @override
  bool get synced => false;

  @override
  String get id => 'netease:${song.id}';
}

/// Busca en LRCLIB, NetEase y Genius a la vez y unifica los resultados.
///
/// Es la lógica de la lupa: la UI solo pinta [SearchResult] y luego pide
/// [load] del elegido. Nunca lanza: una fuente caída no debe tumbar la otra.
class LyricsSearchService {
  LyricsSearchService({
    required this.lrclib,
    required this.genius,
    this.netease,
    this.maxResultsPerSource = 15,
  });

  final LrclibProvider lrclib;
  final GeniusScraper genius;

  /// Reserva NetEase. Puede ser `null` en tests que solo cubren el resto.
  final NeteaseProvider? netease;

  /// Tope de coincidencias por fuente que se muestran en la lupa.
  final int maxResultsPerSource;

  /// Lanza las tres búsquedas en paralelo y devuelve los resultados
  /// mezclados, con las letras sincronizadas primero.
  Future<List<SearchResult>> search(String title, {String? artist}) async {
    final query = title.trim();
    final artistTrim = artist?.trim() ?? '';
    if (query.isEmpty && artistTrim.isEmpty) return const [];

    final perSource = await Future.wait<List<SearchResult>>([
      _searchLrclib(query, artistTrim),
      _searchNetease(query, artistTrim),
      _searchGenius(query, artistTrim),
    ]);

    final merged = <SearchResult>[...perSource[0], ...perSource[1], ...perSource[2]];
    merged.sort((a, b) {
      if (a.synced != b.synced) return a.synced ? -1 : 1;
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });
    return merged;
  }

  /// Materializa la letra del resultado elegido. `null` si la fuente falló.
  Future<Lyrics?> load(SearchResult result) {
    switch (result) {
      case LrclibSearchResult():
        return Future.value(lrclib.lyricsFromTrack(result.track));
      case NeteaseSearchResult():
        final netease = this.netease;
        if (netease == null) return Future.value(null);
        return netease.lyricsFromSong(result.song);
      case GeniusSearchResult():
        return genius.fetchFromUrl(result.match.url);
    }
  }

  Future<List<SearchResult>> _searchLrclib(String title, String artist) async {
    try {
      final tracks = await lrclib.searchTracks(title, artist: artist);
      final limited = tracks.length > maxResultsPerSource
          ? tracks.sublist(0, maxResultsPerSource)
          : tracks;
      return [for (final track in limited) LrclibSearchResult(track)];
    } catch (_) {
      return const [];
    }
  }

  Future<List<SearchResult>> _searchNetease(String title, String artist) async {
    final netease = this.netease;
    if (netease == null) return const [];
    try {
      final songs = await netease.search(title, artist: artist);
      final limited = songs.length > maxResultsPerSource
          ? songs.sublist(0, maxResultsPerSource)
          : songs;
      return [for (final song in limited) NeteaseSearchResult(song)];
    } catch (_) {
      return const [];
    }
  }

  Future<List<SearchResult>> _searchGenius(String title, String artist) async {
    try {
      final matches = await genius.search(title, artist: artist);
      final limited = matches.length > maxResultsPerSource
          ? matches.sublist(0, maxResultsPerSource)
          : matches;
      return [for (final match in limited) GeniusSearchResult(match)];
    } catch (_) {
      return const [];
    }
  }
}
