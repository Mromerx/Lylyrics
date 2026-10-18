import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/interfaces/lyrics_provider.dart';
import '../core/models/lyrics.dart';
import '../core/models/track_info.dart';
import 'lrc_parser.dart';

/// Respaldo NetEase Cloud Music entre LRCLIB y Genius.
///
/// Usa los endpoints web públicos sin API key: búsqueda en
/// `/api/search/get` (el `.../get/web` cifrado con `weapi` **no** devuelve
/// JSON plano) y letra en `/api/song/lyric`. La letra llega como LRC (con
/// timestamps) en `lrc.lyric` o como texto plano cuando la pista no está
/// sincronizada.
///
/// Igual que Genius, nunca lanza: todo fallo (red, JSON inesperado, sin
/// resultados) devuelve `null` o lista vacía y el llamante lo trata como
/// "no encontrada".
class NeteaseProvider implements LyricsProvider {
  NeteaseProvider({http.Client? client, this.timeout = _defaultTimeout})
      // ignore: prefer_initializing_formals
      : _client = client;

  static const Duration _defaultTimeout = Duration(seconds: 8);

  final http.Client? _client;

  final Duration timeout;

  static const Map<String, String> _headers = {
    'User-Agent':
        'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) '
            'Chrome/126.0 Safari/537.36',
    'Referer': 'https://music.163.com/',
  };

  /// Búsqueda abierta de canciones. Sin resultados devuelve lista vacía.
  Future<List<NeteaseSong>> search(String query, {String? artist}) async {
    final q = [query.trim(), artist?.trim() ?? '']
        .where((s) => s.isNotEmpty)
        .join(' ');
    if (q.isEmpty) return const [];

    final uri = Uri.parse('https://music.163.com/api/search/get').replace(
      queryParameters: {
        's': q,
        'type': '1', // 1 = canción
        'limit': '15',
        'offset': '0',
      },
    );

    try {
      final body = await _get(uri);
      if (body == null) return const [];
      return neteaseSongsFromSearchJson(body);
    } catch (_) {
      return const [];
    }
  }

  /// Letra en crudo de una canción por id. `null` si no hay letra.
  Future<NeteaseLyrics?> _fetchLyrics(int id) async {
    final uri = Uri.parse('https://music.163.com/api/song/lyric').replace(
      queryParameters: {
        'id': '$id',
        'lv': '-1', // letra en LRC
        'kv': '-1',
        'tv': '-1',
        'os': 'pc',
      },
    );

    final body = await _get(uri);
    if (body == null) return null;
    return neteaseLyricsFromJson(body);
  }

  /// Convierte la respuesta cruda de `/api/song/lyric` en [Lyrics].
  ///
  /// `nolyric: true` significa pista instrumental. Un LRC sin timestamps
  /// viables cae a letra plana. Sin letra utilizable devuelve `null`.
  Lyrics? lyricsFromRaw(NeteaseLyrics? raw) {
    if (raw == null) return null;
    if (raw.noLyric) {
      return const Lyrics(lines: [], isSynced: false, instrumental: true);
    }
    final lyric = raw.lyric;
    if (lyric == null || lyric.trim().isEmpty) return null;

    // NetEase mete créditos con marca de tiempo («作曲 : X») y cuando la
    // pista es instrumental pone una sola línea «纯音乐，请欣赏».
    final cleaned = _stripCreditLines(lyric);
    if (cleaned.trim().isEmpty) return null;

    if (_hasTimestamp(cleaned)) {
      final parsed = const LrcParser().parse(cleaned);
      if (parsed.lines.isNotEmpty) {
        if (_looksInstrumental(parsed.lines)) {
          return const Lyrics(lines: [], isSynced: true, instrumental: true);
        }
        return Lyrics(
          lines: parsed.lines,
          isSynced: true,
          plainText: raw.plainLyric ?? parsed.plainText,
        );
      }
    }
    return Lyrics.fromPlain(_stripCreditLinesMulti(cleaned));
  }

  /// Resuelve la letra de [track] en NetEase. `null` si no hay suerte.
  @override
  Future<Lyrics?> fetch(TrackInfo track) async {
    final title = track.title.trim();
    if (title.isEmpty) return null;

    final songs = await search(title, artist: track.artist);
    final best = pickNeteaseSong(songs, title, track.artist);
    if (best == null) return null;

    final raw = await _fetchLyrics(best.id);
    return lyricsFromRaw(raw);
  }

  /// Convierte una canción elegida en la lupa en [Lyrics].
  Future<Lyrics?> lyricsFromSong(NeteaseSong song) async =>
      lyricsFromRaw(await _fetchLyrics(song.id));

  Future<String?> _get(Uri uri) async {
    final client = _client ?? http.Client();
    final shouldClose = _client == null;
    try {
      final resp = await client.get(uri, headers: _headers).timeout(timeout);
      if (resp.statusCode != 200) return null;
      // NetEase sirve UTF-8 y no siempre declara charset: respond.body
      // caería a latin1. Los bytes a UTF-8, explícitos.
      return utf8.decode(resp.bodyBytes, allowMalformed: true);
    } catch (_) {
      return null;
    } finally {
      if (shouldClose) client.close();
    }
  }
}

/// ¿El LRC tiene al menos una marca `[mm:ss]` arriba?
bool _hasTimestamp(String lrc) {
  return RegExp(r'^\s*\[\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?\]', multiLine: true)
      .hasMatch(lrc);
}

/// Créditos de NetEase: «作曲 : …», «作词：…», «OP：…», «Lyrics by: …».
/// Llevan un prefijo opcional de timestamps (vienen como líneas con tiempo).
final RegExp _creditLineRe = RegExp(
  r'^(?:\s*\[[^\]]*\]\s*)*'
  r"(?:作词|作詞|作曲|编曲|編曲|制作|製作|制作人|製作人|策划|企劃|企划|"
  r"和声|和聲|混音|混縮|混缩|母带|錄音|录音|填词|填詞|改编|改編|監製|监制|"
  r"翻唱|发行|出品|版权|翻译|譯|"
  r"OP|SP|Vocal|Choir|Keyboard|Programming|Producer|Lyricist|Lyrics\s*by|"
  r'Written\s*by|Composed\s*by|Arranger)'
  r'\s*[::]\s*',
  caseSensitive: false,
);

/// Quita las líneas de créditos de un LRC con timestamps (línea a línea).
String _stripCreditLines(String lrc) {
  return lrc.split('\n').where((l) => !_creditLineRe.hasMatch(l)).join('\n');
}

/// Quita los créditos de un texto plano (sin timestamps): una línea entera
/// de créditos se descarta, no se le arranca el prefijo.
String _stripCreditLinesMulti(String text) {
  return text
      .split('\n')
      .where((l) => !_creditLineRe.hasMatch(l))
      .join('\n');
}

/// ¿Todas las líneas con texto dicen «纯音乐» / "instrumental"?
bool _looksInstrumental(List<LyricLine> lines) {
  final withText =
      lines.where((l) => l.text.trim().isNotEmpty).toList(growable: false);
  if (withText.isEmpty) return false;
  return withText.every((l) => l.text.contains('纯音乐'));
}

/// Una canción tal y como la devuelve la búsqueda de NetEase.
class NeteaseSong {
  const NeteaseSong({
    required this.id,
    required this.name,
    required this.artists,
    this.albumName,
    this.durationMs,
  });

  factory NeteaseSong.fromJson(Map<String, dynamic> json) => NeteaseSong(
        id: (json['id'] as num?)?.toInt() ?? -1,
        name: (json['name'] as String?) ?? '',
        artists: [
          for (final a in (json['artists'] as List? ?? const []))
            if (a is Map && a['name'] is String) a['name'] as String,
        ].join(', '),
        albumName: (json['album'] as Map?)?['name'] as String?,
        durationMs: (json['duration'] as num?)?.toInt(),
      );

  final int id;
  final String name;

  /// Artistas unidos con coma (NetEase da una lista).
  final String artists;
  final String? albumName;

  /// Duración en **milisegundos** (NetEase da ms; LRCLIB da segundos).
  final int? durationMs;

  @override
  String toString() => 'NeteaseSong($id, $name, $artists)';
}

/// Letra cruda de NetEase: LRC sincronizado y/o traducción.
class NeteaseLyrics {
  const NeteaseLyrics({
    required this.lyric,
    this.noLyric = false,
    this.plainLyric,
  });

  factory NeteaseLyrics.fromJson(Map<String, dynamic> json) => NeteaseLyrics(
        lyric: ((json['lrc'] as Map?)?['lyric'] as String?)?.trim(),
        noLyric: (json['nolyric'] as bool?) ??
            // NetEase devuelve `uncollected` = true cuando no hay pista.
            (json['uncollected'] as bool?) ??
            false,
        plainLyric: ((json['txtLyric'] as Map?)?['lyric'] as String?)?.trim(),
      );

  /// LRC sincronizado (o texto plano si la pista no lo está).
  final String? lyric;
  final bool noLyric;

  /// Letra plana si NetEase la trae aparte (`txtLyric`).
  final String? plainLyric;
}

/// Canciones de la búsqueda de NetEase.
///
/// El endpoint devuelve `{"result": {"songs": [...]}}` (conforme verificado:
/// cada canción lleva `id`, `name`, `artists[]`, `album` y `duration` en ms),
/// pero se recorre el JSON entero buscando maps de canción para tolerar
/// cambios de forma: con `id`, `name` y alguna de `artists`/`album`/
/// `duration`. Solo esos: los objetos `album` y `artist` anidados también
/// llevan `id`+`name`. Deduplica por id y conserva el orden del servidor.
List<NeteaseSong> neteaseSongsFromSearchJson(String body) {
  bool looksLikeSong(Map node) {
    return node['name'] is String &&
        node['id'] is num &&
        (node['artists'] != null ||
            node['album'] != null ||
            node['duration'] != null);
  }

  try {
    final decoded = jsonDecode(body);
    final out = <NeteaseSong>[];
    final seen = <int>{};

    void collect(Object? node) {
      if (node is Map) {
        if (looksLikeSong(node)) {
          final id = (node['id'] as num).toInt();
          if (id >= 0 && seen.add(id)) {
            out.add(NeteaseSong.fromJson(
              Map<String, dynamic>.from(node),
            ));
          }
        }
        for (final value in node.values) {
          collect(value);
        }
      } else if (node is List) {
        for (final item in node) {
          collect(item);
        }
      }
    }

    collect(decoded);
    return out;
  } catch (_) {
    return [];
  }
}

/// Letra cruda desde el JSON de `/api/song/lyric`. `null` si la forma no cuadra.
NeteaseLyrics? neteaseLyricsFromJson(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map) return null;
    return NeteaseLyrics.fromJson(Map<String, dynamic>.from(decoded));
  } catch (_) {
    return null;
  }
}

/// Elige la mejor candidata para [title]/[artist].
///
/// Puntúa por palabras del título y del artista presentes en el nombre de la
/// canción, igual que `pickGeniusUrl`. `null` sin candidatas con algo del
/// título: no nos fiamos del primer resultado a ciegas.
NeteaseSong? pickNeteaseSong(
  List<NeteaseSong> songs,
  String title,
  String artist,
) {
  if (songs.isEmpty) return null;
  final titleWords = _words(title);
  final artistWords = _words(artist);
  if (titleWords.isEmpty) return null;

  NeteaseSong? best;
  var bestScore = 0;
  for (final song in songs) {
    final name = song.name.toLowerCase();
    var score = 0;
    for (final w in titleWords) {
      if (w.length > 2 && name.contains(w)) score += 2;
    }
    for (final w in artistWords) {
      if (w.length > 2 && song.artists.toLowerCase().contains(w)) score += 1;
    }
    if (score > bestScore) {
      bestScore = score;
      best = song;
    }
  }
  // Sin nada del título no nos fiamos del primer resultado.
  if (bestScore == 0) return null;
  return best;
}

Set<String> _words(String s) {
  return s
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9áéíóúüñ]+'))
      .where((w) => w.isNotEmpty)
      .toSet();
}
