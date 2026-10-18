import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../core/models/lyrics.dart';
import '../core/models/track_info.dart';

/// Respaldo Genius cuando LRCLIB no tiene la canción.
///
/// Sin API key: usa el endpoint público de búsqueda del sitio
/// (`/api/search/multi`, el mismo que llama la web) y extrae la letra de los
/// `div[data-lyrics-container]` de la página del tema. Devuelve letra PLANA
/// (sin tiempos): la insignia de la UI la mostrará como "sin sincronizar".
///
/// Todo fallo (red, HTML inesperado, sin resultados) devuelve `null` sin
/// lanzar: el llamante decide si eso es "no encontrada".
class GeniusScraper {
  // ignore: prefer_initializing_formals
  GeniusScraper({http.Client? client}) : _client = client;

  final http.Client? _client;

  static const Map<String, String> _headers = {
    'User-Agent':
        'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) '
            'Chrome/126.0 Safari/537.36',
    'Accept-Language': 'es-ES,es;q=0.9,en;q=0.8',
    'Referer': 'https://genius.com/',
  };

  /// Búsqueda abierta en Genius: devuelve todas las coincidencias de temas
  /// (no solo la mejor), para que la lupa de la UI las muestre al usuario.
  ///
  /// Prioriza el endpoint JSON `/api/search/multi`; si no da nada, cae a la
  /// página HTML de búsqueda. Nunca lanza: un fallo devuelve lista vacía.
  Future<List<GeniusMatch>> search(String query, {String? artist}) async {
    final q = [query.trim(), artist?.trim() ?? '']
        .where((s) => s.isNotEmpty)
        .join(' ');
    if (q.isEmpty) return const [];

    final client = _client ?? http.Client();
    final shouldClose = _client == null;
    try {
      // OJO: Genius rechaza `per_page` > 5 con HTTP 422. Con 6+ la API devuelve
      // null y se cae al HTML de búsqueda (renderizado en cliente), que solo
      // trae enlaces promocionados. 5 es el máximo aceptado.
      final apiUri = Uri.parse(
        'https://genius.com/api/search/multi?per_page=5&q=${Uri.encodeComponent(q)}',
      );
      final apiBody = await _get(client, apiUri);
      if (apiBody != null) {
        final matches = geniusMatchesFromSearchJson(apiBody);
        if (matches.isNotEmpty) return matches;
      }

      final htmlUri = Uri.parse(
        'https://genius.com/search?q=${Uri.encodeComponent(q)}',
      );
      final htmlBody = await _get(client, htmlUri);
      if (htmlBody == null) return const [];
      return [
        for (final url in geniusUrlsFromHtml(htmlBody))
          GeniusMatch(title: _titleFromUrl(url), artist: '', url: url),
      ];
    } catch (_) {
      return const [];
    } finally {
      if (shouldClose) client.close();
    }
  }

  /// Descarga y extrae la letra plana de una URL de tema de Genius.
  Future<Lyrics?> fetchFromUrl(String url) async {
    final client = _client ?? http.Client();
    final shouldClose = _client == null;
    try {
      final page = await _get(client, Uri.parse(url));
      if (page == null) return null;
      final text = extractGeniusLyrics(page);
      if (text.trim().isEmpty) return null;
      return Lyrics.fromPlain(text);
    } catch (_) {
      return null;
    } finally {
      if (shouldClose) client.close();
    }
  }

  /// Busca la letra de [track] en Genius. `null` si no hay suerte.
  Future<Lyrics?> fetch(TrackInfo track) async {
    final title = track.title.trim();
    if (title.isEmpty) return null;
    final client = _client ?? http.Client();
    final shouldClose = _client == null;
    try {
      final url = await _findLyricsUrl(client, title, track.artist);
      if (url == null) return null;
      final page = await _get(client, Uri.parse(url));
      if (page == null) return null;
      final text = extractGeniusLyrics(page);
      if (text.trim().isEmpty) return null;
      return Lyrics.fromPlain(text);
    } catch (_) {
      return null;
    } finally {
      if (shouldClose) client.close();
    }
  }

  Future<String?> _findLyricsUrl(
    http.Client client,
    String title,
    String artist,
  ) async {
    // 1. API pública de búsqueda del sitio (sin autenticación).
    final apiUri = Uri.parse(
      'https://genius.com/api/search/multi?per_page=5&q='
      '${Uri.encodeComponent([title, artist].where((s) => s.trim().isNotEmpty).join(' '))}',
    );
    final apiBody = await _get(client, apiUri);
    if (apiBody != null) {
      final urls = geniusUrlsFromSearchJson(apiBody);
      final best = pickGeniusUrl(urls, title, artist);
      if (best != null) return best;
    }

    // 2. Reserva: página HTML de búsqueda y primer enlace a tema.
    final htmlUri = Uri.parse(
      'https://genius.com/search?q='
      '${Uri.encodeComponent([title, artist].where((s) => s.trim().isNotEmpty).join(' '))}',
    );
    final htmlBody = await _get(client, htmlUri);
    if (htmlBody == null) return null;
    return pickGeniusUrl(geniusUrlsFromHtml(htmlBody), title, artist);
  }

  Future<String?> _get(http.Client client, Uri uri) async {
    try {
      final resp = await client
          .get(uri, headers: _headers)
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return null;
      return resp.body;
    } catch (_) {
      return null;
    }
  }
}

/// Coincidencia de búsqueda de Genius: título, artista y URL del tema.
class GeniusMatch {
  const GeniusMatch({
    required this.title,
    required this.artist,
    required this.url,
  });

  final String title;
  final String artist;
  final String url;
}

/// Coincidencias de temas (con título y artista) del JSON de
/// `/api/search/multi`. Deduplica por URL y conserva el orden del servidor.
List<GeniusMatch> geniusMatchesFromSearchJson(String body) {
  try {
    final decoded = jsonDecode(body);
    final out = <GeniusMatch>[];
    final seen = <String>{};
    void collect(Object? node) {
      if (node is Map) {
        final url = node['url'];
        final title = node['title'];
        if (url is String &&
            title is String &&
            url.startsWith('https://genius.com/') &&
            url.endsWith('-lyrics')) {
          final clean = url.split('?').first;
          if (seen.add(clean)) {
            out.add(GeniusMatch(
              title: title,
              artist: (node['artist_names'] as String?) ?? '',
              url: clean,
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

/// Deriva un título legible del slug de una URL de tema (plan B del HTML).
String _titleFromUrl(String url) {
  final slug = url
      .replaceFirst('https://genius.com/', '')
      .replaceAll('-lyrics', '')
      .replaceAll('-', ' ')
      .trim();
  if (slug.isEmpty) return url;
  return slug[0].toUpperCase() + slug.substring(1);
}

/// URLs de temas (`...-lyrics`) encontradas en el JSON de `/api/search/multi`.
List<String> geniusUrlsFromSearchJson(String body) {
  try {
    final decoded = jsonDecode(body);
    final urls = <String>[];
    void collect(Object? node) {
      if (node is Map) {
        for (final entry in node.entries) {
          if (entry.key == 'url' && entry.value is String) {
            final url = entry.value as String;
            if (url.startsWith('https://genius.com/') &&
                url.endsWith('-lyrics') &&
                !urls.contains(url)) {
              urls.add(url.split('?').first);
            }
          } else {
            collect(entry.value);
          }
        }
      } else if (node is List) {
        for (final item in node) {
          collect(item);
        }
      }
    }

    collect(decoded);
    return urls;
  } catch (_) {
    return [];
  }
}

/// URLs de temas encontradas en HTML (página de búsqueda como reserva).
List<String> geniusUrlsFromHtml(String body) {
  final urls = <String>[];
  final re = RegExp(r'href="(https://genius\.com/[A-Za-z0-9\-_]+-lyrics)"');
  for (final m in re.allMatches(body)) {
    final url = m.group(1)!;
    if (!urls.contains(url)) urls.add(url);
  }
  return urls;
}

/// Elige la mejor candidata para [title]/[artist].
///
/// Puntúa por palabras del título y del artista presentes en el slug;
/// descarta páginas que no son letras (artistas, álbumes). `null` sin
/// candidatas con algo del título.
String? pickGeniusUrl(List<String> urls, String title, String artist) {
  if (urls.isEmpty) return null;
  final titleWords = _words(title);
  final artistWords = _words(artist);
  if (titleWords.isEmpty) return null;

  String? best;
  var bestScore = 0;
  for (final url in urls) {
    final slug = url
        .replaceFirst('https://genius.com/', '')
        .replaceAll('-lyrics', '')
        .toLowerCase();
    var score = 0;
    for (final w in titleWords) {
      if (w.length > 2 && slug.contains(w)) score += 2;
    }
    for (final w in artistWords) {
      if (w.length > 2 && slug.contains(w)) score += 1;
    }
    if (score > bestScore) {
      bestScore = score;
      best = url;
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

/// Extrae la letra plana de una página de tema de Genius.
///
/// Une los `div[data-lyrics-container]`, convierte `<br>` en saltos y
/// limpia etiquetas y entidades. Conserva cabeceras como `[Chorus]`.
String extractGeniusLyrics(String pageHtml) {
  final Document document = html_parser.parse(pageHtml);
  final containers =
      document.querySelectorAll('div[data-lyrics-container="true"]');
  if (containers.isEmpty) return '';

  final out = <String>[];
  for (final container in containers) {
    // Genius mete dentro del propio contenedor de letra un bloque de
    // cabecera (Contributors, Translations, descripción "Read More") marcado
    // con `data-exclude-from-selection`. Si no lo quitamos, aparece como si
    // fuera letra al principio de la canción.
    for (final excluded
        in container.querySelectorAll('[data-exclude-from-selection]')) {
      excluded.remove();
    }
    var html = container.innerHtml;
    html = html.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    // Bloques y cabeceras a su propia línea.
    html = html.replaceAll(RegExp(r'</(div|p)>', caseSensitive: false), '\n');
    final text = _stripTags(html);
    void push(String chunk) {
      // Desescapa entidades (&amp;, &quot;...) con el propio parser HTML.
      final lines =
          (html_parser.parseFragment(chunk).text ?? chunk).split('\n');
      for (final line in lines) {
        final trimmed = line.trim();
        // Colapsamos huecos múltiples pero conservamos uno simple.
        if (trimmed.isEmpty) {
          if (out.isEmpty || out.last.isNotEmpty) out.add('');
        } else {
          out.add(trimmed);
        }
      }
    }

    push(text);
  }

  // Recorte de huecos al inicio/fin y colapso final.
  while (out.isNotEmpty && out.first.isEmpty) {
    out.removeAt(0);
  }
  while (out.isNotEmpty && out.last.isEmpty) {
    out.removeLast();
  }
  return out.join('\n');
}

/// Quita etiquetas HTML dejando el texto (los `\n` ya insertados quedan).
String _stripTags(String html) {
  return html.replaceAll(RegExp(r'<[^>]*>'), '');
}
