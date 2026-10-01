/// Una línea de letra con su marca de tiempo.
class LyricLine {
  const LyricLine({required this.time, required this.text});

  /// Tiempo de inicio de la línea.
  final Duration time;

  /// Texto de la línea. Puede estar vacío para representar una pausa
  /// instrumental, y esos vacíos se conservan a propósito.
  final String text;

  /// Una línea vacía no se muestra, pero sí ocupa su hueco temporal.
  bool get isBlank => text.trim().isEmpty;

  @override
  bool operator ==(Object other) =>
      other is LyricLine && other.time == time && other.text == text;

  @override
  int get hashCode => Object.hash(time, text);

  @override
  String toString() => 'LyricLine(${time.inMilliseconds}ms, "$text")';
}

/// Letra completa de una canción.
class Lyrics {
  const Lyrics({
    required this.lines,
    required this.isSynced,
    this.plainText,
    this.instrumental = false,
  });

  /// Líneas parseadas. Para letra no sincronizada se devuelve una única
  /// línea [LyricLine] con `time = Duration.zero` por cada línea del texto,
  /// para que la UI pueda usar el mismo renderer.
  final List<LyricLine> lines;

  /// `true` si las líneas tienen marcas de tiempo utilizables.
  final bool isSynced;

  /// Texto plano tal cual lo devuelve LRCLIB, si existe.
  final String? plainText;

  /// `true` si la fuente marcó la pista como instrumental.
  final bool instrumental;

  /// Líneas con texto real (excluye pausas vacías).
  List<LyricLine> get visibleLines =>
      lines.where((l) => !l.isBlank).toList(growable: false);

  factory Lyrics.fromPlain(String text, {bool instrumental = false}) {
    final raw = text.replaceAll('\r\n', '\n').split('\n');
    return Lyrics(
      lines: [
        for (final line in raw)
          LyricLine(time: Duration.zero, text: line.trimRight()),
      ],
      isSynced: false,
      plainText: text,
      instrumental: instrumental,
    );
  }

  @override
  String toString() => 'Lyrics(lines: ${lines.length}, '
      'synced: $isSynced, instrumental: $instrumental)';
}