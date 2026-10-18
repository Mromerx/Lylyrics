import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/interfaces/lyrics_provider.dart';
import '../core/models/lyrics.dart';
import '../core/models/track_info.dart';
import 'lyrics_cache.dart';
import 'lrc_parser.dart';
import 'metadata_normalizer.dart';

/// Naturaleza del fallo al hablar con LRCLIB.
enum LrclibKind {
  /// Error de red (DNS, socket cerrado, TLS...).
  network,

  /// La petición superó el tiempo límite.
  timeout,

  /// LRCLIB devolvió 5xx.
  server,

  /// No hay coincidencia exacta (404). Nunca se reintenta.
  notFound,

  /// Respuesta con cuerpo ilegible o con forma inesperada.
  badResponse,

  /// Otro 4xx distinto de 404 (429, 400...).
  client,
}

/// Error controlado de LRCLIB. La UI decide qué mostrar según [kind].
class LrclibException implements Exception {
  const LrclibException(this.kind, [this.message]);

  final LrclibKind kind;
  final String? message;

  @override
  String toString() =>
      'LrclibException(${kind.name}${message != null ? ': $message' : ''})';
}

/// Una pista tal y como la devuelve lrclib.net.
class LrcLibTrack {
  const LrcLibTrack({
    this.id,
    this.trackName,
    this.artistName,
    this.albumName,
    this.duration,
    this.instrumental,
    this.plainLyrics,
    this.syncedLyrics,
  });

  /// LRCLIB devuelve `duration` como decimal en `/search` (`177.0`) y como
  /// entero en `/get`, así que se acepta cualquier número y se trunca.
  factory LrcLibTrack.fromJson(Map<String, dynamic> json) => LrcLibTrack(
        id: (json['id'] as num?)?.toInt(),
        trackName: json['trackName'] as String?,
        artistName: json['artistName'] as String?,
        albumName: json['albumName'] as String?,
        duration: (json['duration'] as num?)?.round(),
        instrumental: json['instrumental'] as bool?,
        plainLyrics: json['plainLyrics'] as String?,
        syncedLyrics: json['syncedLyrics'] as String?,
      );

  final int? id;
  final String? trackName;
  final String? artistName;
  final String? albumName;

  /// Duración en **segundos**, tal como la usa la API.
  final int? duration;

  final bool? instrumental;
  final String? plainLyrics;
  final String? syncedLyrics;

  /// `true` si trae letra utilizable de algún tipo.
  bool get hasLyrics =>
      (syncedLyrics != null && syncedLyrics!.trim().isNotEmpty) ||
      (plainLyrics != null && plainLyrics!.trim().isNotEmpty);
}

/// Puntuación de un resultado de búsqueda frente a lo que buscábamos.
class LrcLibScore {
  const LrcLibScore({
    required this.score,
    required this.durationOk,
    required this.durationDeltaSeconds,
  });

  /// 0..1. Mayor es mejor.
  final double score;

  /// `true` si la duración difiere 3 s o menos.
  final bool durationOk;

  /// Diferencia absoluta de duración en segundos.
  final int durationDeltaSeconds;
}

/// Proveedor de letras contra [lrclib.net](https://lrclib.net).
///
/// Flujo por pista:
///  1. Se genera la lista de candidatos con [MetadataNormalizer].
///  2. Para cada candidato (como mucho [maxCandidates] por pista, para no
///     Castigar al servicio) se intenta `/get` con álbum, luego `/get` sin
///     álbum, y por último `/search` puntuando resultados.
///  3. La primera letra válida gana y se cachea. Un "no hay letra" también se
///     cachea (24 h) para no repetir la búsqueda.
class LrclibProvider implements LyricsProvider {
  LrclibProvider({
    http.Client? httpClient,
    this._cache,
    MetadataNormalizer? normalizer,
    this.userAgent =
        'Lylyrics/0.1.0 (+https://github.com/maxi/lylyrics; visor de letras '
        'sincronizadas MPRIS para Linux)',
    this.timeout = const Duration(seconds: 8),
    this.maxRetries = 2,
    this.baseUrl = 'https://lrclib.net/api',
    this.maxCandidates = 2,
    this.debounceDelay = const Duration(milliseconds: 800),
    this.parser = const LrcParser(),
  })  : _client = httpClient ?? http.Client(),
        _ownsClient = httpClient == null,
        _normalizer = normalizer ?? MetadataNormalizer();

  final http.Client _client;
  final bool _ownsClient;
  final LyricsCache? _cache;
  final MetadataNormalizer _normalizer;

  /// Parser LRC reutilizado para todas las respuestas de LRCLIB.
  final LrcParser parser;

  /// Header `User-Agent` identificable, como pide LRCLIB.
  final String userAgent;

  final Duration timeout;

  /// Reintentos solo para red/5xx. Un 404 no se reintenta nunca.
  final int maxRetries;

  final String baseUrl;

  /// Tope de candidatos consultados por pista.
  final int maxCandidates;

  /// Espera antes de lanzar la consulta al cambiar de canción.
  final Duration debounceDelay;

  bool _disposed = false;
  Timer? _debounceTimer;
  int _generation = 0;

  String? _lastError;

  /// Mensaje de error legible del último fallo, si lo hubo.
  String? get lastError => _lastError;

  /// Cancela la búsqueda pendiente y descarta la generación en curso.
  void cancelPending() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _generation++;
  }

  /// Consulta con retardo y descarte de resultados obsoletos.
  ///
  /// Si la pista cambia antes de que dispare el temporizador, la búsqueda
  /// anterior se cancela. Si cambia mientras hay una petición en vuelo, el
  /// resultado de esa petición se ignora al llegar.
  Future<Lyrics?> fetchDebounced(TrackInfo track) {
    _debounceTimer?.cancel();
    final generation = ++_generation;

    final completer = Completer<Lyrics?>();
    _debounceTimer = Timer(debounceDelay, () {
      _debounceTimer = null;
      if (_disposed) {
        if (!completer.isCompleted) completer.complete(null);
        return;
      }
      fetch(track).then((lyrics) {
        // Solo la generación más reciente puede publicar su resultado.
        if (generation != _generation) {
          if (!completer.isCompleted) completer.complete(null);
          return;
        }
        if (!completer.isCompleted) completer.complete(lyrics);
      }).catchError((Object error, StackTrace stack) {
        if (!completer.isCompleted) completer.completeError(error, stack);
      });
    });

    return completer.future;
  }

  /// Resuelve la letra de [track].
  ///
  /// Primero mira la caché (positiva y negativa). Solo si no hay nada va a la
  /// red, lo que hace que repetir la misma canción sea instantáneo.
  @override
  Future<Lyrics?> fetch(TrackInfo track) async {
    _lastError = null;

    final cache = _cache;
    if (cache != null) {
      final cached = await cache.get(track.cacheKey);
      if (cached != null) {
        if (cached.isNegative) {
          // Confirmado que no hay letra: no volvemos a preguntar.
          return null;
        }
        final hit = cached.lyrics;
        if (hit != null) {
          return hit;
        }
      }
    }

    try {
      final candidates = _normalizer.candidates(track);
      final limit =
          candidates.length < maxCandidates ? candidates.length : maxCandidates;

      for (var i = 0; i < limit; i++) {
        final result = await _resolveCandidate(track, candidates[i]);
        if (result != null) {
          await _storeInCache(track, result);
          return result;
        }
      }

      // Ningún candidato dio letra: cacheamos el negativo.
      await cache?.putNegative(track.cacheKey);
      return null;
    } on LrclibException catch (error) {
      _lastError = _describe(error);
      rethrow;
    }
  }

  Future<void> _storeInCache(TrackInfo track, Lyrics lyrics) async {
    final cache = _cache;
    if (cache == null) return;
    // El id de LRCLIB solo está disponible en la respuesta cruda; guardamos
    // un id sintético porque la clave de caché es el par artista+título.
    await cache.put(
      track.cacheKey,
      lyrics,
      id: -1,
      lrclibDuration: track.duration?.inSeconds,
    );
  }

  /// Búsqueda abierta: devuelve todos los resultados de `/search` que traen
  /// letra utilizable, sin el filtrado agresivo de [fetch].
  ///
  /// Se usa desde la lupa de la UI para que el usuario elija entre varias
  /// coincidencias. Si [artist] viene vacío se consulta por texto libre
  /// (`q=`), que es lo que admite lrclib.net para búsquedas sueltas.
  Future<List<LrcLibTrack>> searchTracks(String query, {String? artist}) async {
    final title = query.trim();
    final artistTrim = artist?.trim() ?? '';
    if (title.isEmpty && artistTrim.isEmpty) return const [];

    final Map<String, String> params;
    if (title.isEmpty) {
      params = {'q': artistTrim};
    } else if (artistTrim.isEmpty) {
      params = {'q': title};
    } else {
      params = {'track_name': title, 'artist_name': artistTrim};
    }

    final response = await _send(() => _client.get(_uri('/search', params)));
    if (response == null) return const [];

    final body = _decodeBody(response);
    if (body is! List) {
      throw LrclibException(LrclibKind.badResponse, '/search no devolvió lista');
    }

    final results = <LrcLibTrack>[];
    for (final item in body) {
      if (item is! Map) continue;
      final track = LrcLibTrack.fromJson(Map<String, dynamic>.from(item));
      if (track.hasLyrics) results.add(track);
    }
    return results;
  }

  /// Convierte un resultado crudo de LRCLIB en [Lyrics]. Público para que la
  /// búsqueda abierta pueda materializar el resultado que elija el usuario.
  Lyrics? lyricsFromTrack(LrcLibTrack? track) => _toLyrics(track);

  /// Aplica la estrategia completa a un candidato. `null` si no hay letra.
  Future<Lyrics?> _resolveCandidate(TrackInfo track, TitleCandidate candidate) async {
    final title = candidate.title.trim();
    if (title.isEmpty) return null;
    final artist = candidate.artist?.trim();
    final hasArtist = artist != null && artist.isNotEmpty;
    final durationSeconds = track.duration?.inSeconds;

    // `/get` exige SIEMPRE `artist_name`: sin él la API responde 400. Por eso
    // los candidatos sin artista (porque el reproductor dio un canal en lugar de
    // un nombre) van directos a `/search`, que sí admite buscar por título.
    if (hasArtist) {
      // 1. /get con artista + título + álbum + duración.
      final album = track.album?.trim();
      if (album != null && album.isNotEmpty && durationSeconds != null) {
        final withAlbum = await _get(
          trackName: title,
          artistName: artist,
          albumName: album,
          duration: durationSeconds,
        );
        final lyrics = _toLyrics(withAlbum);
        if (lyrics != null) return lyrics;
      }

      // 2. /get sin álbum.
      final exact = await _get(
        trackName: title,
        artistName: artist,
        duration: durationSeconds,
      );
      final fromExact = _toLyrics(exact);
      if (fromExact != null) return fromExact;
    }

    // 3. /search y elegir el mejor resultado.
    final best = await _searchBest(
      title: title,
      artist: hasArtist ? artist : null,
      durationSeconds: durationSeconds,
    );
    return _toLyrics(best);
  }

  /// `GET /get` con reintentos solo en red/5xx.
  Future<LrcLibTrack?> _get({
    required String trackName,
    String? artistName,
    String? albumName,
    int? duration,
  }) async {
    final query = <String, String>{'track_name': trackName};
    if (artistName != null) query['artist_name'] = artistName;
    if (albumName != null) query['album_name'] = albumName;
    if (duration != null) query['duration'] = '$duration';

    final response = await _send(
      () => _client.get(_uri('/get', query)),
    );
    if (response == null) return null;

    final body = _decodeSingle(response);
    return body;
  }

  /// `GET /search` + selección puntuada.
  Future<LrcLibTrack?> _searchBest({
    required String title,
    String? artist,
    int? durationSeconds,
  }) async {
    // `/search` sí admite buscar solo por título, así que los candidatos sin
    // artista llegan aquí directamente en lugar de provocar un 400 en `/get`.
    final Map<String, String> query;
    if (artist != null && artist.isNotEmpty) {
      query = {'track_name': title, 'artist_name': artist};
    } else {
      query = {'track_name': title};
    }

    final response = await _send(
      () => _client.get(_uri('/search', query)),
    );
    if (response == null) return null;

    final body = _decodeBody(response);
    if (body is! List) {
      throw LrclibException(LrclibKind.badResponse, '/search no devolvió lista');
    }

    final results = <LrcLibTrack>[];
    for (final item in body) {
      if (item is Map) {
        results.add(LrcLibTrack.fromJson(Map<String, dynamic>.from(item)));
      }
    }
    if (results.isEmpty) return null;

    LrcLibTrack? best;
    LrcLibScore? bestScore;
    for (final candidate in results) {
      final score = scoreResult(
        result: candidate,
        wantTitle: title,
        wantArtist: artist,
        wantDuration: durationSeconds,
      );
      if (!_isAcceptable(result: candidate, wantTitle: title, score: score,
          resultCount: results.length)) {
        continue;
      }
      final previousScore = bestScore;
      final better = best == null ||
          score.score > previousScore!.score ||
          (score.score == previousScore.score && _beatsTieBreak(candidate, best));
      if (better) {
        best = candidate;
        bestScore = score;
      }
    }
    return best;
  }

  /// Desempate: primero la letra sincronizada, luego el id más bajo.
  bool _beatsTieBreak(LrcLibTrack a, LrcLibTrack b) {
    final aSynced = a.syncedLyrics?.trim().isNotEmpty ?? false;
    final bSynced = b.syncedLyrics?.trim().isNotEmpty ?? false;
    if (aSynced != bSynced) return aSynced;
    final aId = a.id ?? 1 << 30;
    final bId = b.id ?? 1 << 30;
    return aId < bId;
  }

  /// Regla dura: el título debe parecerse al buscado.
  ///
  /// Solo se acepta un resultado casi idéntico (>= 0.95) cuando la búsqueda
  /// devolvió un único elemento y el título pedido es corto, que es el caso
  /// típico de "busqué X y LRCLIB tiene X con una coletilla".
  bool _isAcceptable({
    required LrcLibTrack result,
    required String wantTitle,
    required LrcLibScore score,
    required int resultCount,
  }) {
    final titleSim = _titleSimilarity(
      MetadataNormalizer.normalizeForCompare(wantTitle),
      MetadataNormalizer.normalizeForCompare(result.trackName ?? ''),
    );
    if (titleSim >= minTitleSimilarity) return true;
    return resultCount == 1 && titleSim >= nearExactTitleSimilarity;
  }

  /// Umbral de similitud de título para aceptar un resultado de /search.
  static const double minTitleSimilarity = 0.80;

  /// Umbral de la excepción "un único resultado casi idéntico".
  static const double nearExactTitleSimilarity = 0.95;

  /// Similitud Jaro-Winkler entre dos cadenas ya normalizadas (0..1).
  ///
  /// Jaro-Winkler premia el prefijo común, que es lo que distingue
  /// "Tití Me Preguntó" de "Tití" en títulos de discografía larga.
  static double _titleSimilarity(String a, String b) {
    if (a.isEmpty || b.isEmpty) return 0;
    if (a == b) return 1;
    final jaro = _jaro(a, b);
    final prefix = _commonPrefix(a, b);
    return (jaro + prefix * 0.1 * (1 - jaro)).clamp(0.0, 1.0);
  }

  static double _jaro(String s1, String s2) {
    if (s1 == s2) return 1;
    if (s1.isEmpty || s2.isEmpty) return 0;

    final matchDistance = (s1.length > s2.length ? s1.length : s2.length) ~/ 2 - 1;
    final window = matchDistance < 0 ? 0 : matchDistance;

    final s1Matches = List<bool>.filled(s1.length, false);
    final s2Matches = List<bool>.filled(s2.length, false);

    var matches = 0;
    for (var i = 0; i < s1.length; i++) {
      final start = i - window < 0 ? 0 : i - window;
      final end = i + window + 1 > s2.length ? s2.length : i + window + 1;
      for (var j = start; j < end; j++) {
        if (s2Matches[j] || s1[i] != s2[j]) continue;
        s1Matches[i] = true;
        s2Matches[j] = true;
        matches++;
        break;
      }
    }
    if (matches == 0) return 0;

    var transpositions = 0;
    var k = 0;
    for (var i = 0; i < s1.length; i++) {
      if (!s1Matches[i]) continue;
      while (!s2Matches[k]) {
        k++;
      }
      if (s1[i] != s2[k]) transpositions++;
      k++;
    }

    final t = transpositions / 2;
    final m = matches.toDouble();
    return (m / s1.length + m / s2.length + (m - t) / m) / 3;
  }

  static int _commonPrefix(String a, String b) {
    final limit = a.length < b.length ? a.length : b.length;
    const maxPrefix = 4;
    var i = 0;
    while (i < limit && i < maxPrefix && a[i] == b[i]) {
      i++;
    }
    return i;
  }

  /// Puntuación de un resultado frente a lo buscado.
  ///
  /// Pesos: título 0.60, artista 0.30, duración 0.10. La duración solo suma si
  /// la diferencia es de 3 s o menos, y a menor diferencia más bonus.
  static LrcLibScore scoreResult({
    required LrcLibTrack result,
    required String? wantTitle,
    required String? wantArtist,
    int? wantDuration,
  }) {
    final titleSim = _titleSimilarity(
      MetadataNormalizer.normalizeForCompare(wantTitle ?? ''),
      MetadataNormalizer.normalizeForCompare(result.trackName ?? ''),
    );

    final wantArtistNorm =
        MetadataNormalizer.normalizeForCompare(wantArtist ?? '');
    final gotArtistNorm =
        MetadataNormalizer.normalizeForCompare(result.artistName ?? '');
    double artistScore;
    if (wantArtistNorm.isEmpty && gotArtistNorm.isEmpty) {
      artistScore = 1;
    } else if (wantArtistNorm.isEmpty || gotArtistNorm.isEmpty) {
      // Falta uno de los dos: penalizamos pero no descartamos.
      artistScore = 0.5;
    } else if (wantArtistNorm == gotArtistNorm) {
      artistScore = 1;
    } else {
      final artistSim = _titleSimilarity(wantArtistNorm, gotArtistNorm);
      artistScore = artistSim >= 0.85 ? 0.7 : (artistSim * 0.5);
    }

    var durationBonus = 0.0;
    var delta = 0;
    var durationOk = false;
    if (wantDuration != null && result.duration != null) {
      delta = (wantDuration - result.duration!).abs();
      durationOk = delta <= 3;
      if (durationOk) {
        durationBonus = 1.0 - (delta / 3.0) * 0.5;
      }
    }

    final total =
        (titleSim * 0.60 + artistScore * 0.30 + durationBonus * 0.10)
            .clamp(0.0, 1.0);
    return LrcLibScore(
      score: total,
      durationOk: durationOk,
      durationDeltaSeconds: delta,
    );
  }

  /// Ejecuta la petición aplicando timeout y reintentos.
  ///
  /// Devuelve `null` en 404 **y en cualquier 4xx**: LRCLIB responde 400 cuando
  /// la combinación de parámetros no es válida y eso solo significa "prueba
  /// otra vía", no que haya un fallo que mostrar al usuario.
  Future<http.Response?> _send(Future<http.Response> Function() attempt) async {
    LrclibException? last;
    final maxAttempts = maxRetries + 1;

    for (var i = 0; i < maxAttempts; i++) {
      if (i > 0) {
        // Backoff corto y creciente entre reintentos.
        await Future<void>.delayed(Duration(milliseconds: 300 * i));
      }
      try {
        final response = await attempt().timeout(timeout);
        final status = response.statusCode;
        if (status == 404) {
          // Sin reintentos: la letra no existe.
          return null;
        }
        if (status >= 500) {
          last = LrclibException(LrclibKind.server, 'HTTP $status');
          continue;
        }
        if (status >= 400) {
          // 4xx: consulta no válida o no encontrada. Sin reintentos, pero
          // tampoco es un error que merezcahibitarse en la UI.
          return null;
        }
        return response;
      } on LrclibException {
        rethrow;
      } on TimeoutException {
        last = const LrclibException(LrclibKind.timeout, 'sin respuesta a tiempo');
      } on http.ClientException catch (error) {
        last = LrclibException(LrclibKind.network, error.message);
      } catch (error) {
        last = LrclibException(LrclibKind.network, '$error');
      }
    }

    throw last ?? const LrclibException(LrclibKind.network);
  }

  Object? _decodeBody(http.Response response) {
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException catch (error) {
      throw LrclibException(LrclibKind.badResponse, error.message);
    }
  }

  LrcLibTrack? _decodeSingle(http.Response response) {
    final body = _decodeBody(response);
    if (body is Map) return LrcLibTrack.fromJson(Map<String, dynamic>.from(body));
    throw LrclibException(LrclibKind.badResponse, '/get no devolvió objeto');
  }

  /// Convierte la respuesta cruda en [Lyrics], o `null` si no hay nada útil.
  Lyrics? _toLyrics(LrcLibTrack? track) {
    if (track == null) return null;
    if (track.instrumental == true) {
      return const Lyrics(
        lines: [],
        isSynced: false,
        instrumental: true,
      );
    }

    final synced = track.syncedLyrics;
    if (synced != null && synced.trim().isNotEmpty) {
      final parsed = parser.parse(synced);
      if (parsed.lines.isNotEmpty) {
        return Lyrics(
          lines: parsed.lines,
          isSynced: true,
          plainText: track.plainLyrics ?? parsed.plainText,
          instrumental: false,
        );
      }
    }

    final plain = track.plainLyrics;
    if (plain != null && plain.trim().isNotEmpty) {
      return Lyrics.fromPlain(plain);
    }

    return null;
  }

  Uri _uri(String path, Map<String, String> query) {
    final cleaned = <String, String>{};
    query.forEach((key, value) {
      if (value.trim().isNotEmpty) cleaned[key] = value.trim();
    });
    return Uri.parse('$baseUrl$path').replace(
      queryParameters: cleaned.isEmpty ? null : cleaned,
    );
  }

  String _describe(LrclibException error) => switch (error.kind) {
        LrclibKind.timeout => 'LRCLIB took too long to respond',
        LrclibKind.network => 'No connection to lrclib.net',
        LrclibKind.server => 'lrclib.net is having problems right now',
        LrclibKind.notFound => 'No lyrics in LRCLIB',
        LrclibKind.badResponse => 'lrclib.net returned an invalid response',
        LrclibKind.client => 'LRCLIB rejected the request (${error.message ?? ''})',
      };

  /// Libera temporizadores y, si somos dueños, el cliente HTTP.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    cancelPending();
    if (_ownsClient) _client.close();
  }
}