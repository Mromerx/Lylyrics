import 'dart:convert';

import 'package:http/http.dart' as http;

/// Un segmento alineado que devuelve Google: texto original y su traducción.
///
/// Con `dt=t` el endpoint `gtx` parte la petición en trozos y reporta, por
/// cada uno, el texto ORIGINAL que cubre ([source]) y su traducción
/// ([target]). Esa alineación gratis es la materia prima del emparejamiento
/// palabra-por-palabra ([alignLineTokens] en `token_alignment.dart`).
class TextSegment {
  const TextSegment({required this.source, required this.target});

  /// Texto original que cubre el segmento (con `\n` si cruza líneas).
  final String source;

  /// Su traducción al español (con `\n` si cruza líneas).
  final String target;
}

/// Resultado de traducir la canción completa.
class SongTranslation {
  const SongTranslation({
    required this.translations,
    this.segmentPairs = const {},
  });

  /// Mapa `índice de línea -> traducción de la línea entera`. Omite las
  /// líneas vacías, las traducciones vacías y las traducciones idénticas al
  /// original (nada que mostrar). Pueden faltar líneas.
  final Map<int, String> translations;

  /// Mapa `índice de línea -> segmentos alineados ([TextSegment])` que
  /// Google reportó para esa línea. Líneas pueden faltar: la UI cae al
  /// prior de la línea entera ([translations]).
  final Map<int, List<TextSegment>> segmentPairs;
}

/// Léxico palabra-por-palabra construido con UNA petición.
///
/// * [primary]: `original normalizado -> traducción aislada` (como salía
///   del viejo `translateWordList`); la clave se arma con [normalizeToken],
///   así frases de n-gramas (`give up`) y palabras casan igual.
/// * [senses]: `original normalizado -> sentidos CRUDOS que da Google con
///   `dt=bd` (español, sin normalizar)`. Solo se puebla para palabras
///   pedidas con normalizado de 4+ letras.
class WordLexicon {
  const WordLexicon({required this.primary, this.senses = const {}});

  /// Traducción aislada de cada palabra/frase (.primary para los
  /// consumidores: `original normalizado -> traducción aislada`).
  final Map<String, String> primary;

  /// Sentidos crudos `dt=bd` por palabra (español, sin normalizar), solo
  /// para palabras con normalizado de 4+ letras.
  final Map<String, Set<String>> senses;
}

/// Traducción vía Google Translate (endpoint público `gtx`, sin API key).
///
/// Diseño pedido por el usuario:
/// * **Pocas peticiones por canción** ([translateSong]): la letra se junta
///   con `\n` y se traduce en LOTES contiguos de líneas (`sl=auto`, `tl=es`)
///   lo bastante pequeños para que ninguna URL rebase el límite de longitud
///   ni el tope de ~5000 caracteres por petición, y después se reparte por
///   línea con un `for`. Una canción corta viaja en una sola petición; una
///   larga, en varias; nunca una por línea.
/// * **Detección automática de idioma** y traducción al español.
/// * Si el texto ya está en español, se devuelve resultado vacío (nada que
///   mostrar).
/// * [translateContextualLines] usa un truco de numeración agnóstico al
///   idioma para traducir palabras EN CONTEXTO con pocas peticiones.
class GoogleTranslationService {
  // ignore: prefer_initializing_formals
  GoogleTranslationService({http.Client? client}) : _client = client;

  final http.Client? _client;

  /// Traduce [lines] (toda la canción) al español con pocas peticiones.
  ///
  /// Une las líneas con `\n` y las manda al endpoint `gtx` (`dt=t`) en lotes
  /// contiguos ([_chunkIndices]) que quepan en una URL; una canción corta va
  /// en una sola petición. De la respuesta sale TODO:
  ///
  /// * **[SongTranslation.translations]**: reparto por línea con un `for`
  ///   (la posición N del texto traducido corresponde a la línea N del
  ///   original), con las reglas del viejo `translateLines`: se omiten las
  ///   líneas vacías, las traducciones vacías y las traducciones idénticas
  ///   al original.
  /// * **[SongTranslation.segmentPairs]**: Google devuelve cada segmento
  ///   como `[traducción, texto_original]`; se reparte por línea con un
  ///   puntero acumulativo de `indexOf` sobre el texto unido. Un segmento
  ///   que cabe en UNA línea va completo a esa línea; uno con `\n` que
  ///   cruza líneas se parte (si la cantidad de partes coincide, se reparte
  ///   en orden; si no, se descarta). La concatenación de los sources debe
  ///   reconstruir (aprox., tolerada por espacios en blanco) el texto
  ///   unido: si no cuadra o llega malformado, `segmentPairs` queda vacío
  ///   PERO `translations` sigue funcionando (split por `\n`, como el
  ///   viejo). Líneas sin segmentos no aparecen en `segmentPairs`.
  Future<SongTranslation> translateSong(
    List<String> lines, {
    String target = 'es',
  }) async {
    // Índices de líneas con texto real.
    final targets = <int>[];
    final texts = <String>[];
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].trim().isEmpty) continue;
      targets.add(i);
      texts.add(lines[i]);
    }
    if (texts.isEmpty) return const SongTranslation(translations: {});

    // La canción se traduce en LOTES contiguos de líneas: cada petición lleva
    // un `q` corto, así una canción larga no rebasa el límite de la URL ni el
    // de ~5000 caracteres por petición (que antes la hacía fallar en
    // silencio). Un fallo en un lote no tumba los demás.
    final out = <int, String>{};
    final segmentPairs = <int, List<TextSegment>>{};
    for (final chunk in _chunkIndices(texts)) {
      final chunkTexts = [for (final k in chunk) texts[k]];
      final chunkTargets = [for (final k in chunk) targets[k]];
      final joined = chunkTexts.join('\n');
      final decoded = await _peticion(joined, target: target);
      if (decoded == null) continue;

      // ---- 1. Traducción por línea (reglas del viejo translateLines) ----
      final raw0 = decoded[0];
      final body = _concatenarDt(raw0);
      if (body == null) continue;

      final translatedLines = body.split('\n');
      for (var k = 0; k < chunkTargets.length; k++) {
        final t = k < translatedLines.length ? translatedLines[k].trim() : '';
        if (t.isEmpty) continue;
        // Si la traducción es idéntica al original, no aporta nada.
        if (t.toLowerCase() == chunkTexts[k].trim().toLowerCase()) continue;
        out[chunkTargets[k]] = t;
      }

      // ---- 2. Segmentos alineados (traducción, texto_original) ----
      segmentPairs.addAll(
        _repartirSegmentos(raw0, joined, chunkTexts, chunkTargets, out),
      );
    }
    return SongTranslation(translations: out, segmentPairs: segmentPairs);
  }

  /// Traduce una lista de palabras/frases con pocas peticiones.
  ///
  /// Deduplica las entradas por normalizado (conservando la forma original
  /// para la petición; acotado a ~250) y las reparte en lotes que quepan en
  /// una URL ([_chunkIndices]); cada lote pide `dt=t` Y `dt=bd` en la MISMA
  /// llamada:
  ///
  /// * **`dt=t`** (decoded[0], repartido por `\n`): puebla
  ///   [WordLexicon.primary], igual que el viejo `translateWordList`.
  /// * **`dt=bd`** (decoded[1]): entradas del tipo
  ///   `[palabra, [sentido1, sentido2, ...], ...]`; SOLO se guardan para
  ///   palabras pedidas con [normalizeToken] de 4+ letras, casadas por
  ///   `normalizeToken(entry[0])`, y los sentidos van CRUDOS (español, sin
  ///   normalizar, en orden, `Set<String>`). Decodificación defensiva: si
  ///   `decoded[1]` no es lista o algún shape no cuadra, los sentidos se
  ///   quedan vacíos sin romper; si la respuesta trae `bd` pero la palabra
  ///   no fue pedida, no se guarda nada.
  Future<WordLexicon> translateWordList(
    List<String> words, {
    String target = 'es',
  }) async {
    // Deduplicamos sin distinción de mayúsculas, conservando la forma
    // original para la petición.
    final seen = <String>{};
    final unique = <String>[];
    for (final w in words) {
      final norm = normalizeToken(w);
      if (norm.isEmpty || !seen.add(norm)) continue;
      unique.add(w.trim());
      // Acotamos la URL: con ~250 palabras sobra para cualquier canción.
      if (unique.length >= 250) break;
    }
    if (unique.isEmpty) return const WordLexicon(primary: {});

    final primary = <String, String>{};
    final senses = <String, Set<String>>{};
    // Solo palabras pedidas con normalizado de 4+ letras juegan: para las
    // cortas el banco de sentidos es puro ruido ("no", "the", "oh"...).
    final pedidas = <String>{
      for (final w in unique)
        if (normalizeToken(w).length >= 4) normalizeToken(w),
    };

    // Igual que la canción, la lista se parte en lotes para no rebasar el
    // límite de la URL. Los resultados de todos los lotes se acumulan.
    for (final chunk in _chunkIndices(unique)) {
      final chunkWords = [for (final k in chunk) unique[k]];
      final decoded = await _peticion(
        chunkWords.join('\n'),
        dts: const ['t', 'bd'],
        target: target,
      );
      if (decoded == null) continue;

      // ---- primary: decoded[0], reparto por línea (igual que antes) ----
      final body = _concatenarDt(decoded[0]);
      if (body != null) {
        final translatedLines = body.split('\n');
        for (var k = 0; k < chunkWords.length; k++) {
          final t = k < translatedLines.length ? translatedLines[k].trim() : '';
          if (t.isEmpty) continue;
          primary[normalizeToken(chunkWords[k])] = t;
        }
      }

      // ---- senses: decoded[1], entradas crudas de `dt=bd` ----
      final rawBd = decoded[1];
      if (rawBd is List) {
        for (final entry in rawBd) {
          if (entry is! List || entry.length < 2) continue;
          if (entry[0] is! String || entry[1] is! List) continue;
          final norm = normalizeToken(entry[0] as String);
          if (!pedidas.contains(norm)) continue;
          final set = senses.putIfAbsent(norm, () => <String>{});
          for (final s in entry[1] as List) {
            if (s is String && s.trim().isNotEmpty) set.add(s);
          }
        }
      }
    }
    return WordLexicon(primary: primary, senses: senses);
  }

  /// Traduce los textos de [lines] EN CONTEXTO, palabras por palabras, con
  /// el truco de numeración (agnóstico al idioma).
  ///
  /// Por CADA texto se hace UNA petición (en serie, con `await`) con
  /// `q = "1. W1 2. W2 ... N. WN"` (`W*` = [wordTokens] del texto). Google
  /// traduce cada palabra en su contexto y conserva la numeración; el
  /// resultado por índice de línea del input es la lista de traducciones en
  /// el MISMO orden de los tokens (puede quedar más corta que los tokens:
  /// el consumidor recorta).
  ///
  /// Parseo robusto del target: se detectan marcadores `\d{1,3}` seguidos
  /// de `. ) : º °` (regex tolerante, también números sin puntuación), se
  /// toman las palabras ENTRE marcadores como grupo de cada número y:
  /// * si los números empiezan en 1 y ascienden, mapeo DIRECTO por número
  ///   (el grupo `n` cae en el token `n-1`; números ausentes dejan hueco).
  /// * si no, mapeo PROPORCIONAL *best-effort* ([originalIndexForTranslated]).
  /// * si no hay números (numeración perdida), la lista queda vacía.
  ///
  /// Una línea sin tokens entra con lista vacía. Fallos / timeout de una
  /// petición (10 s) simplemente no aportan entrada (si todo falla, `{}`),
  /// nunca rompen el método.
  Future<Map<int, List<String>>> translateContextualLines(
      List<String> lines,
      {String target = 'es'}) async {
    final out = <int, List<String>>{};
    for (var i = 0; i < lines.length; i++) {
      final tokens = wordTokens(lines[i]);
      if (tokens.isEmpty) {
        out[i] = <String>[];
        continue;
      }
      final numerado = [
        for (var k = 0; k < tokens.length; k++) '${k + 1}. ${tokens[k]}',
      ].join(' ');

      final decoded = await _peticion(numerado, target: target);
      if (decoded == null) continue;
      final texto = _concatenarDt(decoded[0]);
      if (texto == null || texto.trim().isEmpty) continue;
      out[i] = _parsearNumerado(texto, tokens.length);
    }
    return out;
  }

  /// Traduce un texto suelto (una palabra o frase) al español.
  ///
  /// Devuelve `null` si falla o si ya estaba en español / es idéntico.
  Future<String?> translateWord(String word, {String target = 'es'}) async {
    final clean = word.trim();
    if (clean.isEmpty) return null;
    final translated = await translateText(clean, target: target);
    if (translated == null) return null;
    final t = translated.trim();
    if (t.isEmpty) return null;
    if (t.toLowerCase() == clean.toLowerCase()) return null;
    return t;
  }

  /// Petición única al endpoint `gtx`. Devuelve el texto traducido completo
  /// o `null` si falla / el origen ya es español.
  Future<String?> translateText(String text, {String target = 'es'}) async {
    final decoded = await _gtx(text, target: target);
    if (decoded == null) return null;
    return _concatenarDt(decoded[0]);
  }

  /// Petición común `gtx` con respuesta DECODIFICADA para los métodos de
  /// arriba (los códigos `dt` deciden las partes que se piden).
  ///
  /// Devuelve `null` si: el texto queda vacío, falla la red / el timeout
  /// (10 s) / el estado, el JSON no es una lista razonable o el idioma
  /// detectado es `es` (nada que traducir).
  Future<List?> _peticion(
    String text, {
    List<String> dts = const ['t'],
    String target = 'es',
  }) =>
      _gtx(text, dts: dts, target: target);

  /// Presupuesto de `q` ya codificado para la URL, por petición. Deja margen
  /// sobrado bajo el límite de ~2 KB habitual y muy por debajo del tope de
  /// ~5000 caracteres de texto del endpoint.
  static const int _maxEncodedQuery = 1500;

  /// Reparte [texts] en lotes contiguos de índices cuyo `q` codificado no
  /// supera [_maxEncodedQuery]. Una entrada que por sí sola ya lo supera
  /// viaja sola (no se puede partir: el reparto por línea depende de los
  /// `\n`).
  List<List<int>> _chunkIndices(List<String> texts) {
    final chunks = <List<int>>[];
    var current = <int>[];
    var size = 0;
    for (var i = 0; i < texts.length; i++) {
      // +3 por el '\n' que separa las entradas al unirlas.
      final cost = Uri.encodeComponent(texts[i]).length + 3;
      if (current.isNotEmpty && size + cost > _maxEncodedQuery) {
        chunks.add(current);
        current = <int>[];
        size = 0;
      }
      current.add(i);
      size += cost;
    }
    if (current.isNotEmpty) chunks.add(current);
    return chunks;
  }

  /// ÚNICO lugar que construye la petición a Google (`gtx`).
  ///
  /// El `q` viaja en la URL (GET), por lo que los llamadores DEBEN partir el
  /// texto en lotes pequeños: [translateSong] y [translateWordList] lo hacen
  /// con [_chunkIndices], de modo que ninguna URL supera
  /// [_maxEncodedQuery] caracteres codificados ni el límite de ~5000
  /// caracteres por petición del endpoint. `translateText` y las líneas
  /// contextuales son unidades cortas y se mandan sueltas.
  ///
  /// Cierra el cliente solo si fue suyo (el [http.Client] inyectado lo
  /// maneja su dueño).
  Future<List?> _gtx(
    String text, {
    List<String> dts = const ['t'],
    String target = 'es',
  }) async {
    final clean = text.trim();
    if (clean.isEmpty) return null;
    final client = _client ?? http.Client();
    final shouldClose = _client == null;
    try {
      var qs = 'client=gtx&sl=auto&tl=$target';
      for (final dt in dts) {
        qs += '&dt=$dt';
      }
      final uri = Uri.parse(
        'https://translate.googleapis.com/translate_a/single'
        '?$qs&q=${Uri.encodeComponent(clean)}',
      );
      final resp = await client
          .get(uri, headers: {'User-Agent': 'Lylyrics/0.1.0'})
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return null;
      final decoded = jsonDecode(resp.body);
      if (decoded is! List || decoded.isEmpty) return null;

      // Idioma detectado: decoded[2] suele ser el código ("en", "es"...).
      final detected = decoded.length > 2 ? decoded[2]?.toString() : null;
      if (detected == target) return null;
      return decoded;
    } catch (_) {
      return null;
    } finally {
      if (shouldClose) client.close();
    }
  }

  /// Concatena los `decoded[0]` de `dt=t` en el texto traducido completo
  /// (los segmentos traen `[traducción, original, ...]`; solo la primera
  /// casilla importa). Devuelve `null` si el shape no es lista.
  String? _concatenarDt(Object? raw0) {
    final segments = raw0;
    if (segments is! List) return null;
    final buf = StringBuffer();
    for (final seg in segments) {
      if (seg is List && seg.isNotEmpty && seg[0] is String) {
        buf.write(seg[0] as String);
      }
    }
    final result = buf.toString().trim();
    return result.isEmpty ? null : result;
  }

  /// Forma comparable tolerante a espacios en blanco de [s].
  ///
  /// Colapsa toda tirada de espacios en UNO y recorta puntas: así la
  /// validación "los sources reconstruyen el texto unido" no truena por un
  /// espacio extra que se haya colado en el JSON de Google.
  String _reducir(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

  /// Reparte los segmentos `[target, source]` de `dt=t` por línea.
  ///
  /// El texto [joined] es la unión con `\n`; para cada texto de [texts]
  /// se precomputa su offset de arranque. Con un puntero acumulativo de
  /// `indexOf` sobre los sources de [raw0] se ubica cada segmento:
  ///
  /// * dentro de UNA línea: par ([TextSegment]) completo a esa línea;
  /// * con `\n` que cruza líneas: se parten source y target por `\n`; si
  ///   la cantidad de partes coincide, se reparten en orden a las líneas
  ///   consecutivas; si no, el segmento se descarta;
  /// * si la concatenación de sources NO reconstruye (aprox.: tolerado por
  ///   espacios) [joined], o algún segmento llega malformado, se devuelven
  ///   cero pares;
  /// * solo entran pares de líneas con traducción en [out] (las demás, la
  ///   UI las tumba con el prior de línea entera).
  Map<int, List<TextSegment>> _repartirSegmentos(
    Object? raw0,
    String joined,
    List<String> texts,
    List<int> targets,
    Map<int, String> out,
  ) {
    final segmentPairs = <int, List<TextSegment>>{};
    if (raw0 is! List) return segmentPairs;

    // Shapes: si algún segmento llega malformado (no lista, con entradas
    // que no son String, o sin source), se corta aquí: no hay pares.
    final pares = <TextSegment>[];
    for (final seg in raw0) {
      if (seg is! List || seg.length < 2) return segmentPairs;
      if (seg[0] is! String || seg[1] is! String) return segmentPairs;
      final src = seg[1] as String;
      if (src.isEmpty) continue; // segmento fantasma
      pares.add(TextSegment(source: src, target: seg[0] as String));
    }
    if (pares.isEmpty) return segmentPairs;

    // Validación: la concatenación de sources debe reconstruir (aprox.)
    // el texto unido. Con tolerancia a espacios en blanco, porque Google
    // devuelve todos los caracteres del original segmentado a segmento,
    // pero no siempre exacto al pie del espacio.
    var reconstruido = '';
    for (final par in pares) {
      reconstruido += par.source;
    }
    if (_reducir(reconstruido) != _reducir(joined)) return segmentPairs;

    // Offset de arranque de cada texto dentro de [joined].
    final offsets = <int>[];
    var off = 0;
    for (final text in texts) {
      offsets.add(off);
      off += text.length + 1; // +1 por el '\n' del join
    }

    // Puntero acumulativo: los segmentos llegan en orden, así que cada
    // búsqueda usa `indexOf` DESDE donde quedó la anterior; si no aparece
    // (Google entregó uno fuera de orden), se re-busca sobre el texto
    // completo antes de rendirse con ese segmento.
    final porLinea = <int, List<TextSegment>>{}; // clave: pos. en `targets`
    var cursor = 0;
    for (final par in pares) {
      var start = joined.indexOf(par.source, cursor);
      if (start < 0) start = joined.indexOf(par.source);
      if (start < 0) continue; // no se ubicó: se cae este segmento
      cursor = start + par.source.length;

      // Línea que contiene el arranque: la última con offset <= start.
      var k0 = 0;
      for (var k = offsets.length - 1; k >= 0; k--) {
        if (offsets[k] <= start) {
          k0 = k;
          break;
        }
      }
      final finLinea = offsets[k0] + texts[k0].length;
      // Dentro de UNA línea: par completo a esa línea.
      if (start + par.source.length <= finLinea) {
        porLinea.putIfAbsent(k0, () => <TextSegment>[]).add(par);
        continue;
      }

      // Cruza líneas: partir por '\n' y repartir EN ORDEN si las partes
      // cuadran; si no, descartar el segmento entero.
      final srcPartes = par.source.split('\n');
      final tgtPartes = par.target.split('\n');
      if (srcPartes.length != tgtPartes.length) continue;
      for (var p = 0; p < srcPartes.length; p++) {
        final slot = k0 + p;
        if (slot >= offsets.length) break; // se sale: se cae esa parte
        final src = srcPartes[p].trim();
        final tgt = tgtPartes[p].trim();
        if (src.isEmpty || tgt.isEmpty) continue;
        porLinea
            .putIfAbsent(slot, () => <TextSegment>[])
            .add(TextSegment(source: src, target: tgt));
      }
    }

    // Solo líneas con traducción de línea entera (el resto lo tumba la UI).
    for (final entry in porLinea.entries) {
      final lineIdx = targets[entry.key];
      if (!out.containsKey(lineIdx)) continue;
      segmentPairs[lineIdx] = entry.value;
    }
    return segmentPairs;
  }

  /// Parseo del target numerado de [GoogleTranslationService.translateContextualLines].
  ///
  /// Devuelve la lista de traducciones, UN casillero por token original
  /// ([tokenCount] de largo), con `''` donde no llegó traducción (el
  /// consumidor salta los huecos). Si [target] no trae números, devuelve
  /// lista vacía ("numeración perdida", sin mapeo posible).
  List<String> _parsearNumerado(String target, int tokenCount) {
    // Tokens por espacio; el marcador es un número (1-3 dígitos), quizá
    // seguido de puntuación de marcador (`. ) : º °`), como token entero.
    final marcador = RegExp(r'^(\d{1,3})([.):º°]*)$');
    final grupos = <MapEntry<int, String>>[];
    var numero = -1;
    final actuales = <String>[];
    void cerrar() {
      if (numero >= 0) {
        grupos.add(MapEntry(numero, actuales.join(' ').trim()));
        actuales.clear();
      }
    }

    for (final trozo in target.split(RegExp(r'\s+'))) {
      final tok = trozo.trim();
      if (tok.isEmpty) continue;
      final m = marcador.firstMatch(tok);
      if (m != null) {
        // Cierre del grupo anterior y apertura del nuevo.
        cerrar();
        numero = int.parse(m.group(1)!);
        continue;
      }
      // Palabras ANTES del primer marcador: se tumban (no sabemos para
      // qué token son).
      if (numero < 0) continue;
      actuales.add(tok);
    }
    cerrar();
    if (grupos.isEmpty) return <String>[];

    final salida = List<String>.filled(tokenCount, '');

    // ¿Numeración directa? Empieza en 1 y asciende de verdad: el grupo de
    // número `n` es la traducción del token `n-1`.
    var directo = grupos[0].key == 1;
    for (var k = 1; k < grupos.length; k++) {
      if (grupos[k].key <= grupos[k - 1].key) directo = false;
    }
    if (directo) {
      for (final grupo in grupos) {
        final slot = grupo.key - 1;
        if (slot >= 0 && slot < tokenCount) salida[slot] = grupo.value;
      }
      return salida;
    }

    // Numeración desalineada: mapeo proporcional best-effort (posición del
    // grupo k de `m` grupos en el espacio de `tokenCount` tokens).
    for (var k = 0; k < grupos.length; k++) {
      final slot = originalIndexForTranslated(
        translatedTokenIndex: k,
        originalCount: tokenCount,
        translatedCount: grupos.length,
      );
      salida[slot] = grupos[k].value;
    }
    return salida;
  }
}

/// Parte una línea en palabras conservando los separadores.
///
/// Devuelve una lista donde las palabras y los espacios van intercalados,
/// para poder reconstruir la línea exacta al renderizar.
List<String> splitWords(String line) {
  final parts = <String>[];
  final buf = StringBuffer();
  var inWord = false;
  for (final rune in line.runes) {
    final ch = String.fromCharCode(rune);
    final isSpace = ch.trim().isEmpty;
    if (isSpace) {
      if (inWord) {
        parts.add(buf.toString());
        buf.clear();
        inWord = false;
      }
      parts.add(ch);
    } else {
      if (!inWord && buf.isNotEmpty) {
        parts.add(buf.toString());
        buf.clear();
      }
      inWord = true;
      buf.write(ch);
    }
  }
  if (buf.isNotEmpty) parts.add(buf.toString());
  return parts;
}

/// Limpia una palabra de puntuación para traducirla.
String cleanWord(String word) {
  return word.replaceAll(RegExp(r'^[^\wáéíóúüñ¿¡]+', caseSensitive: false), '')
      .replaceAll(RegExp(r'[^\wáéíóúüñ]+$', caseSensitive: false), '')
      .trim();
}

/// Forma normalizada para comparar palabras (minúsculas, sin puntuación).
String normalizeToken(String word) => cleanWord(word).toLowerCase();

/// `true` si [part] (de [splitWords]) es una palabra y no un separador.
bool isWordPart(String part) => part.trim().isNotEmpty;

/// Solo las palabras de una línea, sin los espacios intermedios.
List<String> wordTokens(String line) {
  return [for (final p in splitWords(line)) if (isWordPart(p)) p];
}

/// Índice de paleta para la palabra original número [originalTokenIndex].
///
/// Las palabras originales se colorean en orden cíclico (0, 1, 2, 3, 0…):
/// cada color marca una "parte" de la línea.
int paletteIndexForOriginal(int originalTokenIndex, int paletteSize) {
  if (paletteSize <= 0) return 0;
  return originalTokenIndex % paletteSize;
}

/// A qué palabra original corresponde la palabra traducida número
/// [translatedTokenIndex] (aproximación por posición relativa).
///
/// Se usa como reserva cuando el alineador palabra-por-palabra
/// (`alignLineTokens` en `token_alignment.dart`) no encuentra emparejamiento
/// exacto: la palabra traducida en la fracción `j/m` se empareja con la
/// original en la misma fracción `i/n`.
///
/// Devuelve el índice en la lista de palabras originales (`wordTokens`).
int originalIndexForTranslated({
  required int translatedTokenIndex,
  required int originalCount,
  required int translatedCount,
}) {
  if (originalCount <= 0) return 0;
  if (translatedCount <= 0) return 0;
  final j = translatedTokenIndex.clamp(0, translatedCount - 1);
  final i = (j * originalCount) ~/ translatedCount;
  return i.clamp(0, originalCount - 1);
}

/// ¿Comparten raíz [a] y [b]?
///
/// Comparación barata de tallo para cazar flexiones que la coincidencia
/// exacta no ve: "cantan"/"cantar", "corriendo"/"correr",
/// "hermoso"/"hermosa", "sings"/"sing". Exige 4+ letras en común para no
/// juntar palabras cortas distintas ("la"/"las", "he"/"él" van por exacta).
bool sharesRoot(String a, String b) {
  if (a.isEmpty || b.isEmpty) return false;
  if (a == b) return true;
  if (a.length < 4 || b.length < 4) return false;
  var common = 0;
  final limit = a.length < b.length ? a.length : b.length;
  while (common < limit && a.codeUnitAt(common) == b.codeUnitAt(common)) {
    common++;
  }
  return common >= 4;
}
