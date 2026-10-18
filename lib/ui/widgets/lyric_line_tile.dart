import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/token_alignment.dart';
import '../../services/translation_service.dart';
import '../../state/providers/app_providers.dart';

/// Cómo se ve una línea de letra respecto a la línea actual.
enum LyricLineStyle {
  /// Antes de la actual: atenuada.
  past,

  /// La línea resaltada.
  current,

  /// Después de la actual: atenuada.
  future,

  /// Letra sin sincronizar: se muestra entera, sin atenuar ni resaltar.
  plain,

  /// Hueco de pausa instrumental.
  blank,
}

const double _nonCurrentLineScale = 0.92;
const double _translationScale = 0.72;
const double _lineHeight = 1.35;

/// Paleta pastel con un tono DISTINTO por palabra de la línea.
///
/// Se genera una por línea con el ángulo dorado (137,5°): por muchas palabras
/// que tenga la línea, ninguna repite tono. Cada palabra del original lleva
/// su color, y cada palabra de la traducción lleva el color de la palabra
/// original de la que viene.
List<Color> wordPalette(int count) {
  if (count <= 0) return const <Color>[];
  return [
    for (var i = 0; i < count; i++)
      HSLColor.fromAHSL(1.0, (i * 137.508) % 360.0, 0.7, 0.78).toColor(),
  ];
}

/// Una línea de letra con su traducción debajo.
///
/// Interacción:
/// * Clic izquierdo / toque en la línea → salta la canción a ese segundo
///   ([onSeek], puede ser `null` si no hay a dónde saltar).
/// * Clic derecho (escritorio) / mantener pulsado (Android) sobre una
///   palabra original → su traducción exacta al español en un diálogo.
/// * Clic derecho / mantener pulsado sobre una palabra traducida → muestra
///   a qué parte del original corresponde (aprox.).
class LyricLineTile extends StatelessWidget {
  const LyricLineTile({
    super.key,
    required this.text,
    required this.style,
    required this.fontSize,
    this.translation,
    this.onSeek,
    this.colorWords = true,
    this.wordLinks,
  });

  final String text;
  final LyricLineStyle style;
  final double fontSize;

  /// Traducción al español de toda la línea (una sola petición por canción,
  /// repartida con un `for` en el provider). `null` = sin traducir / ya es
  /// español / línea vacía.
  final String? translation;

  /// Salto a este segundo de la canción. `null` = no se puede saltar
  /// (letra sin sincronizar o sin reproductor).
  final VoidCallback? onSeek;

  /// `false` = palabras sin colorear (solo texto).
  final bool colorWords;

  /// Emparejamiento REAL de ESTA línea, `orden traducido -> TokenLink`
  /// (ver `songWordLinksProvider`). Lo que no venga aquí usa la reserva
  /// posicional y se etiqueta como "aprox."; lo que venga con `tier == 1`
  /// (raíz común) se pinta atenuado y también se etiqueta "aprox.".
  final Map<int, TokenLink>? wordLinks;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final bool isCurrent = style == LyricLineStyle.current;
    // Letra sin sincronizar: ninguna línea es "la actual", así que no se
    // atenúa ninguna (se vería todo opaco).
    final bool isPlain = style == LyricLineStyle.plain;
    final bool isBlank = style == LyricLineStyle.blank;
    if (isBlank || text.trim().isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
        child: SizedBox(height: fontSize * _nonCurrentLineScale * _lineHeight),
      );
    }

    final Color color;
    if (isCurrent || isPlain) {
      color = scheme.onSurface;
    } else {
      color = scheme.onSurface.withValues(alpha: 0.35);
    }

    // La línea actual crece un poco y las demás se encogen; la letra sin
    // sincronizar no resalta, se queda a tamaño normal.
    final double scale = isCurrent || isPlain ? 1.0 : _nonCurrentLineScale;
    final FontWeight weight = isCurrent ? FontWeight.w700 : FontWeight.w500;

    final lineStyle = TextStyle(
      color: color,
      fontSize: fontSize * scale,
      fontWeight: weight,
      height: _lineHeight,
      letterSpacing: 0.1,
    );
    // Misma fuente que el original: se distingue por tamaño, itálica y
    // color atenuado.
    final translationStyle = TextStyle(
      color: isCurrent || isPlain
          ? scheme.onSurfaceVariant
          : scheme.onSurfaceVariant.withValues(alpha: 0.6),
      fontSize: fontSize * scale * _translationScale,
      fontStyle: FontStyle.italic,
      height: 1.3,
    );

    final translationText = translation?.trim() ?? '';

    // Correspondencia por posición: la palabra traducida j/m se pinta con el
    // color de la original i/n. Ver `originalIndexForTranslated`.
    final parts = splitWords(text);
    final translatedParts = translationText.isEmpty
        ? const <String>[]
        : splitWords(translationText);
    final originalTokens = [
      for (final p in parts)
        if (isWordPart(p)) p,
    ];
    final translatedTokens = [
      for (final p in translatedParts)
        if (isWordPart(p)) p,
    ];
    // Un tono por palabra: imposible que se repita en la misma línea.
    final palette = wordPalette(originalTokens.length);

    final Widget content = AnimatedDefaultTextStyle(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      style: lineStyle,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Original palabra por palabra: el clic derecho / mantener pulsado
          // sabe exactamente sobre qué palabra se hizo. Los separadores se
          // pintan como texto real (no un ancho fijo) para que el espacio
          // entre palabras sea el normal de la fuente.
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final entry in parts.asMap().entries)
                if (!isWordPart(entry.value))
                  Text(entry.value, style: lineStyle, softWrap: false)
                else
                  _Word(
                    word: entry.value,
                    style: lineStyle,
                    background: _backgroundFor(
                      _tokenOrderBefore(parts, entry.key),
                      isCurrent,
                      palette,
                    ),
                    onTap: onSeek,
                    onWordAction: () =>
                        showWordTranslation(context, entry.value),
                  ),
            ],
          ),
          if (translationText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: colorWords
                  ? Wrap(
                      alignment: WrapAlignment.center,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        for (final entry in translatedParts.asMap().entries)
                          if (!isWordPart(entry.value))
                            Text(
                              entry.value,
                              style: translationStyle,
                              softWrap: false,
                            )
                          else
                            _translatedWord(
                              context: context,
                              part: entry.value,
                              order: _tokenOrderBefore(
                                translatedParts,
                                entry.key,
                              ),
                              originalTokens: originalTokens,
                              translatedCount: translatedTokens.length,
                              style: translationStyle,
                              isCurrent: isCurrent,
                              palette: palette,
                            ),
                      ],
                    )
                  : GestureDetector(
                      onTap: onSeek,
                      behavior: HitTestBehavior.opaque,
                      child: Text(
                        translationText,
                        textAlign: TextAlign.center,
                        softWrap: true,
                        style: translationStyle,
                      ),
                    ),
            ),
        ],
      ),
    );

    return Semantics(
      label: translationText.isEmpty ? text : '$text. $translationText',
      button: onSeek != null,
      child: GestureDetector(
        // Tocar en los huecos entre palabras también salta.
        onTap: onSeek,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          // Separación entre líneas originales; la traducción va pegada a
          // su línea (ver el `top: 2` de arriba) y no se ve afectada.
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
          child: content,
        ),
      ),
    );
  }

  /// Cuántas palabras hay antes de la posición [partIndex] en [parts].
  int _tokenOrderBefore(List<String> parts, int partIndex) {
    var order = 0;
    for (var k = 0; k < partIndex && k < parts.length; k++) {
      if (isWordPart(parts[k])) order++;
    }
    return order;
  }

  /// Fondo pastel para la palabra original número [tokenOrder], o `null` si
  /// el coloreado está apagado. Un punto más intenso que la traducción, sin
  /// pasarse.
  Color? _backgroundFor(int tokenOrder, bool isCurrent, List<Color> palette) {
    if (!colorWords || palette.isEmpty) return null;
    final base = palette[tokenOrder.clamp(0, palette.length - 1)];
    return base.withValues(alpha: isCurrent ? 0.6 : 0.3);
  }

  /// Palabra de la traducción con el color de la palabra original de la que
  /// viene (enlace real de [wordLinks], o reserva posicional); el clic
  /// derecho / mantener pulsado muestra cuál es.
  Widget _translatedWord({
    required BuildContext context,
    required String part,
    required int order,
    required List<String> originalTokens,
    required int translatedCount,
    required TextStyle style,
    required bool isCurrent,
    required List<Color> palette,
  }) {
    // Enlace real si lo hay; si no, la reserva posicional.
    final link = wordLinks?[order];
    final originalIndex =
        link?.originalIndex ??
        originalIndexForTranslated(
          translatedTokenIndex: order,
          originalCount: originalTokens.length,
          translatedCount: translatedCount,
        );
    final base = palette.isEmpty
        ? Colors.transparent
        : palette[originalIndex.clamp(0, palette.length - 1)];
    final corresponding = originalTokens.isEmpty
        ? ''
        : originalTokens[originalIndex.clamp(0, originalTokens.length - 1)];
    // Confianza en la UI: un enlace por raíz común (tier 1) es menos fiable
    // que una igualdad/contención (tier 2), y la reserva posicional es la
    // menos fiable de todas. Solo el tier 2 se llama "exacto".
    final confident = link != null && link.tier >= 2;
    final alphaFactor = !confident ? 0.7 : 1.0;
    return _Word(
      word: part,
      style: style,
      // Mismo fondo que el original: la que distingue es la letra gris.
      // Los enlaces de raíz (menos fiables) van atenuados.
      background: base.withValues(
        alpha: (isCurrent ? 0.45 : 0.22) * alphaFactor,
      ),
      onTap: onSeek,
      onWordAction: () =>
          showCorrespondence(context, part, corresponding, exact: confident),
    );
  }

  /// Muestra la traducción exacta de [rawWord] al español.
  static Future<void> showWordTranslation(
    BuildContext context,
    String rawWord,
  ) async {
    final clean = cleanWord(rawWord);
    if (clean.isEmpty) return;
    // ignore: use_build_context_synchronously
    if (!context.mounted) return;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => _WordDialog(word: clean),
    );
  }

  /// Muestra a qué palabra del original corresponde una palabra traducida.
  static Future<void> showCorrespondence(
    BuildContext context,
    String translatedWord,
    String originalWord, {
    bool exact = false,
  }) async {
    if (!context.mounted) return;
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(translatedWord.trim(), textAlign: TextAlign.center),
        content: originalWord.isEmpty
            ? const Text('No correspondence.', textAlign: TextAlign.center)
            : Text(
                exact
                    ? 'Corresponds to “$originalWord” in the original.'
                    : 'Approximately corresponds to “$originalWord” in the original.',
                textAlign: TextAlign.center,
              ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

/// Una palabra con sus gestos.
///
/// * `onTap` (clic izquierdo / toque): salta la canción al segundo de la
///   línea — es el mismo destino para todas las palabras de la línea.
/// * `onSecondaryTapUp` (clic derecho, escritorio) y `onLongPress`
///   (mantener pulsado, Android): acción de ESTA palabra.
class _Word extends StatelessWidget {
  const _Word({
    required this.word,
    required this.style,
    required this.onTap,
    required this.onWordAction,
    this.background,
  });

  final String word;
  final TextStyle style;
  final VoidCallback? onTap;
  final VoidCallback onWordAction;

  /// Fondo pastel que marca la correspondencia. `null` = sin colorear.
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final text = Text(word, style: style, softWrap: false);
    final clickable = onTap != null;
    final child = background == null
        ? Padding(padding: const EdgeInsets.symmetric(vertical: 1), child: text)
        : Container(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
            margin: EdgeInsets.zero,
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(6),
            ),
            child: text,
          );
    return MouseRegion(
      cursor: clickable ? SystemMouseCursors.click : MouseCursor.defer,
      child: GestureDetector(
        onTap: onTap,
        // Clic derecho en escritorio.
        onSecondaryTapUp: (_) => onWordAction(),
        // Mantener pulsado en Android = clic derecho.
        onLongPress: onWordAction,
        behavior: HitTestBehavior.opaque,
        child: child,
      ),
    );
  }
}

/// Diálogo con la traducción exacta de una palabra.
class _WordDialog extends ConsumerStatefulWidget {
  const _WordDialog({required this.word});

  final String word;

  @override
  ConsumerState<_WordDialog> createState() => _WordDialogState();
}

class _WordDialogState extends ConsumerState<_WordDialog> {
  late final Future<String?> _future;

  @override
  void initState() {
    super.initState();
    final target =
        ref.read(appSettingsProvider).get(Settings.translationTarget);
    _future = ref
        .read(translationServiceProvider)
        .translateWord(widget.word, target: target);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.word, textAlign: TextAlign.center),
      content: FutureBuilder<String?>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const SizedBox(
              height: 48,
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final translated = snapshot.data;
          if (translated == null || translated.isEmpty) {
            return const Text(
              'No translation (it is already in the target language or it '
              'could not be translated).',
              textAlign: TextAlign.center,
            );
          }
          return Text(
            translated,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          );
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
