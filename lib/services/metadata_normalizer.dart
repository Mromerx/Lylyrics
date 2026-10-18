import '../core/models/track_info.dart';

/// Un candidato a consulta contra LRCLIB.
///
/// La idea es que el proveedor pruebe los candidatos en orden hasta dar con
/// la letra; por eso cada candidato lleva su [confidence] (0..100) y la lista
/// devuelta por `MetadataNormalizer.candidates` viene ordenada de mayor a
/// menor probabilidad.
class TitleCandidate {
  const TitleCandidate({
    required this.artist,
    required this.title,
    required this.confidence,
  });

  /// Artista a consultar, o `null` para una búsqueda por título solamente.
  ///
  /// Nunca debe ser un nombre inventado: si el artista no es fiable se
  /// devuelve `null` y se delega el trabajo al título.
  final String? artist;

  /// Título a consultar (preferiblemente ya limpio de etiquetas).
  final String title;

  /// Confianza estimada, 0..100. Los candidatos se ordenan de mayor a menor.
  final int confidence;

  /// `true` si el candidato lleva artista.
  bool get hasArtist => artist != null && artist!.trim().isNotEmpty;

  /// Clave de comparación: par artista+título normalizado.
  ///
  /// Sirve para deduplicar candidatos equivalentes ("Bad Bunny" / "bad  bunny"
  /// y "Bad Bunny" son el mismo candidato).
  String get compareKey =>
      '${MetadataNormalizer.normalizeForCompare(artist ?? '')}'
      '|${MetadataNormalizer.normalizeForCompare(title)}';

  @override
  bool operator ==(Object other) =>
      other is TitleCandidate &&
      other.artist == artist &&
      other.title == title &&
      other.confidence == confidence;

  @override
  int get hashCode => Object.hash(artist, title, confidence);

  @override
  String toString() =>
      'TitleCandidate(artist: $artist, title: "$title", conf: $confidence)';
}

/// Resultado de intentar separar "Artista - Canción" dentro del propio título.
class ArtistTitleSplit {
  const ArtistTitleSplit({
    required this.artist,
    required this.title,
    this.separator,
  });

  /// Parte izquierda del separador, o `null` si no se encontró un artista
  /// creíble dentro del título.
  final String? artist;

  /// Parte del título que queda tras el separador (o el título entero).
  final String title;

  /// Separador encontrado (`" - "`, `" | "`, `": "`, ...), informativo.
  final String? separator;

  /// `true` si se detectó "Artista - Canción".
  bool get hasSplit => artist != null;

  @override
  bool operator ==(Object other) =>
      other is ArtistTitleSplit &&
      other.artist == artist &&
      other.title == title &&
      other.separator == separator;

  @override
  int get hashCode => Object.hash(artist, title, separator);

  @override
  String toString() =>
      'ArtistTitleSplit(artist: $artist, title: "$title", sep: $separator)';
}

/// Limpia los metadatos sucios que llegan de YouTube y produce una lista
/// ordenada de candidatos para consultar LRCLIB.
///
/// El problema: los reproductores entregar títulos como
/// `"KAROL G - PROVENZA (Official Video)"`, `"Bad Bunny - Tití Me Preguntó
/// (Official Video)"` con artista `"Bad Bunny - Topic"`, o
/// `"Quevedo: BZRP Music Sessions, Vol. 52 - Resaca (Letra)"`. En LRCLIB la
/// pista se llama `"Provenza"` y el artista `"KAROL G"`.
///
/// Estrategia: no se intenta adivinar una única respuesta "correcta", sino
/// generar varios candidatos y que el proveedor los pruebe en orden.
class MetadataNormalizer {
  MetadataNormalizer();

  // ---------------------------------------------------------------------
  // Expresiones regulares internas
  // ---------------------------------------------------------------------

  /// Grupo de etiqueta delimitado por paréntesis, corchetes o llaves.
  static final RegExp _tagRe = RegExp(r'[\(\[\{]([^\(\)\[\]\{\}]*)[\)\]\}]');

  /// Marcadores de artista invitado: `feat.`, `ft.`, `featuring`, `with`,
  /// `con`.
  static final RegExp _featuredRe = RegExp(
    r'\b(?:feat|ft|featuring|with|con)\b\.?\s*',
    caseSensitive: false,
  );

  /// Marcadores de colaboración: `A x B`, `A y B`, `A vs B`.
  ///
  /// `&` y `and` quedan fuera a propósito: "Simon & Garfunkel",
  /// "Earth, Wind & Fire" o "Simon and Garfunkel" son nombres de artista
  /// completos, no un artista con invitado.
  static final RegExp _collabRe = RegExp(
    r'\s+(?:x|y|vs\.?)\s+',
    caseSensitive: false,
  );

  /// Separador "Artista - Canción": exige espacios a ambos lados para no
  /// romper "AC/DC", "Jay-Z", "Al-alpha", "Snoop-Dog" ni "Spider-Man".
  static final RegExp _sepRe = RegExp(r'\s+[-–—|]\s+');

  /// Separador "Artista: Canción" (dos puntos pegados a la palabra y seguidos
  /// de espacio).
  static final RegExp _colonRe = RegExp(r':\s+');

  /// Palabras que hacen que un paréntesis/corchete aporte información musical
  /// real y por tanto se conserve: feat, with, edit, remix, version, live,
  /// acoustic, instrumental, variation, ...
  static final RegExp _keepTagRe = RegExp(
    r'\b(?:feat|ft|featuring|with|edit|edition|remix|remixes|mix|bootleg|'
    r'demo|reprise|version|versions|variation|variations|live|acoustic|'
    r'acustico|acustica|instrumental|karaoke|vip|vol|pt|part|speed|slowed|'
    r'sped|reverb|vivo|directo|radio|promo)\b',
  );

  /// Token suelto de calidad que sí se puede quitar al final del título
  /// ("Song 4K", "Song HD"). Deliberadamente corto para no comerse títulos
  /// legítimos como "The Video" o "TV Girl".
  static const Set<String> _singleTailNoise = {
    'hd',
    'hq',
    'sd',
    '4k',
    '2k',
    '8k',
    '1080',
    '1080p',
    '720',
    '720p',
    '480p',
    'mv',
    'm v',
    'oficial',
  };

  /// Palabras de marketing/calidad que forman una cola de 2 o 3 tokens
  /// eliminable ("Song Official Video", "Letra Oficial Video HD").
  static const Set<String> _tailNoise = {
    ..._singleTailNoise,
    'official',
    'music',
    'video',
    'audio',
    'visualizer',
    'visualizador',
    'lyric',
    'lyrics',
    'lyricvideo',
    'letra',
    'letras',
    'full',
    'high',
    'quality',
    'calidad',
    'version',
    'trailer',
    'preview',
    'out',
  };

  /// Sufijos de nombre de canal que se pueden quitar del ARTISTA
  /// ("Bad Bunny - Topic", "WISIN VEVO", "Karol G Records 2").
  static const Set<String> _artistTailNoise = {
    'topic',
    'vevo',
    'official',
    'oficial',
    'records',
    'recordz',
    'music',
    'musica',
    'musicas',
    'musico',
    'tv',
    'television',
    'channel',
    'canal',
    'audio',
    'video',
    'visualizer',
    'musicvideo',
    'officialmusic',
    'officialvideo',
  };

  /// Marcadores de canal buscados como subcadena del nombre normalizado.
  ///
  /// "Música" se busca también sin tilde porque [normalizeForCompare] la
  /// pliega a "musica", que no contiene "music".
  static const Set<String> _channelMarkers = {
    'topic',
    'vevo',
    'official',
    'oficial',
    'records',
    'recordz',
    'music',
    'musica',
    'musicas',
    'musico',
    'channel',
    'canal',
    'visualizer',
  };

  /// Tokens que solo delatan un canal si están AL FINAL del nombre, para no
  /// destrozar artistas reales como "TV Girl" o "Alan Walker".
  static const Set<String> _channelTailTokens = {
    'tv',
    'television',
    'hd',
    'tvs',
    'radio',
  };

  /// Nombres completos que son marcadores de "no sé el artista".
  ///
  /// Se comparan enteros porque 'Unknown Mortal Orchestra' es un grupo real y
  /// no debe descartarse por contener "unknown".
  static const Set<String> _unknownArtists = {
    'unknown',
    'unknownartist',
    'desconocido',
    'desconocidoartista',
    'artista',
    'artistanombre',
    'variosartistas',
    'variousartists',
  };

  /// Pliegue de caracteres a su equivalente sin diacríticos.
  static const Map<String, String> _folds = {
    'á': 'a',
    'à': 'a',
    'ä': 'a',
    'â': 'a',
    'ã': 'a',
    'å': 'a',
    'ā': 'a',
    'ă': 'a',
    'ą': 'a',
    'é': 'e',
    'è': 'e',
    'ë': 'e',
    'ê': 'e',
    'ē': 'e',
    'ĕ': 'e',
    'ė': 'e',
    'ę': 'e',
    'ě': 'e',
    'í': 'i',
    'ì': 'i',
    'ï': 'i',
    'î': 'i',
    'ī': 'i',
    'į': 'i',
    'ı': 'i',
    'ó': 'o',
    'ò': 'o',
    'ö': 'o',
    'ô': 'o',
    'õ': 'o',
    'ø': 'o',
    'ō': 'o',
    'ő': 'o',
    'ú': 'u',
    'ù': 'u',
    'ü': 'u',
    'û': 'u',
    'ū': 'u',
    'ů': 'u',
    'ñ': 'n',
    'ń': 'n',
    'ň': 'n',
    'ç': 'c',
    'ć': 'c',
    'č': 'c',
    'ý': 'y',
    'ÿ': 'y',
    'š': 's',
    'ś': 's',
    'ș': 's',
    'ž': 'z',
    'ź': 'z',
    'ż': 'z',
    'ğ': 'g',
    'ģ': 'g',
    'ď': 'd',
    'ł': 'l',
    'æ': 'ae',
    'œ': 'oe',
    'ß': 'ss',
    'þ': 'th',
    'ð': 'd',
    'µ': 'u',
  };

  static final RegExp _wordRe = RegExp(r'[0-9a-z]+');
  static final RegExp _digitEndRe = RegExp(r'\d$');
  static final RegExp _spaceRe = RegExp(r'\s+');
  static final RegExp _digitsRe = RegExp(r'^\d+$');
  static final RegExp _trailingSepRe = RegExp(r'\s+[-–—|:,]+\s*$');
  static final RegExp _leadingSepRe = RegExp(r'^[\s\-–—|:,]+');
  static final RegExp _artistEdgeSepRe = RegExp(r'^[\s\-–—|:,.&]+');
  static final RegExp _gluedTailRe = RegExp(
    r'(?:officialmusic|officialvideo|official|oficial|topic|vevo)$',
    caseSensitive: false,
  );

  // ---------------------------------------------------------------------
  // Normalización genérica (pública: la reutiliza el proveedor LRCLIB)
  // ---------------------------------------------------------------------

  /// Normaliza una cadena para comparaciones: minúsculas, sin tildes ni
  /// signos de puntuación y con espacios colapsados.
  ///
  /// Cubre español e inglés: `áéíóúüñÁÉÍÓÚÜÑ`, `ç`, `âêîôû`, `ëï`, etc.
  /// La puntuación se sustituye por espacio para que "Jay-Z" y "Jay Z"
  /// comparen igual.
  static String normalizeForCompare(String s) {
    final lower = s.toLowerCase();
    final buf = StringBuffer();
    for (final rune in lower.runes) {
      final ch = String.fromCharCode(rune);
      if (ch == ' ') {
        buf.write(' ');
        continue;
      }
      final folded = _folds[ch];
      if (folded != null) {
        buf.write(folded);
        continue;
      }
      final isAlnum =
          (rune >= 0x30 && rune <= 0x39) || (rune >= 0x61 && rune <= 0x7a);
      buf.write(isAlnum ? ch : ' ');
    }
    return buf.toString().replaceAll(_spaceRe, ' ').trim();
  }

  /// Palabras (con letras o dígitos) de una cadena ya normalizada.
  static List<String> _wordsOf(String normalized) =>
      _wordRe.allMatches(normalized).map((m) => m.group(0)!).toList();

  /// Nº de palabras del nombre, contando cada lado de una colaboración por
  /// separado ("Bad Bunny x Jhay Cortez" son 2 y 2, no 5).
  static int _nameWordCount(String normalized) {
    var max = 0;
    for (final side in normalized.split(_collabRe)) {
      final n = _wordsOf(side).length;
      if (n > max) max = n;
    }
    return max;
  }

  // ---------------------------------------------------------------------
  // Detección de nombres de canal
  // ---------------------------------------------------------------------

  /// `true` si [raw] parece el nombre de un canal de YouTube y no el nombre
  /// de un artista.
  ///
  /// Motivos: contener "Topic", "VEVO", "Official"/"Oficial", "Records",
  /// terminar en número ("Artista 2"), tener más de 4 palabras, ser
  /// "Unknown"/"Desconocido", o venir vacío.
  static bool looksLikeChannelName(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return true;
    final n = normalizeForCompare(s);
    if (n.isEmpty) return true;
    if (_unknownArtists.contains(n)) return true;
    for (final marker in _channelMarkers) {
      if (n.contains(marker)) return true;
    }
    final words = _wordsOf(n);
    final last = words.isEmpty ? '' : words.last;
    if (_channelTailTokens.contains(last)) return true;
    if (_digitEndRe.hasMatch(n)) return true;
    if (_nameWordCount(n) > 4) return true;
    return false;
  }

  /// `true` si [raw] es un artista utilizable tal cual (no vacío, no canal).
  static bool isReliableArtist(String raw) => !looksLikeChannelName(raw);

  // ---------------------------------------------------------------------
  // Título
  // ---------------------------------------------------------------------

  /// Título limpio de etiquetas de marketing, calidad, idioma y letra.
  ///
  /// Elimina etiquetas entre paréntesis y corchetes siempre que NO aporten
  /// información musical real:
  ///
  /// * Se van: `(Official Video)`, `[Official Audio]`, `(Lyrics)`, `(Letra)`,
  ///   `(Video Oficial)`, `(Letra Oficial)`, `(Audio)`, `(HD)`, `[HD]`, `HD`,
  ///   `4K`, `(Remastered)`, `(Remastered 2011)`, `[Remaster]`,
  ///   `(Subtitulado)`, `(English)`, `(Español)`, `(Video)`,
  ///   `(Official Music Video)`, `(Official Lyric Video)`, `(Full Album)`.
  /// * Se conservan: `(feat. Natti Natasha)`, `(ft. Young Thug)`,
  ///   `(Don Omar Remix)`, `(Radio Edit)`, `(Taylor's Version)`,
  ///   `(Live)`, `(Acoustic)`, `(Instrumental)`, `(Variation)`, `(En Vivo)`,
  ///   `(Acústica)`, `(Deluxe Edition)`.
  ///
  /// También quita la cola suelta equivalente sin paréntesis
  /// ("Provenza Official Video") y sanea separadores sobrantes.
  static String cleanTitle(String raw) {
    var s = _stripNoiseTags(raw);
    s = _stripTailNoise(s);
    s = _tidy(s);
    return s;
  }

  /// Título al que se le quitan TODOS los grupos de paréntesis y corchetes,
  /// incluidos los que sí aportan información ("Style (Taylor's Version)" ->
  /// "Style"), más la cola suelta de marketing ("Blinding Lights 4K" ->
  /// "Blinding Lights"). Es el candidato "sin paréntesis" de confianza 60.
  static String stripAllTags(String raw) =>
      _tidy(_stripTailNoise(_stripNoiseTags(raw, all: true)));

  // ---------------------------------------------------------------------
  // Artista
  // ---------------------------------------------------------------------

  /// Artista principal limpio: sin invitados, sin sufijos de canal y sin
  /// etiquetas.
  ///
  /// `"Bad Bunny - Topic"` -> `"Bad Bunny"`, `"WISIN VEVO"` -> `"WISIN"`,
  /// `"Karol G Records"` -> `"Karol G"`, `"Artista 2"` -> `"Artista"`,
  /// `"WISIN feat. Yandel"` -> `"WISIN"`, `"Bad Bunny x Jhay Cortez"` ->
  /// `"Bad Bunny"`, `"Simon & Garfunkel"` -> `"Simon & Garfunkel"`.
  static String cleanArtist(String raw) {
    final stripped = _stripNoiseTags(raw);
    if (stripped.trim().isEmpty) return '';
    var main = _splitFeatured(stripped)[0];
    main = _stripArtistTail(main);
    final out = _tidyArtist(main);
    if (out.isEmpty) return '';
    return out;
  }

  /// Artista invitado de [raw], o `null` si no hay.
  ///
  /// `"WISIN feat. Yandel"` -> `"Yandel"`,
  /// `"Bad Bunny x Jhay Cortez"` -> `"Jhay Cortez"`,
  /// `"Camila Cabello - Havana ft. Young Thug"` -> `"Young Thug"` (se corta en
  /// el primer separador para no comerse el resto del título).
  static String? featuredPart(String raw) {
    final parts = _splitFeatured(_stripNoiseTags(raw));
    final guest = parts[1].trim();
    return guest.isEmpty ? null : guest;
  }

  /// Artistas invitados que aparecen DENTRO de etiquetas del título.
  ///
  /// `"Nube (con Nathy Peluso)"` -> `["Nathy Peluso"]`,
  /// `"Tití Me Preguntó (feat. Bad Bunny)"` -> `["Bad Bunny"]`.
  /// Son etiquetas que [cleanTitle] elimina (LRCLIB no las guarda), pero el
  /// invitado sirve para el candidato "principal & invitado".
  static List<String> featuredInTags(String raw) {
    final out = <String>[];
    for (final m in _tagRe.allMatches(raw)) {
      final guest = featuredPart(m.group(1) ?? '');
      if (guest == null) continue;
      if (out.every(
        (e) => normalizeForCompare(e) == normalizeForCompare(guest),
      )) {
        out.add(guest);
      }
    }
    return out;
  }

  /// Devuelve `[artista principal, invitado]` separando por feat/ft/with/con
  /// y por colaboraciones `x`/`y`/`vs`.
  static List<String> _splitFeatured(String s) {
    final m = _featuredRe.firstMatch(s);
    if (m != null) {
      final guest = _cutAtSeparator(s.substring(m.end)).trim();
      return [s.substring(0, m.start).trim(), guest];
    }
    final c = _collabRe.firstMatch(s);
    if (c != null) {
      final guest = _cutAtSeparator(s.substring(c.end)).trim();
      return [s.substring(0, c.start).trim(), guest];
    }
    return [s.trim(), ''];
  }

  /// Quita sufijos de canal: " - Topic", " VEVO", " Official", " Records",
  /// " Music", " TV", " 2". Nunca deja la cadena vacía por debajo de un token.
  static String _stripArtistTail(String raw) {
    var s = raw.trim();
    var changed = true;
    while (changed) {
      changed = false;
      final tokens = s.split(_spaceRe).where((t) => t.isNotEmpty).toList();
      if (tokens.length == 1) {
        final n = normalizeForCompare(tokens.first);
        if (_artistTailNoise.contains(n) || _digitsRe.hasMatch(n)) return '';
        final glued = tokens.first.replaceFirst(_gluedTailRe, '');
        return glued.isEmpty ? '' : glued;
      }
      if (tokens.length > 1) {
        final last = tokens.last;
        final n = normalizeForCompare(last);
        if (_artistTailNoise.contains(n) ||
            n.isEmpty ||
            _digitsRe.hasMatch(n)) {
          s = tokens.sublist(0, tokens.length - 1).join(' ');
          changed = true;
          continue;
        }
        final glued = last.replaceFirst(_gluedTailRe, '');
        if (glued != last && _wordsOf(normalizeForCompare(glued)).isNotEmpty) {
          s = (tokens.sublist(0, tokens.length - 1)..add(glued)).join(' ');
          changed = true;
          continue;
        }
      }
      final trimmed = s.replaceAll(_trailingSepRe, '').trim();
      if (trimmed.isNotEmpty && trimmed != s) {
        s = trimmed;
        changed = true;
      }
    }
    return s;
  }

  /// Sanea un artista: colapsa espacios y quita separadores sobrantes al
  /// principio o al final (sin tocar "/", que sí es parte de "AC/DC").
  static String _tidyArtist(String raw) {
    var out = raw.replaceAll(_spaceRe, ' ').trim();
    out = out.replaceAll(_artistEdgeSepRe, '');
    out = out.replaceAll(RegExp(r'[\s\-–—|:,.&]+$'), '');
    return out.replaceAll(_spaceRe, ' ').trim();
  }

  // ---------------------------------------------------------------------
  // Separación "Artista - Canción"
  // ---------------------------------------------------------------------

  /// Artista presente en el propio título, o `null`.
  ///
  /// Atajo sobre [splitTitle] para quien solo necesite el nombre.
  static String? splitArtistTitle(String rawTitle, {String? knownArtist}) =>
      splitTitle(rawTitle, knownArtist: knownArtist).artist;

  /// Separa "Artista - Canción" del propio título.
  ///
  /// Reglas, en este orden:
  /// * Busca el ÚLTIMO separador con espacios alrededor (`" - "`, `" – "`,
  ///   `" — "`, `" | "`) cuya parte izquierda parezca un artista de verdad,
  ///   para no romper ni los guiones internos ("Jay-Z") ni las barras
  ///   ("AC/DC").
  /// * Si la izquierda más a la derecha no vale (parece un canal, tiene más
  ///   de 4 palabras o acaba en número) retrocede al separador anterior:
  ///   así "Shakira - BZRP Music Sessions, Vol. 53 - El Psy, El Autocontrol"
  ///   acaba dando artista "Shakira" y título "BZRP Music Sessions, Vol. 53 -
  ///   El Psy, El Autocontrol" en vez de inventarse un artista.
  /// * Entre las izquierdas válidas manda la más a la derecha que deje la
  ///   parte derecha SIN separadores ("Jay-Z - Biggie Tyga - Jock Rockstar" ->
  ///   "Jock Rockstar"); si hay varias, gana la que coincide con
  ///   [knownArtist] (ignorando el sufijo "- Topic" del canal).
  /// * Si ninguna izquierda vale, prueba el patrón "Artista: Canción".
  static ArtistTitleSplit splitTitle(String rawTitle, {String? knownArtist}) {
    final s = rawTitle.trim();
    if (s.isEmpty) return const ArtistTitleSplit(artist: null, title: '');

    final known = (knownArtist == null || knownArtist.trim().isEmpty)
        ? ''
        : normalizeForCompare(_stripArtistTail(_stripNoiseTags(knownArtist)));

    final valid = <MapEntry<String, RegExpMatch>>[];
    final clean = <MapEntry<String, RegExpMatch>>[];
    for (final m in _sepRe.allMatches(s)) {
      final left = s.substring(0, m.start).trim();
      final right = s.substring(m.end).trim();
      if (left.isEmpty || right.isEmpty) continue;
      if (looksLikeChannelName(left)) continue;
      final entry = MapEntry(left, m);
      valid.add(entry);
      if (!_sepRe.hasMatch(right)) clean.add(entry);
    }
    if (valid.isNotEmpty) {
      final pool = clean.isNotEmpty ? clean : valid;
      var chosen = pool.last;
      if (known.isNotEmpty) {
        for (final entry in pool.reversed) {
          if (_matchesKnownArtist(entry.key, known)) {
            chosen = entry;
            break;
          }
        }
      }
      return ArtistTitleSplit(
        artist: chosen.key,
        title: s.substring(chosen.value.end).trim(),
        separator: chosen.value.group(0),
      );
    }

    final colon = _colonRe.firstMatch(s);
    if (colon != null) {
      final left = s.substring(0, colon.start).trim();
      final right = s.substring(colon.end).trim();
      if (left.isNotEmpty && right.isNotEmpty && !looksLikeChannelName(left)) {
        return ArtistTitleSplit(
          artist: left,
          title: right,
          separator: colon.group(0),
        );
      }
    }

    return ArtistTitleSplit(artist: null, title: s);
  }

  /// `true` si el nombre de artista extraído [left] es el mismo que el
  /// [known] que da el reproductor, ignorando ruido de canal ("- Topic",
  /// "VEVO", "Official").
  static bool _matchesKnownArtist(String left, String known) {
    if (known.isEmpty) return false;
    final n = normalizeForCompare(left);
    if (n == known) return true;
    if (!known.startsWith(n)) return false;
    final rest = normalizeForCompare(
      known.substring(n.length),
    ).split(' ').where((t) => t.isNotEmpty);
    return rest.every(
      (t) => _artistTailNoise.contains(t) || _digitsRe.hasMatch(t),
    );
  }

  // ---------------------------------------------------------------------
  // Candidatos
  // ---------------------------------------------------------------------

  /// Lista ordenada de candidatos (de mayor a menor probabilidad) para
  /// consultar [track] en LRCLIB, sin duplicados por par artista+título
  /// normalizado.
  ///
  /// Orden y motivos (todos los valores son deliberados, no misteriosos):
  ///
  /// | conf. | candidato | por qué |
  /// |-------|-----------|---------|
  /// | 100 | artista fiable + título limpio | lo que casi siempre está en LRCLIB |
  /// | 90 | par **literal** (artista canal + título tal cual) | solo si el título traía "Artista - Canción" y el campo artista es un canal: LRCLIB importa muchas de estas entradas tal cual |
  /// | 85 | artista tal cual venía dentro del título + título limpio | cubre "WISIN feat. Yandel" como artista |
  /// | 80 | `principal & invitado(s)` | LRCLIB a veces guarda la colaboración con " & " |
  /// | 76 | artista fiable + parte derecha si el título limpio aún tiene separador | "Shakira: BZRP ... Vol. 53 - El Psy, El Autocontrol" -> "El Psy, El Autocontrol" |
  /// | 74 | primer segmento del artista del título | "Jay-Z - Biggie Tyga - ..." -> "Jay-Z" |
  /// | 70 | solo título limpio | cuando el artista no es fiable |
  /// | 68 | artista deducido del álbum ("Álbum - ..."), solo si no hay artista fiable | último intento con un dato del propio [TrackInfo] |
  /// | 65 | artista fiable + título **sin** limpiar | entradas de LRCLIB importadas de YouTube |
  /// | 60 | solo título, sin ningún paréntesis | "Style (Taylor's Version)" -> "Style" |
  /// | 55 | artista limpiado aunque el campo fuera un canal | "Bad Bunny - Topic" -> "Bad Bunny" |
  /// | 40 | solo título tal cual venía | respaldo final |
  ///
  /// Si no hay ningún artista fiable, ningún candidato baja de 70 y ninguno
  /// lleva un artista inventado: los candidatos con artista de más de 70
  /// requieren que el propio título o el campo del reproductor aporten el
  /// nombre (o que venga literal de la fuente, el caso 90).
  List<TitleCandidate> candidates(TrackInfo track) {
    final rawTitle = track.title.trim();
    final rawArtist = track.artist.trim();
    final out = <TitleCandidate>[];

    void add(String? artist, String title, int confidence) {
      final t = title.trim();
      if (t.isEmpty) return;
      final a = (artist == null || artist.trim().isEmpty)
          ? null
          : artist.trim();
      final candidate = TitleCandidate(
        artist: a,
        title: t,
        confidence: confidence,
      );
      if (out.any((e) => e.compareKey == candidate.compareKey)) return;
      out.add(candidate);
    }

    final artistReliable = isReliableArtist(rawArtist);
    final split = splitTitle(rawTitle, knownArtist: rawArtist);
    final left = split.artist;
    final leftReliable = left != null && isReliableArtist(left);
    final body = split.title;
    final title = cleanTitle(body);
    final songTitle = title.isEmpty ? body : title;

    String? main;
    final feats = <String>[];
    void addFeature(String? feat) {
      final f = feat?.trim();
      if (f == null || f.isEmpty) return;
      if (feats.any((e) => normalizeForCompare(e) == normalizeForCompare(f))) {
        return;
      }
      feats.add(f);
    }

    if (artistReliable) {
      main = cleanArtist(rawArtist);
      if (main.isEmpty) main = null;
      addFeature(featuredPart(rawArtist));
    }
    if (main == null && leftReliable) {
      main = cleanArtist(left);
      if (main.isEmpty) main = null;
    }
    if (leftReliable) {
      addFeature(featuredPart(left));
    }
    addFeature(featuredPart(body));
    for (final guest in featuredInTags(body)) {
      addFeature(guest);
    }

    // 100 — artista y título de confianza.
    if (main != null) add(main, songTitle, 100);

    // 90 — par literal, solo con canal como artista y "Artista - Canción".
    if (!artistReliable && split.hasSplit && rawArtist.isNotEmpty) {
      add(rawArtist, rawTitle, 90);
    }

    // 85 — artista tal cual venía dentro del título.
    if (leftReliable) add(left, songTitle, 85);

    // 80 — principal & invitados.
    if (main != null && feats.isNotEmpty) {
      add([main, ...feats].join(' & '), songTitle, 80);
    }

    // 76 — el título limpio todavía es "Serie - Canción": probar solo la
    // parte derecha (comunes en las sesiones de BZRP).
    if (main != null && _sepRe.hasMatch(songTitle)) {
      add(main, _cutAtSeparatorLast(songTitle), 76);
    }

    // 74 — el artista del título eran varios segmentos separados por " - ".
    if (leftReliable && _sepRe.hasMatch(left)) {
      final first = cleanArtist(_cutAtSeparator(left));
      if (first.isNotEmpty && isReliableArtist(first)) {
        add(first, songTitle, 74);
      }
    }

    // 70 — solo título.
    add(null, songTitle, 70);

    // 68 — artista deducido del álbum, si el campo artista no era de fiar.
    final album = (track.album ?? '').trim();
    if (main == null && album.isNotEmpty) {
      final albumSplit = splitTitle(album);
      final albumArtist = albumSplit.artist;
      if (albumArtist != null && isReliableArtist(albumArtist)) {
        final a = cleanArtist(albumArtist);
        if (a.isNotEmpty) add(a, songTitle, 68);
      }
    }

    // 65 — artista fiable con el título tal cual (entradas sin limpiar).
    if (main != null) add(main, rawTitle, 65);

    // 60 — solo título sin paréntesis.
    add(null, stripAllTags(body), 60);

    // 55 — el artista venía en un canal, pero se puede limpiar.
    if (!artistReliable && rawArtist.isNotEmpty) {
      add(cleanArtist(rawArtist), songTitle, 55);
    }

    // 40 — solo título tal cual.
    add(null, rawTitle, 40);

    // Orden estable descendente por confidence.
    final ordered =
        <MapEntry<int, TitleCandidate>>[
          for (var i = 0; i < out.length; i++) MapEntry(i, out[i]),
        ]..sort((a, b) {
          final diff = b.value.confidence.compareTo(a.value.confidence);
          return diff != 0 ? diff : a.key.compareTo(b.key);
        });
    return [for (final e in ordered) e.value];
  }

  // ---------------------------------------------------------------------
  // Utilidades internas de texto
  // ---------------------------------------------------------------------

  /// Corta en el primer separador (" - ", " | ", " – ", ...).
  static String _cutAtSeparator(String s) {
    final m = _sepRe.firstMatch(s);
    return m == null ? s : s.substring(0, m.start).trim();
  }

  /// Corta en el último separador ("... Vol. 53 - El Psy" -> "El Psy").
  static String _cutAtSeparatorLast(String s) {
    final all = _sepRe.allMatches(s).toList();
    if (all.isEmpty) return s.trim();
    return s.substring(all.last.end).trim();
  }

  /// Quita los grupos de etiquetas que son ruido.
  ///
  /// Con [all] se quitan todos los grupos, sean de marketing o no.
  static String _stripNoiseTags(String s, {bool all = false}) {
    var out = s;
    var changed = true;
    while (changed) {
      changed = false;
      out = out.replaceAllMapped(_tagRe, (m) {
        final inner = m.group(1) ?? '';
        if (all || !_keepTagRe.hasMatch(normalizeForCompare(inner))) {
          changed = true;
          return ' ';
        }
        return m.group(0)!;
      });
    }
    return _fixUnbalancedBrackets(out);
  }

  /// Sustituye por espacio solo los corchetes que están sin pareja, de modo
  /// que "(Official Video" no deja basura pero "(feat. X)" sobrevive.
  static String _fixUnbalancedBrackets(String s) {
    const openers = '([{';
    final buf = StringBuffer();
    final stack = <int>[];
    for (final rune in s.runes) {
      final ch = String.fromCharCode(rune);
      if (openers.contains(ch)) {
        stack.add(buf.length);
        buf.write(ch);
      } else if (ch == ')' || ch == ']' || ch == '}') {
        if (stack.isEmpty) {
          buf.write(' ');
        } else {
          stack.removeLast();
          buf.write(ch);
        }
      } else {
        buf.write(ch);
      }
    }
    var out = buf.toString();
    for (final idx in stack) {
      if (idx < out.length) {
        out = out.replaceRange(idx, idx + 1, ' ');
      }
    }
    return out;
  }

  /// Quita la cola suelta de 1..3 palabras de marketing/calidad
  /// ("Song Official Video", "Song 4K", "Letra Video HD").
  static String _stripTailNoise(String s) {
    var out = s.trim();
    var changed = true;
    while (changed) {
      changed = false;
      final tokens = out.split(_spaceRe).where((t) => t.isNotEmpty).toList();
      for (final size in const [3, 2, 1]) {
        if (tokens.length <= size) continue;
        final tail = tokens
            .sublist(tokens.length - size)
            .map(normalizeForCompare)
            .toList();
        if (!tail.every(_tailNoise.contains)) continue;
        if (size == 1 && !_singleTailNoise.contains(tail.first)) continue;
        out = tokens.sublist(0, tokens.length - size).join(' ');
        changed = true;
        break;
      }
    }
    return out.trim();
  }

  /// Sanea espacios y separadores sobrantes (sin tocar los corchetes que
  /// siguen emparejados: "(Taylor's Version)" se conserva).
  static String _tidy(String s) {
    var out = s.replaceAll(_spaceRe, ' ');
    out = out.replaceAll(_leadingSepRe, '');
    out = out.replaceAll(RegExp(r'[\s\-–—|:,]+$'), '');
    out = out.replaceAll(RegExp(r'\s*\|\s*'), ' | ');
    out = out.replaceAll(RegExp(r'(?:\s\|\s){2,}'), ' | ');
    // "Who Am I (What's My Name)?" -> "Who Am I?" al quitar la etiqueta.
    out = out.replaceAllMapped(RegExp(r'\s+([?!,;:.])'), (m) => m.group(1)!);
    return out.replaceAll(_spaceRe, ' ').trim();
  }
}
