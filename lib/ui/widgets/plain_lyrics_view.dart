import 'package:flutter/material.dart';

import '../../core/models/lyrics.dart';
import '../../services/token_alignment.dart';
import 'lyric_line_tile.dart';

/// Letra no sincronizada: texto plano con scroll libre y traducción debajo.
class PlainLyricsView extends StatelessWidget {
  const PlainLyricsView({
    super.key,
    required this.lyrics,
    required this.fontSize,
    this.translations = const {},
    this.colorWords = true,
    this.wordLinks = const {},
    this.label,
  });

  final Lyrics lyrics;
  final double fontSize;
  final Map<int, String> translations;
  final bool colorWords;
  final Map<int, Map<int, TokenLink>> wordLinks;

  /// Cabecera del panel. `null` usa el texto por defecto.
  final String? label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scrollbar(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: Text(
                  label ?? 'Unsynced lyrics',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            // Se itera sobre `lyrics.lines` con el índice REAL: las
            // traducciones y los enlaces están keyed por ese índice, aunque
            // las líneas vacías se oculten visualmente.
            for (var i = 0; i < lyrics.lines.length; i++)
              if (!lyrics.lines[i].isBlank)
                LyricLineTile(
                  text: lyrics.lines[i].text,
                  translation: translations[i],
                  fontSize: fontSize,
                  style: LyricLineStyle.plain,
                  colorWords: colorWords,
                  wordLinks: wordLinks[i],
                ),
          ],
        ),
      ),
    );
  }
}
