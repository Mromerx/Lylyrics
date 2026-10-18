import 'dart:async';

import '../core/models/lyrics.dart';
import '../core/models/playback_state.dart';

/// Mantiene cuál es la línea de letra que toca en cada momento.
///
/// Diseño (decisiones conscientes, porque las alternativas también son
/// razonables):
///
/// * **Reloj interpolado**: MPRIS no emite la posición, solo la da junto a un
///   instante. Aquí se extrapola `posición = position + (ahora - timestamp) *
///   speed` mientras `isPlaying`, y se congela cuando está en pausa. Es
///   exactamente lo que hace [PlaybackState.positionAt], que ya recibe el
///   `now` como parámetro.
/// * **El offset se aplica a los TIEMPOS DE LÍNEA, no a la posición.** Así
///   [interpolatedPosition] sigue siendo la posición real de la pista (sirve
///   para la barra de progreso y para comparar con la duración) y el desfase
///   solo afecta a qué línea se resalta.
/// * **Las líneas vacías se emiten como índice normal.** Una pausa
///   instrumental es información: la UI la usa para atenuar/saltar. Por eso no
///   se filtran en ningún punto de este motor.
/// * **Sin letra o letra no sincronizada**: se emite `null` UNA vez y el motor
///   se calla hasta que haya algo que decir.
/// * **Solo se emite cuando el índice cambia**, nunca en cada tick.
///
/// Precisión: el tick por defecto son 100 ms, así que una línea se detecta
/// como mucho 100 ms tarde (más el redondeo del reloj, despreciable). El
/// objetivo de 150 ms está cubierto sin alargar el tick.
class SyncEngine {
  /// Crea el motor.
  ///
  /// [tickInterval] es la cadencia de comprobación (100 ms por defecto).
  /// [clock] existe para poder fijar el reloj en los tests: `fakeAsync`
  /// falsea los temporizadores pero **no** `DateTime.now()`, y sin un reloj
  /// inyectado las pruebas de interpolación no podrían ser deterministas.
  SyncEngine({
    Duration tickInterval = const Duration(milliseconds: 100),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       _controller = StreamController<int?>.broadcast() {
    // Un intervalo cero o negativo haría fallar Timer.periodic; 1 ms es el
    // suelo (solo se usa en pruebas raras).
    final interval = tickInterval <= Duration.zero
        ? const Duration(milliseconds: 1)
        : tickInterval;
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  final StreamController<int?> _controller;
  final DateTime Function() _clock;
  late final Timer _timer;

  PlaybackState? _state;
  Lyrics? _lyrics;

  /// [LyricLine] de [_lyrics] con el desfase ya aplicado. Vacía cuando no hay
  /// letra utilizable (null o no sincronizada), y es lo que consulta
  /// [indexAt].
  List<LyricLine> _effective = const <LyricLine>[];

  Duration _offset = Duration.zero;
  int? _currentIndex;

  /// Último valor realmente emitido, para no repetir. [_hasEmitted] hace
  /// falta porque `null` también es un valor emitible.
  int? _lastEmitted;
  bool _hasEmitted = false;

  bool _disposed = false;

  // ---------------------------------------------------------------------
  // API pública
  // ---------------------------------------------------------------------

  /// Recalibra con un estado de reproducción nuevo (seek, pausa, reanudar,
  /// cambio de velocidad) y emite el índice si ha cambiado.
  void update(PlaybackState state) {
    if (_disposed) return;
    _state = state;
    _emitIfChanged();
  }

  /// Cambia la letra, reinicia el desfase manual y recalibra.
  ///
  /// El índice recalculado se emite en el acto, para que la UI salte
  /// directamente a la línea correcta sin esperar al siguiente tick.
  ///
  /// OJO: pone [offset] a cero porque el desfase manual es POR CANCIÓN (lo
  /// guarda la UI en caché). Quien lo recupere debe llamar a [setOffset]
  /// después de [setLyrics].
  void setLyrics(Lyrics? lyrics) {
    if (_disposed) return;
    _lyrics = lyrics;
    _offset = Duration.zero;
    _rebuild();
    _emitIfChanged();
  }

  /// Desfase manual, en pasos de ±0,5 s desde la UI (persiste por canción en
  /// la UI o en caché). Acotado a ±10 s: más que eso no es un desfase, es un
  /// error de la letra.
  void setOffset(Duration offset) {
    if (_disposed) return;
    final clamped = offset < -maxOffset ? -maxOffset : offset;
    final bounded = clamped > maxOffset ? maxOffset : clamped;
    if (bounded == _offset) return;
    _offset = bounded;
    _rebuild();
    _emitIfChanged();
  }

  /// Desfase manual actual.
  Duration get offset => _offset;

  /// Tope del desfase manual (±10 s).
  static const Duration maxOffset = Duration(seconds: 10);

  /// Índice de la línea actual, o `null` si no hay letra sincronizada.
  ///
  /// Se emite como máximo una vez por cambio: con letra utilizable, un valor
  /// por línea (incluidas las vacías, para que la UI pueda atenuarlas); sin
  /// letra o sin sincronizar, un único `null` y silencio.
  Stream<int?> get lineIndexStream => _controller.stream;

  /// Índice de la línea que toca ahora mismo.
  ///
  /// Se recalcula en la lectura (búsqueda binaria, O(log n)), así que siempre
  /// está al día aunque no haya pasado ningún tick.
  int? get currentIndex {
    _recompute();
    return _currentIndex;
  }

  /// Posición real extrapolada (sin desfase aplicado).
  Duration get interpolatedPosition => _position();

  /// Letra cargada, o `null`.
  Lyrics? get lyrics => _lyrics;

  /// Último estado de reproducción recibido, o `null`.
  PlaybackState? get playbackState => _state;

  /// `true` si ya se ha llamado a [dispose].
  bool get isDisposed => _disposed;

  /// Cancela el timer y cierra el stream. Idempotente: llamarlo dos veces (o
  /// llamar a cualquier otro método después) no falla ni emite nada.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer.cancel();
    unawaited(_controller.close());
  }

  // ---------------------------------------------------------------------
  // Búsqueda
  // ---------------------------------------------------------------------

  /// Índice de la última línea con `time <= position`, o `null` si
  /// [position] es anterior a la primera línea (aún no ha empezado la letra).
  ///
  /// Búsqueda binaria pura: O(log n) y sin estado. [lines] DEBE venir
  /// ordenada por tiempo ascendente (lo garantiza `LrcParser.parse`). Con
  /// tiempos empatados devuelve la última de las empatadas, que es lo que
  /// espera la UI (la última gana).
  static int? indexAt(List<LyricLine> lines, Duration position) {
    if (lines.isEmpty) return null;
    if (position < lines.first.time) return null;

    // Invariante: todas las líneas de [0, low) tienen time <= position.
    var low = 0;
    var high = lines.length;
    while (low < high) {
      final mid = low + ((high - low) >> 1);
      if (lines[mid].time <= position) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    final index = low - 1;
    return index < 0 ? null : index;
  }

  // ---------------------------------------------------------------------
  // Interno
  // ---------------------------------------------------------------------

  /// Posición extrapolada con el reloj inyectado.
  Duration _position() {
    final state = _state;
    if (state == null) return Duration.zero;
    return state.positionAt(_clock());
  }

  /// Recalcula [_currentIndex] con la posición actual. Devuelve el índice
  /// (o `null` si no hay letra sincronizada o todavía no empezó).
  int? _recompute() {
    final position = _position();
    _currentIndex = _effective.isEmpty ? null : indexAt(_effective, position);
    return _currentIndex;
  }

  /// Reaplica el desfase a los tiempos de línea. Se llama solo cuando cambian
  /// la letra o el offset.
  void _rebuild() {
    final lines = _lyrics?.lines;
    final synced = _lyrics?.isSynced ?? false;
    if (!synced || lines == null || lines.isEmpty) {
      _effective = const <LyricLine>[];
      return;
    }
    if (_offset == Duration.zero) {
      _effective = List<LyricLine>.unmodifiable(lines);
      return;
    }
    _effective = List<LyricLine>.unmodifiable([
      for (final line in lines)
        LyricLine(time: line.time + _offset, text: line.text),
    ]);
  }

  /// Recalcula y emite SOLO si el índice ha cambiado. Con letra no
  /// sincronizada esto significa: un `null` y silencio.
  void _emitIfChanged() {
    final index = _recompute();
    if (_disposed) return;
    if (_hasEmitted && index == _lastEmitted) return;
    _hasEmitted = true;
    _lastEmitted = index;
    if (!_controller.isClosed) _controller.add(index);
  }

  void _tick() {
    if (_disposed) return;
    _emitIfChanged();
  }
}
