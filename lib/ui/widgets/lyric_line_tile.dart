import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Cómo se ve una línea de letra respecto a la línea actual.
enum LyricLineStyle {
  /// Antes de la actual: atenuada.
  past,

  /// La línea resaltada.
  current,

  /// Después de la actual: atenuada.
  future,

  /// Hueco de pausa instrumental.
  blank,
}

/// Una línea de letra con su estilo visual resuelto.
///
/// No controla la reproducción: un clic solo copia el texto, que es lo que
/// pidió el diseño para no interferir con el reproductor.
class LyricLineTile extends StatelessWidget {
  const LyricLineTile({
    super.key,
    required this.text,
    required this.style,
    required this.fontSize,
  });

  final String text;
  final LyricLineStyle style;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final bool isCurrent = style == LyricLineStyle.current;
    final bool isBlank = style == LyricLineStyle.blank;

    final Color color;
    if (isBlank) {
      // Un hueco instrumental no tiene color propio, solo respiro.
      color = Colors.transparent;
    } else if (isCurrent) {
      color = scheme.onSurface;
    } else {
      color = scheme.onSurface.withValues(alpha: 0.35);
    }

    // La línea actual crece un poco y la anterior se encoge: el cambio se
    // nota sin necesidad de un indicador extra.
    final double scale = isCurrent ? 1.0 : 0.92;
    final FontWeight weight = isCurrent ? FontWeight.w700 : FontWeight.w500;

    final Widget content = AnimatedDefaultTextStyle(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      style: TextStyle(
        color: color,
        fontSize: fontSize * scale,
        fontWeight: weight,
        height: 1.35,
        letterSpacing: 0.1,
      ),
      child: isBlank
          ? const SizedBox(height: 24)
          : Text(
              text,
              textAlign: TextAlign.center,
              softWrap: true,
            ),
    );

    return Semantics(
      label: text,
      button: !isBlank,
      child: GestureDetector(
        onTap: isBlank ? null : () => _copy(context, text),
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: content,
        ),
      ),
    );
  }

  void _copy(BuildContext context, String value) {
    unawaitedCopy(value);
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text('Copiado: $value'),
          duration: const Duration(milliseconds: 1200),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }
}

/// Copia al portapapeles sin propagar errores al llamador.
void unawaitedCopy(String value) {
  // ignore: discarded_futures
  Clipboard.setData(ClipboardData(text: value)).catchError((_) {});
}