import 'translation_service.dart';

/// Enlace entre una palabra traducida y su palabra original.
///
/// A diferencia del antiguo `Map<int, int>`, aquí cada enlace lleva su
/// nivel de confianza: la UI puede pintar distinto los enlaces de raíz
/// (más dudosos) que los de igualdad/contención.
class TokenLink {
  const TokenLink({required this.originalIndex, required this.tier});

  /// Índice en [wordTokens] de la línea ORIGINAL con la que enlaza.
  final int originalIndex;

  /// Nivel de evidencia del enlace: `2` = igualdad o contención en el
  /// léxico (traducción aislada, frase o sentido); `1` = raíz común
  /// ([sharesRoot], flexiones morfológicas).
  final int tier;

  @override
  bool operator ==(Object other) =>
      other is TokenLink &&
      other.originalIndex == originalIndex &&
      other.tier == tier;

  @override
  int get hashCode => Object.hash(originalIndex, tier);

  @override
  String toString() => 'TokenLink($originalIndex, tier $tier)';
}

/// Vocabulario de frases para el servicio de traducción: unigramas,
/// bigramas y trigramas de [originalTokens].
///
/// Toda frase se devuelve NORMALIZADA ([normalizeToken]) y con sus tokens
/// unidos por UN espacio (por ejemplo `give up`, `up everything`,
/// `give up everything`), para usarla como clave en `wordMap`.
/// Regla anti-ruido universal: una frase de DOS o MÁS palabras cuyos
/// tokens normalizados sean TODOS de <= 2 letras no se incluye
/// (evita pedir al traductor `to be`, `of it`, etc.). Los unigramas
/// entran siempre.
Set<String> phraseVocabulary(List<String> originalTokens) {
  final out = <String>{};
  final norm = [for (final t in originalTokens) normalizeToken(t)];

  // Ventana normalizada [desde .. hasta] (inclusive): si algún token del
  // tramo queda vacío (pura puntuación), la frase cruza ese hueco y no vale.
  void agregar(int desde, int hasta) {
    if (desde < 0 || hasta >= norm.length || desde > hasta) return;
    final buf = <String>[];
    var cortos = 0;
    for (var k = desde; k <= hasta; k++) {
      final t = norm[k];
      if (t.isEmpty) return;
      if (t.length <= 2) cortos++;
      buf.add(t);
    }
    // Multi-palabra hecha solo de tokens ultra cortos: fuera.
    if (buf.length > 1 && cortos == buf.length) return;
    out.add(buf.join(' '));
  }

  for (var i = 0; i < norm.length; i++) {
    agregar(i, i); // unigrama
    agregar(i, i + 1); // bigrama hacia delante
    agregar(i - 1, i); // bigrama hacia atrás (redundante con el de i-1; explícito por cobertura)
    agregar(i, i + 2); // trigrama deslizante
  }
  return out;
}

/// Palabras normalizadas de un texto suelto (traducción o sentido).
List<String> _palabras(String texto) {
  final out = <String>[];
  for (final parte in wordTokens(texto)) {
    final norm = normalizeToken(parte);
    if (norm.isNotEmpty) out.add(norm);
  }
  return out;
}

/// Solo los caracteres "de palabra" de [token], en minúsculas: es la forma
/// desnuda con la que se arman las cadenas globales para ubicar segmentos
/// (quita puntuación intermedia también, así `don't` se compara como
/// `dont` y coincide con el strip aplicado a `segment.source`).
String _desnudo(String token) {
  final letra = RegExp(r'[0-9A-Za-z_ÁÉÍÓÚÜÑáéíóúüñ]');
  final buf = StringBuffer();
  for (final rune in token.runes) {
    final ch = String.fromCharCode(rune);
    if (letra.hasMatch(ch)) buf.write(ch.toLowerCase());
  }
  return buf.toString();
}

/// Nivel de evidencia de enlazar el original normalizado [norm] (cuyo
/// léxico es [parts]) con la traducción normalizada [t].
///
/// * `2`: igualdad directa, o contención — [t] es una de las palabras del
///   léxico (traducción aislada, frases o sentidos).
/// * `1`: alguna parte del léxico comparte raíz con [t] ([sharesRoot]).
/// * `0`: sin evidencia.
///
/// REGLA anti-ruido de longitud: para originales cortos (norm <= 3 letras)
/// el tier 2 solo sale por igualdad directa; su léxico suele ser ambiguo
/// ("no", "el", "the") y la contención atraería basura ajena.
int _tierDe(String norm, Set<String> parts, String t) {
  if (norm.isEmpty || t.isEmpty) return 0;
  if (norm == t) return 2;
  if (norm.length <= 3) {
    // El tier 2 por contención ya quedó vetado arriba, y la subida por
    // raíz no debe poder simular contención (sharesRoot da `true` cuando
    // p == t), así que se salta esa parte del léxico.
    for (final p in parts) {
      if (p != t && sharesRoot(p, t)) return 1;
    }
    return 0;
  }
  if (parts.contains(t)) return 2;
  for (final p in parts) {
    if (sharesRoot(p, t)) return 1;
  }
  return 0;
}

/// Cadena global de una línea y el rango de caracteres que ocupa cada token.
class _CadenaDesnuda {
  const _CadenaDesnuda(this.texto, this.comienzos, this.fines);

  final String texto;
  final List<int> comienzos;
  final List<int> fines;

  /// Token cuyo rango de caracteres contiene [pos] (-1 si no cae en nadie).
  int tokenEn(int pos) {
    for (var i = 0; i < comienzos.length; i++) {
      if (pos >= comienzos[i] && pos < fines[i]) return i;
    }
    return -1;
  }
}

_CadenaDesnuda _encadenar(List<String> tokens) {
  final buf = StringBuffer();
  final comienzos = <int>[];
  final fines = <int>[];
  for (final t in tokens) {
    final desn = _desnudo(t);
    comienzos.add(buf.length);
    buf.write(desn);
    fines.add(buf.length);
  }
  return _CadenaDesnuda(buf.toString(), comienzos, fines);
}

/// Segmento alineado de verdad: `[i0..i1)` tokens del original
/// corresponden a `[j0..j1)` tokens de la traducción.
class _SegmentoReal {
  const _SegmentoReal(this.i0, this.i1, this.j0, this.j1);
  final int i0;
  final int i1;
  final int j0;
  final int j1;
}

/// Ubica cada [TextSegment] sobre su línea (original y traducción) para
/// saber qué tokens cubre cada lado.
///
/// La búsqueda es `indexOf` con puntero acumulado para respetar el orden
/// de los segmentos; si falla (segmentos que llegan en otro orden), se
/// reintenta sobre la línea entera, y si aun así no aparece, el segmento
/// se descarta y sus tokens vuelven al prior de línea completa.
List<_SegmentoReal> _alinearSegmentos(
  List<TextSegment> segments,
  _CadenaDesnuda original,
  _CadenaDesnuda traducida,
  int n,
  int m,
) {
  final out = <_SegmentoReal>[];
  var punteroO = 0;
  var punteroT = 0;
  for (final seg in segments) {
    final src = _desnudo(seg.source);
    final tgt = _desnudo(seg.target);
    if (src.isEmpty || tgt.isEmpty) continue;

    var p = original.texto.indexOf(src, punteroO);
    if (p < 0) p = original.texto.indexOf(src);
    if (p < 0) continue;
    final i0 = original.tokenEn(p);
    final i1 = original.tokenEn(p + src.length - 1) + 1;
    if (i0 < 0 || i1 <= i0 || i1 > n) continue;
    punteroO = p + src.length - 1;

    var q = traducida.texto.indexOf(tgt, punteroT);
    if (q < 0) q = traducida.texto.indexOf(tgt);
    if (q < 0) continue;
    final j0 = traducida.tokenEn(q);
    final j1 = traducida.tokenEn(q + tgt.length - 1) + 1;
    if (j0 < 0 || j1 <= j0 || j1 > m) continue;
    punteroT = q + tgt.length - 1;

    out.add(_SegmentoReal(i0, i1, j0, j1));
  }
  return out;
}

/// Alinea cada palabra traducida con su palabra original REAL, con nivel
/// de confianza ([TokenLink.tier]).
///
/// Pipeline:
/// 1. **Léxico**: se arma, para cada token original, el conjunto de
///   palabras que puede llegar a generar en la traducción
///   (`phraseParts`): su traducción aislada en [wordMap] partida en
///   tokens, todos los sentidos de [senseMap], y —si el token participa
///   en una FRASE del vocabulario con traducción en [wordMap]— los tokens
///   de esa traducción (así `give up`→`rendirse` vincula a `give` Y a
///   `up`). A partir de ahí se puntúa cada par (original i, traducida j)
///   en dos tiers de evidencia (ver [_tierDe]).
/// 2. **Prior posicional por segmentos**: si [segments] trae pares
///   `source`/`target` de esta línea, se ubican como rangos de tokens y la
///   posición relativa de cada palabra se mide DENTRO de su segmento, lo
///   que orienta el alineado aunque las partes del par estén lejos. Sin
///   segmento, se usa la fracción relativa en la línea entera.
/// 3. **DP global** en lugar de greedy: programación dinámica sobre
///   (original i, traducida j) con movimientos `match`, `swap` (par de
///   dos invertido, para adjetivo+sustantivo tipo
///   `beautiful world` <-> `mundo hermoso`), `derrame de frase` (una
///   original con traducción de dos palabras cubre dos traducidas
///   consecutivas, siempre que su traducción aislada tenga 2+ tokens) y
///   los dos `skip`. Garantiza que cada palabra traducida pinta a lo sumo
///   una original y que no haya cruces salvo el swap/derrame explícito.
///
/// Devuelve `índice traducida -> [TokenLink]` SOLO con los enlaces de
/// evidencia (tier 1 o 2) que superan el umbral; el resto, la UI lo
/// resuelve con la reserva posicional
/// ([originalIndexForTranslated]).
Map<int, TokenLink> alignLineTokens({
  required List<String> originalTokens,
  required List<String> translatedTokens,
  required Map<String, String> wordMap,
  required Map<String, Set<String>> senseMap,
  List<TextSegment> segments = const [],
}) {
  final n = originalTokens.length;
  final m = translatedTokens.length;
  if (n == 0 || m == 0) return {};

  final origNorm = [for (final t in originalTokens) normalizeToken(t)];
  final transNorm = [for (final t in translatedTokens) normalizeToken(t)];

  // ---- 1. Léxico (phraseParts por token original, sin diccionarios) ----
  final parts = <String, Set<String>>{};
  for (var i = 0; i < n; i++) {
    final key = origNorm[i];
    if (key.isEmpty || parts.containsKey(key)) continue;
    final set = <String>{key};
    final solo = wordMap[key];
    if (solo != null) set.addAll(_palabras(solo));
    final sentidos = senseMap[key];
    if (sentidos != null) {
      for (final sentido in sentidos) {
        set.addAll(_palabras(sentido));
      }
    }
    parts[key] = set;
  }
  // Frases del vocabulario: su traducción entra en el léxico de cada
  // token participante (buscando la ventana EXACTA en la línea).
  for (final frase in phraseVocabulary(originalTokens)) {
    if (!frase.contains(' ')) continue;
    final traduccion = wordMap[frase];
    if (traduccion == null) continue;
    final toks = _palabras(traduccion);
    if (toks.isEmpty) continue;
    final piezas = frase.split(' ');
    for (var i = 0; i + piezas.length <= n; i++) {
      var calza = true;
      for (var k = 0; k < piezas.length; k++) {
        if (origNorm[i + k] != piezas[k]) {
          calza = false;
          break;
        }
      }
      if (!calza) continue;
      for (var k = 0; k < piezas.length; k++) {
        parts[origNorm[i + k]]?.addAll(toks);
      }
    }
  }

  // ---- 2. Prior posicional (relativa por segmento o por línea) ----
  final segO = _alinearSegmentos(
      segments, _encadenar(originalTokens), _encadenar(translatedTokens), n, m);
  final segDeO = List<_SegmentoReal?>.filled(n, null);
  final segDeJ = List<_SegmentoReal?>.filled(m, null);
  for (final seg in segO) {
    for (var i = seg.i0; i < seg.i1; i++) {
      segDeO[i] ??= seg;
    }
    for (var j = seg.j0; j < seg.j1; j++) {
      segDeJ[j] ??= seg;
    }
  }
  double fraccion(int idx, int largo) {
    if (largo <= 0) return 0;
    return idx / largo;
  }

  final relO = <double>[];
  for (var i = 0; i < n; i++) {
    final seg = segDeO[i];
    relO.add(seg == null
        ? fraccion(i, n)
        : fraccion(i - seg.i0, seg.i1 - seg.i0));
  }
  final relT = <double>[];
  for (var j = 0; j < m; j++) {
    final seg = segDeJ[j];
    relT.add(seg == null
        ? fraccion(j, m)
        : fraccion(j - seg.j0, seg.j1 - seg.j0));
  }

  // Puntaje de un match (tier + bonus posicional); -1 si no es viable.
  int tierDe(int i, int j) =>
      _tierDe(origNorm[i], parts[origNorm[i]] ?? const <String>{}, transNorm[j]);
  double scoreDe(int i, int j) {
    final tier = tierDe(i, j);
    if (tier <= 0) return -1;
    final s = (tier == 2 ? 10.0 : 5.0) + 6.0 * (1 - (relO[i] - relT[j]).abs());
    return s >= 4.0 ? s : -1; // umbral: descarta evidencias débiles
  }

  // ---- 3. DP global (match / swap / derrame / skips) ----
  // Códigos de movimiento (el orden evalúa empates: se queda el primero).
  const coMatch = 1, coSwap = 2, coDerrame = 3, coSkipO = 4, coSkipT = 5;
  final w = m + 1;
  final dp = List<double>.filled((n + 1) * w, 0);
  final sel = List<int>.filled((n + 1) * w, 0);
  int ca(int i, int j) => i * w + j;
  const eps = 1e-9;

  for (var i = n; i >= 0; i--) {
    for (var j = m; j >= 0; j--) {
      if (i == n && j == m) continue; // dp = 0 por defecto
      var mejor = double.negativeInfinity;
      var movimiento = 0;
      void considerar(double cand, int codigo) {
        if (cand > mejor + eps) {
          mejor = cand;
          movimiento = codigo;
        }
      }

      if (i < n && j < m) {
        final s = scoreDe(i, j);
        if (s > 0) {
          considerar(s + dp[ca(i + 1, j + 1)], coMatch);
        }
        if (i + 1 < n && j + 1 < m) {
          final sa = scoreDe(i, j + 1);
          final sb = scoreDe(i + 1, j);
          if (sa > 0 && sb > 0) {
            considerar(sa + sb - 2.0 + dp[ca(i + 2, j + 2)], coSwap);
          }
        }
      }
      if (i < n && j + 1 < m) {
        // Derrame de frase: el MISMO original cubre dos traducidas
        // seguidas; solo si su traducción aislada acarrea 2+ tokens.
        final mapa = wordMap[origNorm[i]];
        if (mapa != null && _palabras(mapa).length >= 2) {
          final s1 = scoreDe(i, j);
          final s2 = scoreDe(i, j + 1);
          if (s1 > 0 && s2 > 0) {
            considerar(s1 + s2 + dp[ca(i + 1, j + 2)], coDerrame);
          }
        }
      }
      if (i < n) considerar(dp[ca(i + 1, j)] - 2.5, coSkipO);
      if (j < m) considerar(dp[ca(i, j + 1)] - 2.5, coSkipT);

      dp[ca(i, j)] = mejor;
      sel[ca(i, j)] = movimiento;
    }
  }

  // Reconstrucción: se emiten solo los matches (ya todos pasaron el umbral).
  final out = <int, TokenLink>{};
  var i = 0;
  var j = 0;
  while (i < n && j < m) {
    final movimiento = sel[ca(i, j)];
    if (movimiento == coMatch) {
      out[j] = TokenLink(originalIndex: i, tier: tierDe(i, j));
      i++;
      j++;
    } else if (movimiento == coSwap) {
      out[j + 1] = TokenLink(originalIndex: i, tier: tierDe(i, j + 1));
      out[j] = TokenLink(originalIndex: i + 1, tier: tierDe(i + 1, j));
      i += 2;
      j += 2;
    } else if (movimiento == coDerrame) {
      final tier = tierDe(i, j);
      out[j] = TokenLink(originalIndex: i, tier: tier);
      out[j + 1] = TokenLink(originalIndex: i, tier: tierDe(i, j + 1));
      i++;
      j += 2;
    } else if (movimiento == coSkipO) {
      i++;
    } else if (movimiento == coSkipT) {
      j++;
    } else {
      i++;
      j++;
    }
  }
  return out;
}
