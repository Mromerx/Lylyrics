import '../core/models/lyrics.dart';

/// Metadatos de cabecera de un fichero LRC (`[ar:]`, `[ti:]`, ...).
///
/// Nota sobre [length]: el enunciado del contrato lo agrupaba con los `String`
/// (`artist, title, album, length`), pero el requisito de parseo dice
/// explícitamente "[length:] se parsea a Duration", así que [length] es un
/// [Duration]. El texto crudo sigue disponible en [rawLength] por si a alguien
/// le hace falta mostrarlo tal cual.
class LrcMetadata {
  const LrcMetadata({
    this.artist,
    this.title,
    this.album,
    this.length,
    this.rawLength,
    this.author,
    this.creator,
    this.offset,
    this.extraTags = const {},
  });

  /// `[ar:]` — artista.
  final String? artist;

  /// `[ti:]` — título.
  final String? title;

  /// `[al:]` — álbum.
  final String? album;

  /// `[length:]` — duración de la pista, ya convertida.
  ///
  /// Acepta `mm:ss`, `mm:ss.fff` y un número de segundos sueltos.
  final Duration? length;

  /// Texto crudo de `[length:]`, por si [length] resultó ser `null`.
  final String? rawLength;

  /// `[au:]` — autor de la letra (el que la escribió).
  final String? author;

  /// `[by:]` — quién exportó el fichero.
  final String? creator;

  /// `[offset:]` — desfase en milisegundos (puede ser negativo).
  ///
  /// Ya acotado a ±[LrcParser.maxOffsetMs]. Es el desfase que declara el
  /// propio fichero; el desfase manual del usuario vive en `SyncEngine`.
  final Duration? offset;

  /// Tags con clave `clave:valor` que no son de las conocidas (`[re:]`,
  /// `[ve:]`, `[tool:]`, `[encoding:]`, `[lang:]`, ...).
  final Map<String, String> extraTags;

  /// Etiquetas con campo propio en esta clase.
  static const Set<String> knownTags = {
    'ar',
    'ti',
    'al',
    'au',
    'by',
    'length',
    'offset',
  };

  /// `true` si no se reconoció ningún campo (el texto no traía cabecera).
  bool get isEmpty =>
      artist == null &&
      title == null &&
      album == null &&
      length == null &&
      rawLength == null &&
      author == null &&
      creator == null &&
      offset == null &&
      extraTags.isEmpty;

  /// `true` si hay al menos un campo reconocido.
  bool get isNotEmpty => !isEmpty;

  @override
  bool operator ==(Object other) =>
      other is LrcMetadata &&
      other.artist == artist &&
      other.title == title &&
      other.album == album &&
      other.length == length &&
      other.rawLength == rawLength &&
      other.author == author &&
      other.creator == creator &&
      other.offset == offset &&
      _mapEquals(other.extraTags, extraTags);

  @override
  int get hashCode => Object.hash(
    artist,
    title,
    album,
    length,
    rawLength,
    author,
    creator,
    offset,
    Object.hashAllUnordered(
      extraTags.entries.map((e) => Object.hash(e.key, e.value)),
    ),
  );

  @override
  String toString() =>
      'LrcMetadata(artist: $artist, title: $title, '
      'album: $album, length: $length, offset: $offset)';
}

/// Comparación de mapas sin `dart:collection` ni `package:collection`.
bool _mapEquals(Map<String, String> a, Map<String, String> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (!b.containsKey(entry.key) || b[entry.key] != entry.value) return false;
  }
  return true;
}

/// Resultado de [LrcParser.parse].
///
/// [lines] viene SIEMPRE ordenada por tiempo ascendente y con orden estable
/// entre líneas empatadas (conserva el orden del fichero), porque el
/// [Lyrics] que se entrega a la UI se usa tal cual para pintar.
class LrcParseResult {
  const LrcParseResult({
    required this.lines,
    required this.metadata,
    required this.ignoredLines,
  });

  /// Resultado vacío: texto sin ninguna marca de tiempo utilizable.
  const LrcParseResult.empty()
    : lines = const <LyricLine>[],
      metadata = null,
      ignoredLines = const <String>[];

  /// Líneas con tiempo, ordenadas. Incluye las vacías (pausas instrumentales).
  final List<LyricLine> lines;

  /// Cabecera reconocida, o `null` si el texto no traía ninguna.
  final LrcMetadata? metadata;

  /// Líneas con contenido que NO se pudieron interpretar (sin timestamp, o
  /// con timestamp malformado). Las líneas en blanco no se registran aquí:
  /// son separadores, no contenido.
  final List<String> ignoredLines;

  /// `true` si hay al menos una línea con tiempo (letra sincronizada).
  bool get isSynced => lines.isNotEmpty;

  /// `true` si el fichero declaraba un `[offset:]`.
  bool get hasOffset => (metadata?.offset ?? Duration.zero) != Duration.zero;

  /// Las mismas líneas de [lines], con el texto plano de las líneas que sí
  /// tienen contenido. Para letra sincronizada no aporta nada (LRCLIB ya trae
  /// su propio `plainText`), pero sirve si hay que buscar o depurar.
  String get plainText =>
      lines.where((l) => !l.isBlank).map((l) => l.text).join('\n');

  /// Conversión directa a [Lyrics] para el pipeline de la app.
  Lyrics toLyrics({bool instrumental = false}) =>
      Lyrics(lines: lines, isSynced: isSynced, instrumental: instrumental);

  @override
  bool operator ==(Object other) =>
      other is LrcParseResult &&
      _listEquals(other.lines, lines) &&
      other.metadata == metadata &&
      _listEquals(other.ignoredLines, ignoredLines);

  @override
  int get hashCode => Object.hash(
    Object.hashAll(lines),
    metadata,
    Object.hashAll(ignoredLines),
  );

  @override
  String toString() =>
      'LrcParseResult(lines: ${lines.length}, '
      'ignored: ${ignoredLines.length}, metadata: $metadata)';
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Una línea con tiempo antes de aplicar el `[offset:]` global.
class _Entry {
  const _Entry({
    required this.time,
    required this.text,
    required this.sequence,
  });

  final Duration time;
  final String text;

  /// Índice de lectura en el fichero. Desempata cuando dos líneas tienen el
  /// mismo tiempo, para que el orden sea ESTABLE (y no dependa del algoritmo
  /// de ordenación, que en Dart no es estable).
  final int sequence;
}

/// Parser de letras LRC (`[mm:ss.xx] Texto`).
///
/// Tolera lo que se encuentra en la realidad: CRLF, BOM de UTF-8, varios
/// timestamps por línea, timestamps sin corchetes, coma decimal, espacios
/// dentro del timestamp, minutos de más de 59, cabeceras de metadatos en la
/// misma línea que el texto y textos desordenados en el tiempo. Ante basura
/// nunca lanza: lo que no entiende va a [LrcParseResult.ignoredLines].
class LrcParser {
  const LrcParser();

  /// Tope del `[offset:]`: ±5 s. Valores locos se acotan a este rango.
  static const int maxOffsetMs = 5000;

  /// `mm:ss`, `mm:ss.x`, `mm:ss.xx`, `mm:ss.xxx` (coma o punto decimal).
  /// Los grupos 1..3 son minutos, segundos y fracción; la misma estructura
  /// que usa [_bareTimestampRe] para no duplicar la lógica.
  static final RegExp _timestampRe = RegExp(
    r'^(\d{1,4})\s*:\s*(\d{1,2})(?:[.,](\d{1,3}))?$',
  );

  /// Igual que [_timestampRe] pero anclado al principio y con la condición de
  /// que detrás haya un espacio o el final de la línea, para no comerse
  /// media palabra: `00:12.00 Texto` sí, `00:12.00Texto` no.
  static final RegExp _bareTimestampRe = RegExp(
    r'^(\d{1,4})\s*:\s*(\d{1,2})(?:[.,](\d{1,3}))?(?=\s|$)',
  );

  /// `[clave:valor]` de cabecera. La clave empieza por letra o `_`.
  static final RegExp _tagRe = RegExp(
    r'^([A-Za-z_][A-Za-z0-9_\- ]{0,15})\s*:\s*(.*)$',
  );

  /// `mm:ss[.fff]` para `[length:]`.
  static final RegExp _lengthRe = RegExp(
    r'^(\d{1,4}):([0-5]?\d)(?:[.,](\d{1,3}))?$',
  );

  /// Caracteres de control que no aportan nada al texto (se quitan). Se
  /// conservan tabulador y salto de línea.
  static final RegExp _controlRe = RegExp(
    '[\u0000-\u0008\u000B\u000C'
    '\u000E-\u001F\u007F]',
  );

  /// Parsea un LRC completo.
  ///
  /// Reglas relevantes:
  /// * `[00:12.00][01:20.30]Texto` -> DOS [LyricLine].
  /// * `[00:20.00]` sin texto -> línea vacía conservada (pausa instrumental).
  /// * El `[offset:]` del fichero se suma a TODAS las líneas. Puede dejar
  ///   tiempos negativos: eso es correcto (la línea ya está activa en el
  ///   segundo 0) y el buscador lo maneja.
  /// * Las líneas con contenido pero sin timestamp válido van a
  ///   [LrcParseResult.ignoredLines]; las líneas solo-etiqueta y las líneas en
  ///   blanco no cuentan.
  LrcParseResult parse(String raw) {
    final source = _sanitize(raw);
    if (source.trim().isEmpty) return const LrcParseResult.empty();

    final entries = <_Entry>[];
    final ignored = <String>[];
    final tags = <String, String>{};
    var sequence = 0;

    for (final line in source.split('\n')) {
      if (line.trim().isEmpty) continue;

      final times = <Duration>[];
      var tagCount = 0;
      var rest = line;

      // Se consumen tokens de cabecera mientras los haya al principio:
      // timestamps entre corchetes, tags `clave:valor` y timestamps sueltos.
      while (true) {
        final probe = rest.trimLeft();
        if (probe.isEmpty) break;

        if (probe.startsWith('[')) {
          final close = probe.indexOf(']');
          if (close < 0) break; // corchete sin cerrar: no se interprete
          final inner = probe.substring(1, close).trim();

          // Un `[]` vacío no significa nada pero sí separa: se salta para que
          // `[00:20.00][]` siga siendo una pausa instrumental.
          if (inner.isEmpty) {
            rest = probe.substring(close + 1);
            continue;
          }

          final time = parseTimestamp(inner);
          final tag = time == null ? _tagRe.firstMatch(inner) : null;

          // Un `[algo]` que no es timestamp ni `clave:valor` es TEXTO: se
          // deja de mirar cabeceras y la línea sigue con lo que queda, así
          // una letra que empieza por corchete no pierde nada.
          if (time == null && tag == null) break;

          rest = probe.substring(close + 1);
          if (time != null) {
            times.add(time);
            continue;
          }

          final key = tag!.group(1)!.trim().toLowerCase();
          // Si una clave viene repetida gana la primera: es la que suele
          // valer y evita que un tag al final pise la cabecera buena.
          tags.putIfAbsent(key, () => tag.group(2) ?? '');
          tagCount++;
          continue;
        }

        final bare = _bareTimestampRe.firstMatch(probe);
        if (bare == null) break;
        final time = _timeFromMatch(bare);
        if (time == null) break;
        times.add(time);
        rest = probe.substring(bare.end);
      }

      final content = rest.trim();

      if (times.isEmpty) {
        // Línea solo de metadatos (`[ar:...]`) o solo separadores: no es una
        // línea de letra, así que no se marca como ignorada.
        if (content.isEmpty && tagCount > 0) continue;
        ignored.add(line);
        continue;
      }

      for (final time in times) {
        entries.add(_Entry(time: time, text: content, sequence: sequence++));
      }
    }

    final offset = parseOffset(tags['offset'] ?? '');
    final shift = offset ?? Duration.zero;

    // Orden por tiempo ascendente y, a igualdad de tiempo, por orden de
    // lectura (estable). Nunca se comparan textos.
    entries.sort((a, b) {
      final diff = a.time.compareTo(b.time);
      return diff != 0 ? diff : a.sequence.compareTo(b.sequence);
    });

    final lines = List<LyricLine>.unmodifiable([
      for (final entry in entries)
        LyricLine(time: entry.time + shift, text: entry.text),
    ]);

    return LrcParseResult(
      lines: lines,
      metadata: _buildMetadata(tags, offset),
      ignoredLines: List<String>.unmodifiable(ignored),
    );
  }

  /// Azúcar: solo las líneas, sin metadatos ni ignoradas.
  static List<LyricLine> parseSynced(String raw) =>
      const LrcParser().parse(raw).lines;

  /// Convierte un token de timestamp a [Duration], o `null` si no lo es.
  ///
  /// Acepta `[mm:ss.xx]`, `mm:ss.xxx`, `mm:ss`, con espacios dentro
  /// (`[00:12.00 ]`) y con coma decimal (`00:12,50` -> 12,5 s). Los minutos
  /// pueden pasar de 59; los segundos no (un `00:75.00` está mal formado).
  static Duration? parseTimestamp(String token) {
    var t = token.trim();
    if (t.startsWith('[') || t.endsWith(']')) {
      if (t.length < 2 || !t.startsWith('[') || !t.endsWith(']')) return null;
      t = t.substring(1, t.length - 1).trim();
    }
    if (t.isEmpty) return null;
    return _timeFromMatch(_timestampRe.firstMatch(t));
  }

  /// Convierte el valor de `[length:]` a [Duration].
  ///
  /// Acepta `03:41`, `3:41.5` y segundos sueltos (`221` o `221.4`).
  /// Devuelve `null` si no hay un número detrás.
  static Duration? parseLength(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;

    final m = _lengthRe.firstMatch(s);
    if (m != null) {
      final minutes = int.parse(m.group(1)!);
      final seconds = int.parse(m.group(2)!);
      final frac = m.group(3);
      var ms = 0;
      if (frac != null) {
        final d = int.parse(frac);
        ms = switch (frac.length) {
          1 => d * 100,
          2 => d * 10,
          _ => d,
        };
      }
      return Duration(milliseconds: minutes * 60000 + seconds * 1000 + ms);
    }

    final seconds = double.tryParse(s.replaceAll(',', '.'));
    if (seconds == null || !seconds.isFinite || seconds < 0) return null;
    return Duration(milliseconds: (seconds * 1000).round());
  }

  /// Convierte el valor de `[offset:]` (milisegundos, puede venir con signo)
  /// a [Duration], acotado a ±[maxOffsetMs]. `null` si no es un entero.
  static Duration? parseOffset(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    final ms = int.tryParse(s);
    if (ms == null) return null;
    return Duration(milliseconds: ms.clamp(-maxOffsetMs, maxOffsetMs).toInt());
  }

  /// Normaliza la entrada: quita el BOM de UTF-8, unifica CRLF/CR en LF y
  /// borra caracteres de control inútiles.
  static String _sanitize(String raw) {
    var s = raw.replaceAll('\uFEFF', '');
    s = s.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    return s.replaceAll(_controlRe, '');
  }

  /// Construye los metadatos a partir de los tags detectados.
  static LrcMetadata? _buildMetadata(
    Map<String, String> tags,
    Duration? offset,
  ) {
    if (tags.isEmpty && offset == null) return null;

    String? value(String key) {
      final raw = tags[key];
      if (raw == null) return null;
      final trimmed = raw.trim();
      return trimmed.isEmpty ? null : trimmed;
    }

    final extra = <String, String>{
      for (final entry in tags.entries)
        if (!LrcMetadata.knownTags.contains(entry.key)) entry.key: entry.value,
    };

    final metadata = LrcMetadata(
      artist: value('ar'),
      title: value('ti'),
      album: value('al'),
      author: value('au'),
      creator: value('by'),
      length: parseLength(tags['length'] ?? ''),
      rawLength: value('length'),
      offset: offset,
      extraTags: Map<String, String>.unmodifiable(extra),
    );
    return metadata.isEmpty ? null : metadata;
  }

  /// Construye el [Duration] de un match con los grupos
  /// (minutos, segundos, fracción). `null` si los segundos no valen.
  static Duration? _timeFromMatch(RegExpMatch? m) {
    if (m == null) return null;
    final minutes = int.parse(m.group(1)!);
    final seconds = int.parse(m.group(2)!);
    if (seconds > 59) return null;

    var ms = 0;
    final frac = m.group(3);
    if (frac != null) {
      final digits = int.parse(frac);
      ms = switch (frac.length) {
        1 => digits * 100,
        2 => digits * 10,
        _ => digits,
      };
    }
    return Duration(milliseconds: minutes * 60000 + seconds * 1000 + ms);
  }
}
